package push

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

type endpoint struct {
	mu      sync.Mutex
	hits    map[string]int
	urgency string
	status  int
}

func newEndpoint(t *testing.T, status int) (*endpoint, *httptest.Server) {
	t.Helper()
	e := &endpoint{hits: map[string]int{}, status: status}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.mu.Lock()
		e.hits[r.URL.Path]++
		e.urgency = r.Header.Get("Urgency")
		e.mu.Unlock()
		w.WriteHeader(e.status)
	}))
	t.Cleanup(srv.Close)
	return e, srv
}

func device(t *testing.T, url string) Device {
	t.Helper()
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	auth := make([]byte, 16)
	if _, err := rand.Read(auth); err != nil {
		t.Fatal(err)
	}
	enc := base64.RawURLEncoding.EncodeToString
	return Device{Endpoint: url, P256dh: enc(key.PublicKey().Bytes()), Auth: enc(auth)}
}

func open(t *testing.T, srv *httptest.Server) (*Store, string) {
	t.Helper()
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	s.client = srv.Client()
	return s, dir
}

func TestRingReachesTargetsOnly(t *testing.T) {
	e, srv := newEndpoint(t, http.StatusCreated)
	s, dir := open(t, srv)
	for _, sub := range []struct{ pubkey, path string }{
		{"alice", "/alice"}, {"bob", "/bob"}, {"bob", "/bob-phone"}, {"carol", "/carol"},
	} {
		if err := s.Subscribe(sub.pubkey, device(t, srv.URL+sub.path)); err != nil {
			t.Fatal(err)
		}
	}

	now := time.Now()
	n, err := s.Ring(context.Background(), "alice", []string{"alice", "bob"}, Message{Type: "ring", From: "alice"}, now)
	if err != nil || n != 2 {
		t.Fatalf("ring = %d, %v; want 2 devices", n, err)
	}
	if e.hits["/bob"] != 1 || e.hits["/bob-phone"] != 1 || e.hits["/alice"] != 0 || e.hits["/carol"] != 0 {
		t.Fatalf("hits = %v", e.hits)
	}
	if e.urgency != "high" {
		t.Fatalf("urgency = %q", e.urgency)
	}

	if _, err := s.Ring(context.Background(), "alice", []string{"bob"}, Message{Type: "ring"}, now.Add(time.Second)); !errors.Is(err, ErrTooSoon) {
		t.Fatalf("second ring err = %v, want ErrTooSoon", err)
	}
	if n, err := s.Ring(context.Background(), "alice", []string{"bob"}, Message{Type: "stop"}, now.Add(time.Second)); err != nil || n != 2 {
		t.Fatalf("stop = %d, %v", n, err)
	}

	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.PublicKey() != s.PublicKey() || len(reopened.state.Devices["bob"]) != 2 {
		t.Fatal("key or devices lost on reopen")
	}
}

func TestGoneDevicesAreDropped(t *testing.T) {
	_, srv := newEndpoint(t, http.StatusGone)
	s, _ := open(t, srv)
	if err := s.Subscribe("bob", device(t, srv.URL+"/old")); err != nil {
		t.Fatal(err)
	}
	if n, err := s.Ring(context.Background(), "alice", []string{"bob"}, Message{Type: "ring"}, time.Now()); err != nil || n != 0 {
		t.Fatalf("ring = %d, %v", n, err)
	}
	if len(s.state.Devices["bob"]) != 0 {
		t.Fatal("gone device kept")
	}
}

func TestSubscribeValidatesAndCaps(t *testing.T) {
	_, srv := newEndpoint(t, http.StatusCreated)
	s, _ := open(t, srv)
	if err := s.Subscribe("bob", Device{Endpoint: "http://plain.example/x", P256dh: "a", Auth: "b"}); !errors.Is(err, ErrBadSubscription) {
		t.Fatalf("plain http err = %v", err)
	}
	for i := range maxDevices + 2 {
		if err := s.Subscribe("bob", device(t, srv.URL+"/d"+string(rune('a'+i)))); err != nil {
			t.Fatal(err)
		}
	}
	if got := len(s.state.Devices["bob"]); got != maxDevices {
		t.Fatalf("devices = %d, want %d", got, maxDevices)
	}
}
