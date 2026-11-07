// Command moranduba-sfu is the Moranduba selective forwarding unit.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"fiatjaf.com/nostr"
	"fiatjaf.com/nostr/nip19"

	"github.com/vzsoares/moranduba/sfu/internal/config"
	"github.com/vzsoares/moranduba/sfu/internal/media"
	"github.com/vzsoares/moranduba/sfu/internal/push"
	"github.com/vzsoares/moranduba/sfu/internal/server"
	"github.com/vzsoares/moranduba/sfu/internal/state"
	"github.com/vzsoares/moranduba/sfu/internal/turnsrv"
)

var version = "0.1.0"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "moranduba-sfu:", err)
		os.Exit(1)
	}
}

type identityLine struct {
	Pubkey    string `json:"pubkey"`
	Npub      string `json:"npub"`
	ClaimCode string `json:"claim_code"`
	TURNPort  int    `json:"turn_port"`
}

func run() error {
	cfg, err := config.FromEnv()
	if err != nil {
		return err
	}
	var level slog.Level
	if err := level.UnmarshalText([]byte(cfg.LogLevel)); err != nil {
		level = slog.LevelInfo
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return err
	}
	sk, err := state.LoadKey(cfg.DataDir)
	if err != nil {
		return fmt.Errorf("key: %w", err)
	}
	store, err := state.Open(cfg.DataDir)
	if err != nil {
		return fmt.Errorf("state: %w", err)
	}

	iceHost := cfg.PublicIP
	if iceHost == "" {
		iceHost = localIPv4()
	}
	creds, err := turnsrv.NewCredentials(store.IsAllowed)
	if err != nil {
		return err
	}
	turnServer, turnPort, err := turnsrv.Start(turnsrv.Config{
		Port:      cfg.TURNPort,
		RelayIP:   net.ParseIP(iceHost),
		PortMin:   cfg.UDPPortMin,
		PortMax:   cfg.UDPPortMax,
		Validator: creds,
	})
	if err != nil {
		return err
	}
	defer turnServer.Close()

	sfu, err := media.New(media.Config{
		PublicIP: cfg.PublicIP,
		PortMin:  cfg.UDPPortMin,
		PortMax:  cfg.UDPPortMax,
		Logger:   logger,
	})
	if err != nil {
		return err
	}
	defer sfu.Close()

	pushes, err := push.Open(cfg.DataDir)
	if err != nil {
		return fmt.Errorf("push: %w", err)
	}

	handler := &server.Handler{
		Store:    store,
		SFU:      sfu,
		Creds:    creds,
		ICEHost:  iceHost,
		TURNPort: turnPort,
		Version:  version,
		Push:     pushes,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if cfg.ExitOnStdinEOF {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			logger.Info("stdin closed, exiting")
			stop()
		}()
	}

	relays := server.NewRelays(cfg.Relays, sk, handler, logger)
	relays.Run(ctx)
	relays.WaitAttempted(5 * time.Second)

	pk := sk.Public()
	npub := nip19.EncodeNpub(pk)
	code := store.ClaimCode()
	fmt.Printf("Moranduba SFU %s\n", version)
	fmt.Printf("  npub:       %s\n", npub)
	fmt.Printf("  pubkey:     %s\n", pk.Hex())
	if code != "" {
		fmt.Printf("  claim code: %s\n", code)
	} else if owner, err := nostr.PubKeyFromHex(store.Owner()); err == nil {
		fmt.Printf("  owner:      %s\n", nip19.EncodeNpub(owner))
	}
	fmt.Printf("  relays:     %s (connected: %d)\n", strings.Join(cfg.Relays, ", "), len(relays.Connected()))
	fmt.Printf("  ice host:   %s, turn udp/%d, media udp/%d-%d\n", iceHost, turnPort, cfg.UDPPortMin, cfg.UDPPortMax)
	line, err := json.Marshal(identityLine{Pubkey: pk.Hex(), Npub: npub, ClaimCode: code, TURNPort: turnPort})
	if err != nil {
		return err
	}
	fmt.Printf("MORANDUBA_SFU %s\n", line)

	<-ctx.Done()
	logger.Info("shutting down")
	return nil
}

// localIPv4 returns the address used for outbound traffic; no packet is sent.
func localIPv4() string {
	if conn, err := net.Dial("udp4", "1.1.1.1:53"); err == nil {
		defer conn.Close()
		if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok {
			return addr.IP.String()
		}
	}
	addrs, err := net.InterfaceAddrs()
	if err == nil {
		for _, a := range addrs {
			if ipNet, ok := a.(*net.IPNet); ok && !ipNet.IP.IsLoopback() && ipNet.IP.To4() != nil {
				return ipNet.IP.String()
			}
		}
	}
	return "127.0.0.1"
}
