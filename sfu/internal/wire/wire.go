// Package wire implements the SFU's Nostr transport (ADR 0002): gift wraps
// with an ephemeral outer kind, and the JSON messages they carry.
package wire

import (
	"errors"
	"fmt"
	"math/rand/v2"
	"time"

	"fiatjaf.com/nostr"
	"fiatjaf.com/nostr/nip44"
	"github.com/mailru/easyjson"
)

const (
	KindWrap       nostr.Kind = 21059
	KindStoredWrap nostr.Kind = 1059
	KindSeal       nostr.Kind = 13
	KindRumor      nostr.Kind = 25051
)

var ErrNotForUs = errors.New("rumor not addressed to us")

// Wrap builds rumor (kind 25051) -> seal (kind 13, signed by sk) -> wrap
// (kind 21059, signed by a one-time key), addressed to recipient.
func Wrap(sk nostr.SecretKey, recipient nostr.PubKey, content string, now time.Time) (nostr.Event, error) {
	ts := nostr.Timestamp(now.Unix())
	rumor := nostr.Event{
		Kind:      KindRumor,
		PubKey:    sk.Public(),
		CreatedAt: ts,
		Tags:      nostr.Tags{{"p", recipient.Hex()}},
		Content:   content,
	}
	rumor.SetID()

	ck, err := nip44.GenerateConversationKey(recipient, sk)
	if err != nil {
		return nostr.Event{}, err
	}
	sealed, err := nip44.Encrypt(rumor.String(), ck)
	if err != nil {
		return nostr.Event{}, err
	}
	seal := nostr.Event{
		Kind:      KindSeal,
		CreatedAt: ts - nostr.Timestamp(rand.Int64N(2*24*3600)),
		Tags:      nostr.Tags{},
		Content:   sealed,
	}
	if err := seal.Sign(sk); err != nil {
		return nostr.Event{}, err
	}

	oneTime := nostr.Generate()
	ck, err = nip44.GenerateConversationKey(recipient, oneTime)
	if err != nil {
		return nostr.Event{}, err
	}
	wrapped, err := nip44.Encrypt(seal.String(), ck)
	if err != nil {
		return nostr.Event{}, err
	}
	// The outer created_at stays current: relays may drop old ephemeral events.
	wrap := nostr.Event{
		Kind:      KindWrap,
		CreatedAt: ts,
		Tags:      nostr.Tags{{"p", recipient.Hex()}},
		Content:   wrapped,
	}
	if err := wrap.Sign(oneTime); err != nil {
		return nostr.Event{}, err
	}
	return wrap, nil
}

// Unwrap opens a wrap addressed to sk. The returned rumor's PubKey is the
// seal signer, i.e. the authenticated sender.
func Unwrap(sk nostr.SecretKey, wrap nostr.Event) (nostr.Event, error) {
	if wrap.Kind != KindWrap && wrap.Kind != KindStoredWrap {
		return nostr.Event{}, fmt.Errorf("unexpected wrap kind %d", wrap.Kind)
	}
	if !wrap.VerifySignature() {
		return nostr.Event{}, errors.New("invalid wrap signature")
	}
	ck, err := nip44.GenerateConversationKey(wrap.PubKey, sk)
	if err != nil {
		return nostr.Event{}, err
	}
	sealJSON, err := nip44.Decrypt(wrap.Content, ck)
	if err != nil {
		return nostr.Event{}, fmt.Errorf("decrypt seal: %w", err)
	}
	var seal nostr.Event
	if err := easyjson.Unmarshal([]byte(sealJSON), &seal); err != nil {
		return nostr.Event{}, fmt.Errorf("parse seal: %w", err)
	}
	if seal.Kind != KindSeal {
		return nostr.Event{}, fmt.Errorf("unexpected seal kind %d", seal.Kind)
	}
	if !seal.VerifySignature() {
		return nostr.Event{}, errors.New("invalid seal signature")
	}
	ck, err = nip44.GenerateConversationKey(seal.PubKey, sk)
	if err != nil {
		return nostr.Event{}, err
	}
	rumorJSON, err := nip44.Decrypt(seal.Content, ck)
	if err != nil {
		return nostr.Event{}, fmt.Errorf("decrypt rumor: %w", err)
	}
	var rumor nostr.Event
	if err := easyjson.Unmarshal([]byte(rumorJSON), &rumor); err != nil {
		return nostr.Event{}, fmt.Errorf("parse rumor: %w", err)
	}
	if rumor.Kind != KindRumor {
		return nostr.Event{}, fmt.Errorf("unexpected rumor kind %d", rumor.Kind)
	}
	if rumor.PubKey != seal.PubKey {
		return nostr.Event{}, errors.New("rumor pubkey does not match seal signer")
	}
	if rumor.Tags.FindWithValue("p", sk.Public().Hex()) == nil {
		return nostr.Event{}, ErrNotForUs
	}
	return rumor, nil
}
