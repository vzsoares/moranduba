package state

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"fiatjaf.com/nostr"
	"fiatjaf.com/nostr/nip19"
)

func TestKeyPersists(t *testing.T) {
	dir := t.TempDir()
	a, err := LoadKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "key"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(raw), "nsec1") {
		t.Fatalf("key file should hold an nsec, got %q", raw)
	}
	info, _ := os.Stat(filepath.Join(dir, "key"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key mode %v", info.Mode().Perm())
	}
	b, err := LoadKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	if a != b {
		t.Fatal("key changed between loads")
	}
}

func TestClaimFirstWinsAndBurnsCode(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	code := s.ClaimCode()
	if len(code) != 14 {
		t.Fatalf("claim code %q", code)
	}
	alice, bob := nostr.Generate().Public().Hex(), nostr.Generate().Public().Hex()

	if err := s.Claim(bob, "WRONG-CODE"); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("wrong code: %v", err)
	}
	if s.Owner() != "" {
		t.Fatal("wrong code must not claim")
	}

	var wg sync.WaitGroup
	results := make([]error, 8)
	for i := range results {
		pk := alice
		if i%2 == 1 {
			pk = bob
		}
		wg.Go(func() { results[i] = s.Claim(pk, strings.ToLower(code)) })
	}
	wg.Wait()
	wins := 0
	for _, err := range results {
		if err == nil {
			wins++
		} else if !errors.Is(err, ErrAlreadyClaimed) {
			t.Fatalf("unexpected: %v", err)
		}
	}
	if wins != 1 {
		t.Fatalf("%d claims succeeded", wins)
	}
	owner := s.Owner()
	if s.ClaimCode() != "" {
		t.Fatal("claim code must be burned")
	}

	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.Owner() != owner || reopened.ClaimCode() != "" {
		t.Fatal("claim not persisted")
	}
	if err := reopened.Claim(alice, code); !errors.Is(err, ErrAlreadyClaimed) {
		t.Fatalf("reusing the code: %v", err)
	}
}

func TestAllowlist(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	owner, member, stranger := nostr.Generate().Public(), nostr.Generate().Public(), nostr.Generate().Public()

	if s.IsAllowed(owner.Hex()) {
		t.Fatal("nobody is allowed before the claim")
	}
	if err := s.Claim(owner.Hex(), s.ClaimCode()); err != nil {
		t.Fatal(err)
	}
	if !s.IsAllowed(owner.Hex()) || s.IsAllowed(member.Hex()) {
		t.Fatal("only the owner is allowed after the claim")
	}

	if _, err := s.SetAllowlist(member.Hex(), []string{member.Hex()}, 10); !errors.Is(err, ErrNotOwner) {
		t.Fatalf("non-owner allow: %v", err)
	}

	n, err := s.SetAllowlist(owner.Hex(), []string{nip19.EncodeNpub(member), member.Hex(), owner.Hex()}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("count = %d, want 1 (deduped, owner implicit)", n)
	}
	if !s.IsAllowed(member.Hex()) || s.IsAllowed(stranger.Hex()) {
		t.Fatal("allowlist not applied")
	}

	if _, err := s.SetAllowlist(owner.Hex(), []string{stranger.Hex()}, 5); !errors.Is(err, ErrStale) {
		t.Fatalf("older allow must be rejected: %v", err)
	}
	if _, err := s.SetAllowlist(owner.Hex(), []string{"nope"}, 20); !errors.Is(err, ErrInvalidPubkey) {
		t.Fatalf("invalid pubkey: %v", err)
	}

	if _, err := s.SetAllowlist(owner.Hex(), nil, 30); err != nil {
		t.Fatal(err)
	}
	if s.IsAllowed(member.Hex()) || !s.IsAllowed(owner.Hex()) {
		t.Fatal("replacing with an empty list keeps only the owner")
	}

	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.IsAllowed(member.Hex()) || !reopened.IsAllowed(owner.Hex()) {
		t.Fatal("allowlist not persisted")
	}
}
