package media

import (
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

type captureWriter struct {
	mu      sync.Mutex
	headers []rtp.Header
}

func (w *captureWriter) WriteRTP(h *rtp.Header, _ []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.headers = append(w.headers, *h)
	return 0, nil
}

func (w *captureWriter) Write(b []byte) (int, error) { return len(b), nil }

func bound(kind webrtc.RTPCodecType) (*downTrack, *captureWriter) {
	pub := &Peer{key: "pub"}
	d := newDownTrack(kind, pub, &Peer{key: "sub"})
	w := &captureWriter{}
	d.ws, d.ssrc, d.pt, d.levelID = w, 777, 100, 5
	return d, w
}

func assertContinuous(t *testing.T, hs []rtp.Header) {
	t.Helper()
	for i := 1; i < len(hs); i++ {
		if hs[i].SequenceNumber != hs[i-1].SequenceNumber+1 {
			t.Fatalf("seq gap at %d: %d -> %d", i, hs[i-1].SequenceNumber, hs[i].SequenceNumber)
		}
		if int32(hs[i].Timestamp-hs[i-1].Timestamp) <= 0 {
			t.Fatalf("ts not increasing at %d", i)
		}
		if hs[i].SSRC != 777 || hs[i].PayloadType != 100 {
			t.Fatal("ssrc/pt not rewritten")
		}
	}
}

func TestAudioGatingKeepsSequence(t *testing.T) {
	d, w := bound(webrtc.RTPCodecTypeAudio)
	d.setAudio(true)
	seq, ts := uint16(65530), uint32(1000)
	send := func(n int) {
		for range n {
			d.writeAudio(&rtp.Packet{Header: rtp.Header{SSRC: 1, SequenceNumber: seq, Timestamp: ts}, Payload: []byte{1}}, 30, true)
			seq++
			ts += 960
		}
	}
	send(10)
	d.setAudio(false)
	send(10)
	d.setAudio(true)
	send(10)
	if len(w.headers) != 20 {
		t.Fatalf("forwarded %d packets, want 20", len(w.headers))
	}
	assertContinuous(t, w.headers)
	if got := w.headers[10].Timestamp - w.headers[9].Timestamp; got != 11*960 {
		t.Fatalf("same-source resume should keep the source clock, ts jump %d", got)
	}
	if !w.headers[10].Marker {
		t.Fatal("first packet after a gap should carry the marker bit")
	}
	if ext := w.headers[0].GetExtension(5); len(ext) != 1 || ext[0] != 30 {
		t.Fatal("audio level not re-added with the subscriber's extension id")
	}
}

func vp8(key bool) []byte {
	tag := byte(0x01)
	if key {
		tag = 0x00
	}
	return []byte{0x10, tag, 0, 0, 0x9d, 0x01, 0x2a}
}

func TestVideoLayerSwitchWaitsForKeyframe(t *testing.T) {
	d, w := bound(webrtc.RTPCodecTypeVideo)
	now := time.Now()
	if req := d.setVideo(true, "h", now); req != "h" {
		t.Fatalf("selecting a layer should request a keyframe, got %q", req)
	}
	hSeq, hTS := uint16(10), uint32(500)
	fSeq, fTS := uint16(60000), uint32(4_000_000_000)
	frame := func(rid string, key bool) {
		var p *rtp.Packet
		if rid == "h" {
			p = &rtp.Packet{Header: rtp.Header{SSRC: 2, SequenceNumber: hSeq, Timestamp: hTS}, Payload: vp8(key)}
			hSeq++
			hTS += 3000
		} else {
			p = &rtp.Packet{Header: rtp.Header{SSRC: 3, SequenceNumber: fSeq, Timestamp: fTS}, Payload: vp8(key)}
			fSeq++
			fTS += 3000
		}
		k, s := vp8Info(p.Payload)
		d.writeVideo(rid, p, k, s)
	}

	frame("h", false)
	if len(w.headers) != 0 {
		t.Fatal("delta frame forwarded before the first keyframe")
	}
	frame("h", true)
	frame("h", false)
	frame("f", true)
	if len(w.headers) != 2 {
		t.Fatalf("forwarded %d, want 2 (only layer h)", len(w.headers))
	}

	if req := d.setVideo(true, "f", now); req != "f" {
		t.Fatal("layer switch should request a keyframe on the new layer")
	}
	frame("f", false)
	frame("h", false)
	if len(w.headers) != 3 {
		t.Fatal("must keep forwarding h until f has a keyframe")
	}
	frame("f", true)
	frame("h", false)
	frame("f", false)
	if len(w.headers) != 5 {
		t.Fatalf("forwarded %d, want 5", len(w.headers))
	}
	assertContinuous(t, w.headers)

	if req := d.setVideo(false, "f", now); req != "" {
		t.Fatal("deselecting must not request a keyframe")
	}
	frame("f", true)
	if len(w.headers) != 5 {
		t.Fatal("deselected video forwarded")
	}
}

func TestVP8Info(t *testing.T) {
	if k, s := vp8Info(vp8(true)); !k || !s {
		t.Fatal("keyframe not detected")
	}
	if k, s := vp8Info(vp8(false)); k || !s {
		t.Fatal("delta frame misdetected")
	}
	if k, s := vp8Info([]byte{0x00, 0x00}); k || s {
		t.Fatal("continuation packet is not a frame start")
	}
}
