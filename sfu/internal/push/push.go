// Package push rings members' devices through Web Push (RFC 8030/8291
// with VAPID). UnifiedPush endpoints take the same messages, so one sender
// covers browsers and the Android app.
package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"

	"github.com/vzsoares/moranduba/sfu/internal/state"
)

const (
	file = "push.json"
	// Per pubkey: a few browsers and phones.
	maxDevices = 8
	// A ring is stale once the call likely stopped ringing.
	ringTTL      = 60
	ringInterval = 10 * time.Second
	subscriber   = "https://github.com/vzsoares/moranduba"
)

var (
	ErrBadSubscription = errors.New("bad subscription")
	ErrTooSoon         = errors.New("too soon")
)

// Device is one push subscription.
type Device struct {
	Endpoint string `json:"endpoint"`
	P256dh   string `json:"p256dh"`
	Auth     string `json:"auth"`
}

type fileState struct {
	PublicKey  string              `json:"vapid_public"`
	PrivateKey string              `json:"vapid_private"`
	Devices    map[string][]Device `json:"devices"`
}

// Message is the push payload. It names no group: the app opens, sees
// the call's presence, and rings from there.
type Message struct {
	Type   string `json:"t"`
	From   string `json:"from"`
	CallID string `json:"call"`
}

// Store keeps the VAPID key and subscriptions in DATA_DIR/push.json.
type Store struct {
	mu       sync.Mutex
	path     string
	state    fileState
	lastRing map[string]time.Time
	client   webpush.HTTPClient
}

// Open loads DATA_DIR/push.json, creating a VAPID key on first start.
func Open(dir string) (*Store, error) {
	s := &Store{
		path:     filepath.Join(dir, file),
		lastRing: map[string]time.Time{},
		client:   &http.Client{Timeout: 10 * time.Second},
	}
	raw, err := os.ReadFile(s.path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		private, public, err := webpush.GenerateVAPIDKeys()
		if err != nil {
			return nil, err
		}
		s.state = fileState{PublicKey: public, PrivateKey: private, Devices: map[string][]Device{}}
		if err := s.save(); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(raw, &s.state); err != nil {
			return nil, fmt.Errorf("%s: %w", s.path, err)
		}
		if s.state.Devices == nil {
			s.state.Devices = map[string][]Device{}
		}
	}
	return s, nil
}

// PublicKey is the VAPID application server key, base64url.
func (s *Store) PublicKey() string { return s.state.PublicKey }

// Subscribe adds or refreshes pubkey's device; the oldest goes past the cap.
func (s *Store) Subscribe(pubkey string, d Device) error {
	u, err := url.Parse(d.Endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" || d.P256dh == "" || d.Auth == "" {
		return ErrBadSubscription
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	devices := slices.DeleteFunc(slices.Clone(s.state.Devices[pubkey]), func(old Device) bool {
		return old.Endpoint == d.Endpoint
	})
	devices = append(devices, d)
	if len(devices) > maxDevices {
		devices = devices[len(devices)-maxDevices:]
	}
	s.state.Devices[pubkey] = devices
	return s.save()
}

func (s *Store) Unsubscribe(pubkey, endpoint string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Devices[pubkey] = slices.DeleteFunc(s.state.Devices[pubkey], func(d Device) bool {
		return d.Endpoint == endpoint
	})
	return s.save()
}

// Ring pushes msg to every device of targets. A sender may ring once per
// ringInterval; a "stop" message is never held back. Returns how many
// devices accepted it.
func (s *Store) Ring(ctx context.Context, sender string, targets []string, msg Message, now time.Time) (int, error) {
	payload, err := json.Marshal(msg)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	if msg.Type == "ring" {
		if last, ok := s.lastRing[sender]; ok && now.Sub(last) < ringInterval {
			s.mu.Unlock()
			return 0, ErrTooSoon
		}
		s.lastRing[sender] = now
	}
	type send struct {
		pubkey string
		device Device
	}
	var sends []send
	for _, pk := range targets {
		if pk == sender {
			continue
		}
		for _, d := range s.state.Devices[pk] {
			sends = append(sends, send{pk, d})
		}
	}
	s.mu.Unlock()

	sent := 0
	var gone []send
	for _, x := range sends {
		resp, err := webpush.SendNotificationWithContext(ctx, payload, &webpush.Subscription{
			Endpoint: x.device.Endpoint,
			Keys:     webpush.Keys{P256dh: x.device.P256dh, Auth: x.device.Auth},
		}, &webpush.Options{
			HTTPClient:      s.client,
			Subscriber:      subscriber,
			TTL:             ringTTL,
			Urgency:         webpush.UrgencyHigh,
			Topic:           "ring",
			VAPIDPublicKey:  s.state.PublicKey,
			VAPIDPrivateKey: s.state.PrivateKey,
		})
		if err != nil {
			continue
		}
		resp.Body.Close()
		switch {
		case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
			gone = append(gone, x)
		case resp.StatusCode < 300:
			sent++
		}
	}
	for _, x := range gone {
		if err := s.Unsubscribe(x.pubkey, x.device.Endpoint); err != nil {
			return sent, err
		}
	}
	return sent, nil
}

func (s *Store) save() error {
	raw, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	return state.WriteAtomic(s.path, append(raw, '\n'), 0o600)
}
