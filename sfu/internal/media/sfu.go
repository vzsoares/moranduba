// Package media is the selective forwarding core: peer connections, rooms,
// forwarding policy and DataChannel renegotiation (ADR 0002).
package media

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

var (
	opusCodec = webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeOpus,
			ClockRate:   48000,
			Channels:    2,
			SDPFmtpLine: "minptime=10;useinbandfec=1",
		},
		PayloadType: 111,
	}
	vp8Codec = webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:  webrtc.MimeTypeVP8,
			ClockRate: 90000,
			RTCPFeedback: []webrtc.RTCPFeedback{
				{Type: "ccm", Parameter: "fir"},
				{Type: "nack"},
				{Type: "nack", Parameter: "pli"},
			},
		},
		PayloadType: 96,
	}
)

const (
	DataChannelLabel = "moranduba"
	connectTimeout   = 30 * time.Second
	maxRoomIDLen     = 256
)

var ErrClosed = errors.New("sfu closed")

type Config struct {
	// PublicIP replaces host candidate addresses (NAT 1:1).
	PublicIP string
	PortMin  uint16
	PortMax  uint16
	// IncludeLoopback gathers loopback candidates (tests).
	IncludeLoopback bool
	Logger          *slog.Logger
}

type SFU struct {
	api *webrtc.API
	log *slog.Logger

	mu     sync.Mutex
	rooms  map[string]*Room
	closed bool
}

// NewMediaEngine registers Opus and VP8 plus the simulcast and audio level extensions.
func NewMediaEngine() (*webrtc.MediaEngine, error) {
	m := &webrtc.MediaEngine{}
	if err := m.RegisterCodec(opusCodec, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, err
	}
	if err := m.RegisterCodec(vp8Codec, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, err
	}
	for _, uri := range []string{sdp.SDESMidURI, sdp.SDESRTPStreamIDURI, sdp.SDESRepairRTPStreamIDURI} {
		if err := m.RegisterHeaderExtension(webrtc.RTPHeaderExtensionCapability{URI: uri}, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, err
		}
	}
	for _, uri := range []string{sdp.SDESMidURI, sdp.AudioLevelURI} {
		if err := m.RegisterHeaderExtension(webrtc.RTPHeaderExtensionCapability{URI: uri}, webrtc.RTPCodecTypeAudio); err != nil {
			return nil, err
		}
	}
	return m, nil
}

func New(cfg Config) (*SFU, error) {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	m, err := NewMediaEngine()
	if err != nil {
		return nil, err
	}
	ir := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(m, ir); err != nil {
		return nil, err
	}

	se := webrtc.SettingEngine{}
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	se.SetICETimeouts(5*time.Second, 15*time.Second, 2*time.Second)
	se.SetIncludeLoopbackCandidate(cfg.IncludeLoopback)
	se.SetInterfaceFilter(func(name string) bool {
		for _, prefix := range []string{"docker", "br-", "veth", "virbr"} {
			if strings.HasPrefix(name, prefix) {
				return false
			}
		}
		return true
	})
	if cfg.PortMin != 0 || cfg.PortMax != 0 {
		if err := se.SetEphemeralUDPPortRange(cfg.PortMin, cfg.PortMax); err != nil {
			return nil, fmt.Errorf("udp port range: %w", err)
		}
	}
	if cfg.PublicIP != "" {
		// Append keeps the local address too, so the embedded TURN relay on the
		// same host reaches the SFU without hairpin NAT.
		if err := se.SetICEAddressRewriteRules(webrtc.ICEAddressRewriteRule{
			External:        []string{cfg.PublicIP},
			AsCandidateType: webrtc.ICECandidateTypeHost,
			Mode:            webrtc.ICEAddressRewriteAppend,
		}); err != nil {
			return nil, fmt.Errorf("public ip: %w", err)
		}
	}

	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(ir), webrtc.WithSettingEngine(se))
	return &SFU{api: api, log: logger, rooms: map[string]*Room{}}, nil
}

// Join answers a participant's offer for room. The answer carries all local
// candidates because there is no trickle ICE over Nostr.
func (s *SFU) Join(ctx context.Context, pubkey, roomID, offer string) (string, error) {
	if roomID == "" || len(roomID) > maxRoomIDLen {
		return "", errors.New("invalid room")
	}
	p := newPeer(s, pubkey)
	old, err := s.attach(roomID, p)
	if err != nil {
		return "", err
	}
	if old != nil {
		old.Close()
	}
	answer, err := p.start(ctx, offer)
	if err != nil {
		p.Close()
		return "", err
	}
	time.AfterFunc(connectTimeout, func() {
		if !p.activated.Load() {
			p.log.Info("peer did not connect in time")
			p.Close()
		}
	})
	return answer, nil
}

func (s *SFU) attach(roomID string, p *Peer) (*Peer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, ErrClosed
	}
	r := s.rooms[roomID]
	if r == nil {
		r = newRoom(s, roomID)
		s.rooms[roomID] = r
		go r.run()
	}
	p.room = r
	p.log = s.log.With("room", roomID, "peer", shortKey(p.key))
	return r.add(p), nil
}

func (s *SFU) dropRoom(r *Room) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r.mu.Lock()
	empty := len(r.peers) == 0
	r.mu.Unlock()
	if empty && s.rooms[r.id] == r {
		delete(s.rooms, r.id)
		r.stop()
	}
}

// Close disconnects every peer.
func (s *SFU) Close() {
	s.mu.Lock()
	s.closed = true
	var peers []*Peer
	for _, r := range s.rooms {
		peers = append(peers, r.allPeers()...)
	}
	s.mu.Unlock()
	for _, p := range peers {
		p.Close()
	}
}

func shortKey(k string) string {
	if len(k) > 8 {
		return k[:8]
	}
	return k
}

// Participants lists the connected pubkeys in a room.
func (s *SFU) Participants(roomID string) []string {
	s.mu.Lock()
	r := s.rooms[roomID]
	s.mu.Unlock()
	if r == nil {
		return nil
	}
	peers := r.activePeers()
	out := make([]string, 0, len(peers))
	for _, p := range peers {
		out = append(out, p.key)
	}
	return out
}
