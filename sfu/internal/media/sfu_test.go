package media

import (
	"strings"
	"testing"

	"github.com/pion/webrtc/v4"
)

func TestPublicIPCandidate(t *testing.T) {
	s, err := New(Config{PublicIP: "203.0.113.9", IncludeLoopback: true})
	if err != nil {
		t.Fatal(err)
	}
	pc, err := s.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	if _, err := pc.CreateDataChannel("x", nil); err != nil {
		t.Fatal(err)
	}
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	sdp := pc.LocalDescription().SDP
	if !strings.Contains(sdp, "203.0.113.9") {
		t.Fatalf("public ip missing from candidates:\n%s", sdp)
	}
	if strings.Count(sdp, "a=candidate") < 2 {
		t.Fatalf("local candidate should be kept alongside the public one:\n%s", sdp)
	}
}
