package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// One node program per machine (claude-fleet#2333, EPIC #2329 C5).
//
// A MACHINE link is one websocket, opened with the machine's own node token,
// that carries every login of the machine: each login says its own hello on
// it (Message.Login set, its own node token in Hello.LoginToken) and is served
// by the very same serveNode a plain link gets — its own endpoint, roster row,
// leases, relays and writes. Only the wire differs: nodeWire is what serveNode
// reads from and writes to, a whole websocket for a plain link and one login's
// lane (subWire) on a machine link.

// nodeWire is one endpoint's half of a control channel.
type nodeWire interface {
	// write sends m to the node (stamped with the lane's login on a machine
	// link).
	write(ctx context.Context, m control.Message) error
	// read returns the next message for this endpoint.
	read(ctx context.Context) (control.Message, error)
	// close ends this endpoint's session; on a machine link one login's lane
	// closes and the others stay up.
	close(code websocket.StatusCode, reason string)
	// machine is the machine endpoint whose link carries this one; "" for a
	// plain link.
	machine() string
}

// wsWire is a plain link: the whole websocket is one endpoint.
type wsWire struct{ c *websocket.Conn }

func (w wsWire) write(ctx context.Context, m control.Message) error { return wsjson.Write(ctx, w.c, m) }

func (w wsWire) read(ctx context.Context) (control.Message, error) {
	var m control.Message
	err := wsjson.Read(ctx, w.c, &m)
	return m, err
}

func (w wsWire) close(code websocket.StatusCode, reason string) { w.c.Close(code, reason) }
func (w wsWire) machine() string                                { return "" }

// errLaneClosed ends a lane's reader.
var errLaneClosed = errors.New("lane closed")

// subWire is one login's lane on a machine link.
type subWire struct {
	c       *websocket.Conn
	login   string // "" is the machine's own lane
	machEP  string
	in      chan control.Message
	done    chan struct{}
	closeMu sync.Once
}

func newSubWire(c *websocket.Conn, login, machEP string) *subWire {
	return &subWire{c: c, login: login, machEP: machEP, in: make(chan control.Message, 256), done: make(chan struct{})}
}

func (w *subWire) write(ctx context.Context, m control.Message) error {
	select {
	case <-w.done:
		return errLaneClosed
	default:
	}
	m.Login = w.login
	return wsjson.Write(ctx, w.c, m)
}

func (w *subWire) read(ctx context.Context) (control.Message, error) {
	select {
	case m := <-w.in:
		return m, nil
	case <-w.done:
		return control.Message{}, errLaneClosed
	case <-ctx.Done():
		return control.Message{}, ctx.Err()
	}
}

// deliver hands the demux's message to the lane; false once it closed.
func (w *subWire) deliver(m control.Message) bool {
	select {
	case w.in <- m:
		return true
	case <-w.done:
		return false
	}
}

func (w *subWire) close(code websocket.StatusCode, reason string) {
	w.closeMu.Do(func() {
		close(w.done)
		if w.login == "" {
			// The machine's own lane is the link: closing it closes all.
			w.c.Close(code, reason)
			return
		}
		// One login only: tell the node so it says its hello again later.
		m := control.Message{Type: control.TypeError, Proto: control.Proto, Login: w.login,
			Error: &control.Error{Code: control.CodeLinkClosed, Message: reason}}
		wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = wsjson.Write(wctx, w.c, m)
	})
}

func (w *subWire) machine() string { return w.machEP }

// quiet ends the lane without telling the node: it already opened a new one
// for the same login, and a LINK_CLOSED now would close that one instead.
func (w *subWire) quiet() { w.closeMu.Do(func() { close(w.done) }) }

// loginEndpoint resolves a login hello on machine mach's link to the login's
// endpoint, or says why not — the one rule that keeps an op from ever landing
// on the wrong login (BREAK-IT machine-agent-wrong-login): the token must be a
// live enrollment, not the machine link's own, of exactly that OS user (an
// endpoint that never said its user — no usage pushed yet — takes the login
// the hello names, as a plain agent's heartbeat would), on the machine's own
// host.
func (s *Server) loginEndpoint(mach store.Endpoint, login string, hp control.Hello) (*store.Endpoint, string, string) {
	if hp.LoginToken == "" {
		return nil, "", "a login hello needs the login's own node token"
	}
	h := HashToken(hp.LoginToken)
	ep, err := s.Store.EndpointByTokenHash(h)
	if err != nil {
		return nil, "", "unrecognised enrollment token for login " + login
	}
	if ep.ID == mach.ID {
		return nil, "", "the machine's token cannot speak for a login"
	}
	if ep.OSUser != "" && ep.OSUser != login {
		return nil, "", "that token is " + ep.OSUser + "'s, not " + login + "'s"
	}
	if mh, lh := s.endpointHost(mach), s.endpointHost(*ep); mh != "" && lh != "" && mh != lh {
		return nil, "", "that token belongs to " + lh + ", not this machine (" + mh + ")"
	}
	if ep.OSUser == "" {
		ep.OSUser = login
	}
	return ep, h, ""
}

// endpointHost is the machine an endpoint is on: the name it reports, else
// the one it joined as (claude-fleet#2214); "" when it never said.
func (s *Server) endpointHost(ep store.Endpoint) string {
	if ep.Hostname != "" {
		return ep.Hostname
	}
	if et, err := s.Store.EndpointTrustOf(ep.ID); err == nil && et.EnrolledHost != "?" {
		return et.EnrolledHost
	}
	return ""
}

// serveMachine runs a machine link: it is the link's only reader and hands
// each message to its login's lane.
func (s *Server) serveMachine(ctx context.Context, conn *websocket.Conn, ep *store.Endpoint, tokHash string,
	hello control.Message, hp control.Hello) {
	var mu sync.Mutex
	lanes := map[string]*subWire{}
	own := newSubWire(conn, "", ep.ID)
	lanes[""] = own
	defer func() {
		mu.Lock()
		defer mu.Unlock()
		for _, l := range lanes {
			l.closeMu.Do(func() { close(l.done) })
		}
	}()
	go func() {
		s.serveNode(ctx, own, ep, tokHash, hello, hp)
		conn.Close(websocket.StatusNormalClosure, "machine session ended")
	}()

	idle := time.Duration(hp.HeartbeatMS*(lostAfterBeats+1)) * time.Millisecond
	if idle < helloTimeout {
		idle = helloTimeout
	}
	for {
		rctx, cancel := context.WithTimeout(ctx, idle)
		var m control.Message
		err := wsjson.Read(rctx, conn, &m)
		cancel()
		if err != nil {
			return
		}
		mu.Lock()
		lane := lanes[m.Login]
		mu.Unlock()
		if lane != nil {
			if m.Type == control.TypeHello && m.Login != "" {
				// A second hello for a live lane: the node restarted that
				// login's half. The old lane ends — quietly, the node has
				// already let it go — and this hello opens a new one.
				lane.quiet()
				mu.Lock()
				if lanes[m.Login] == lane {
					delete(lanes, m.Login)
				}
				mu.Unlock()
			} else {
				lane.deliver(m)
				continue
			}
		}
		if m.Type != control.TypeHello {
			s.refuseLogin(ctx, conn, m, "login "+m.Login+" has no session on this machine link")
			continue
		}
		var lhp control.Hello
		if len(m.Payload) > 0 {
			if err := json.Unmarshal(m.Payload, &lhp); err != nil {
				refuse(ctx, wsWire{conn}, m.OpID, control.CodeBadMessage, "malformed hello")
				continue
			}
		}
		lep, lh, why := s.loginEndpoint(*ep, m.Login, lhp)
		if why != "" {
			log.Printf("machine link %s (%s): login %q refused: %s", ep.ID, ep.Hostname, m.Login, why)
			s.leaseAudit("node:"+ep.ID, "machine_login", "login:"+m.Login, "REFUSED — "+why, time.Now())
			s.refuseLogin(ctx, conn, m, why)
			continue
		}
		if lhp.HeartbeatMS <= 0 {
			lhp.HeartbeatMS = defaultHeartbeatMS
		}
		lhp.LoginToken = "" // proven; nothing downstream needs it
		lane = newSubWire(conn, m.Login, ep.ID)
		mu.Lock()
		lanes[m.Login] = lane
		mu.Unlock()
		go func(l *subWire, lep *store.Endpoint, lh string, hm control.Message, lhp control.Hello) {
			s.serveNode(ctx, l, lep, lh, hm, lhp)
			l.close(websocket.StatusNormalClosure, "login session ended")
			mu.Lock()
			if lanes[l.login] == l {
				delete(lanes, l.login)
			}
			mu.Unlock()
		}(lane, lep, lh, m, lhp)
	}
}

// refuseLogin answers a message on a machine link with WRONG_LOGIN, stamped
// with the login it named so the node can tell which half it was.
func (s *Server) refuseLogin(ctx context.Context, conn *websocket.Conn, m control.Message, why string) {
	out := control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto, Login: m.Login,
		Error: &control.Error{Code: control.CodeWrongLogin, Message: why}}
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_ = wsjson.Write(wctx, conn, out)
}
