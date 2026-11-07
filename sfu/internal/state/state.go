// Package state persists the SFU identity key and its ownership state.
package state

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"fiatjaf.com/nostr"
	"fiatjaf.com/nostr/nip19"
)

var (
	ErrAlreadyClaimed = errors.New("already claimed")
	ErrInvalidCode    = errors.New("invalid code")
	ErrNotOwner       = errors.New("not owner")
	ErrStale          = errors.New("stale allowlist")
	ErrInvalidPubkey  = errors.New("invalid pubkey")
)

const (
	keyFile   = "key"
	stateFile = "state.json"
	// Crockford base32 without I, L, O, U.
	codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	codeLen      = 12
)

type fileState struct {
	Owner          string   `json:"owner"`
	Allowlist      []string `json:"allowlist"`
	ClaimCode      string   `json:"claim_code"`
	AllowUpdatedAt int64    `json:"allow_updated_at"`
}

// Store is the ownership state backed by DATA_DIR/state.json.
type Store struct {
	mu    sync.RWMutex
	path  string
	state fileState
	allow map[string]bool
}

// LoadKey reads DATA_DIR/key (nsec or hex), creating it on first start.
func LoadKey(dir string) (nostr.SecretKey, error) {
	path := filepath.Join(dir, keyFile)
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		sk := nostr.Generate()
		if err := WriteAtomic(path, []byte(nip19.EncodeNsec(sk)+"\n"), 0o600); err != nil {
			return sk, err
		}
		return sk, nil
	}
	if err != nil {
		return nostr.SecretKey{}, err
	}
	text := strings.TrimSpace(string(raw))
	if strings.HasPrefix(text, "nsec1") {
		prefix, value, err := nip19.Decode(text)
		if err != nil || prefix != "nsec" {
			return nostr.SecretKey{}, fmt.Errorf("%s: invalid nsec", path)
		}
		sk, ok := value.(nostr.SecretKey)
		if !ok {
			return nostr.SecretKey{}, fmt.Errorf("%s: invalid nsec", path)
		}
		return sk, nil
	}
	return nostr.SecretKeyFromHex(text)
}

// Open loads DATA_DIR/state.json, creating it with a fresh claim code on first start.
func Open(dir string) (*Store, error) {
	s := &Store{path: filepath.Join(dir, stateFile)}
	raw, err := os.ReadFile(s.path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		code, err := newClaimCode()
		if err != nil {
			return nil, err
		}
		s.state = fileState{ClaimCode: code, Allowlist: []string{}}
		if err := s.save(); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(raw, &s.state); err != nil {
			return nil, fmt.Errorf("%s: %w", s.path, err)
		}
		if s.state.Owner == "" && s.state.ClaimCode == "" {
			code, err := newClaimCode()
			if err != nil {
				return nil, err
			}
			s.state.ClaimCode = code
			if err := s.save(); err != nil {
				return nil, err
			}
		}
	}
	s.rebuild()
	return s, nil
}

func (s *Store) rebuild() {
	s.allow = make(map[string]bool, len(s.state.Allowlist))
	for _, pk := range s.state.Allowlist {
		s.allow[pk] = true
	}
}

// ClaimCode returns the unused claim code, or "" once claimed.
func (s *Store) ClaimCode() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.state.Owner != "" {
		return ""
	}
	return formatCode(s.state.ClaimCode)
}

func (s *Store) Owner() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.Owner
}

func (s *Store) IsOwner(pubkey string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.Owner != "" && s.state.Owner == pubkey
}

func (s *Store) IsAllowed(pubkey string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.state.Owner == "" {
		return false
	}
	return pubkey == s.state.Owner || s.allow[pubkey]
}

// Claim makes pubkey the owner if code matches the unused claim code; the code is burned.
func (s *Store) Claim(pubkey, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Owner != "" {
		return ErrAlreadyClaimed
	}
	want := []byte(normalizeCode(s.state.ClaimCode))
	got := []byte(normalizeCode(code))
	if len(want) == 0 || subtle.ConstantTimeCompare(want, got) != 1 {
		return ErrInvalidCode
	}
	prev := s.state
	s.state.Owner = pubkey
	s.state.ClaimCode = ""
	if err := s.save(); err != nil {
		s.state = prev
		return err
	}
	return nil
}

// SetAllowlist replaces the allowlist. at is the request's created_at; older
// requests than the last applied one are rejected so replays cannot roll it back.
func (s *Store) SetAllowlist(sender string, pubkeys []string, at int64) (int, error) {
	normalized := make([]string, 0, len(pubkeys))
	for _, pk := range pubkeys {
		hex, err := NormalizePubkey(pk)
		if err != nil {
			return 0, fmt.Errorf("%w: %q", ErrInvalidPubkey, pk)
		}
		normalized = append(normalized, hex)
	}
	slices.Sort(normalized)
	normalized = slices.Compact(normalized)

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Owner == "" || s.state.Owner != sender {
		return 0, ErrNotOwner
	}
	if at < s.state.AllowUpdatedAt {
		return 0, ErrStale
	}
	normalized = slices.DeleteFunc(normalized, func(pk string) bool { return pk == s.state.Owner })
	prev := s.state
	s.state.Allowlist = normalized
	s.state.AllowUpdatedAt = at
	if err := s.save(); err != nil {
		s.state = prev
		return 0, err
	}
	s.rebuild()
	return len(normalized), nil
}

// NormalizePubkey accepts a hex pubkey or an npub and returns lowercase hex.
func NormalizePubkey(pk string) (string, error) {
	pk = strings.TrimSpace(pk)
	if strings.HasPrefix(pk, "npub1") {
		prefix, value, err := nip19.Decode(pk)
		if err != nil || prefix != "npub" {
			return "", ErrInvalidPubkey
		}
		key, ok := value.(nostr.PubKey)
		if !ok {
			return "", ErrInvalidPubkey
		}
		return key.Hex(), nil
	}
	key, err := nostr.PubKeyFromHex(strings.ToLower(pk))
	if err != nil {
		return "", ErrInvalidPubkey
	}
	return key.Hex(), nil
}

func (s *Store) save() error {
	raw, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	return WriteAtomic(s.path, append(raw, '\n'), 0o600)
}

// WriteAtomic replaces path with data through a synced temp file.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func newClaimCode() (string, error) {
	buf := make([]byte, codeLen)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, codeLen)
	for i, b := range buf {
		out[i] = codeAlphabet[int(b)%len(codeAlphabet)]
	}
	return string(out), nil
}

func normalizeCode(code string) string {
	code = strings.ToUpper(code)
	return strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' {
			return -1
		}
		return r
	}, code)
}

func formatCode(code string) string {
	var b strings.Builder
	for i, r := range code {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		b.WriteRune(r)
	}
	return b.String()
}
