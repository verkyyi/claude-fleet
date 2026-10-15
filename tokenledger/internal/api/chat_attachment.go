package api

import (
	"github.com/coder/websocket"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// This lives under /v1/chat so the existing trial/view-as route guards apply.
// Admission metadata travels through the hub; request and response bodies use
// the selected path. Each request has its own lease, caps and lifetime.
func (s *Server) handleChatAttachment(w http.ResponseWriter, r *http.Request) {
	person, status, code, msg := s.chatPerson(r)
	name := r.URL.Query().Get("target")
	var browser *websocket.Conn
	refuse := func(st int, c, m string) {
		if browser == nil {
			s.chatRefuse(w, person, name, st, c, m)
			return
		}
		s.chatAudit(person, "chat_refused", c+" "+name)
		sendAttachmentSignal(r.Context(), browser, control.AttachmentSignal{T: "error", Error: c, Status: st, Message: m})
		// Normal closure flushes the structured refusal before closing the socket.
		browser.Close(websocket.StatusNormalClosure, "refused")
	}
	if code != "" {
		refuse(status, code, msg)
		return
	}
	if r.Method != "GET" || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		refuse(400, "upgrade", "websocket required")
		return
	}
	if !s.termOriginOK(r) {
		refuse(403, "origin", "same-origin required")
		return
	}
	if !s.attachmentSessionLive(r) {
		refuse(401, "signin", "sign in again")
		return
	}
	if !control.ValidAttachmentTarget("chat", name) {
		refuse(400, "route", "invalid chat route")
		return
	}
	n, err := strconv.Atoi(r.URL.Query().Get("bytes"))
	req := control.ChatAttachmentRequest{ID: r.URL.Query().Get("request"), Bytes: n, Client: s.chatClientHeader(r)}
	if err != nil || !req.Valid(name) || r.URL.Query().Get("previous") != "" {
		refuse(400, "request", "invalid chat request")
		return
	}
	_ = s.Store.TouchTrial(person, time.Now())
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		refuse(503, "home_down", "home unavailable")
		return
	}
	if !ok || home.Machine == "" || home.Login == "" {
		refuse(409, "no_home", "choose your home first")
		return
	}
	if name == "conversation" {
		s.seedKeptConvo(person, time.Now())
	}
	if peer, ok := s.chatRelayPeer(r, home.Machine, home.Login); ok {
		s.proxyRelay(w, r, peer, "chat attachment")
		return
	}
	epID, nc, err := s.chatRelayNode(home.Machine, home.Login)
	if err != nil {
		refuse(503, "home_down", "home unavailable")
		return
	}
	if !nc.canChatAttachment || nc.attachmentGeneration == "" {
		refuse(409, "unsupported", "use the existing chat relay")
		return
	}
	gen := nc.attachmentGeneration
	if want := r.URL.Query().Get("generation"); want != "" && want != gen {
		refuse(409, "interrupted", "the node generation changed")
		return
	}
	browser, err = websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer browser.CloseNow()
	recheck := func() bool {
		p, _, c, _ := s.chatPerson(r)
		h, ok, e := s.Store.EntryHomeOf(person)
		if c != "" || p != person || e != nil || !ok || h.Machine != home.Machine || h.Login != home.Login || s.nodes.get(epID) != nc || !s.attachmentSessionLive(r) {
			return false
		}
		settings, e := s.Store.FleetSettings()
		if e != nil {
			return false
		}
		_, maintenance := maintenanceOf(home.Machine, settings)
		return !maintenance
	}
	if !recheck() {
		refuse(503, "home_down", "home unavailable or in maintenance")
		return
	}
	max, perMin := s.ChatMaxPerPerson, s.ChatPerMinute
	if max == 0 {
		max = defaultChatPerPerson
	}
	if perMin == 0 {
		perMin = defaultChatPerMinute
	}
	if why := s.chatGate.admit(person, max, perMin, time.Now()); why != "" {
		refuse(429, why, "too many chat requests; wait a moment")
		return
	}
	defer s.chatGate.release(person)
	claimed, err := s.Store.ClaimChatRequest(req.ID, person, name)
	if err != nil {
		refuse(503, "admission", "request admission unavailable")
		return
	}
	if !claimed {
		refuse(409, "duplicate", "request already admitted; reload the conversation")
		return
	}
	_ = s.Store.CloseChatRequest(req.ID, "admitted", 0, 0)
	var refund func(string)
	if name == "turn" {
		code, msg, counted := s.trialTurn(w, person, time.Now())
		if code != "" {
			_ = s.Store.CloseChatRequest(req.ID, code, 0, 0)
			refuse(403, code, msg)
			return
		}
		if counted {
			var once sync.Once
			refund = func(why string) { once.Do(func() { s.trialRefund(person, why) }) }
		}
	}
	dispatched, accepted, completed := false, false, false
	defer func() {
		// Once selection is sent, delivery may be uncertain. Browser cancellation
		// alone is never authority to refund or to resubmit a turn.
		if !dispatched && refund != nil {
			refund("attachment did not reach the service")
		}
	}()
	limit := s.ChatRelayMaxPerLogin
	if limit <= 0 {
		limit = defaultChatRelayMaxPerLogin
	}
	rate := s.ChatRelayRateBPS
	if rate == 0 {
		rate = defaultChatRelayRateBPS
	}
	req.Rate = rate
	s.serveAttachment(w, r, attachmentAdmission{browser: browser, person: person, home: home, logical: name,
		target: name, epID: epID, node: nc, generation: gen, service: "chat", request: req,
		table: &s.chatRelays, max: limit, rate: rate, recheck: recheck,
		dispatched: func() { dispatched = true },
		result: func(sig control.AttachmentSignal) {
			if completed {
				return
			}
			if sig.T == "chat_accepted" {
				if !accepted {
					s.chatAudit(person, "chat_attachment", "ACCEPTED "+name)
					accepted = true
				}
			} else {
				completed = true
				if sig.Refund && refund != nil {
					refund("node confirmed no reply")
				}
				s.chatAudit(person, "chat_attachment", "COMPLETED "+name)
			}
		},
	})
}
