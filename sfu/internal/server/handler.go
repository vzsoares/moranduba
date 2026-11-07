// Package server handles SFU requests (ADR 0002) and carries them over Nostr relays.
package server

import (
	"context"
	"errors"
	"net"
	"strconv"
	"time"

	"github.com/vzsoares/moranduba/sfu/internal/media"
	"github.com/vzsoares/moranduba/sfu/internal/state"
	"github.com/vzsoares/moranduba/sfu/internal/turnsrv"
	"github.com/vzsoares/moranduba/sfu/internal/wire"
)

const joinTimeout = 10 * time.Second

// Inbound is an authenticated request: Sender is the seal signer (hex).
type Inbound struct {
	Sender    string
	CreatedAt int64
	Req       wire.Request
}

type Handler struct {
	Store    *state.Store
	SFU      *media.SFU
	Creds    *turnsrv.Credentials
	ICEHost  string
	TURNPort int
	Version  string
}

func (h *Handler) Handle(ctx context.Context, in Inbound) wire.Reply {
	req := in.Req
	switch req.Type {
	case "ping":
		owner := h.Store.IsOwner(in.Sender)
		allowed := h.Store.IsAllowed(in.Sender)
		return wire.Pong(req.ID, owner, allowed, h.ICEServers(in.Sender, allowed, time.Now()), h.Version)
	case "claim":
		if err := h.Store.Claim(in.Sender, req.Code); err != nil {
			return wire.Error(req.ID, errMessage(err))
		}
		return wire.Claimed(req.ID)
	case "allow":
		count, err := h.Store.SetAllowlist(in.Sender, req.Pubkeys, in.CreatedAt)
		if err != nil {
			return wire.Error(req.ID, errMessage(err))
		}
		return wire.AllowedCount(req.ID, count)
	case "join":
		if !h.Store.IsAllowed(in.Sender) {
			return wire.Error(req.ID, "not allowed")
		}
		if req.Room == "" || req.SDP == "" {
			return wire.Error(req.ID, "bad request: room and sdp are required")
		}
		ctx, cancel := context.WithTimeout(ctx, joinTimeout)
		defer cancel()
		answer, err := h.SFU.Join(ctx, in.Sender, req.Room, req.SDP)
		if err != nil {
			return wire.Error(req.ID, "join failed: "+err.Error())
		}
		return wire.Answer(req.ID, req.Room, answer)
	default:
		return wire.Error(req.ID, "unknown type")
	}
}

// ICEServers lists the embedded STUN server, plus TURN credentials for allowed pubkeys.
func (h *Handler) ICEServers(pubkey string, allowed bool, now time.Time) []wire.ICEServer {
	hostPort := net.JoinHostPort(h.ICEHost, strconv.Itoa(h.TURNPort))
	servers := []wire.ICEServer{{URLs: []string{"stun:" + hostPort}}}
	if allowed && h.Creds != nil {
		user, pass := h.Creds.Issue(pubkey, now)
		servers = append(servers, wire.ICEServer{
			URLs:       []string{"turn:" + hostPort + "?transport=udp"},
			Username:   user,
			Credential: pass,
		})
	}
	return servers
}

func errMessage(err error) string {
	for _, known := range []error{state.ErrAlreadyClaimed, state.ErrInvalidCode, state.ErrNotOwner, state.ErrStale, state.ErrInvalidPubkey} {
		if errors.Is(err, known) {
			return err.Error()
		}
	}
	return "internal error"
}
