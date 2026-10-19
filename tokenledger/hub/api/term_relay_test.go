package api

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// The browser terminal's acceptance (claude-fleet#3838, EPIC #3836 C1; BREAK-IT
// term-other-person · term-relay-orphan): a hub with sign-in, a REAL agent on the
// control channel, and the agent's real `term-pty` on a real pseudo-terminal —
// only the one command is a throwaway shell instead of fleet-term-attach.sh. Every
// run of that command is counted (a marker line per start, its process by a
// unique token), so "never reached" is a count of zero and "released" is no
// process left.

func send(t *testing.T, c *websocket.Conn, typ websocket.MessageType, b []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Write(ctx, typ, b); err != nil {
		t.Fatal(err)
	}
}
