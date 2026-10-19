package e2e

import (
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// tnode is a test node's connection with a background reader: a read whose
// context expires closes a coder/websocket connection, so "nothing arrives"
// is asked of the channel, never of the socket.
type tnode struct {
	c  *websocket.Conn
	in chan control.Message
}

// readMsg returns the next message, or ok=false when none comes in d.
func readMsg(n *tnode, d time.Duration) (control.Message, bool) {
	select {
	case m, ok := <-n.in:
		return m, ok
	case <-time.After(d):
		return control.Message{}, false
	}
}
