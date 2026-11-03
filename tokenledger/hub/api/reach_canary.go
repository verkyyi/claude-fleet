package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The relay canary (task FQAR): what the status page's `relay` component
// probes once a minute. On 2026-11-02 the view→pod road through the peer
// relay answered 426 for hours while every component stayed green — no probe
// ever opened a WebSocket through the front door. The canary is a tiny echo
// endpoint beside the peer relay (ReachCanaryPath), and the probe is the hub
// dialling it through its OWN public address (FleetPublicURL, as `core`):
// DNS, TLS, the load balancer's and ingress's WebSocket upgrade, a replica
// accepting it, the relay's `ready` hello and its binary frames echoed back.
// It needs no person's machine or pod and reaches none: no node is asked, no
// identity is read, nothing is recorded but the probe's own state. It does NOT
// prove a node's dial-back or a pod's own proxy — those are what the views'
// reports measure (reach_stats.go). Open to anyone, so bounded per replica:
// reachCanaryOpenMax at once, a token bucket of reachCanaryPerMin a minute,
// reachCanaryBytes echoed, reachCanaryLife long.
const (
	ReachCanaryPath    = "/v1/node/peer-relay-canary"
	reachCanaryOpenMax = 4
	reachCanaryPerMin  = 30
	reachCanaryBurst   = 10
	reachCanaryBytes   = 4096
	reachCanaryLife    = 10 * time.Second
)

type reachCanaryGate struct {
	mu     sync.Mutex
	open   int
	last   time.Time
	tokens float64
}

func (g *reachCanaryGate) admit(now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.last.IsZero() {
		g.tokens = reachCanaryBurst
	} else {
		g.tokens += now.Sub(g.last).Minutes() * reachCanaryPerMin
		if g.tokens > reachCanaryBurst {
			g.tokens = reachCanaryBurst
		}
	}
	g.last = now
	if g.tokens < 1 || g.open >= reachCanaryOpenMax {
		return false
	}
	g.tokens--
	g.open++
	return true
}

func (g *reachCanaryGate) release() {
	g.mu.Lock()
	g.open--
	g.mu.Unlock()
}

func (s *Server) handleReachCanary(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET (a WebSocket) only")
		return
	}
	if !s.reachCanary.admit(time.Now()) {
		w.Header().Set("Retry-After", "5")
		httpError(w, http.StatusTooManyRequests, "Please retry shortly")
		return
	}
	defer s.reachCanary.release()
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(reachCanaryBytes)
	ctx, cancel := context.WithTimeout(context.Background(), reachCanaryLife)
	defer cancel()
	if wsjson.Write(ctx, conn, control.SSHRelayHello{Type: "ready"}) != nil {
		return
	}
	total := 0
	for total < reachCanaryBytes {
		typ, b, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageBinary {
			conn.Close(websocket.StatusUnsupportedData, "binary frames only")
			return
		}
		total += len(b)
		if conn.Write(ctx, websocket.MessageBinary, b) != nil {
			return
		}
	}
	conn.Close(websocket.StatusNormalClosure, "")
}

// reachCanaryTarget is the canary's address on the hub's own public URL.
func reachCanaryTarget(public string) string {
	u, e := url.Parse(public)
	if e != nil || u.Host == "" {
		return ""
	}
	switch u.Scheme {
	case "https":
		return "wss://" + u.Host + ReachCanaryPath
	case "http":
		return "ws://" + u.Host + ReachCanaryPath
	}
	return ""
}

// probeReachCanary opens the canary through target and checks its hello and
// one echoed frame. Errors are fixed words: nothing of the upstream answer.
func probeReachCanary(ctx context.Context, target string) error {
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	c, resp, err := websocket.Dial(ctx, target, &websocket.DialOptions{HTTPClient: client})
	if err != nil {
		if resp != nil && resp.StatusCode != http.StatusSwitchingProtocols {
			return errors.New("status")
		}
		return errors.New("unreachable")
	}
	defer c.CloseNow()
	c.SetReadLimit(reachCanaryBytes)
	var hello control.SSHRelayHello
	if wsjson.Read(ctx, c, &hello) != nil || hello.Type != "ready" {
		return errors.New("hello")
	}
	payload := make([]byte, 32)
	_, _ = rand.Read(payload)
	if c.Write(ctx, websocket.MessageBinary, payload) != nil {
		return errors.New("write")
	}
	typ, b, err := c.Read(ctx)
	if err != nil || typ != websocket.MessageBinary || !bytes.Equal(b, payload) {
		return errors.New("echo")
	}
	c.Close(websocket.StatusNormalClosure, "")
	return nil
}
