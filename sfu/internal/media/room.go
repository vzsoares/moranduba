package media

import (
	"cmp"
	"slices"
	"sync"
	"time"
)

const (
	tickInterval = 250 * time.Millisecond
	maxAudio     = 3
	maxVideo     = 6
	// Mean (127 - dBov) over a tick at or above this counts as speaking (about -55 dBov).
	speakingLoudness = 72
	emaDecay         = 0.85
	speakerHold      = 1500 * time.Millisecond
)

// Room is one call: every active peer subscribes to every other active peer,
// and the forwarding policy gates which packets flow.
type Room struct {
	sfu *SFU
	id  string

	mu           sync.Mutex
	peers        map[string]*Peer
	active       map[string]*Peer
	nextSeq      int
	lastSpeakers []string

	kickCh chan struct{}
	done   chan struct{}
	once   sync.Once
}

func newRoom(s *SFU, id string) *Room {
	return &Room{
		sfu:    s,
		id:     id,
		peers:  map[string]*Peer{},
		active: map[string]*Peer{},
		kickCh: make(chan struct{}, 1),
		done:   make(chan struct{}),
	}
}

// add registers p and returns the peer it replaces (same pubkey rejoining).
func (r *Room) add(p *Peer) *Peer {
	r.mu.Lock()
	defer r.mu.Unlock()
	old := r.peers[p.key]
	r.peers[p.key] = p
	r.nextSeq++
	p.seq = r.nextSeq
	return old
}

func (r *Room) allPeers() []*Peer {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*Peer, 0, len(r.peers))
	for _, p := range r.peers {
		out = append(out, p)
	}
	return out
}

// activate wires a newly connected peer to everyone already active.
func (r *Room) activate(p *Peer) {
	r.mu.Lock()
	if r.peers[p.key] != p || p.closed() {
		r.mu.Unlock()
		return
	}
	for _, o := range r.active {
		p.subscribe(o)
		o.subscribe(p)
	}
	r.active[p.key] = p
	r.mu.Unlock()
	p.log.Info("peer connected")
	r.kick()
}

func (r *Room) remove(p *Peer) {
	r.mu.Lock()
	if r.peers[p.key] == p {
		delete(r.peers, p.key)
	}
	if r.active[p.key] == p {
		delete(r.active, p.key)
		for _, o := range r.active {
			p.removeOutFor(o)
			o.removeOutFor(p)
			o.unsubscribe(p)
		}
	}
	empty := len(r.peers) == 0
	r.mu.Unlock()
	if empty {
		r.sfu.dropRoom(r)
	} else {
		r.kick()
	}
}

func (r *Room) kick() {
	select {
	case r.kickCh <- struct{}{}:
	default:
	}
}

func (r *Room) stop() {
	r.once.Do(func() { close(r.done) })
}

func (r *Room) run() {
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()
	for {
		select {
		case <-r.done:
			return
		case <-ticker.C:
			r.tick(time.Now(), true)
		case <-r.kickCh:
			r.tick(time.Now(), false)
		}
	}
}

func (r *Room) activePeers() []*Peer {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*Peer, 0, len(r.active))
	for _, p := range r.active {
		out = append(out, p)
	}
	slices.SortFunc(out, func(a, b *Peer) int { return cmp.Compare(a.seq, b.seq) })
	return out
}

// tick recomputes the forwarding selection. sample is false for kicks, which
// re-apply preferences without consuming the audio level window.
func (r *Room) tick(now time.Time, sample bool) {
	peers := r.activePeers()
	if sample {
		for _, p := range peers {
			sum, n := p.levelSum.Swap(0), p.levelCount.Swap(0)
			avg := 0.0
			if n > 0 {
				avg = float64(sum) / float64(n)
			}
			p.ema = max(avg, p.ema*emaDecay)
			if n > 0 && avg >= speakingLoudness {
				p.lastSpoke = now
			}
		}
	}

	loud := slices.Clone(peers)
	slices.SortStableFunc(loud, func(a, b *Peer) int {
		if c := cmp.Compare(b.ema, a.ema); c != 0 {
			return c
		}
		return b.lastSpoke.Compare(a.lastSpoke)
	})
	recent := slices.Clone(peers)
	slices.SortStableFunc(recent, func(a, b *Peer) int { return b.lastSpoke.Compare(a.lastSpoke) })

	byKey := make(map[string]*Peer, len(peers))
	for _, p := range peers {
		byKey[p.key] = p
	}

	for _, sub := range peers {
		sub.subMu.Lock()
		pins := sub.pins
		prefs := make(map[string]string, len(sub.layerPref))
		for k, v := range sub.layerPref {
			prefs[k] = v
		}
		sub.subMu.Unlock()

		audioSel := pickExcept(loud, maxAudio, sub)
		videoSel := pickExcept(recent, maxVideo, sub)
		for k := range pins {
			videoSel[k] = true
		}
		for key, s := range sub.subscriptions() {
			pub := byKey[key]
			if pub == nil || s.pub != pub {
				continue
			}
			if s.audio != nil {
				s.audio.setAudio(audioSel[key])
			}
			if s.video != nil {
				rid := pub.pickLayer(prefs[key], now)
				if req := s.video.setVideo(videoSel[key], rid, now); req != "" {
					pub.requestKeyframe(req)
				}
			}
		}
	}

	if sample {
		r.updateSpeakers(loud, now)
	}
}

func pickExcept(ranked []*Peer, n int, except *Peer) map[string]bool {
	out := make(map[string]bool, n)
	for _, p := range ranked {
		if len(out) == n {
			break
		}
		if p != except {
			out[p.key] = true
		}
	}
	return out
}

func (r *Room) updateSpeakers(loud []*Peer, now time.Time) {
	speakers := []string{}
	for _, p := range loud {
		if !p.lastSpoke.IsZero() && now.Sub(p.lastSpoke) < speakerHold {
			speakers = append(speakers, p.key)
		}
	}
	r.mu.Lock()
	prev := r.lastSpeakers
	changed := len(prev) != len(speakers) || (len(prev) > 0 && prev[0] != speakers[0])
	if !changed {
		sortedPrev, sortedNow := slices.Sorted(slices.Values(prev)), slices.Sorted(slices.Values(speakers))
		changed = !slices.Equal(sortedPrev, sortedNow)
	}
	if changed {
		r.lastSpeakers = speakers
	}
	r.mu.Unlock()
	if !changed {
		return
	}
	for _, p := range r.activePeers() {
		_ = p.send(DCMessage{Type: "speakers", Pubkeys: speakers})
	}
}

func (r *Room) sendSpeakersTo(p *Peer) {
	r.mu.Lock()
	speakers := slices.Clone(r.lastSpeakers)
	r.mu.Unlock()
	if speakers == nil {
		speakers = []string{}
	}
	_ = p.send(DCMessage{Type: "speakers", Pubkeys: speakers})
}
