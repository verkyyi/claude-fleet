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
	"github.com/verkyyi/claude-fleet/tokenledger/internal/attachment"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

const AttachmentPath = "/v1/attachment/connect"

// This first consumer is the terminal. The shared grant, frame and browser
// transport are also usable by C6's independently admitted chat request adapter.
// Until that adapter exists, service=chat is explicitly refused, never tunneled.
func (s *Server) handleAttachment(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	person, status, code, msg := s.termPerson(r)
	refuse := func(status int, code, msg string) { s.termRefuse(w, person, "attachment", status, code, msg) }
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
	logical, target, status, code, msg := s.termTarget(r.URL.Query(), home)
	if code != "" {
		refuse(status, code, msg)
		return
	}
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
	gen := nc.attachmentGeneration
	previous := r.URL.Query().Get("previous")
	if len(previous) > 128 || strings.ContainsAny(previous, "/\\ \t\r\n") {
		refuse(400, "previous", "invalid previous connection")
		return
	}
	if want := r.URL.Query().Get("generation"); want != "" && want != gen {
		refuse(409, "interrupted", "the node generation changed")
		return
	}
	recheck := func() bool {
		p, _, c, _ := s.termPerson(r)
		h, ok, e := s.Store.EntryHomeOf(person)
		if c != "" || p != person || e != nil || !ok || h.Machine != home.Machine || h.Login != home.Login || s.nodes.get(epID) != nc || !s.attachmentSessionLive(r) {
			return false
		}
		settings, e := s.Store.FleetSettings()
		if e != nil {
			return false
		}
		if _, maintenance := maintenanceOf(home.Machine, settings); maintenance {
			return false
		}
		l, t, _, c, _ := s.termTarget(r.URL.Query(), h)
		return c == "" && l == logical && t == target
	}
	if !recheck() {
		refuse(403, "revoked", "attachment not authorized")
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
	stun := strings.Fields(os.Getenv("CCQUOTA_ATTACHMENT_STUN"))
	if _, err := attachment.ICEConfig(stun); err != nil {
		refuse(503, "configuration", "invalid STUN configuration")
		return
	}
	browser, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer browser.CloseNow()
	browser.SetReadLimit(control.AttachmentSignalMax)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	send := func(v control.AttachmentSignal) error { return sendAttachmentSignal(ctx, browser, v) }
	if send(control.AttachmentSignal{T: "config", STUN: stun, Generation: gen, Target: logical}) != nil {
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
		kind: "attachment", table: &s.termRelays, epID: epID, node: nc, key: chatRelayKey(home.Machine, home.Login), max: termRelayMax(s.TermRelayMaxPerLogin), person: person,
		open: func(id, secret string) (control.Message, error) {
			return control.New(control.TypeAttachmentOpen, control.AttachmentOpen{RelayID: id, Secret: secret, Login: home.Login})
		},
		hello: func(id, key string, now time.Time) []byte {
			signingKey = key
			grant = control.AttachmentGrant{V: 1, Person: person, Home: home.Machine, Login: home.Login, Node: epID, Service: "term", Target: target, Conn: id, Previous: previous, Generation: gen, Fingerprint: fp, Mode: mode, Epoch: 1, Iat: now.Unix(), Exp: now.Add(control.AttachmentLease).Unix()}
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
	if err := s.Store.RecordTermOpen(store.FleetTermSession{ID: or.id, Person: person, Machine: home.Machine, Login: home.Login, Target: logical, Mode: "negotiating", OpenedAt: time.Now()}); err != nil {
		return
	}
	var up, down int64
	outcome := "closed"
	defer func() { s.Store.RecordTermClose(or.id, outcome, up, down, time.Now()) }()
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
	choose := func(mode string) error {
		if selected || (mode != "direct" && mode != "relay") || !recheck() {
			return errors.New("selection refused")
		}
		if mode == "direct" && grant.Mode != "negotiate" {
			return errors.New("no peer negotiated")
		}
		selected = true
		grant.Mode = mode
		grant.Epoch = 2
		grant.Iat = time.Now().Unix()
		grant.Exp = time.Now().Add(control.AttachmentLease).Unix()
		if send(control.AttachmentSignal{T: "selecting", Mode: mode}) != nil {
			return errors.New("browser gone")
		}
		return sendAttachmentSignal(ctx, or.ws, control.AttachmentSignal{T: "select", Grant: control.SignAttachment(grant, signingKey)})
	}
	rate := s.TermRelayRateBPS
	if rate == 0 {
		rate = defaultTermRateBPS
	}
	lim := s.termRelays.limiter(or.key, rate)
	for {
		select {
		case <-ctx.Done():
			return
		case <-or.ctx.Done():
			return
		case <-deadline.C:
			if !selected {
				if choose("relay") != nil {
					return
				}
			}
		case <-ticker.C:
			if !recheck() {
				outcome = "revoked"
				send(control.AttachmentSignal{T: "error", Error: "revoked"})
				return
			}
			grant.Iat = time.Now().Unix()
			grant.Exp = time.Now().Add(control.AttachmentLease).Unix()
			if sendAttachmentSignal(ctx, or.ws, control.AttachmentSignal{T: "lease", Grant: control.SignAttachment(grant, signingKey)}) != nil {
				return
			}
		case f := <-bc:
			if f.err != nil {
				return
			}
			var sig control.AttachmentSignal
			if f.typ == websocket.MessageText && json.Unmarshal(f.b, &sig) == nil && sig.T == "select" {
				// An automatic timeout may have selected relay concurrently. Ignore
				// a late direct selection; it never replaces or cleans up the winner.
				if selected {
					continue
				}
				if choose(sig.Mode) != nil {
					return
				}
				continue
			}
			if !ready || grant.Mode != "relay" {
				outcome = "data_before_ready"
				return
			}
			if f.typ == websocket.MessageText {
				if _, _, err := control.ParseTermResize(f.b); err != nil {
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
				return
			}
			var sig control.AttachmentSignal
			if f.typ == websocket.MessageText && json.Unmarshal(f.b, &sig) == nil {
				switch sig.T {
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
					if s.Store.RecordTermMode(or.id, grant.Mode) != nil {
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
				c, e := control.ParseTermAgentControl(f.b)
				if e != nil {
					return
				}
				if c.T == "ready" {
					ready = true
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
