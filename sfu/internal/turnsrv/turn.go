// Package turnsrv runs the embedded TURN server and issues TURN REST style
// credentials: username "<unix expiry>:<pubkey>", password
// base64(HMAC-SHA1(secret, username)).
package turnsrv

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // mandated by the TURN REST credential format
	"encoding/base64"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/pion/turn/v4"
)

const (
	Realm = "moranduba"
	TTL   = 12 * time.Hour
)

// Credentials signs short-lived TURN credentials and checks them.
type Credentials struct {
	secret    []byte
	isAllowed func(pubkey string) bool
}

func NewCredentials(isAllowed func(pubkey string) bool) (*Credentials, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	return &Credentials{secret: secret, isAllowed: isAllowed}, nil
}

// Issue returns a username/password pair for pubkey, valid until now+TTL.
func (c *Credentials) Issue(pubkey string, now time.Time) (username, password string) {
	username = strconv.FormatInt(now.Add(TTL).Unix(), 10) + ":" + pubkey
	return username, c.password(username)
}

func (c *Credentials) password(username string) string {
	mac := hmac.New(sha1.New, c.secret)
	mac.Write([]byte(username))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// Key is a turn.AuthHandler: it accepts unexpired usernames whose pubkey is still allowed.
func (c *Credentials) Key(username, realm string, _ net.Addr) ([]byte, bool) {
	expiry, pubkey, ok := strings.Cut(username, ":")
	if !ok {
		return nil, false
	}
	exp, err := strconv.ParseInt(expiry, 10, 64)
	if err != nil || exp < time.Now().Unix() {
		return nil, false
	}
	if c.isAllowed != nil && !c.isAllowed(pubkey) {
		return nil, false
	}
	return turn.GenerateAuthKey(username, realm, c.password(username)), true
}

// Config is the TURN listener configuration.
type Config struct {
	Port      int
	RelayIP   net.IP
	PortMin   uint16
	PortMax   uint16
	ListenIP  string
	Validator *Credentials
}

// Start listens on UDP Port (0 picks one) and relays through RelayIP within
// [PortMin, PortMax]. Returns the port it listens on.
func Start(cfg Config) (*turn.Server, int, error) {
	listenIP := cfg.ListenIP
	if listenIP == "" {
		listenIP = "0.0.0.0"
	}
	conn, err := net.ListenPacket("udp4", net.JoinHostPort(listenIP, strconv.Itoa(cfg.Port)))
	if err != nil {
		return nil, 0, fmt.Errorf("turn listen: %w", err)
	}
	port := conn.LocalAddr().(*net.UDPAddr).Port
	server, err := turn.NewServer(turn.ServerConfig{
		Realm:       Realm,
		AuthHandler: cfg.Validator.Key,
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn: conn,
			RelayAddressGenerator: &turn.RelayAddressGeneratorPortRange{
				RelayAddress: cfg.RelayIP,
				Address:      listenIP,
				MinPort:      cfg.PortMin,
				MaxPort:      cfg.PortMax,
			},
		}},
	})
	if err != nil {
		conn.Close()
		return nil, 0, err
	}
	return server, port, nil
}
