package server

import (
	"context"
	"slices"
	"testing"
	"time"

	"fiatjaf.com/nostr"
	"github.com/pion/webrtc/v4"

	"github.com/vzsoares/moranduba/sfu/internal/media"
	"github.com/vzsoares/moranduba/sfu/internal/wire"
)

func join(t *testing.T, h *Handler, c *testClient, room string) {
	t.Helper()
	reply := h.Handle(context.Background(), Inbound{
		Sender:    c.key,
		CreatedAt: int64(nostr.Now()),
		Req:       wire.Request{Type: "join", ID: "join-" + c.key[:6], Room: room, SDP: c.offer()},
	})
	if reply.Type != "answer" || reply.ReplyTo != "join-"+c.key[:6] || reply.Room != room {
		t.Fatalf("join reply: %+v", reply)
	}
	c.setAnswer(reply.SDP)
}

func trackOf(c *testClient, streamID string, kind webrtc.RTPCodecType) *rxTrack {
	for _, tr := range c.tracksFrom(streamID) {
		if tr.kind == kind {
			return tr
		}
	}
	return nil
}

func countMarker(pkts []rxPacket, marker byte) int {
	n := 0
	for _, p := range pkts {
		if p.marker == marker {
			n++
		}
	}
	return n
}

func TestForwarding(t *testing.T) {
	h := newTestHandler(t)
	a := newTestClient(t, nostr.Generate())
	b := newTestClient(t, nostr.Generate())
	if err := h.Store.Claim(a.key, h.Store.ClaimCode()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Store.SetAllowlist(a.key, []string{b.key}, 1); err != nil {
		t.Fatal(err)
	}

	const room = "call-1"
	join(t, h, a, room)
	join(t, h, b, room)
	for _, c := range []*testClient{a, b} {
		select {
		case <-c.dcOpen:
		case <-time.After(10 * time.Second):
			t.Fatal("datachannel did not open")
		}
		c.startMedia()
	}

	waitFor(t, 10*time.Second, "both peers connected", func() bool { return len(h.SFU.Participants(room)) == 2 })
	waitFor(t, 10*time.Second, "B gets A's audio and video tracks", func() bool {
		return trackOf(b, a.key, webrtc.RTPCodecTypeAudio) != nil && trackOf(b, a.key, webrtc.RTPCodecTypeVideo) != nil
	})
	if b.answered.Load() < 1 {
		t.Fatal("tracks arrived without DataChannel renegotiation")
	}
	for _, tr := range b.tracksFrom(a.key) {
		if tr.streamID != a.key {
			t.Fatalf("stream id %q, want publisher pubkey", tr.streamID)
		}
	}
	if len(b.tracksFrom(b.key)) != 0 {
		t.Fatal("B must not receive its own tracks")
	}

	audio := trackOf(b, a.key, webrtc.RTPCodecTypeAudio)
	video := trackOf(b, a.key, webrtc.RTPCodecTypeVideo)
	waitFor(t, 10*time.Second, "audio packets", func() bool { return len(audio.snapshot()) >= 25 })
	waitFor(t, 10*time.Second, "default layer h", func() bool { return countMarker(video.snapshot(), 'h') >= 30 })
	if n := countMarker(video.snapshot(), 'f') + countMarker(video.snapshot(), 'q'); n != 0 {
		t.Fatalf("got %d packets from other layers before any switch", n)
	}
	waitFor(t, 5*time.Second, "speakers message naming A", func() bool { return b.sawSpeaker(a.key) })

	b.sendDC(media.DCMessage{Type: "layer", Pubkey: a.key, RID: "f"})
	waitFor(t, 10*time.Second, "layer f after switch", func() bool { return countMarker(video.snapshot(), 'f') >= 30 })

	pkts := video.snapshot()
	switched := false
	for i := 1; i < len(pkts); i++ {
		prev, cur := pkts[i-1], pkts[i]
		if cur.seq != prev.seq+1 {
			t.Fatalf("sequence gap at %d: %d -> %d (layers %c -> %c)", i, prev.seq, cur.seq, prev.marker, cur.marker)
		}
		if int32(cur.ts-prev.ts) <= 0 {
			t.Fatalf("timestamp not increasing at %d: %d -> %d", i, prev.ts, cur.ts)
		}
		if prev.marker == 'h' && cur.marker == 'f' {
			switched = true
		}
		if prev.marker == 'f' && cur.marker != 'f' {
			t.Fatalf("switched back from f to %c", cur.marker)
		}
	}
	if !switched {
		t.Fatal("no h -> f switch observed")
	}

	aud := audio.snapshot()
	for i := 1; i < len(aud); i++ {
		if aud[i].seq != aud[i-1].seq+1 {
			t.Fatalf("audio sequence gap %d -> %d", aud[i-1].seq, aud[i].seq)
		}
	}

	before := b.answered.Load()
	a.close()
	waitFor(t, 25*time.Second, "A removed from the room", func() bool {
		return !slices.Contains(h.SFU.Participants(room), a.key)
	})
	waitFor(t, 10*time.Second, "B renegotiated after A left", func() bool { return b.answered.Load() > before })
}
