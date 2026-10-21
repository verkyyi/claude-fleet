package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 接管 / 交回 (task VV8F, EPIC GR5E C6): the session workspace hands a terminal
// session's conversation to the person's WebChat and back. Only ever one side
// talks: taken over, the page writes and the terminal rests on its end page;
// given back, the terminal resumes the same conversation.
//
//	browser ──POST /v1/chat/takeover|giveback?worker=<id> (X-Fleet-Webchat: 1)──▶ hub
//	hub: who (termPerson) · the worker theirs (termTarget) · on their HOME login —
//	     the only WebChat their page talks to (else 409 not_home)
//	hub ──dialChatRelay──▶ the home's /api/takeover|giveback {"fid": <window>}
//
// The body is the hub's: the browser names a worker id, never a window. The
// service refuses while either side answers (409 terminal_busy / web_busy) and
// a second handover of one window at once (409 taking).
var chatHandoverRoutes = map[string]string{"takeover": "takeover", "giveback": "giveback"}

// chatHandoverWait bounds one handover: the agent's /exit, or the end page's
// resume, takes seconds — never a stream.
const chatHandoverWait = 45 * time.Second

func (s *Server) handleChatHandover(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	person, status, code, msg := s.termPerson(r)
	if code != "" {
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		}
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	if r.Header.Get("X-Fleet-Webchat") != "1" {
		s.chatRefuse(w, person, name, http.StatusForbidden, "forbidden", "X-Fleet-Webchat: 1 is required")
		return
	}
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok {
		home = store.EntryHome{}
	}
	home.Person = person
	wid, target, dest, status, code, msg := s.termTarget(r.URL.Query(), home)
	if code == "" && wid == control.TermTargetPersonal {
		status, code, msg = http.StatusBadRequest, "bad_target", "a session's worker id"
	}
	if code != "" {
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	// the page's conversation is the home's: a session on another login is followed, never taken
	if home.Machine == "" || dest.Machine != home.Machine || dest.Login != home.Login {
		s.chatRefuse(w, person, name, http.StatusConflict, "not_home",
			"这个会话不在你的家机器上，网页接管不了；请到它的终端里说")
		return
	}
	fid := target[len(control.TermWorkerTarget("")):]
	where := dest.Machine + "/" + dest.Login
	if peer, ok := s.chatRelayPeer(r, dest.Machine, dest.Login); ok {
		s.proxyRelay(w, r, peer, "a chat "+name+" to "+where)
		return
	}
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(dest.Machine, settings); flagged {
			s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器在维护中，现在连不上")
			return
		}
	}
	if _, _, err := s.chatRelayNode(dest.Machine, dest.Login); err != nil {
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "NO_CHAT" {
			s.chatRefuse(w, person, name+" "+where, http.StatusConflict, "old_agent",
				"这台机器的 fleet 还旧，网页接管不了；更新后就能，现在请用终端")
			return
		}
		s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
		return
	}
	gateKey := person + "\x00handover"
	if why := s.chatGate.admit(gateKey, 2, defaultChatViewPerMinute, time.Now()); why != "" {
		s.chatRefuse(w, person, name, http.StatusTooManyRequests, why, "too many handovers at once; wait a moment")
		return
	}
	defer s.chatGate.release(gateKey)

	one := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			c, err := s.dialChatRelay(ctx, person, dest.Machine, dest.Login)
			if err == nil {
				s.chatAudit(person, "chat_relay", "OPENED "+name+" "+wid+" "+where)
			}
			return c, err
		},
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	defer one.CloseIdleConnections()
	body, _ := json.Marshal(map[string]string{"fid": fid})
	ctx, cancel := context.WithTimeout(r.Context(), chatHandoverWait)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://webchat/api/"+chatHandoverRoutes[name], strings.NewReader(string(body)))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Fleet-Webchat", "1")
	req.Header.Set(control.ChatPersonHeader, person)
	resp, err := one.RoundTrip(req)
	if err != nil {
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "TOO_MANY" {
			s.chatRefuse(w, person, name+" "+where, http.StatusTooManyRequests, "too_many", re.msg)
			return
		}
		s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
		return
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	// a service from before this step has no such route: say so, as the view does
	if resp.StatusCode == http.StatusNotFound && !strings.Contains(string(out), `"code"`) {
		s.chatRefuse(w, person, name+" "+where, http.StatusConflict, "old_service",
			"这台机器的网页对话服务还旧，接管不了；更新后就能，现在请用终端")
		return
	}
	s.chatAudit(person, "chat_relay", strings.ToUpper(name)+" "+wid+" "+where+" "+resp.Status)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
}
