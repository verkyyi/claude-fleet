package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/attachment"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

const AttachmentPath = "/v1/attachment/connect"

// Each consumer admits its own service before entering the shared transport.
func (s *Server) handleAttachment(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	person, status, code, msg := s.termPerson(r)
	refuse := func(status int, code, msg string) {
		// Browsers hide failed-upgrade status. Return a terminal status over a
		// same-origin socket so expired auth is never retried as a network failure.
		if r.URL.Query().Get("errors") == "stream" && r.Method == http.MethodGet && strings.EqualFold(r.Header.Get("Upgrade"), "websocket") && s.termOriginOK(r) {
			ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
			if err == nil {
				sendAttachmentSignal(r.Context(), ws, control.AttachmentSignal{T: "error", Status: status, Error: code, Message: msg})
				ws.Close(websocket.StatusNormalClosure, "refused")
			}
			return
		}
		s.termRefuse(w, person, "attachment", status, code, msg)
	}
	if code != "" {
		refuse(status, code, msg)
		return
	}
	if r.Method != http.MethodGet || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		refuse(400, "upgrade", "a websocket is required")
		return
	}
	if !s.termOriginOK(r) {
		refuse(403, "origin", "same-origin required")
		return
	}
	if r.URL.Query().Get("service") != "term" {
		refuse(400, "service", "unsupported attachment service")
		return
	}
	if !s.attachmentSessionLive(r) {
		refuse(401, "revoked", "sign in again")
		return
	}
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		refuse(503, "home_down", "home unavailable")
		return
	}
	if !ok || home.Machine == "" || home.Login == "" {
		refuse(409, "no_home", "choose your home first")
		return
	}
	logical, target, dest, status, code, msg := s.termTarget(r.URL.Query(), home)
	if code != "" {
		refuse(status, code, msg)
		return
	}
	// The login the session runs on: home, or another of the person's own (C8X3).
	home = dest
	if peer, ok := s.termRelayPeer(r, home.Machine, home.Login); ok {
		s.proxyRelay(w, r, peer, "attachment")
		return
	}
	epID, nc, err := s.termRelayNode(home.Machine, home.Login)
	if err != nil {
		refuse(503, "home_down", "home unavailable")
		return
	}
	if !nc.canAttachment || nc.attachmentGeneration == "" {
		refuse(409, "unsupported", "update the node for direct attachments")
		return
	}
	if r.URL.Query().Get("controller") == "1" && !nc.canTermController {
		refuse(409, "unsupported", "update the node for terminal recovery")
		return
	}
	gen := nc.attachmentGeneration
	resume := r.URL.Query().Get("term_resume")
	if len(resume) > 128 || strings.ContainsAny(resume, "/\\ \t\r\n") {
		refuse(400, "resume", "invalid terminal identity")
		return
	}
	take := r.URL.Query().Get("take") == "1"
	renew := r.URL.Query().Get("renew") == "1"
	if renew && (target != control.TermTargetPersonal || resume == "" || take) {
		refuse(400, "invalid_renew", "renew requires an ended personal terminal identity")
		return
	}
	if renew && !nc.canTermRenew {
		refuse(409, "unsupported", "update the node to reopen personal terminals")
		return
	}
	previous := r.URL.Query().Get("previous")
	if len(previous) > 128 || strings.ContainsAny(previous, "/\\ \t\r\n") {
		refuse(400, "previous", "invalid previous connection")
		return
	}
	if want := r.URL.Query().Get("generation"); want != "" && want != gen {
		refuse(409, "interrupted", "the node generation changed")
		return
	}
	// checkWhy is "" while this attachment may go on, else the browser's word
	// for why not: only a sign-in or a home that changed is «revoked» (final);
	// a node that relinked or a machine in maintenance comes back (RMVE).
	checkWhy := func() string {
		p, _, c, _ := s.termPerson(r)
		if c != "" || p != person || !s.attachmentSessionLive(r) {
			return "revoked"
		}
		h, ok, e := s.Store.EntryHomeOf(person)
		if e != nil {
			return "home_down"
		}
		if !ok {
			return "revoked"
		}
		if s.nodes.get(epID) != nc {
			return "node_unavailable"
		}
		settings, e := s.Store.FleetSettings()
		if e != nil {
			return "home_down"
		}
		if _, maintenance := maintenanceOf(home.Machine, settings); maintenance {
			return "maintenance"
		}
		l, t, d, _, c, _ := s.termTarget(r.URL.Query(), h)
		if c == "" && l == logical && t == target && d.Machine == home.Machine && d.Login == home.Login {
			return ""
		}
		return "revoked"
	}
	recheck := func() bool { return checkWhy() == "" }
	if why := checkWhy(); why != "" {
		if why == "revoked" {
			refuse(403, "revoked", "attachment not authorized")
		} else {
			refuse(503, why, "the terminal's machine is not reachable right now")
		}
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
		refuse(429, why, "too many attachments")
		return
	}
	defer s.termGate.release(person)
	var doors []termDoor
	if nc.canTermVia {
		doors = s.termDoors()
	}
	s.serveAttachment(w, r, attachmentAdmission{person: person, home: home, logical: logical,
		target: target, epID: epID, node: nc, generation: gen, previous: previous,
		termResume: resume, termTake: take, termRenew: renew, service: "term", table: &s.termRelays, max: termRelayMax(s.TermRelayMaxPerLogin),
		rate: s.TermRelayRateBPS, recheck: recheck, why: checkWhy, doors: doors})
}

// Service adapters share negotiation and leases, never their admission, data
// parsers, accounting, or resource budgets.
type attachmentAdmission struct {
	termResume                                                   string
	termTake                                                     bool
	termRenew                                                    bool
	browser                                                      *websocket.Conn
	person, logical, target, epID, generation, previous, service string
	home                                                         store.EntryHome
	node                                                         *nodeConn
	table                                                        *sshRelayTable
	max                                                          int
	rate                                                         int64
	recheck                                                      func() bool
	// why recheck failed, as the browser's word (RMVE); nil = «revoked»
	why        func() string
	request    control.ChatAttachmentRequest
	dispatched func()
	result     func(control.AttachmentSignal)
	// doors a terminal's payload may go through (XX79); nil = none offered
	doors []termDoor
}

func (s *Server) serveAttachment(w http.ResponseWriter, r *http.Request, a attachmentAdmission) {
	person, home, logical, target := a.person, a.home, a.logical, a.target
	epID, nc, gen, previous, recheck := a.epID, a.node, a.generation, a.previous, a.recheck
	refuse := func(status int, code, msg string) {
		if a.browser == nil {
			refuseJSON(w, status, code, msg)
			return
		}
		sendAttachmentSignal(r.Context(), a.browser, control.AttachmentSignal{T: "error", Status: status, Error: code, Message: msg})
		a.browser.Close(websocket.StatusNormalClosure, "refused")
	}
	stun := strings.Fields(os.Getenv("CCQUOTA_ATTACHMENT_STUN"))
	if _, err := attachment.ICEConfig(stun); err != nil {
		refuse(503, "configuration", "invalid STUN configuration")
		return
	}
	browser := a.browser
	if browser == nil {
		var err error
		browser, err = websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
	}
	defer browser.CloseNow()
	browser.SetReadLimit(control.AttachmentSignalMax)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	send := func(v control.AttachmentSignal) error { return sendAttachmentSignal(ctx, browser, v) }
	if send(control.AttachmentSignal{T: "config", STUN: stun, Generation: gen, Target: logical, TrialLeft: w.Header().Get(trialLeftHeader), Doors: browserDoors(a.doors)}) != nil {
		return
	}
	firstCtx, firstCancel := context.WithTimeout(ctx, control.AttachmentNegotiate)
	t, b, err := browser.Read(firstCtx)
	firstCancel()
	var first control.AttachmentSignal
	if err != nil || t != websocket.MessageText || json.Unmarshal(b, &first) != nil || (first.T != "offer" && first.T != "relay") {
		return
	}
	fp := ""
	mode := "relay"
	if first.T == "offer" {
		fp, err = attachment.Fingerprint(first.SDP)
		if err != nil {
			return
		}
		mode = "negotiate"
	} else if first.SDP != "" {
		return
	}
	if !recheck() {
		return
	}
	var grant control.AttachmentGrant
	var signingKey string
	or, err := s.openLoginRelay(ctx, loginRelaySpec{
		kind: "attachment", table: a.table, epID: epID, node: nc, key: chatRelayKey(home.Machine, home.Login), max: a.max, person: person,
		open: func(id, secret string) (control.Message, error) {
			return control.New(control.TypeAttachmentOpen, control.AttachmentOpen{RelayID: id, Secret: secret, Login: home.Login, Service: a.service})
		},
		hello: func(id, key string, now time.Time) []byte {
			signingKey = key
			grant = control.AttachmentGrant{V: 1, Person: person, Home: home.Machine, Login: home.Login, Node: epID, Service: a.service, TermResume: a.termResume, TermTake: a.termTake, TermRenew: a.termRenew, Chat: a.request, Target: target, Conn: id, Previous: previous, Generation: gen, Fingerprint: fp, Mode: mode, Epoch: 1, Iat: now.Unix(), Exp: now.Add(control.AttachmentLease).Unix()}
			b, _ := json.Marshal(control.AttachmentSignal{T: "open", Grant: control.SignAttachment(grant, key), SDP: first.SDP, STUN: stun})
			return b
		},
	})
	if err != nil {
		send(control.AttachmentSignal{T: "error", Error: "node_unavailable"})
		return
	}
	defer or.end("attachment closed")
	defer or.ws.CloseNow()
	or.ws.SetReadLimit(control.AttachmentSignalMax)
	if send(control.AttachmentSignal{T: "hello", Conn: or.id, Generation: gen, Target: logical}) != nil {
		return
	}
	if a.service == "term" {
		if err := s.Store.RecordTermOpen(store.FleetTermSession{ID: or.id, Person: person, Machine: home.Machine, Login: home.Login, Target: logical, Mode: "negotiating", OpenedAt: time.Now(), Cause: termCause(r.URL.Query().Get("cause")), Previous: previous}); err != nil {
			return
		}
	}
	var up, down int64
	outcome := "closed"
	// why a terminal ended (RMVE): who went — the browser, the node, this hub
	// restarting — or the node's own word; appended to the path in outcome
	reason := ""
	defer func() {
		if a.service == "term" {
			if reason != "" {
				outcome += "; " + reason
			}
			s.Store.RecordTermClose(or.id, outcome, up, down, time.Now())
		} else {
			s.Store.CloseChatRequest(a.request.ID, outcome, up, down)
		}
	}()
	bc, ac := readAttachmentFrames(ctx, browser), readAttachmentFrames(ctx, or.ws)
	// Pongs are processed by the one socket reader, even while payload is direct.
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				pctx, pcancel := context.WithTimeout(ctx, 5*time.Second)
				err := browser.Ping(pctx)
				pcancel()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	deadline := time.NewTimer(control.AttachmentNegotiate)
	defer deadline.Stop()
	selected, ready := false, false
	doorID := ""
	choose := func(mode, door string) error {
		if selected || (mode != "direct" && mode != "relay" && mode != "door") || !recheck() {
			return errors.New("selection refused")
		}
		if mode == "direct" && grant.Mode != "negotiate" {
			return errors.New("no peer negotiated")
		}
		var picked *termDoor
		for i := range a.doors {
			if a.doors[i].ID == door {
				picked = &a.doors[i]
			}
		}
		if mode == "door" && picked == nil {
			return errors.New("no such door")
		}
		var browserTicket, homeTicket string
		if picked != nil && mode == "door" {
			pipe, bt, ht, err := s.doorTickets(*picked, time.Now())
			if err != nil {
				return err
			}
			grant.Door, grant.Pipe, browserTicket, homeTicket, doorID = picked.URL, pipe, bt, ht, picked.ID
		}
		selected = true
		grant.Mode = mode
		grant.Epoch = 2
		grant.Iat = time.Now().Unix()
		grant.Exp = time.Now().Add(control.AttachmentLease).Unix()
		sel := control.AttachmentSignal{T: "selecting", Mode: mode}
		if mode == "door" {
			sel.Door, sel.URL, sel.Ticket = doorID, grant.Door, browserTicket
		}
		if send(sel) != nil {
			return errors.New("browser gone")
		}
		if a.dispatched != nil {
			a.dispatched()
		}
		return sendAttachmentSignal(ctx, or.ws, control.AttachmentSignal{T: "select", Grant: control.SignAttachment(grant, signingKey), Ticket: homeTicket})
	}
	rate := a.rate
	if rate == 0 {
		rate = defaultTermRateBPS
	}
	lim := a.table.limiter(or.key, rate)
	for {
		select {
		case <-ctx.Done():
			reason = "browser_closed"
			return
		case <-or.ctx.Done():
			reason = "node_closed"
			return
		case <-s.drainCh():
			// This hub is going away (a rolling release): tell the page to come
			// back at once — to the other replica — not to wait out a dead socket.
			reason = "hub_restart"
			send(control.AttachmentSignal{T: "error", Error: "hub_restart"})
			return
		case <-deadline.C:
			if !selected {
				if choose("relay", "") != nil {
					return
				}
			}
		case <-ticker.C:
			if !recheck() {
				// only a sign-in that really went says «revoked»: a node that
				// relinked or a machine put into maintenance is a reconnect (RMVE)
				why := "revoked"
				if a.why != nil {
					why = a.why()
				}
				outcome, reason = why, ""
				send(control.AttachmentSignal{T: "error", Error: why})
				return
			}
			grant.Iat = time.Now().Unix()
			grant.Exp = time.Now().Add(control.AttachmentLease).Unix()
			if sendAttachmentSignal(ctx, or.ws, control.AttachmentSignal{T: "lease", Grant: control.SignAttachment(grant, signingKey)}) != nil {
				return
			}
		case f := <-bc:
			if f.err != nil {
				reason = "browser_closed"
				return
			}
			var sig control.AttachmentSignal
			if f.typ == websocket.MessageText && json.Unmarshal(f.b, &sig) == nil && sig.T == "select" {
				// An automatic timeout may have selected relay concurrently. Ignore
				// a late direct selection; it never replaces or cleans up the winner.
				if selected {
					continue
				}
				if sig.Mode == "door" && a.service != "term" {
					return
				}
				if choose(sig.Mode, sig.Door) != nil {
					return
				}
				continue
			}
			if f.typ == websocket.MessageText && a.service == "term" && selected && sig.T == "stats" {
				// the browser's echo report: numbers only, never a byte typed
				if sig.EchoN > 0 && sig.EchoN <= 1_000_000 && sig.EchoP50 >= 0 && sig.EchoP95 >= sig.EchoP50 && sig.EchoP95 <= 60_000 {
					s.Store.RecordTermEcho(or.id, sig.EchoP50, sig.EchoP95, sig.EchoN)
				}
				continue
			}
			if !ready || grant.Mode != "relay" {
				outcome = "data_before_ready"
				return
			}
			if f.typ == websocket.MessageText && a.service == "term" {
				if _, _, err := control.ParseTermResize(f.b); err != nil {
					return
				}
			}
			if a.service == "chat" && f.typ == websocket.MessageText {
				var fctl map[string]json.RawMessage
				if json.Unmarshal(f.b, &fctl) != nil || len(fctl) != 1 {
					return
				}
				var kind string
				if json.Unmarshal(fctl["t"], &kind) != nil || (kind != "request_end" && kind != "received" && kind != "cancel") {
					return
				}
			}
			if len(f.b) > attachment.FrameMax || lim.wait(ctx, len(f.b)) != nil {
				return
			}
			if attachmentWrite(ctx, or.ws, f.typ, f.b) != nil {
				return
			}
			if f.typ == websocket.MessageBinary {
				up += int64(len(f.b))
			}
		case f := <-ac:
			if f.err != nil {
				reason = "node_closed"
				return
			}
			var sig control.AttachmentSignal
			if f.typ == websocket.MessageText && json.Unmarshal(f.b, &sig) == nil {
				switch sig.T {
				case "chat_accepted", "chat_result":
					if a.service != "chat" || !selected || sig.Conn != a.request.ID {
						return
					}
					if a.result != nil {
						a.result(sig)
					}
					// Acknowledge the accounting BEFORE the node ends its stream.
					if sig.T == "chat_result" {
						if sendAttachmentSignal(ctx, or.ws, control.AttachmentSignal{T: "chat_recorded", Conn: sig.Conn}) != nil {
							return
						}
					}
					continue
				case "error":
					reason = termReason(sig.Error)
					send(control.AttachmentSignal{T: "error", Error: sig.Error, Term: sig.Term, TermGen: sig.TermGen})
					return
				case "answer":
					if selected {
						continue
					}
					if sig.SDP != "" {
						if _, err := attachment.Fingerprint(sig.SDP); err != nil {
							return
						}
					}
					if send(control.AttachmentSignal{T: "answer", SDP: sig.SDP, Error: sig.Error}) != nil {
						return
					}
					continue
				case "selected":
					if !selected || sig.Mode != grant.Mode {
						return
					}
					outcome = grant.Mode + " " + sig.Pair
					if grant.Mode == "door" {
						outcome = "door " + doorID
					}
					if a.service == "term" && s.Store.RecordTermMode(or.id, grant.Mode) != nil {
						return
					}
					if send(control.AttachmentSignal{T: "selected", Mode: grant.Mode, Pair: sig.Pair}) != nil {
						return
					}
					continue
				}
			}
			if !selected || grant.Mode != "relay" {
				return
			}
			if f.typ == websocket.MessageText {
				if a.service == "term" {
					c, e := control.ParseTermAgentControl(f.b)
					if e != nil {
						return
					}
					if c.T == "ready" {
						ready = true
					}
				} else {
					var c control.ChatAttachmentFrame
					if json.Unmarshal(f.b, &c) != nil {
						return
					}
					if c.T == "ready" {
						ready = true
					}
				}
			}
			if !ready || len(f.b) > attachment.FrameMax || lim.wait(ctx, len(f.b)) != nil {
				return
			}
			if attachmentWrite(ctx, browser, f.typ, f.b) != nil {
				return
			}
			if f.typ == websocket.MessageBinary {
				down += int64(len(f.b))
			}
		}
	}
}

type attachmentFrame struct {
	typ websocket.MessageType
	b   []byte
	err error
}

func readAttachmentFrames(ctx context.Context, c *websocket.Conn) <-chan attachmentFrame {
	ch := make(chan attachmentFrame, 1)
	go func() {
		for {
			t, b, e := c.Read(ctx)
			select {
			case ch <- attachmentFrame{t, b, e}:
			case <-ctx.Done():
				return
			}
			if e != nil {
				return
			}
		}
	}()
	return ch
}
func attachmentWrite(ctx context.Context, c *websocket.Conn, t websocket.MessageType, b []byte) error {
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return c.Write(wctx, t, b)
}
func sendAttachmentSignal(ctx context.Context, c *websocket.Conn, v control.AttachmentSignal) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return attachmentWrite(ctx, c, websocket.MessageText, b)
}
