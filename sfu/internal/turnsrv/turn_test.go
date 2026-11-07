package turnsrv

import (
	"crypto/hmac"
	"crypto/sha1" //nolint:gosec // TURN REST format
	"encoding/base64"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/pion/turn/v4"
)

func TestCredentialFormat(t *testing.T) {
	pubkey := strings.Repeat("ab", 32)
	c, err := NewCredentials(func(pk string) bool { return pk == pubkey })
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	user, pass := c.Issue(pubkey, now)

	expiry, pk, ok := strings.Cut(user, ":")
	if !ok || pk != pubkey {
		t.Fatalf("username %q", user)
	}
	if exp, err := strconv.ParseInt(expiry, 10, 64); err != nil || exp != now.Add(TTL).Unix() {
		t.Fatalf("expiry %q", expiry)
	}
	mac := hmac.New(sha1.New, c.secret)
	mac.Write([]byte(user))
	if want := base64.StdEncoding.EncodeToString(mac.Sum(nil)); pass != want {
		t.Fatalf("password %q, want %q", pass, want)
	}

	fresh, freshPass := c.Issue(pubkey, time.Now())
	key, ok := c.Key(fresh, Realm, nil)
	if !ok {
		t.Fatal("fresh credential rejected")
	}
	if string(key) != string(turn.GenerateAuthKey(fresh, Realm, freshPass)) {
		t.Fatal("auth key mismatch")
	}

	expired, _ := c.Issue(pubkey, time.Now().Add(-TTL-time.Minute))
	if _, ok := c.Key(expired, Realm, nil); ok {
		t.Fatal("expired credential accepted")
	}
	stranger, _ := c.Issue(strings.Repeat("cd", 32), time.Now())
	if _, ok := c.Key(stranger, Realm, nil); ok {
		t.Fatal("credential for a pubkey that is no longer allowed accepted")
	}
	if _, ok := c.Key("garbage", Realm, nil); ok {
		t.Fatal("malformed username accepted")
	}
}
