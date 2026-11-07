package server

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"fiatjaf.com/nostr"
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"

	"github.com/vzsoares/moranduba/sfu/internal/media"
)

var rids = []string{"q", "h", "f"}

type rxPacket struct {
	seq    uint16
	ts     uint32
	marker byte
}

type rxTrack struct {
	streamID string
	kind     webrtc.RTPCodecType

	mu      sync.Mutex
	packets []rxPacket
}

func (r *rxTrack) snapshot() []rxPacket {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]rxPacket(nil), r.packets...)
}

// testClient behaves like the Moranduba app: one sendrecv Opus transceiver
// with audio level, one sendrecv VP8 transceiver with simulcast q/h/f, and a
// negotiated DataChannel on which it answers SFU offers.
type testClient struct {
	t   *testing.T
	sk  nostr.SecretKey
	key string
	pc  *webrtc.PeerConnection
	dc  *webrtc.DataChannel

	audio       *webrtc.TrackLocalStaticRTP
	audioSender *webrtc.RTPSender
	video       map[string]*webrtc.TrackLocalStaticRTP
	videoSender *webrtc.RTPSender
	keyNeeded   map[string]*atomic.Bool

	dcOpen   chan struct{}
	answered atomic.Int64

	mu       sync.Mutex
	tracks   []*rxTrack
	speakers [][]string

	stop chan struct{}
	once sync.Once
}

func testLogger() *slog.Logger {
	if os.Getenv("SFU_TEST_LOG") != "" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newTestClient(t *testing.T, sk nostr.SecretKey) *testClient {
	t.Helper()
	m, err := media.NewMediaEngine()
	if err != nil {
		t.Fatal(err)
	}
	ir := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(m, ir); err != nil {
		t.Fatal(err)
	}
	se := webrtc.SettingEngine{}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	se.SetIncludeLoopbackCandidate(true)
	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(ir), webrtc.WithSettingEngine(se))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	c := &testClient{
		t:         t,
		sk:        sk,
		key:       sk.Public().Hex(),
		pc:        pc,
		video:     map[string]*webrtc.TrackLocalStaticRTP{},
		keyNeeded: map[string]*atomic.Bool{},
		dcOpen:    make(chan struct{}),
		stop:      make(chan struct{}),
	}
	t.Cleanup(c.close)

	c.audio, err = webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus}, "mic", "local")
	if err != nil {
		t.Fatal(err)
	}
	atr, err := pc.AddTransceiverFromTrack(c.audio, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendrecv})
	if err != nil {
		t.Fatal(err)
	}
	c.audioSender = atr.Sender()

	for _, rid := range rids {
		c.video[rid], err = webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8}, "cam", "local", webrtc.WithRTPStreamID(rid))
		if err != nil {
			t.Fatal(err)
		}
		flag := &atomic.Bool{}
		flag.Store(true)
		c.keyNeeded[rid] = flag
	}
	vtr, err := pc.AddTransceiverFromTrack(c.video["q"], webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendrecv})
	if err != nil {
		t.Fatal(err)
	}
	c.videoSender = vtr.Sender()
	for _, rid := range rids[1:] {
		if err := c.videoSender.AddEncoding(c.video[rid]); err != nil {
			t.Fatal(err)
		}
	}

	ordered, negotiated, id := true, true, uint16(0)
	c.dc, err = pc.CreateDataChannel(media.DataChannelLabel, &webrtc.DataChannelInit{Ordered: &ordered, Negotiated: &negotiated, ID: &id})
	if err != nil {
		t.Fatal(err)
	}
	c.dc.OnOpen(func() { close(c.dcOpen) })
	c.dc.OnMessage(func(msg webrtc.DataChannelMessage) { c.onDC(msg.Data) })

	pc.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		rx := &rxTrack{streamID: track.StreamID(), kind: track.Kind()}
		c.mu.Lock()
		c.tracks = append(c.tracks, rx)
		c.mu.Unlock()
		go func() {
			for {
				pkt, _, err := track.ReadRTP()
				if err != nil {
					return
				}
				var marker byte
				if len(pkt.Payload) > 7 {
					marker = pkt.Payload[7]
				}
				rx.mu.Lock()
				rx.packets = append(rx.packets, rxPacket{seq: pkt.SequenceNumber, ts: pkt.Timestamp, marker: marker})
				rx.mu.Unlock()
			}
		}()
	})
	return c
}

func (c *testClient) close() {
	c.once.Do(func() {
		close(c.stop)
		_ = c.pc.Close()
	})
}

func (c *testClient) offer() string {
	c.t.Helper()
	offer, err := c.pc.CreateOffer(nil)
	if err != nil {
		c.t.Fatal(err)
	}
	gathered := webrtc.GatheringCompletePromise(c.pc)
	if err := c.pc.SetLocalDescription(offer); err != nil {
		c.t.Fatal(err)
	}
	<-gathered
	return c.pc.LocalDescription().SDP
}

func (c *testClient) setAnswer(answer string) {
	c.t.Helper()
	if err := c.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
		c.t.Fatal(err)
	}
}

func (c *testClient) onDC(data []byte) {
	var msg media.DCMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		c.t.Errorf("bad dc message: %v", err)
		return
	}
	switch msg.Type {
	case "offer":
		if err := c.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: msg.SDP}); err != nil {
			c.t.Errorf("client set offer: %v", err)
			return
		}
		answer, err := c.pc.CreateAnswer(nil)
		if err != nil {
			c.t.Errorf("client answer: %v", err)
			return
		}
		if err := c.pc.SetLocalDescription(answer); err != nil {
			c.t.Errorf("client set answer: %v", err)
			return
		}
		c.sendDC(media.DCMessage{Type: "answer", SDP: c.pc.LocalDescription().SDP})
		c.answered.Add(1)
	case "speakers":
		c.mu.Lock()
		c.speakers = append(c.speakers, msg.Pubkeys)
		c.mu.Unlock()
	}
}

func (c *testClient) sendDC(msg media.DCMessage) {
	raw, err := json.Marshal(msg)
	if err != nil {
		c.t.Fatal(err)
	}
	if err := c.dc.SendText(string(raw)); err != nil {
		c.t.Errorf("send dc: %v", err)
	}
}

func extID(params webrtc.RTPSendParameters, uri string) uint8 {
	for _, e := range params.HeaderExtensions {
		if e.URI == uri {
			return uint8(e.ID)
		}
	}
	return 0
}

// startMedia sends Opus at 50 pps with a loud audio level, and VP8 on every
// rid at 30 fps; a layer sends a keyframe only on its first frame and after a PLI.
func (c *testClient) startMedia() {
	audioParams := c.audioSender.GetParameters()
	videoParams := c.videoSender.GetParameters()
	audioMid := extID(audioParams, sdp.SDESMidURI)
	levelID := extID(audioParams, sdp.AudioLevelURI)
	videoMid := extID(videoParams, sdp.SDESMidURI)
	ridID := extID(videoParams, sdp.SDESRTPStreamIDURI)
	var amid, vmid string
	for _, tr := range c.pc.GetTransceivers() {
		switch tr.Sender() {
		case c.audioSender:
			amid = tr.Mid()
		case c.videoSender:
			vmid = tr.Mid()
		}
	}

	go func() {
		for {
			if _, _, err := c.audioSender.ReadRTCP(); err != nil {
				return
			}
		}
	}()
	for _, rid := range rids {
		go func() {
			for {
				pkts, _, err := c.videoSender.ReadSimulcastRTCP(rid)
				if err != nil {
					return
				}
				for _, p := range pkts {
					if _, ok := p.(*rtcp.PictureLossIndication); ok {
						c.keyNeeded[rid].Store(true)
					}
				}
			}
		}()
	}

	go func() {
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		seq, ts := uint16(40000), uint32(12345)
		for {
			select {
			case <-c.stop:
				return
			case <-ticker.C:
			}
			pkt := &rtp.Packet{Header: rtp.Header{Version: 2, SequenceNumber: seq, Timestamp: ts}, Payload: []byte{0xfc, 0xff, 0xfe}}
			_ = pkt.Header.SetExtension(audioMid, []byte(amid))
			_ = pkt.Header.SetExtension(levelID, []byte{0x80 | 30})
			_ = c.audio.WriteRTP(pkt)
			seq++
			ts += 960
		}
	}()

	go func() {
		ticker := time.NewTicker(33 * time.Millisecond)
		defer ticker.Stop()
		seqs := map[string]uint16{"q": 100, "h": 20000, "f": 65500}
		tss := map[string]uint32{"q": 1000, "h": 5_000_000, "f": 4_294_000_000}
		for {
			select {
			case <-c.stop:
				return
			case <-ticker.C:
			}
			for _, rid := range rids {
				tag := byte(0x01)
				if c.keyNeeded[rid].Swap(false) {
					tag = 0x00
				}
				payload := []byte{0x10, tag, 0x00, 0x00, 0x9d, 0x01, 0x2a, rid[0], 1, 2, 3, 4, 5, 6, 7, 8}
				pkt := &rtp.Packet{Header: rtp.Header{Version: 2, Marker: true, SequenceNumber: seqs[rid], Timestamp: tss[rid]}, Payload: payload}
				_ = pkt.Header.SetExtension(videoMid, []byte(vmid))
				_ = pkt.Header.SetExtension(ridID, []byte(rid))
				_ = c.video[rid].WriteRTP(pkt)
				seqs[rid]++
				tss[rid] += 3000
			}
		}
	}()
}

func (c *testClient) tracksFrom(streamID string) []*rxTrack {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []*rxTrack
	for _, tr := range c.tracks {
		if tr.streamID == streamID {
			out = append(out, tr)
		}
	}
	return out
}

func (c *testClient) sawSpeaker(pubkey string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, list := range c.speakers {
		for _, pk := range list {
			if pk == pubkey {
				return true
			}
		}
	}
	return false
}

func waitFor(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for !cond() {
		select {
		case <-ctx.Done():
			t.Fatalf("timed out waiting for %s", what)
		case <-time.After(50 * time.Millisecond):
		}
	}
}
