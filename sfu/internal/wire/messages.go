package wire

// Request is a client-to-SFU message carried in a rumor's content.
type Request struct {
	Type    string   `json:"type"`
	ID      string   `json:"id"`
	Code    string   `json:"code,omitempty"`
	Pubkeys []string `json:"pubkeys,omitempty"`
	Room    string   `json:"room,omitempty"`
	SDP     string   `json:"sdp,omitempty"`
}

// ICEServer mirrors RTCIceServer.
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// Reply is an SFU-to-client message. Fields are set per Type.
type Reply struct {
	Type       string      `json:"type"`
	ReplyTo    string      `json:"reply_to"`
	Owner      *bool       `json:"owner,omitempty"`
	Allowed    *bool       `json:"allowed,omitempty"`
	ICEServers []ICEServer `json:"ice_servers,omitzero"`
	Version    string      `json:"version,omitempty"`
	Count      *int        `json:"count,omitempty"`
	Room       string      `json:"room,omitempty"`
	SDP        string      `json:"sdp,omitempty"`
	Message    string      `json:"message,omitempty"`
}

func Pong(replyTo string, owner, allowed bool, servers []ICEServer, version string) Reply {
	if servers == nil {
		servers = []ICEServer{}
	}
	return Reply{Type: "pong", ReplyTo: replyTo, Owner: &owner, Allowed: &allowed, ICEServers: servers, Version: version}
}

func Claimed(replyTo string) Reply { return Reply{Type: "claimed", ReplyTo: replyTo} }

func AllowedCount(replyTo string, count int) Reply {
	return Reply{Type: "allowed", ReplyTo: replyTo, Count: &count}
}

func Answer(replyTo, room, sdp string) Reply {
	return Reply{Type: "answer", ReplyTo: replyTo, Room: room, SDP: sdp}
}

func Error(replyTo, message string) Reply {
	return Reply{Type: "error", ReplyTo: replyTo, Message: message}
}
