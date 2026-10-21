package agent

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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
var sshRelayTarget = defaultSSHRelayTarget()

// podSSHDPort is a person's pod's sshd (fleet-node-linux.py POD_SSHD_PORT): the
// pod's other container, no NET_BIND_SERVICE, so not 22.
const podSSHDPort = "2222"

// podRelay: this agent runs in one person's pod (render.py's FLEET_USER_POD=1,
// the pod's own spec — never the hub's say), whose sshd takes a relayed login
// on loopback with the hub's user CA (claude-fleet#4149).
func podRelay() bool { return os.Getenv("FLEET_USER_POD") == "1" }

func defaultSSHRelayTarget() string {
	if podRelay() {
		return "127.0.0.1:" + podSSHDPort
	}
	return "127.0.0.1:22"
}

// entryRelayTarget is the machine's entry port (A5SQ): the door's way home
// lands here, on the sshd the supervisor runs for the entry (keys only, the
// person's own). FLEET_ENTRY_PORT as the supervisor reads it, else 22022 —
// never an address the hub names.
func entryRelayTarget() string {
	if p := os.Getenv("FLEET_ENTRY_PORT"); p != "" {
		if n, err := strconv.Atoi(p); err == nil && n > 0 && n < 65536 {
			return "127.0.0.1:" + p
		}
	}
	return "127.0.0.1:22022"
}

// entryRelayOK: this agent offers CapEntryRelay — a relay agent anywhere but
// a person's pod (whose one sshd is the pod's own).
func entryRelayOK() bool { return !podRelay() }

// sshRelayDialTimeout bounds the data stream's dial and the sshd connect.
const sshRelayDialTimeout = 15 * time.Second

// relayViaDialTimeout bounds a dial-back to a door: shorter than the door's
// wait for it, so a door this machine cannot reach falls back to the hub.
const relayViaDialTimeout = 5 * time.Second

// relayViaURLOK: a door's relay URL is ws(s)://host[:port]/path?id=…, no
// userinfo, no fragment.
func relayViaURLOK(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "ws" || u.Scheme == "wss") && u.Host != "" && u.User == nil &&
		u.Fragment == "" && u.Query().Get("id") != "" && len(raw) <= 512
}

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
	var ws *websocket.Conn
	var err error
	if ro.URL != "" {
		// a door's own relay listener (CapRelayVia): only for the entry
		// port, only ws(s), and it gets the relay's secret — never this
		// agent's credential
		if ro.Target != control.SSHRelayTargetEntry || !entryRelayOK() || !relayViaURLOK(ro.URL) {
			log.Printf("relay %s: refused a dial-back to %q", short(ro.RelayID), ro.URL)
			return
		}
		vctx, vcancel := context.WithTimeout(ctx, relayViaDialTimeout)
		ws, _, err = websocket.Dial(vctx, ro.URL, &websocket.DialOptions{
			HTTPHeader: http.Header{"X-Relay-Secret": []string{ro.Secret}},
		})
		vcancel()
		if err != nil {
			log.Printf("relay %s: dial the door: %v", short(ro.RelayID), err)
			return
		}
	} else {
		ws, _, err = websocket.Dial(dctx, sshRelayDataURL(a.cfg.hub(), ro.RelayID), &websocket.DialOptions{
			HTTPHeader: http.Header{
				"Authorization":  []string{a.authValue(http.MethodGet, sshRelayDataURL(a.cfg.hub(), ro.RelayID))},
				"X-Relay-Secret": []string{ro.Secret},
			},
		})
		if err != nil {
			log.Printf("relay %s: dial the hub: %v", short(ro.RelayID), err)
			return
		}
	}
	defer ws.CloseNow()
	ws.SetReadLimit(1 << 20)

	target, what := sshRelayTarget, "sshd"
	switch ro.Target {
	case "":
	case control.SSHRelayTargetEntry:
		if !entryRelayOK() {
			ws.Close(websocket.StatusPolicyViolation, "no entry port in a pod")
			return
		}
		target, what = entryRelayTarget(), "the entry port"
		if entryRelayTargetTest != "" {
			target = entryRelayTargetTest
		}
	default:
		ws.Close(websocket.StatusPolicyViolation, "unknown relay target")
		return
	}
	var d net.Dialer
	tcp, err := d.DialContext(dctx, "tcp", target)
	if err != nil {
		// The hub passes the reason on to the person, who otherwise sees
		// only "connection closed" from ssh.
		ws.Close(websocket.StatusInternalError, what+" unreachable on this machine")
		return
	}
	cancel()
	splice(ctx, ws, tcp)
}

// splice copies bytes both ways between ws and tcp until either side ends or
// ctx does, then closes both. Each direction half-closes nothing: SSH ends its
// own session, and a stream that has stopped in one direction is finished.
func splice(ctx context.Context, ws *websocket.Conn, tcp io.ReadWriteCloser) {
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

// entryRelayTargetTest overrides entryRelayTarget (tests only).
var entryRelayTargetTest string

// SetEntryRelayTargetForTest points entry relays at addr ("" = the entry port).
func SetEntryRelayTargetForTest(addr string) { entryRelayTargetTest = addr }

// SetSSHRelayTargetForTest points relays at addr instead of the local sshd ("" =
// back to 127.0.0.1:22). For the hub's end-to-end tests only.
func SetSSHRelayTargetForTest(addr string) {
	if addr == "" {
		addr = defaultSSHRelayTarget()
	}
	sshRelayTarget = addr
}
