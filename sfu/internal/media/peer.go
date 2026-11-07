package media

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

const (
	answerTimeout  = 15 * time.Second
	pliMinInterval = 300 * time.Millisecond
	layerStale     = 1500 * time.Millisecond
	// Video tracks without a rid (no simulcast) use this layer name.
	singleLayer = "single"
)

var layerOrder = []string{"q", "h", "f"}

// DCMessage is the JSON carried on the moranduba DataChannel.
type DCMessage struct {
	Type    string   `json:"type"`
	SDP     string   `json:"sdp,omitempty"`
	Pubkeys []string `json:"pubkeys,omitzero"`
	Pubkey  string   `json:"pubkey,omitempty"`
	RID     string   `json:"rid,omitempty"`
}

type layer struct {
	rid        string
	ssrc       uint32
	lastPacket atomic.Int64
	lastPLI    atomic.Int64
}

type subscription struct {
	pub   *Peer
	audio *downTrack
	video *downTrack
}

// Peer is one participant's PeerConnection: it publishes one audio and one
// simulcast video stream and subscribes to everyone else in the room.
type Peer struct {
	sfu  *SFU
	room *Room
	key  string
	seq  int
	log  *slog.Logger
	pc   *webrtc.PeerConnection
	dc   *webrtc.DataChannel

	layerMu  sync.RWMutex
	layers   map[string]*layer
	outMu    sync.Mutex
	audioOut atomic.Pointer[[]*downTrack]
	videoOut atomic.Pointer[[]*downTrack]

	levelSum   atomic.Uint64
	levelCount atomic.Uint64
	// Owned by the room goroutine.
	ema       float64
	lastSpoke time.Time

	subMu     sync.Mutex
	subs      map[string]*subscription
	pins      map[string]bool
	layerPref map[string]string

	opsMu   sync.Mutex
	ops     []func() bool
	wake    chan struct{}
	answers chan string

	dcOpen     atomic.Bool
	activated  atomic.Bool
	negotiated atomic.Int64
	done       chan struct{}
	closeOnce  sync.Once
}

func newPeer(s *SFU, pubkey string) *Peer {
	return &Peer{
		sfu:       s,
		key:       pubkey,
		log:       s.log,
		layers:    map[string]*layer{},
		subs:      map[string]*subscription{},
		pins:      map[string]bool{},
		layerPref: map[string]string{},
		wake:      make(chan struct{}, 1),
		answers:   make(chan string, 4),
		done:      make(chan struct{}),
	}
}

func (p *Peer) start(ctx context.Context, offer string) (string, error) {
	pc, err := p.sfu.api.NewPeerConnection(webrtc.Configuration{SDPSemantics: webrtc.SDPSemanticsUnifiedPlan})
	if err != nil {
		return "", err
	}
	p.pc = pc
	select {
	case <-p.done:
		_ = pc.Close()
		return "", ErrClosed
	default:
	}

	ordered, negotiated, id := true, true, uint16(0)
	dc, err := pc.CreateDataChannel(DataChannelLabel, &webrtc.DataChannelInit{Ordered: &ordered, Negotiated: &negotiated, ID: &id})
	if err != nil {
		return "", err
	}
	p.dc = dc
	dc.OnOpen(func() {
		p.dcOpen.Store(true)
		p.room.sendSpeakersTo(p)
		p.poke()
	})
	dc.OnClose(func() { go p.Close() })
	dc.OnMessage(func(msg webrtc.DataChannelMessage) { p.onDCMessage(msg.Data) })

	pc.OnTrack(func(track *webrtc.TrackRemote, recv *webrtc.RTPReceiver) {
		switch track.Kind() {
		case webrtc.RTPCodecTypeAudio:
			go p.readAudio(track, recv)
		case webrtc.RTPCodecTypeVideo:
			go p.readVideo(track)
		}
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		p.log.Debug("connection state", "state", state.String())
		switch state {
		case webrtc.PeerConnectionStateConnected:
			if p.activated.CompareAndSwap(false, true) {
				p.room.activate(p)
			}
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			go p.Close()
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		return "", err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return "", err
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		return "", err
	}
	select {
	case <-gathered:
	case <-ctx.Done():
		return "", ctx.Err()
	}
	go p.signalLoop()
	return pc.LocalDescription().SDP, nil
}

// Close tears the peer down; safe to call repeatedly from any goroutine.
func (p *Peer) Close() {
	p.closeOnce.Do(func() {
		close(p.done)
		if p.room != nil {
			p.room.remove(p)
		}
		p.audioOut.Store(nil)
		p.videoOut.Store(nil)
		if p.pc != nil {
			_ = p.pc.Close()
		}
		p.log.Info("peer closed")
	})
}

func (p *Peer) closed() bool {
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

// enqueue runs op on the signaling goroutine; op reports whether it changed
// the transceivers and needs a renegotiation.
func (p *Peer) enqueue(op func() bool) {
	p.opsMu.Lock()
	p.ops = append(p.ops, op)
	p.opsMu.Unlock()
	p.poke()
}

func (p *Peer) poke() {
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

// signalLoop serializes transceiver changes and SFU-initiated offers: at most
// one offer is in flight and changes made meanwhile go into the next one.
func (p *Peer) signalLoop() {
	var pending, inFlight bool
	var deadline <-chan time.Time
	for {
		select {
		case <-p.done:
			return
		case <-p.wake:
		case sdpText := <-p.answers:
			if !inFlight {
				p.log.Warn("unexpected answer")
				continue
			}
			if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: sdpText}); err != nil {
				p.log.Warn("set answer", "err", err)
				go p.Close()
				return
			}
			inFlight = false
			deadline = nil
			p.negotiated.Add(1)
		case <-deadline:
			p.log.Warn("no answer to renegotiation offer")
			go p.Close()
			return
		}

		p.opsMu.Lock()
		ops := p.ops
		p.ops = nil
		p.opsMu.Unlock()
		for _, op := range ops {
			if op() {
				pending = true
			}
		}

		if !pending || inFlight || !p.dcOpen.Load() || p.pc.SignalingState() != webrtc.SignalingStateStable {
			continue
		}
		offer, err := p.pc.CreateOffer(nil)
		if err != nil {
			p.log.Warn("create offer", "err", err)
			continue
		}
		if err := p.pc.SetLocalDescription(offer); err != nil {
			p.log.Warn("set offer", "err", err)
			continue
		}
		if err := p.send(DCMessage{Type: "offer", SDP: p.pc.LocalDescription().SDP}); err != nil {
			p.log.Warn("send offer", "err", err)
			go p.Close()
			return
		}
		pending = false
		inFlight = true
		deadline = time.After(answerTimeout)
	}
}

func (p *Peer) send(msg DCMessage) error {
	if !p.dcOpen.Load() {
		return errors.New("datachannel not open")
	}
	raw, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return p.dc.SendText(string(raw))
}

func (p *Peer) onDCMessage(data []byte) {
	var msg DCMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		p.log.Debug("bad datachannel message", "err", err)
		return
	}
	switch msg.Type {
	case "answer":
		select {
		case p.answers <- msg.SDP:
		case <-p.done:
		}
	case "layer":
		if !slices.Contains(layerOrder, msg.RID) || msg.Pubkey == "" {
			return
		}
		p.subMu.Lock()
		p.layerPref[msg.Pubkey] = msg.RID
		p.subMu.Unlock()
		p.room.kick()
	case "pin":
		pins := make(map[string]bool, len(msg.Pubkeys))
		for _, pk := range msg.Pubkeys {
			pins[pk] = true
		}
		p.subMu.Lock()
		p.pins = pins
		p.subMu.Unlock()
		p.room.kick()
	default:
		p.log.Debug("unknown datachannel message", "type", msg.Type)
	}
}

// subscribe adds pub's audio and video to this peer (signaling goroutine).
func (p *Peer) subscribe(pub *Peer) {
	p.enqueue(func() bool {
		if p.closed() || pub.closed() {
			return false
		}
		changed := false
		p.subMu.Lock()
		old := p.subs[pub.key]
		p.subMu.Unlock()
		if old != nil {
			if old.pub == pub {
				return false
			}
			changed = p.dropSubscription(old)
		}
		s := &subscription{pub: pub}
		for _, kind := range []webrtc.RTPCodecType{webrtc.RTPCodecTypeAudio, webrtc.RTPCodecTypeVideo} {
			d := newDownTrack(kind, pub, p)
			tr, err := p.pc.AddTransceiverFromTrack(d, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendonly})
			if err != nil {
				p.log.Warn("add track", "err", err)
				continue
			}
			d.sender = tr.Sender()
			go drainRTCP(d)
			if kind == webrtc.RTPCodecTypeAudio {
				s.audio = d
			} else {
				s.video = d
			}
			pub.addOut(d)
			changed = true
		}
		p.subMu.Lock()
		p.subs[pub.key] = s
		p.subMu.Unlock()
		return changed
	})
}

// unsubscribe removes pub's tracks from this peer (signaling goroutine).
func (p *Peer) unsubscribe(pub *Peer) {
	p.enqueue(func() bool {
		p.subMu.Lock()
		s := p.subs[pub.key]
		p.subMu.Unlock()
		if s == nil || s.pub != pub {
			return false
		}
		return p.dropSubscription(s)
	})
}

func (p *Peer) dropSubscription(s *subscription) bool {
	p.subMu.Lock()
	if p.subs[s.pub.key] == s {
		delete(p.subs, s.pub.key)
	}
	p.subMu.Unlock()
	changed := false
	for _, d := range []*downTrack{s.audio, s.video} {
		if d == nil {
			continue
		}
		s.pub.removeOut(d)
		if p.closed() {
			continue
		}
		if err := p.pc.RemoveTrack(d.sender); err != nil {
			p.log.Debug("remove track", "err", err)
			continue
		}
		changed = true
	}
	return changed
}

func (p *Peer) subscriptions() map[string]*subscription {
	p.subMu.Lock()
	defer p.subMu.Unlock()
	out := make(map[string]*subscription, len(p.subs))
	for k, v := range p.subs {
		out[k] = v
	}
	return out
}

func (p *Peer) addOut(d *downTrack) {
	p.outMu.Lock()
	defer p.outMu.Unlock()
	target := &p.videoOut
	if d.kind == webrtc.RTPCodecTypeAudio {
		target = &p.audioOut
	}
	var next []*downTrack
	if cur := target.Load(); cur != nil {
		next = slices.Clone(*cur)
	}
	next = append(next, d)
	target.Store(&next)
}

func (p *Peer) removeOut(d *downTrack) {
	p.removeOutWhere(func(x *downTrack) bool { return x == d })
}

// removeOutFor drops every downtrack feeding sub.
func (p *Peer) removeOutFor(sub *Peer) {
	p.removeOutWhere(func(x *downTrack) bool { return x.sub == sub })
}

func (p *Peer) removeOutWhere(match func(*downTrack) bool) {
	p.outMu.Lock()
	defer p.outMu.Unlock()
	for _, target := range []*atomic.Pointer[[]*downTrack]{&p.audioOut, &p.videoOut} {
		cur := target.Load()
		if cur == nil {
			continue
		}
		next := slices.DeleteFunc(slices.Clone(*cur), match)
		target.Store(&next)
	}
}

func drainRTCP(d *downTrack) {
	for {
		pkts, _, err := d.sender.ReadRTCP()
		if err != nil {
			return
		}
		if d.kind != webrtc.RTPCodecTypeVideo {
			continue
		}
		for _, pkt := range pkts {
			switch pkt.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				if rid := d.forwardedRID(); rid != "" {
					d.pub.requestKeyframe(rid)
				}
			}
		}
	}
}

func (p *Peer) readAudio(track *webrtc.TrackRemote, recv *webrtc.RTPReceiver) {
	var levelID uint8
	for _, ext := range recv.GetParameters().HeaderExtensions {
		if ext.URI == sdp.AudioLevelURI && ext.ID > 0 && ext.ID < 256 {
			levelID = uint8(ext.ID)
		}
	}
	for {
		pkt, _, err := track.ReadRTP()
		if err != nil {
			return
		}
		var level byte
		hasLevel := false
		if levelID != 0 {
			if raw := pkt.Header.GetExtension(levelID); len(raw) > 0 {
				level = raw[0]
				hasLevel = true
				p.levelSum.Add(uint64(127 - min(level&0x7f, 127)))
				p.levelCount.Add(1)
			}
		}
		if outs := p.audioOut.Load(); outs != nil {
			for _, d := range *outs {
				d.writeAudio(pkt, level, hasLevel)
			}
		}
	}
}

func (p *Peer) readVideo(track *webrtc.TrackRemote) {
	rid := track.RID()
	if rid == "" {
		rid = singleLayer
	}
	l := &layer{rid: rid, ssrc: uint32(track.SSRC())}
	p.layerMu.Lock()
	p.layers[rid] = l
	p.layerMu.Unlock()
	p.log.Debug("video layer", "rid", rid, "ssrc", l.ssrc)
	defer func() {
		p.layerMu.Lock()
		if p.layers[rid] == l {
			delete(p.layers, rid)
		}
		p.layerMu.Unlock()
	}()
	for {
		pkt, _, err := track.ReadRTP()
		if err != nil {
			return
		}
		l.lastPacket.Store(time.Now().UnixNano())
		p.forwardVideo(rid, pkt)
	}
}

func (p *Peer) forwardVideo(rid string, pkt *rtp.Packet) {
	outs := p.videoOut.Load()
	if outs == nil || len(*outs) == 0 {
		return
	}
	keyframe, frameStart := vp8Info(pkt.Payload)
	for _, d := range *outs {
		d.writeVideo(rid, pkt, keyframe, frameStart)
	}
}

// requestKeyframe sends a PLI for the layer, rate limited per layer.
func (p *Peer) requestKeyframe(rid string) {
	p.layerMu.RLock()
	l := p.layers[rid]
	p.layerMu.RUnlock()
	if l == nil || p.pc == nil {
		return
	}
	now := time.Now().UnixNano()
	last := l.lastPLI.Load()
	if now-last < int64(pliMinInterval) || !l.lastPLI.CompareAndSwap(last, now) {
		return
	}
	_ = p.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: l.ssrc}})
}

// pickLayer returns the preferred active layer, else the nearest lower, else
// the nearest higher one; "" if no video is arriving.
func (p *Peer) pickLayer(pref string, now time.Time) string {
	p.layerMu.RLock()
	defer p.layerMu.RUnlock()
	active := func(rid string) bool {
		l := p.layers[rid]
		return l != nil && now.UnixNano()-l.lastPacket.Load() < int64(layerStale)
	}
	if active(singleLayer) {
		return singleLayer
	}
	idx := slices.Index(layerOrder, pref)
	if idx < 0 {
		idx = slices.Index(layerOrder, "h")
	}
	for i := idx; i >= 0; i-- {
		if active(layerOrder[i]) {
			return layerOrder[i]
		}
	}
	for i := idx + 1; i < len(layerOrder); i++ {
		if active(layerOrder[i]) {
			return layerOrder[i]
		}
	}
	return ""
}
