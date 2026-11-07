package server

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"fiatjaf.com/nostr"

	"github.com/vzsoares/moranduba/sfu/internal/wire"
)

// TestRelayIntegration needs a live relay: SFU_RELAY_TEST=ws://localhost:7777.
func TestRelayIntegration(t *testing.T) {
	url := os.Getenv("SFU_RELAY_TEST")
	if url == "" {
		t.Skip("set SFU_RELAY_TEST=ws://localhost:7777 to run")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	h := newTestHandler(t)
	sfuKey := nostr.Generate()
	relays := NewRelays([]string{url}, sfuKey, h, testLogger())
	relays.Run(ctx)
	relays.WaitAttempted(10 * time.Second)
	if len(relays.Connected()) != 1 {
		t.Fatalf("SFU not connected to %s", url)
	}

	clientKey := nostr.Generate()
	conn, err := nostr.RelayConnect(ctx, url, nostr.RelayOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	sub, err := conn.Subscribe(ctx, nostr.Filter{
		Kinds: []nostr.Kind{wire.KindWrap},
		Tags:  nostr.TagMap{"p": {clientKey.Public().Hex()}},
	}, nostr.SubscriptionOptions{})
	if err != nil {
		t.Fatal(err)
	}

	request := func(req wire.Request) wire.Reply {
		t.Helper()
		content, err := json.Marshal(req)
		if err != nil {
			t.Fatal(err)
		}
		ev, err := wire.Wrap(clientKey, sfuKey.Public(), string(content), time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Publish(ctx, ev); err != nil {
			t.Fatalf("relay rejected kind %d: %v", ev.Kind, err)
		}
		deadline := time.After(10 * time.Second)
		for {
			select {
			case <-deadline:
				t.Fatalf("no reply to %s %s: relay did not deliver the kind %d wrap", req.Type, req.ID, wire.KindWrap)
			case ev := <-sub.Events:
				rumor, err := wire.Unwrap(clientKey, ev)
				if err != nil {
					t.Fatalf("unwrap reply: %v", err)
				}
				if rumor.PubKey != sfuKey.Public() {
					t.Fatal("reply not sealed by the SFU")
				}
				var reply wire.Reply
				if err := json.Unmarshal([]byte(rumor.Content), &reply); err != nil {
					t.Fatal(err)
				}
				if reply.ReplyTo == req.ID {
					return reply
				}
			}
		}
	}

	if r := request(wire.Request{Type: "claim", ID: "claim-1", Code: h.Store.ClaimCode()}); r.Type != "claimed" {
		t.Fatalf("claim: %+v", r)
	}
	pong := request(wire.Request{Type: "ping", ID: "ping-1"})
	if pong.Type != "pong" || pong.Owner == nil || !*pong.Owner || len(pong.ICEServers) != 2 {
		t.Fatalf("pong: %+v", pong)
	}
	t.Logf("pong ice_servers: %+v", pong.ICEServers)

	c := newTestClient(t, clientKey)
	answer := request(wire.Request{Type: "join", ID: "join-1", Room: "relay-room", SDP: c.offer()})
	if answer.Type != "answer" || answer.Room != "relay-room" || answer.SDP == "" {
		t.Fatalf("join: %+v", answer)
	}
	c.setAnswer(answer.SDP)
	select {
	case <-c.dcOpen:
	case <-time.After(10 * time.Second):
		t.Fatal("peer connection did not come up after the relayed answer")
	}
}
