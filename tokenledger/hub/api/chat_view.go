package api

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 只读 (task F481, EPIC GR5E C5): a session running in a terminal, its
// conversation read along from the web — the chat relay's road to the login it
// runs on, never typed into.
//
//	browser ──GET /v1/chat/view?worker=<id>&from=<n> (same origin, signed in)──▶ hub
//	hub: who (termPerson: a person as themselves, never the operator's door, never
//	     a view-as) · the worker theirs (termTarget: a fleet on their home or on
//	     another of their own active logins — else 404 not_yours)
//	hub ──dialChatRelay(person, machine, login)──▶ that login's /api/view?fid=<window>
//
// The answer is the service's Server-Sent Events as it writes them. The browser
// names a worker id, never a machine, a login or a session id: the window's
// @fleet_id is the hub's to hand on. An agent without the chat relay is 409
// old_agent (「这台机器还旧」); a login in maintenance is 503 home_down.

// chatViewRoute is ChatPathPrefix's name for it.
const chatViewRoute = "view"

const (
	// a stream holds its line while it is watched: two pages per person, apart
	// from the conversation's own bound
	defaultChatViewPerPerson = 3
	defaultChatViewPerMinute = 30
)

func (s *Server) handleChatView(w http.ResponseWriter, r *http.Request) {
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
		s.chatRefuse(w, person, chatViewRoute, status, code, msg)
		return
	}
	from := 0
	if f := r.URL.Query().Get("from"); f != "" {
		n, err := strconv.Atoi(f)
		if err != nil || n < 0 {
			s.chatRefuse(w, person, chatViewRoute, http.StatusBadRequest, "bad_from", "from is a count")
			return
		}
		from = n
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
	// only a worker: the personal terminal has no conversation to read
	q := url.Values{"worker": {r.URL.Query().Get("worker")}}
	wid, target, dest, status, code, msg := s.termTarget(q, home)
	if code != "" {
		s.chatRefuse(w, person, chatViewRoute, status, code, msg)
		return
	}
	fid := target[len(control.TermWorkerTarget("")):]
	where := dest.Machine + "/" + dest.Login
	if peer, ok := s.chatRelayPeer(r, dest.Machine, dest.Login); ok {
		s.proxyRelay(w, r, peer, "a chat view to "+where)
		return
	}
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(dest.Machine, settings); flagged {
			s.chatRefuse(w, person, chatViewRoute+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器在维护中，现在连不上")
			return
		}
	}
	if _, _, err := s.chatRelayNode(dest.Machine, dest.Login); err != nil {
		var re *sshRelayError
		if errors.As(err, &re) && re.code == "NO_CHAT" {
			s.chatRefuse(w, person, chatViewRoute+" "+where, http.StatusConflict, "old_agent",
				"这台机器的 fleet 还旧，网页里看不了这个会话的对话；更新后就能看，现在请用终端")
			return
		}
		s.chatRefuse(w, person, chatViewRoute+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
		return
	}
	gateKey := person + "\x00view"
	if why := s.chatGate.admit(gateKey, defaultChatViewPerPerson, defaultChatViewPerMinute, time.Now()); why != "" {
		s.chatRefuse(w, person, chatViewRoute, http.StatusTooManyRequests, why, "too many pages following sessions; close one")
		return
	}
	defer s.chatGate.release(gateKey)

	var dialErr error
	one := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			c, err := s.dialChatRelay(ctx, person, dest.Machine, dest.Login)
			if err == nil {
				s.chatAudit(person, "chat_relay", "OPENED view "+wid+" "+where)
			}
			dialErr = err
			return c, err
		},
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	defer one.CloseIdleConnections()
	ctx, stop := context.WithCancel(r.Context())
	defer stop()
	go s.chatViewRecheck(ctx, stop, r, person, dest.Machine)
	r = r.WithContext(ctx)
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			out := pr.Out
			out.URL.Scheme, out.URL.Host, out.Host = "http", "webchat", "webchat"
			out.URL.Path, out.URL.RawPath = "/api/view", ""
			out.URL.RawQuery = url.Values{"fid": {fid}, "from": {strconv.Itoa(from)}}.Encode()
			out.Header = http.Header{}
			out.Header.Set("Accept", "text/event-stream")
			out.Header.Set(control.ChatPersonHeader, person)
		},
		Transport:     one,
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			var re *sshRelayError
			switch {
			case r.Context().Err() != nil:
				// the page went away
			case dialErr != nil && errors.As(dialErr, &re) && re.code == "TOO_MANY":
				s.chatRefuse(w, person, chatViewRoute+" "+where, http.StatusTooManyRequests, "too_many", re.msg)
			case dialErr != nil:
				s.chatRefuse(w, person, chatViewRoute+" "+where, http.StatusServiceUnavailable, "home_down", "这台机器现在连不上")
			default:
				s.chatAudit(person, "chat_relay", "BROKEN view "+where)
				refuseJSON(w, http.StatusBadGateway, "relay", "the conversation service did not answer")
			}
		},
	}
	w.Header().Set("Cache-Control", "no-store")
	rp.ServeHTTP(w, r)
}

// chatViewRecheck ends a view once its person no longer signs in or the
// machine goes into maintenance (chatRecheck's rule, without the home: a view
// may be of a session on another of the person's logins).
func (s *Server) chatViewRecheck(ctx context.Context, stop func(), r *http.Request, person, machine string) {
	t := time.NewTicker(chatRecheckEvery.Get())
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		p, _, code, _ := s.termPerson(r)
		gone := code != "" || p != person
		if !gone {
			if settings, err := s.Store.FleetSettings(); err == nil {
				_, gone = maintenanceOf(machine, settings)
			}
		}
		if gone {
			s.chatAudit(person, "chat_relay", "REVOKED view "+machine)
			stop()
			return
		}
	}
}
