// Package config reads the SFU settings from flags and the environment.
package config

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// DefaultRelays match the app's defaults, so a fresh server and a fresh app
// share relays without any setup.
const DefaultRelays = "wss://relay.damus.io,wss://nos.lol,wss://relay.primal.net"

type Config struct {
	Relays         []string
	DataDir        string
	PublicIP       string
	TURNPort       int
	UDPPortMin     uint16
	UDPPortMax     uint16
	ExitOnStdinEOF bool
	LogLevel       string
	ShowVersion    bool
}

const usage = `Usage: moranduba-sfu [flags]

Runs a Moranduba call server. It prints an npub and a one-time claim code:
paste both in the app under a group's call server settings.

Flags (each also reads the environment variable in brackets):
`

const envHelp = `
More environment variables:
  TURN_PORT                  TURN/STUN UDP port (default 3478, 0 = any free port)
  UDP_PORT_MIN, UDP_PORT_MAX media port range (default 50000-50200)
  LOG_LEVEL                  debug, info, warn, error (default info)
`

// Load reads the settings; flags in args win over the environment.
// It returns flag.ErrHelp after printing usage for -h.
func Load(args []string, out io.Writer) (Config, error) {
	cfg := Config{
		ExitOnStdinEOF: os.Getenv("SFU_EXIT_ON_STDIN_EOF") == "1",
		LogLevel:       envOr("LOG_LEVEL", "info"),
	}
	var relays string
	fs := flag.NewFlagSet("moranduba-sfu", flag.ContinueOnError)
	fs.SetOutput(out)
	fs.Usage = func() {
		fmt.Fprint(out, usage)
		fs.PrintDefaults()
		fmt.Fprint(out, envHelp)
	}
	fs.StringVar(&relays, "relays", envOr("RELAYS", DefaultRelays), "comma-separated relay URLs the app also uses [RELAYS]")
	fs.StringVar(&cfg.DataDir, "data-dir", envOr("DATA_DIR", defaultDataDir()), "keeps the server key and owner [DATA_DIR]")
	fs.StringVar(&cfg.PublicIP, "public-ip", strings.TrimSpace(os.Getenv("PUBLIC_IP")), "public IPv4, needed for callers outside this network [PUBLIC_IP]")
	fs.BoolVar(&cfg.ShowVersion, "version", false, "print the version and exit")
	if err := fs.Parse(args); err != nil {
		return cfg, err
	}
	if fs.NArg() > 0 {
		return cfg, fmt.Errorf("unexpected argument %q (see -h)", fs.Arg(0))
	}
	for _, r := range strings.Split(relays, ",") {
		if r = strings.TrimSpace(r); r != "" {
			cfg.Relays = append(cfg.Relays, r)
		}
	}
	if len(cfg.Relays) == 0 {
		return cfg, fmt.Errorf("no relays: set -relays or RELAYS")
	}
	for _, r := range cfg.Relays {
		if !strings.HasPrefix(r, "wss://") && !strings.HasPrefix(r, "ws://") {
			return cfg, fmt.Errorf("relay %q must start with wss:// or ws://", r)
		}
	}
	if cfg.PublicIP = strings.TrimSpace(cfg.PublicIP); cfg.PublicIP != "" {
		ip := net.ParseIP(cfg.PublicIP)
		if ip == nil || ip.To4() == nil {
			return cfg, fmt.Errorf("public IP must be an IPv4 address, got %q", cfg.PublicIP)
		}
	}
	var err error
	// 0 lets the OS pick, for desktop sidecars that must not clash.
	if os.Getenv("TURN_PORT") == "0" {
		cfg.TURNPort = 0
	} else if cfg.TURNPort, err = port("TURN_PORT", 3478); err != nil {
		return cfg, err
	}
	minPort, err := port("UDP_PORT_MIN", 50000)
	if err != nil {
		return cfg, err
	}
	maxPort, err := port("UDP_PORT_MAX", 50200)
	if err != nil {
		return cfg, err
	}
	if minPort > maxPort {
		return cfg, fmt.Errorf("UDP_PORT_MIN (%d) > UDP_PORT_MAX (%d)", minPort, maxPort)
	}
	cfg.UDPPortMin, cfg.UDPPortMax = uint16(minPort), uint16(maxPort)
	return cfg, nil
}

// defaultDataDir is the per-user config dir, so a downloaded binary keeps its
// key wherever it is started from.
func defaultDataDir() string {
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "moranduba-sfu")
	}
	return "moranduba-sfu-data"
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func port(key string, def int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || n < 1 || n > 65535 {
		return 0, fmt.Errorf("%s must be a port number, got %q", key, raw)
	}
	return n, nil
}
