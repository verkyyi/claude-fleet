package agent

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent half of the relay (claude-fleet#1413).
//
// The hub asks, on the control channel, for one relay; the agent dials a fresh
// data stream back to the hub for it and splices that onto the local sshd. The
// agent opens no listener: both of its connections are outbound, and the one
// local connection goes to loopback. sshd does the authenticating, as it does
// for anyone who reaches port 22 — the agent only moves bytes.

// sshRelayTarget is the one address a relay may reach. Not configurable from the
// hub: a relay is a way into THIS machine's sshd, never a general forwarder.
// A variable only so tests can point it at a throwaway server.
var sshRelayTarget = "127.0.0.1:22"

// sshRelayDialTimeout bounds the data stream's dial and the sshd connect.
const sshRelayDialTimeout = 15 * time.Second

// sshRelayDataURL is the data stream's ws(s) URL for relay id.
func sshRelayDataURL(hub, id string) string {
	u := nodeURL(hub)
	return strings.TrimSuffix(u, control.Path) + control.SSHRelayDataPath + "?id=" + url.QueryEscape(id)
}

// openSSHRelay serves one TypeSSHRelayOpen. ctx is the control channel's session:
// when that link drops, every relay it opened is closed with it.
func (a *Agent) openSSHRelay(ctx context.Context, m control.Message) {
	var ro control.SSHRelayOpen
	if err := json.Unmarshal(m.Payload, &ro); err != nil || ro.RelayID == "" {
		return
	}
	dctx, cancel := context.WithTimeout(ctx, sshRelayDialTimeout)
	defer cancel()
	ws, _, err := websocket.Dial(dctx, sshRelayDataURL(a.cfg.HubURL, ro.RelayID), &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization":  []string{"Bearer " + a.cfg.Token},
			"X-Relay-Secret": []string{ro.Secret},
		},
	})
	if err != nil {
		log.Printf("relay %s: dial the hub: %v", short(ro.RelayID), err)
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(1 << 20)

	var d net.Dialer
	tcp, err := d.DialContext(dctx, "tcp", sshRelayTarget)
	if err != nil {
		// The hub passes the reason on to the person, who otherwise sees
		// only "connection closed" from ssh.
		ws.Close(websocket.StatusInternalError, "sshd unreachable on this machine")
		return
	}
	cancel()
	splice(ctx, ws, tcp)
}

// splice copies bytes both ways between ws and tcp until either side ends or
// ctx does, then closes both. Each direction half-closes nothing: SSH ends its
// own session, and a stream that has stopped in one direction is finished.
func splice(ctx context.Context, ws *websocket.Conn, tcp net.Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	nc := websocket.NetConn(ctx, ws, websocket.MessageBinary)
	var once sync.Once
	done := func() {
		once.Do(func() {
			cancel()
			tcp.Close()
		})
	}
	go func() {
		<-ctx.Done()
		done()
	}()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(nc, tcp); done() }()
	go func() { defer wg.Done(); _, _ = io.Copy(tcp, nc); done() }()
	wg.Wait()
	ws.Close(websocket.StatusNormalClosure, "")
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// SetSSHRelayTargetForTest points relays at addr instead of the local sshd ("" =
// back to 127.0.0.1:22). For the hub's end-to-end tests only.
func SetSSHRelayTargetForTest(addr string) {
	if addr == "" {
		addr = "127.0.0.1:22"
	}
	sshRelayTarget = addr
}
