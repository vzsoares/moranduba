package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"fiatjaf.com/nostr"

	"github.com/vzsoares/moranduba/sfu/internal/media"
	"github.com/vzsoares/moranduba/sfu/internal/state"
	"github.com/vzsoares/moranduba/sfu/internal/turnsrv"
	"github.com/vzsoares/moranduba/sfu/internal/wire"
)

func newTestHandler(t *testing.T) *Handler {
	t.Helper()
	store, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sfu, err := media.New(media.Config{IncludeLoopback: true, Logger: testLogger()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sfu.Close)
	creds, err := turnsrv.NewCredentials(store.IsAllowed)
	if err != nil {
		t.Fatal(err)
	}
	return &Handler{Store: store, SFU: sfu, Creds: creds, ICEHost: "203.0.113.7", TURNPort: 3478, Version: "test"}
}

func call(t *testing.T, h *Handler, sender string, req wire.Request) map[string]json.RawMessage {
	t.Helper()
	reply := h.Handle(context.Background(), Inbound{Sender: sender, CreatedAt: int64(nostr.Now()), Req: req})
	raw, err := json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]json.RawMessage
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	if string(out["reply_to"]) != `"`+req.ID+`"` {
		t.Fatalf("reply_to = %s, want %q", out["reply_to"], req.ID)
	}
	return out
}

func field[T any](t *testing.T, m map[string]json.RawMessage, key string) T {
	t.Helper()
	var v T
	raw, ok := m[key]
	if !ok {
		t.Fatalf("missing %q in %v", key, m)
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("%s: %v", key, err)
	}
	return v
}

func TestPingClaimAllowJoin(t *testing.T) {
	h := newTestHandler(t)
	owner := nostr.Generate().Public().Hex()
	member := nostr.Generate().Public().Hex()
	stranger := nostr.Generate().Public().Hex()

	pong := call(t, h, stranger, wire.Request{Type: "ping", ID: "p1"})
	if field[string](t, pong, "type") != "pong" || field[bool](t, pong, "owner") || field[bool](t, pong, "allowed") {
		t.Fatalf("stranger pong: %v", pong)
	}
	servers := field[[]wire.ICEServer](t, pong, "ice_servers")
	if len(servers) != 1 || servers[0].URLs[0] != "stun:203.0.113.7:3478" || servers[0].Username != "" {
		t.Fatalf("stranger gets STUN only: %+v", servers)
	}
	if field[string](t, pong, "version") != "test" {
		t.Fatal("version missing")
	}

	if r := call(t, h, stranger, wire.Request{Type: "join", ID: "j0", Room: "r", SDP: "v=0"}); field[string](t, r, "type") != "error" || field[string](t, r, "message") != "not allowed" {
		t.Fatalf("unclaimed join: %v", r)
	}

	if r := call(t, h, stranger, wire.Request{Type: "claim", ID: "c0", Code: "nope"}); field[string](t, r, "message") != "invalid code" {
		t.Fatalf("bad claim: %v", r)
	}
	code := h.Store.ClaimCode()
	if r := call(t, h, owner, wire.Request{Type: "claim", ID: "c1", Code: code}); field[string](t, r, "type") != "claimed" {
		t.Fatalf("claim: %v", r)
	}
	if r := call(t, h, stranger, wire.Request{Type: "claim", ID: "c2", Code: code}); field[string](t, r, "message") != "already claimed" {
		t.Fatalf("second claim: %v", r)
	}

	pong = call(t, h, owner, wire.Request{Type: "ping", ID: "p2"})
	if !field[bool](t, pong, "owner") || !field[bool](t, pong, "allowed") {
		t.Fatalf("owner pong: %v", pong)
	}
	servers = field[[]wire.ICEServer](t, pong, "ice_servers")
	if len(servers) != 2 || servers[1].URLs[0] != "turn:203.0.113.7:3478?transport=udp" ||
		!strings.HasSuffix(servers[1].Username, ":"+owner) || servers[1].Credential == "" {
		t.Fatalf("owner ice servers: %+v", servers)
	}

	if r := call(t, h, member, wire.Request{Type: "allow", ID: "a0", Pubkeys: []string{member}}); field[string](t, r, "message") != "not owner" {
		t.Fatalf("non-owner allow: %v", r)
	}
	if r := call(t, h, owner, wire.Request{Type: "allow", ID: "a1", Pubkeys: []string{member}}); field[string](t, r, "type") != "allowed" || field[int](t, r, "count") != 1 {
		t.Fatalf("allow: %v", r)
	}
	if !field[bool](t, call(t, h, member, wire.Request{Type: "ping", ID: "p3"}), "allowed") {
		t.Fatal("member should be allowed")
	}

	if r := call(t, h, stranger, wire.Request{Type: "join", ID: "j1", Room: "r", SDP: "v=0"}); field[string](t, r, "message") != "not allowed" {
		t.Fatalf("stranger join: %v", r)
	}
	if r := call(t, h, member, wire.Request{Type: "join", ID: "j2", Room: "r"}); field[string](t, r, "type") != "error" {
		t.Fatalf("join without sdp: %v", r)
	}
	if r := call(t, h, member, wire.Request{Type: "join", ID: "j3", Room: "r", SDP: "garbage"}); !strings.HasPrefix(field[string](t, r, "message"), "join failed") {
		t.Fatalf("join with bad sdp: %v", r)
	}
	if r := call(t, h, member, wire.Request{Type: "bogus", ID: "x"}); field[string](t, r, "message") != "unknown type" {
		t.Fatalf("unknown: %v", r)
	}

	c := newTestClient(t, nostr.Generate())
	if r := call(t, h, member, wire.Request{Type: "join", ID: "j4", Room: "r", SDP: c.offer()}); field[string](t, r, "type") != "answer" ||
		field[string](t, r, "room") != "r" || !strings.Contains(field[string](t, r, "sdp"), "a=candidate") {
		t.Fatalf("member join: %v", r)
	}
}
