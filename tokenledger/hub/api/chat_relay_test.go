package api

import (
	"context"
	"testing"
)

// The chat relay's acceptance (claude-fleet#3644, EPIC #3642 C2; BREAK-IT
// chat-relay-wrong-person): a hub, a REAL agent on the control channel, and a
// unix socket standing in for the login's conversation service at
// $FLEET_CONF_DIR/webchat/chat.sock. A statement signed wrong, expired, minted
// for another relay or for another login closes the stream, and the socket never
// receives a byte; the target cannot be changed by anything the hub sends; an
// agent that did not offer CapChat is never sent an open.

func TestChatRelayNodeOffline(t *testing.T) {
	h := newFleetHarness(t)
	_, err := h.srv.dialChatRelay(context.Background(), "alice", "nowhere", "nobody")
	if re, ok := err.(*sshRelayError); !ok || re.code != "NODE_OFFLINE" {
		t.Fatalf("dial = %v, want NODE_OFFLINE", err)
	}
}
