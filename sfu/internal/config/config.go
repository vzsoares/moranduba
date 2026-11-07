// Package config reads the SFU settings from the environment.
package config

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Relays         []string
	DataDir        string
	PublicIP       string
	TURNPort       int
	UDPPortMin     uint16
	UDPPortMax     uint16
	ExitOnStdinEOF bool
	LogLevel       string
}

func FromEnv() (Config, error) {
	cfg := Config{
		DataDir:        envOr("DATA_DIR", "/data"),
		PublicIP:       strings.TrimSpace(os.Getenv("PUBLIC_IP")),
		ExitOnStdinEOF: os.Getenv("SFU_EXIT_ON_STDIN_EOF") == "1",
		LogLevel:       envOr("LOG_LEVEL", "info"),
	}
	for _, r := range strings.Split(envOr("RELAYS", "ws://localhost:7777"), ",") {
		if r = strings.TrimSpace(r); r != "" {
			cfg.Relays = append(cfg.Relays, r)
		}
	}
	if len(cfg.Relays) == 0 {
		return cfg, fmt.Errorf("RELAYS is empty")
	}
	if cfg.PublicIP != "" {
		ip := net.ParseIP(cfg.PublicIP)
		if ip == nil || ip.To4() == nil {
			return cfg, fmt.Errorf("PUBLIC_IP must be an IPv4 address, got %q", cfg.PublicIP)
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
