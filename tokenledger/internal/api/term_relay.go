package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// The hub half of the browser terminal (claude-fleet#3838, EPIC #3836 C1): the
// chat relay's road (openLoginRelay, the same table shape, the same keying) to
// a terminal on the person's OWN home login.
//
//	browser ──wss TermConnectPath?worker=<id> | ?target=personal (same origin, signed in)──▶ hub
//	hub: who (a person as themselves — never the operator's door, never a view-as)
//	     · their home (EntryHomeOf) · the target theirs (a worker of a fleet on that login)
//	hub ──TypeTermOpen──▶ that login's agent (CapTerm only) ──wss TermDataPath──▶ hub
//	hub ──{"grant": ftg1…} (person · login · relay · target · 2 min)──▶ agent ──▶ PTY
//
// The browser names a selector, never a machine, a login, a path or a command;
// what the agent reaches is only what the grant the hub signed names. Frames:
// binary = bytes, text = the bounded controls (control.TermControl) — a frame
// that is neither in bounds ends the stream. A ping each way finds a half-open
// leg; the person is re-admitted every termRecheckEvery, so a revoked session
// or a changed home ends the terminal. Every terminal is one fleet_term_sessions
// row (metadata only), every refusal one fleet_audit row.

const (
	// TermConnectPath is the browser's door.
	TermConnectPath = "/v1/term/connect"
	// TermHomePath answers whether a terminal could open now, for the page.
	TermHomePath = "/v1/term/home"

	defaultTermPerPerson = 2
	defaultTermPerMinute = 20
	// 1 MiB/s per login across its terminals: far above a person typing, still
	// a bound on a runaway program's output.
	defaultTermRateBPS = 1 << 20
	termGrantTTL       = 2 * time.Minute
)

var (
	// termPingEvery / termPingTimeout find a half-open leg; termRecheckEvery
	// re-admits the person. Variables only so the tests can run them fast.
	termPingEvery    = 10 * time.Second
	termPingTimeout  = 10 * time.Second
	termRecheckEvery = 15 * time.Second
)

// TermHome is GET TermHomePath's answer. State: ok · offline · maintenance ·
// unsupported (connected, without CapTerm — 「这台机器还不支持」).
type TermHome struct {
	Machine string `json:"machine"`
	Login   string `json:"login"`
	State   string `json:"state"`
}

// termRelayNode picks login's own link on host that offers CapTerm.
func (s *Server) termRelayNode(host, login string) (string, *nodeConn, error) {
	return s.loginRelayNode(host, login, func(c *nodeConn) bool { return c.canTerm }, "NO_TERM", "the terminal relay")
}

// termAudit records one terminal refusal (never content).
func (s *Server) termRefuse(w http.ResponseWriter, actor, what string, status int, code, msg string) {
	if actor == "" {
		actor = "anonymous"
	}
	s.chatAudit(actor, "term_refused", code+" "+what)
	refuseJSON(w, status, code, msg)
}

// termPerson is whose terminal a request is: chatPerson's rule (a person as
// themselves, an admin included, never the operator's door), and no view-as —
// looking through another person's eyes never reaches their terminal.
func (s *Server) termPerson(r *http.Request) (person string, status int, code, msg string) {
	if viewAsAsked(r) != "" {
		return "", http.StatusForbidden, "view_as", "a terminal is only ever your own; leave the view first"
	}
	person, status, code, msg = s.chatPerson(r)
	if code == "operator" {
		msg = "the operator's door has no terminal; sign in as yourself"
	}
	return person, status, code, msg
}

// termTarget resolves the browser's selector against person's home: exactly
// one of target=personal or worker=<worker id>, and a worker only when a fleet
// on that very login reports it. Anything else is not_yours — the same answer
// for another person's worker and for one that does not exist.
func (s *Server) termTarget(q url.Values, home store.EntryHome) (logical, target string, status int, code, msg string) {
	t, w := strings.TrimSpace(q.Get("target")), strings.TrimSpace(q.Get("worker"))
	switch {
	case (t == "") == (w == ""):
		return "", "", http.StatusBadRequest, "bad_target", "name exactly one of target=personal or worker=<id>"
	case t != "":
		if t != control.TermTargetPersonal {
			return "", "", http.StatusBadRequest, "bad_target", "target is personal or nothing"
		}
		return control.TermTargetPersonal, control.TermTargetPersonal, 0, "", ""
	}
	notYours := func() (string, string, int, string, string) {
		return "", "", http.StatusNotFound, "not_yours", "no such session of yours"
	}
	fuid, second, err := fleetid.ParseWorkerID(w)
	if err != nil {
		return notYours()
	}
	f, err := s.Store.Fleet(fuid)
	if err != nil || !f.Present || f.Hostname != home.Machine || f.OSUser != home.Login {
		return notYours()
	}
	var ws []map[string]any
	_ = json.Unmarshal([]byte(f.WorkersJSON), &ws)
	for _, wk := range ws {
		if id, _ := wk["worker_id"].(string); id != w {
			continue
		}
		// The window is found on the node by its @fleet_id: the row's, else
		// the id's own second half when that is one (not a key alias).
		fid, _ := wk["fleet_id"].(string)
		if fid == "" && !strings.ContainsAny(second, ":") && !strings.HasPrefix(second, "issue-") && !strings.HasPrefix(second, "scratch-") {
			fid = second
		}
		if fid == "" || !control.ValidTermTarget(control.TermWorkerTarget(fid)) {
			return notYours()
		}
		return w, control.TermWorkerTarget(fid), 0, "", ""
	}
	return notYours()
}

// termOriginOK is the same-origin rule for the terminal's upgrade: a browser
// always sends Origin, and it must be this hub as the browser reached it — the
// Host it asked for, or, on a request another replica handed on, the host that
// replica was asked for.
func (s *Server) termOriginOK(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return false
	}
	u, err := url.Parse(o)
	if err != nil || u.Host == "" {
		return false
	}
	host := r.Host
	if s.relayHopped(r) {
		if fh := r.Header.Get("X-Forwarded-Host"); fh != "" {
			host = fh
		}
	}
	return strings.EqualFold(u.Host, host)
}

// handleTermHome answers TermHomePath.
func (s *Server) handleTermHome(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	person, status, code, msg := s.termPerson(r)
	if code != "" {
		s.termRefuse(w, person, "home", status, code, msg)
		return
	}
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok || home.Machine == "" || home.Login == "" {
		refuseJSON(w, http.StatusConflict, "no_home", "你还没有家：先在「我的连接」里选一台机器")
		return
	}
	if peer, ok := s.termRelayPeer(r, home.Machine, home.Login); ok {
		s.proxyRelay(w, r, peer, "a terminal home read for "+home.Machine+"/"+home.Login)
		return
	}
	writeJSON(w, http.StatusOK, TermHome{Machine: home.Machine, Login: home.Login, State: s.termState(home)})
}

// termState is whether a terminal to home could open now.
func (s *Server) termState(home store.EntryHome) string {
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(home.Machine, settings); flagged {
			return "maintenance"
		}
	}
	if _, _, err := s.termRelayNode(home.Machine, home.Login); err != nil {
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "NO_TERM" {
			return "unsupported"
		}
		return "offline"
	}
	return "ok"
}

// handleTermConnect serves TermConnectPath: one browser terminal.
func (s *Server) handleTermConnect(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	person, status, code, msg := s.termPerson(r)
	if code != "" {
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		}
		s.termRefuse(w, person, "connect", status, code, msg)
		return
	}
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		s.termRefuse(w, person, "connect", http.StatusBadRequest, "upgrade", "a terminal is a websocket")
		return
	}
	if !s.termOriginOK(r) {
		s.termRefuse(w, person, "connect", http.StatusForbidden, "origin", "a terminal opens only from this site's own page")
		return
	}
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok || home.Machine == "" || home.Login == "" {
		s.termRefuse(w, person, "connect", http.StatusConflict, "no_home", "你还没有家：先在「我的连接」里选一台机器")
		return
	}
	where := home.Machine + "/" + home.Login
	logical, target, status, code, msg := s.termTarget(r.URL.Query(), home)
	if code != "" {
		s.termRefuse(w, person, "connect "+where, status, code, msg)
		return
	}
	// The login's link ends in another replica: hand it the whole upgrade; it
	// admits the person again and serves the terminal as its own.
	if peer, ok := s.termRelayPeer(r, home.Machine, home.Login); ok {
		s.proxyRelay(w, r, peer, "a terminal to "+where)
		return
	}
	switch s.termState(home) {
	case "maintenance":
		s.termRefuse(w, person, "connect "+where, http.StatusServiceUnavailable, "home_down", "你的机器在维护中，现在连不上")
		return
	case "unsupported":
		s.termRefuse(w, person, "connect "+where, http.StatusConflict, "unsupported", "这台机器还不支持网页终端：请更新它")
		return
	case "offline":
		s.termRefuse(w, person, "connect "+where, http.StatusServiceUnavailable, "home_down", "你的机器现在连不上")
		return
	}
	max, perMin := s.TermMaxPerPerson, s.TermPerMinute
	if max <= 0 {
		max = defaultTermPerPerson
	}
	if perMin <= 0 {
		perMin = defaultTermPerMinute
	}
	if why := s.termGate.admit(person, max, perMin, time.Now()); why != "" {
		s.termRefuse(w, person, "connect "+where, http.StatusTooManyRequests, why, "too many terminals; close one first")
		return
	}
	defer s.termGate.release(person)

	// Same origin was checked above, by this hub's own rule (a handed-on
	// request's Host is the replica's): Accept need not repeat it.
	browser, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer browser.CloseNow()
	browser.SetReadLimit(control.TermFrameMax)
	ctx := r.Context()
	sendErr := func(code, msg string) {
		b, _ := json.Marshal(control.TermControl{T: "error", Err: code, Msg: msg})
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_ = browser.Write(wctx, websocket.MessageText, b)
		cancel()
		browser.Close(websocket.StatusPolicyViolation, code)
	}

	epID, nc, err := s.termRelayNode(home.Machine, home.Login)
	if err != nil {
		sendErr("home_down", "你的机器现在连不上")
		return
	}
	or, err := s.openLoginRelay(ctx, loginRelaySpec{
		kind: "term relay", table: &s.termRelays, epID: epID, node: nc,
		key: chatRelayKey(home.Machine, home.Login), max: termRelayMax(s.TermRelayMaxPerLogin), person: person,
		open: func(id, secret string) (control.Message, error) {
			return control.New(control.TypeTermOpen, control.TermOpen{RelayID: id, Secret: secret, Login: home.Login})
		},
		hello: func(id, tokHash string, now time.Time) []byte {
			b, _ := json.Marshal(control.TermRelayHello{Grant: control.SignTermGrant(control.TermGrant{
				V: 1, Aud: control.TermAudience, Person: person, Login: home.Login, Relay: id, Target: target,
				Iat: now.Unix(), Exp: now.Add(termGrantTTL).Unix(),
			}, tokHash)})
			return b
		},
	})
	if err != nil {
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "TOO_MANY" {
			sendErr("too_many", re.msg)
		} else {
			sendErr("home_down", "你的机器现在连不上")
		}
		s.chatAudit(person, "term_refused", "relay "+where+": "+err.Error())
		return
	}
	opened := time.Now()
	if err := s.Store.RecordTermOpen(store.FleetTermSession{ID: or.id, Person: person, Machine: home.Machine,
		Login: home.Login, Target: logical, Mode: "relay", OpenedAt: opened}); err != nil {
		or.end("no audit row: " + err.Error())
		sendErr("internal", "the terminal could not be recorded")
		return
	}
	s.chatAudit(person, "term_relay", "OPENED "+logical+" "+where)
	gen := fmt.Sprintf("%s.%d", shortID(epID), nc.helloAt.Unix())
	hello, _ := json.Marshal(control.TermControl{T: "hello", V: 1, Term: logical, Gen: gen, Conn: or.id, Mode: "relay"})
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = browser.Write(wctx, websocket.MessageText, hello)
	cancel()
	up, down, why := int64(0), int64(0), "browser gone before the hello"
	if err == nil {
		rd := s.TermRelayRateBPS
		if rd == 0 {
			rd = defaultTermRateBPS
		}
		// Told before the stream ends: an ended stream's reads have closed it.
		recheck := func() bool {
			p, _, c, _ := s.termPerson(r)
			h, ok, err := s.Store.EntryHomeOf(person)
			if c == "" && p == person && err == nil && ok && h.Machine == home.Machine && h.Login == home.Login {
				return true
			}
			sendErr("revoked", "你的登录已失效：终端已关闭")
			return false
		}
		up, down, why = pipeTermRelay(or.ctx, browser, or.ws, s.termRelays.limiter(or.key, rd), recheck)
	}
	or.end(why)
	browser.Close(websocket.StatusNormalClosure, "")
	or.ws.Close(websocket.StatusNormalClosure, "")
	_ = s.Store.RecordTermClose(or.id, why, up, down, time.Now())
	log.Printf("term relay %s: %s -> %s %s: %s, %d up %d down", shortID(or.id), person, where, logical, why, up, down)
}

func termRelayMax(n int) int {
	if n <= 0 {
		return defaultChatRelayMaxPerLogin
	}
	return n
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// pipeTermRelay moves frames between the browser and the agent until either
// ends, a frame is out of bounds, a leg stops answering pings, or recheck says
// the person may no longer have it ("revoked"). up/down count binary bytes.
func pipeTermRelay(ctx context.Context, browser, agent *websocket.Conn, lim *byteLimiter, recheck func() bool) (up, down int64, why string) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var mu sync.Mutex
	end := func(w string) {
		mu.Lock()
		if why == "" {
			why = w
		}
		mu.Unlock()
		cancel()
	}
	write := func(dst *websocket.Conn, typ websocket.MessageType, b []byte) error {
		wctx, wcancel := context.WithTimeout(ctx, 30*time.Second)
		defer wcancel()
		return dst.Write(wctx, typ, b)
	}
	var wg sync.WaitGroup
	leg := func(src, dst *websocket.Conn, n *int64, from string, ctl func([]byte) ([]byte, error)) {
		defer wg.Done()
		for {
			typ, b, err := src.Read(ctx)
			if err != nil {
				if websocket.CloseStatus(err) == websocket.StatusNormalClosure || websocket.CloseStatus(err) == websocket.StatusGoingAway {
					end(from + " closed")
				} else if ctx.Err() == nil {
					end(from + " gone")
				}
				return
			}
			if typ == websocket.MessageText {
				out, cerr := ctl(b)
				if cerr != nil {
					end(from + " sent a malformed frame: " + cerr.Error())
					return
				}
				if err := write(dst, websocket.MessageText, out); err != nil {
					end("write failed")
					return
				}
				continue
			}
			if err := lim.wait(ctx, len(b)); err != nil {
				return
			}
			if err := write(dst, websocket.MessageBinary, b); err != nil {
				end("write failed")
				return
			}
			mu.Lock()
			*n += int64(len(b))
			mu.Unlock()
		}
	}
	fromBrowser := func(b []byte) ([]byte, error) {
		cols, rows, err := control.ParseTermResize(b)
		if err != nil {
			return nil, err
		}
		return json.Marshal(control.TermControl{T: "resize", Cols: cols, Rows: rows})
	}
	fromAgent := func(b []byte) ([]byte, error) {
		c, err := control.ParseTermAgentControl(b)
		if err != nil {
			return nil, err
		}
		return json.Marshal(c)
	}
	ping := func(c *websocket.Conn, who string) {
		defer wg.Done()
		t := time.NewTicker(termPingEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				pctx, pcancel := context.WithTimeout(ctx, termPingTimeout)
				err := c.Ping(pctx)
				pcancel()
				if err != nil && ctx.Err() == nil {
					end(who + " stopped answering")
					return
				}
			}
		}
	}
	watch := func() {
		defer wg.Done()
		t := time.NewTicker(termRecheckEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if !recheck() {
					end("revoked")
					return
				}
			}
		}
	}
	wg.Add(5)
	go leg(browser, agent, &up, "browser", fromBrowser)
	go leg(agent, browser, &down, "agent", fromAgent)
	go ping(browser, "browser")
	go ping(agent, "agent")
	go watch()
	<-ctx.Done()
	// A cancelled read closes its connection: every leg is out by now.
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if why == "" {
		why = "ended"
	}
	return up, down, why
}

// termRelayPeer is chatRelayPeer for the terminal: the other replica holding a
// link to login on host that offered CapTerm, when this one holds none.
func (s *Server) termRelayPeer(r *http.Request, host, login string) (store.NodeConn, bool) {
	if s.Replica == nil || s.relayHopped(r) {
		return store.NodeConn{}, false
	}
	if _, _, err := s.termRelayNode(host, login); err == nil {
		return store.NodeConn{}, false
	}
	return s.peerLoginLink(host, login, control.CapTerm)
}

// handleTermRelayData serves control.TermDataPath: an agent attaching the data
// half of a terminal the hub asked it for — the SSH relay's door, its own table.
func (s *Server) handleTermRelayData(w http.ResponseWriter, r *http.Request) {
	s.attachRelayData(w, r, &s.termRelays)
}
