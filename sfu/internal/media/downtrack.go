package media

import (
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

const (
	// After this long waiting for a keyframe on the target layer, switch at any frame start.
	keyframeFallback = 3 * time.Second
	keyframeRetry    = time.Second
)

var trackCounter atomic.Uint64

// downTrack forwards one publisher's audio or video to one subscriber. It
// rewrites SSRC, payload type, sequence numbers and timestamps so the
// subscriber sees one continuous stream across gating and layer switches.
type downTrack struct {
	id        string
	streamID  string
	kind      webrtc.RTPCodecType
	codec     webrtc.RTPCodecCapability
	pub       *Peer
	sub       *Peer
	sender    *webrtc.RTPSender
	clockRate float64

	bmu     sync.RWMutex
	ws      webrtc.TrackLocalWriter
	ssrc    uint32
	pt      uint8
	levelID uint8

	mu         sync.Mutex
	enabled    bool
	target     string
	current    string
	waitSince  time.Time
	lastKeyReq time.Time
	started    bool
	resync     bool
	markNext   bool
	srcSSRC    uint32
	segStart   uint16
	seqOff     uint16
	tsOff      uint32
	lastSeq    uint16
	lastTS     uint32
	lastAt     time.Time
}

func newDownTrack(kind webrtc.RTPCodecType, pub, sub *Peer) *downTrack {
	d := &downTrack{
		streamID: pub.key,
		kind:     kind,
		pub:      pub,
		sub:      sub,
	}
	n := trackCounter.Add(1)
	if kind == webrtc.RTPCodecTypeAudio {
		d.id = "audio-" + strconv.FormatUint(n, 10)
		d.codec = opusCodec.RTPCodecCapability
	} else {
		d.id = "video-" + strconv.FormatUint(n, 10)
		d.codec = vp8Codec.RTPCodecCapability
	}
	d.clockRate = float64(d.codec.ClockRate)
	return d
}

func (d *downTrack) ID() string                { return d.id }
func (d *downTrack) RID() string               { return "" }
func (d *downTrack) StreamID() string          { return d.streamID }
func (d *downTrack) Kind() webrtc.RTPCodecType { return d.kind }

func (d *downTrack) Bind(ctx webrtc.TrackLocalContext) (webrtc.RTPCodecParameters, error) {
	for _, c := range ctx.CodecParameters() {
		if !strings.EqualFold(c.MimeType, d.codec.MimeType) {
			continue
		}
		var levelID uint8
		for _, ext := range ctx.HeaderExtensions() {
			if ext.URI == sdp.AudioLevelURI && ext.ID > 0 && ext.ID < 256 {
				levelID = uint8(ext.ID)
			}
		}
		d.bmu.Lock()
		d.ws = ctx.WriteStream()
		d.ssrc = uint32(ctx.SSRC())
		d.pt = uint8(c.PayloadType)
		d.levelID = levelID
		d.bmu.Unlock()

		d.mu.Lock()
		d.resync = true
		d.current = ""
		if !d.waitSince.IsZero() {
			d.waitSince = time.Now()
		}
		d.mu.Unlock()
		return c, nil
	}
	return webrtc.RTPCodecParameters{}, webrtc.ErrUnsupportedCodec
}

func (d *downTrack) Unbind(webrtc.TrackLocalContext) error {
	d.bmu.Lock()
	d.ws = nil
	d.bmu.Unlock()
	return nil
}

func (d *downTrack) binding() (webrtc.TrackLocalWriter, uint32, uint8, uint8) {
	d.bmu.RLock()
	defer d.bmu.RUnlock()
	return d.ws, d.ssrc, d.pt, d.levelID
}

// rebase starts a new output segment at pkt, continuing the output sequence
// and, for a different source, the output clock.
func (d *downTrack) rebase(pkt *rtp.Packet, now time.Time) {
	if d.started {
		d.seqOff = d.lastSeq + 1 - pkt.SequenceNumber
		if pkt.SSRC != d.srcSSRC {
			ticks := uint32(now.Sub(d.lastAt).Seconds() * d.clockRate)
			if ticks == 0 {
				ticks = 1
			}
			d.tsOff = d.lastTS + ticks - pkt.Timestamp
		}
	} else {
		d.started = true
		d.seqOff = 0
		d.tsOff = 0
		d.lastSeq = pkt.SequenceNumber - 1
		d.lastTS = pkt.Timestamp
	}
	d.srcSSRC = pkt.SSRC
	d.segStart = pkt.SequenceNumber
	d.resync = false
	d.markNext = true
}

func (d *downTrack) rewrite(pkt *rtp.Packet, now time.Time) (uint16, uint32, bool) {
	if int16(pkt.SequenceNumber-d.segStart) < 0 {
		return 0, 0, false
	}
	seq := pkt.SequenceNumber + d.seqOff
	ts := pkt.Timestamp + d.tsOff
	if int16(seq-d.lastSeq) > 0 {
		d.lastSeq = seq
		d.lastTS = ts
		d.lastAt = now
	}
	return seq, ts, true
}

func outHeader(pkt *rtp.Packet, seq uint16, ts uint32, ssrc uint32, pt uint8) rtp.Header {
	return rtp.Header{
		Version:        2,
		Padding:        pkt.Padding,
		PaddingSize:    pkt.Header.PaddingSize,
		Marker:         pkt.Marker,
		PayloadType:    pt,
		SequenceNumber: seq,
		Timestamp:      ts,
		SSRC:           ssrc,
		CSRC:           pkt.CSRC,
	}
}

func (d *downTrack) setAudio(enabled bool) {
	d.mu.Lock()
	if d.enabled && !enabled {
		d.resync = true
	}
	d.enabled = enabled
	d.mu.Unlock()
}

func (d *downTrack) writeAudio(pkt *rtp.Packet, level byte, hasLevel bool) {
	ws, ssrc, pt, levelID := d.binding()
	if ws == nil {
		return
	}
	now := time.Now()
	d.mu.Lock()
	if !d.enabled {
		d.resync = true
		d.mu.Unlock()
		return
	}
	if !d.started || d.resync || pkt.SSRC != d.srcSSRC {
		d.rebase(pkt, now)
	}
	seq, ts, ok := d.rewrite(pkt, now)
	marker := d.markNext
	d.markNext = false
	d.mu.Unlock()
	if !ok {
		return
	}
	h := outHeader(pkt, seq, ts, ssrc, pt)
	h.Marker = h.Marker || marker
	if hasLevel && levelID != 0 {
		_ = h.SetExtension(levelID, []byte{level})
	}
	_, _ = ws.WriteRTP(&h, pkt.Payload)
}

// setVideo applies the selection for this tick and returns the rid that
// needs a keyframe request, if any.
func (d *downTrack) setVideo(enabled bool, target string, now time.Time) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !enabled || target == "" {
		d.enabled = false
		d.current = ""
		d.target = ""
		d.waitSince = time.Time{}
		return ""
	}
	d.enabled = true
	if target != d.target {
		d.target = target
		if target != d.current {
			d.waitSince = now
			d.lastKeyReq = now
			return target
		}
		d.waitSince = time.Time{}
		return ""
	}
	if d.target != d.current && now.Sub(d.lastKeyReq) >= keyframeRetry {
		if d.waitSince.IsZero() {
			d.waitSince = now
		}
		d.lastKeyReq = now
		return d.target
	}
	return ""
}

func (d *downTrack) forwardedRID() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.current != "" {
		return d.current
	}
	return d.target
}

func (d *downTrack) writeVideo(rid string, pkt *rtp.Packet, keyframe, frameStart bool) {
	ws, ssrc, pt, _ := d.binding()
	if ws == nil {
		return
	}
	now := time.Now()
	d.mu.Lock()
	if !d.enabled {
		d.mu.Unlock()
		return
	}
	if rid != d.current || pkt.SSRC != d.srcSSRC {
		if rid != d.target {
			d.mu.Unlock()
			return
		}
		fallback := frameStart && !d.waitSince.IsZero() && now.Sub(d.waitSince) > keyframeFallback
		if !keyframe && !fallback {
			d.mu.Unlock()
			return
		}
		d.current = rid
		d.waitSince = time.Time{}
		d.rebase(pkt, now)
	}
	seq, ts, ok := d.rewrite(pkt, now)
	d.markNext = false
	d.mu.Unlock()
	if !ok {
		return
	}
	h := outHeader(pkt, seq, ts, ssrc, pt)
	_, _ = ws.WriteRTP(&h, pkt.Payload)
}

// vp8Info reads the VP8 payload descriptor and the frame tag's P bit. Both
// stay unencrypted under FrameCryptor (it skips the first 10/3 frame bytes).
func vp8Info(payload []byte) (keyframe, frameStart bool) {
	if len(payload) == 0 {
		return false, false
	}
	var p codecs.VP8Packet
	if _, err := p.Unmarshal(payload); err != nil {
		return false, false
	}
	frameStart = p.S == 1 && p.PID == 0
	keyframe = frameStart && len(p.Payload) > 0 && p.Payload[0]&0x01 == 0
	return keyframe, frameStart
}
