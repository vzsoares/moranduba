package config

import (
	"errors"
	"flag"
	"io"
	"slices"
	"strings"
	"testing"
)

func TestLoadDefaultsToPublicRelays(t *testing.T) {
	t.Setenv("RELAYS", "")
	t.Setenv("DATA_DIR", "")
	cfg, err := Load(nil, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(cfg.Relays, strings.Split(DefaultRelays, ",")) {
		t.Fatalf("relays = %v", cfg.Relays)
	}
	if !strings.HasSuffix(cfg.DataDir, "moranduba-sfu") && cfg.DataDir != "moranduba-sfu-data" {
		t.Fatalf("data dir = %q", cfg.DataDir)
	}
}

func TestLoadFlagsWinOverEnv(t *testing.T) {
	t.Setenv("RELAYS", "ws://localhost:7777")
	t.Setenv("DATA_DIR", "/env")
	cfg, err := Load([]string{"-relays", "wss://a.example, wss://b.example", "-data-dir", "/flag", "-public-ip", "203.0.113.7"}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(cfg.Relays, []string{"wss://a.example", "wss://b.example"}) {
		t.Fatalf("relays = %v", cfg.Relays)
	}
	if cfg.DataDir != "/flag" || cfg.PublicIP != "203.0.113.7" {
		t.Fatalf("cfg = %+v", cfg)
	}
}

func TestLoadRejectsBadInput(t *testing.T) {
	for _, args := range [][]string{
		{"-relays", "relay.damus.io"},
		{"-relays", " , "},
		{"-public-ip", "::1"},
		{"stray"},
	} {
		if _, err := Load(args, io.Discard); err == nil {
			t.Errorf("Load(%v) accepted", args)
		}
	}
}

func TestLoadHelp(t *testing.T) {
	if _, err := Load([]string{"-h"}, io.Discard); !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("err = %v", err)
	}
}
