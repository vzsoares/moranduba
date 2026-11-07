package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"fiatjaf.com/nostr"

	"github.com/vzsoares/moranduba/sfu/internal/wire"
)

const (
	maxSkew        = 5 * time.Minute
	seenTTL        = 15 * time.Minute
	publishTimeout = 5 * time.Second
	maxBackoff     = 30 * time.Second
	maxInFlight    = 64
)

// Relays keeps a subscription for wraps addressed to the SFU on every relay,
// reconnecting with backoff, and publishes replies to all connected relays.
type Relays struct {
	urls    []string
	sk      nostr.SecretKey
	handler *Handler
	log     *slog.Logger

	mu    sync.Mutex
	conns map[string]*nostr.Relay
	seen  map[nostr.ID]time.Time

	attempts sync.WaitGroup
	slots    chan struct{}
}

func NewRelays(urls []string, sk nostr.SecretKey, handler *Handler, logger *slog.Logger) *Relays {
	return &Relays{
		urls:    urls,
		sk:      sk,
		handler: handler,
		log:     logger,
		conns:   map[string]*nostr.Relay{},
		seen:    map[nostr.ID]time.Time{},
		slots:   make(chan struct{}, maxInFlight),
	}
}

// Run starts one connection loop per relay; they stop when ctx is done.
func (r *Relays) Run(ctx context.Context) {
	r.attempts.Add(len(r.urls))
	for _, url := range r.urls {
		go r.loop(ctx, url)
	}
}

// WaitAttempted blocks until every relay has been tried once or timeout passes.
func (r *Relays) WaitAttempted(timeout time.Duration) {
	done := make(chan struct{})
	go func() {
		r.attempts.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
	}
}

// Connected returns the URLs with a live connection.
func (r *Relays) Connected() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.conns))
	for url := range r.conns {
		out = append(out, url)
	}
	return out
}

func (r *Relays) loop(ctx context.Context, url string) {
	var once sync.Once
	attempted := func() { once.Do(r.attempts.Done) }
	defer attempted()

	backoff := time.Second
	for ctx.Err() == nil {
		err := r.session(ctx, url, attempted, func() { backoff = time.Second })
		attempted()
		if ctx.Err() != nil {
			return
		}
		r.log.Warn("relay disconnected", "relay", url, "err", err, "retry_in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, maxBackoff)
	}
}

func (r *Relays) session(ctx context.Context, url string, attempted, connected func()) error {
	dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	relay, err := nostr.RelayConnect(dialCtx, url, nostr.RelayOptions{})
	cancel()
	if err != nil {
		return err
	}
	defer relay.Close()

	pk := r.sk.Public().Hex()
	live, err := relay.Subscribe(ctx, nostr.Filter{
		Kinds: []nostr.Kind{wire.KindWrap},
		Tags:  nostr.TagMap{"p": {pk}},
	}, nostr.SubscriptionOptions{Label: "sfu"})
	if err != nil {
		return err
	}
	stored, err := relay.Subscribe(ctx, nostr.Filter{
		Kinds: []nostr.Kind{wire.KindStoredWrap},
		Tags:  nostr.TagMap{"p": {pk}},
		Since: nostr.Timestamp(time.Now().Add(-maxSkew).Unix()),
	}, nostr.SubscriptionOptions{Label: "sfu-stored"})
	if err != nil {
		return err
	}

	r.mu.Lock()
	r.conns[url] = relay
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		if r.conns[url] == relay {
			delete(r.conns, url)
		}
		r.mu.Unlock()
	}()
	r.log.Info("relay connected", "relay", url)
	connected()
	attempted()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-relay.Context().Done():
			return context.Cause(relay.Context())
		case reason := <-live.ClosedReason:
			return &closedError{reason}
		case reason := <-stored.ClosedReason:
			return &closedError{reason}
		case ev, ok := <-live.Events:
			if !ok {
				return errSubscriptionEnded
			}
			r.dispatch(ctx, ev)
		case ev, ok := <-stored.Events:
			if !ok {
				return errSubscriptionEnded
			}
			r.dispatch(ctx, ev)
		}
	}
}

type closedError struct{ reason string }

func (e *closedError) Error() string { return "subscription closed: " + e.reason }

var errSubscriptionEnded = &closedError{"ended"}

func (r *Relays) firstSeen(id nostr.ID, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.seen[id]; ok {
		return false
	}
	if len(r.seen) > 4096 {
		for k, t := range r.seen {
			if now.Sub(t) > seenTTL {
				delete(r.seen, k)
			}
		}
	}
	r.seen[id] = now
	return true
}

func (r *Relays) dispatch(ctx context.Context, ev nostr.Event) {
	if !r.firstSeen(ev.ID, time.Now()) {
		return
	}
	select {
	case r.slots <- struct{}{}:
	default:
		r.log.Warn("too many requests in flight, dropping")
		return
	}
	go func() {
		defer func() { <-r.slots }()
		r.handle(ctx, ev)
	}()
}

func (r *Relays) handle(ctx context.Context, ev nostr.Event) {
	rumor, err := wire.Unwrap(r.sk, ev)
	if err != nil {
		r.log.Debug("dropping wrap", "err", err)
		return
	}
	now := time.Now()
	age := now.Sub(rumor.CreatedAt.Time())
	if age > maxSkew || age < -maxSkew {
		r.log.Debug("dropping stale rumor", "age", age)
		return
	}
	var req wire.Request
	if err := json.Unmarshal([]byte(rumor.Content), &req); err != nil {
		r.reply(ctx, rumor.PubKey, wire.Error("", "bad request: invalid json"))
		return
	}
	r.log.Info("request", "type", req.Type, "from", rumor.PubKey.Hex()[:8])
	reply := r.handler.Handle(ctx, Inbound{Sender: rumor.PubKey.Hex(), CreatedAt: int64(rumor.CreatedAt), Req: req})
	r.reply(ctx, rumor.PubKey, reply)
}

func (r *Relays) reply(ctx context.Context, to nostr.PubKey, reply wire.Reply) {
	content, err := json.Marshal(reply)
	if err != nil {
		r.log.Error("marshal reply", "err", err)
		return
	}
	ev, err := wire.Wrap(r.sk, to, string(content), time.Now())
	if err != nil {
		r.log.Error("wrap reply", "err", err)
		return
	}
	r.mu.Lock()
	relays := make([]*nostr.Relay, 0, len(r.conns))
	for _, c := range r.conns {
		relays = append(relays, c)
	}
	r.mu.Unlock()
	if len(relays) == 0 {
		r.log.Warn("no relay connected, reply dropped", "type", reply.Type)
		return
	}
	var wg sync.WaitGroup
	for _, relay := range relays {
		wg.Go(func() {
			pctx, cancel := context.WithTimeout(ctx, publishTimeout)
			defer cancel()
			if err := relay.Publish(pctx, ev); err != nil {
				r.log.Warn("publish reply", "relay", relay.URL, "err", err)
			}
		})
	}
	wg.Wait()
}
