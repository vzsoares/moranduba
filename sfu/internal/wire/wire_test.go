package wire

import (
	"encoding/json"
	"testing"
	"time"

	"fiatjaf.com/nostr"
	"fiatjaf.com/nostr/nip44"
	"github.com/mailru/easyjson"
)

// clientWrap builds a wrap the way an independent client would, from the
// NIP-44 primitives, so the test does not only exercise Wrap against Unwrap.
func clientWrap(t *testing.T, sender nostr.SecretKey, sfu nostr.PubKey, content string) nostr.Event {
	t.Helper()
	return buildWrap(t, sender, sender.Public(), sfu, content, KindWrap)
}

func buildWrap(t *testing.T, sender nostr.SecretKey, claimed, sfu nostr.PubKey, content string, kind nostr.Kind) nostr.Event {
	t.Helper()
	rumor := nostr.Event{
		Kind:      KindRumor,
		PubKey:    claimed,
		CreatedAt: nostr.Now(),
		Tags:      nostr.Tags{{"p", sfu.Hex()}},
		Content:   content,
	}
	rumor.SetID()
	ck, err := nip44.GenerateConversationKey(sfu, sender)
	if err != nil {
		t.Fatal(err)
	}
	sealContent, err := nip44.Encrypt(rumor.String(), ck)
	if err != nil {
		t.Fatal(err)
	}
	seal := nostr.Event{Kind: KindSeal, CreatedAt: nostr.Now() - 3600, Content: sealContent}
	if err := seal.Sign(sender); err != nil {
		t.Fatal(err)
	}
	eph := nostr.Generate()
	ck, err = nip44.GenerateConversationKey(sfu, eph)
	if err != nil {
		t.Fatal(err)
	}
	wrapContent, err := nip44.Encrypt(seal.String(), ck)
	if err != nil {
		t.Fatal(err)
	}
	wrap := nostr.Event{Kind: kind, CreatedAt: nostr.Now(), Tags: nostr.Tags{{"p", sfu.Hex()}}, Content: wrapContent}
	if err := wrap.Sign(eph); err != nil {
		t.Fatal(err)
	}
	return wrap
}

func clientUnwrap(t *testing.T, sk nostr.SecretKey, wrap nostr.Event) (nostr.PubKey, string) {
	t.Helper()
	ck, err := nip44.GenerateConversationKey(wrap.PubKey, sk)
	if err != nil {
		t.Fatal(err)
	}
	sealJSON, err := nip44.Decrypt(wrap.Content, ck)
	if err != nil {
		t.Fatal(err)
	}
	var seal nostr.Event
	if err := easyjson.Unmarshal([]byte(sealJSON), &seal); err != nil {
		t.Fatal(err)
	}
	if !seal.VerifySignature() {
		t.Fatal("bad seal signature")
	}
	ck, err = nip44.GenerateConversationKey(seal.PubKey, sk)
	if err != nil {
		t.Fatal(err)
	}
	rumorJSON, err := nip44.Decrypt(seal.Content, ck)
	if err != nil {
		t.Fatal(err)
	}
	var rumor struct {
		Kind    int        `json:"kind"`
		Pubkey  string     `json:"pubkey"`
		Tags    [][]string `json:"tags"`
		Content string     `json:"content"`
		Sig     *string    `json:"sig"`
	}
	if err := json.Unmarshal([]byte(rumorJSON), &rumor); err != nil {
		t.Fatal(err)
	}
	if rumor.Kind != int(KindRumor) {
		t.Fatalf("rumor kind %d", rumor.Kind)
	}
	if rumor.Sig != nil {
		t.Fatal("rumor must not be signed")
	}
	if rumor.Pubkey != seal.PubKey.Hex() {
		t.Fatal("rumor pubkey != seal pubkey")
	}
	return seal.PubKey, rumor.Content
}

func TestRoundTrip(t *testing.T) {
	client := nostr.Generate()
	sfu := nostr.Generate()

	wrap := clientWrap(t, client, sfu.Public(), `{"type":"ping","id":"1"}`)
	if !wrap.VerifySignature() || wrap.PubKey == client.Public() {
		t.Fatal("outer wrap must be signed by a one-time key")
	}
	rumor, err := Unwrap(sfu, wrap)
	if err != nil {
		t.Fatal(err)
	}
	if rumor.PubKey != client.Public() {
		t.Fatalf("sender = %s, want client", rumor.PubKey.Hex())
	}
	if rumor.Content != `{"type":"ping","id":"1"}` {
		t.Fatalf("content = %q", rumor.Content)
	}

	reply, err := Wrap(sfu, client.Public(), `{"type":"pong","reply_to":"1"}`, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if reply.Kind != KindWrap {
		t.Fatalf("reply kind %d", reply.Kind)
	}
	if reply.Tags.FindWithValue("p", client.Public().Hex()) == nil {
		t.Fatal("reply wrap must p-tag the client")
	}
	if d := time.Since(reply.CreatedAt.Time()); d > time.Minute || d < -time.Minute {
		t.Fatalf("outer created_at off by %s", d)
	}
	from, content := clientUnwrap(t, client, reply)
	if from != sfu.Public() || content != `{"type":"pong","reply_to":"1"}` {
		t.Fatalf("client got %s %q", from.Hex(), content)
	}
}

func TestUnwrapAcceptsKind1059(t *testing.T) {
	client, sfu := nostr.Generate(), nostr.Generate()
	rumor, err := Unwrap(sfu, buildWrap(t, client, client.Public(), sfu.Public(), "{}", KindStoredWrap))
	if err != nil {
		t.Fatal(err)
	}
	if rumor.PubKey != client.Public() {
		t.Fatal("wrong sender")
	}
}

func TestUnwrapRejects(t *testing.T) {
	client, sfu, other := nostr.Generate(), nostr.Generate(), nostr.Generate()

	if _, err := Unwrap(other, clientWrap(t, client, sfu.Public(), "{}")); err == nil {
		t.Fatal("wrap for someone else must not open")
	}

	wrap := clientWrap(t, client, sfu.Public(), "{}")
	wrap.Kind = 1
	if _, err := Unwrap(sfu, wrap); err == nil {
		t.Fatal("wrong outer kind must be rejected")
	}

	victim := nostr.Generate()
	if _, err := Unwrap(sfu, buildWrap(t, client, victim.Public(), sfu.Public(), "{}", KindWrap)); err == nil {
		t.Fatal("rumor claiming another pubkey than the seal signer must be rejected")
	}

	tampered := clientWrap(t, client, sfu.Public(), "{}")
	tampered.Content = tampered.Content[:len(tampered.Content)-4] + "AAAA"
	if _, err := Unwrap(sfu, tampered); err == nil {
		t.Fatal("tampered wrap must be rejected")
	}
}
