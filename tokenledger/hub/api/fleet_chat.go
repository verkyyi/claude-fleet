package api

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httputil"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The entry's half of the web chat (claude-fleet#3645, EPIC #3642 C3). A
// person's browser talks to /v1/chat/<name>; the entry runs no conversation —
// it decides WHO is asking, finds their home login and relays the request, over
// C2's dialChatRelay, to that login's conversation service
// (extras/web-chat/server.mjs on $FLEET_CONF_DIR/webchat/chat.sock):
//
//	browser ──/v1/chat/turn (ccq_sess)──▶ entry: person · EntryHomeOf · not down
//	entry ──dialChatRelay(person, machine, login)──▶ that login's agent ──▶ chat.sock /api/turn
//
// Only a person signs in here: a user or an admin, each to THEIR OWN
// conversation (D5 — the X-Fleet-Person statement is minted for the caller,
// never for a name the request carries). The operator's shared door is no one's
// conversation and is refused. No home is 409 no_home; a home that is not
// connected or is in maintenance is 503 home_down — never another machine (D2).
// Every relay opened and every refusal is one fleet_audit row (never content).

// ChatPathPrefix is where the page's API lives on the entry.
const ChatPathPrefix = "/v1/chat/"

// chatRoutes is the whole API: the name after ChatPathPrefix, the one method it
// takes. Each is the conversation service's /api/<name>.
var chatRoutes = map[string]string{
	"conversation": http.MethodGet,
	"turn":         http.MethodPost,
	"stop":         http.MethodPost,
	"answer":       http.MethodPost,
}

// chatHomeRoute is the one route the entry answers itself (claude-fleet#3646):
// where the person's conversation runs, for the page's top bar — no relay.
const chatHomeRoute = "home"

// ChatHome is GET /v1/chat/home's answer. State: ok · offline (the login is
// not connected) · maintenance · old_agent (connected, without the chat relay).
type ChatHome struct {
	Machine string `json:"machine"`
	Login   string `json:"login"`
	State   string `json:"state"`
	Direct  bool   `json:"direct,omitempty"`
}

// handleChatHome answers the person's home and whether a turn could reach it
// now; no home is 409 no_home, as for every other route.
func (s *Server) handleChatHome(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	person, status, code, msg := s.chatPerson(r)
	if code != "" {
		s.chatRefuse(w, person, chatHomeRoute, status, code, msg)
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
	// The person's login is linked to another replica (claude-fleet#3847):
	// that one answers, as it would for a turn.
	if peer, ok := s.chatRelayPeer(r, home.Machine, home.Login); ok {
		s.proxyRelay(w, r, peer, "a chat home read for "+home.Machine+"/"+home.Login)
		return
	}
	out := ChatHome{Machine: home.Machine, Login: home.Login, State: "ok"}
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(home.Machine, settings); flagged {
			out.State = "maintenance"
		}
	}
	if out.State == "ok" {
		if _, nc, err := s.chatRelayNode(home.Machine, home.Login); err != nil {
			out.State = "offline"
			var re *sshRelayError
			if errors.As(err, &re) && re.code == "NO_CHAT" {
				out.State = "old_agent"
			}
		} else {
			out.Direct = nc.canChatAttachment && nc.attachmentGeneration != ""
		}
	}
	writeJSON(w, http.StatusOK, out)
}

const (
	// defaultChatPerPerson bounds one person's requests in flight: a page holds
	// one conversation read or turn stream, plus a stop or an answer beside it.
	defaultChatPerPerson = 4
	// defaultChatPerMinute bounds how many relays one person opens a minute.
	defaultChatPerMinute = 60
	// chatBodyMax bounds a POST: a turn's words, an answer.
	chatBodyMax = 1 << 20
)

// chatGate holds the per-person bounds.
type chatGate struct {
	mu       sync.Mutex
	inflight map[string]int
	buckets  map[string]*chatBucket
}

// chatBucket is a token bucket refilled at perMin a minute, perMin deep.
type chatBucket struct {
	tokens float64
	at     time.Time
}

// admit takes one in-flight slot and one token for person; the reason it
// refused, else "". release gives the slot back.
func (g *chatGate) admit(person string, max, perMin int, now time.Time) string {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.inflight == nil {
		g.inflight, g.buckets = map[string]int{}, map[string]*chatBucket{}
	}
	if max > 0 && g.inflight[person] >= max {
		return "too_many"
	}
	if perMin > 0 {
		b := g.buckets[person]
		if b == nil {
			b = &chatBucket{tokens: float64(perMin), at: now}
			g.buckets[person] = b
		}
		b.tokens += now.Sub(b.at).Minutes() * float64(perMin)
		if b.tokens > float64(perMin) {
			b.tokens = float64(perMin)
		}
		b.at = now
		if b.tokens < 1 {
			return "rate"
		}
		b.tokens--
	}
	g.inflight[person]++
	return ""
}

func (g *chatGate) release(person string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.inflight[person]--; g.inflight[person] <= 0 {
		delete(g.inflight, person)
	}
}

// chatAudit records one relay or refusal: who, which route, how it ended.
func (s *Server) chatAudit(actor, action, outcome string) {
	if s.Store != nil {
		_ = s.Store.FleetAudit(actor, action, "", outcome, "", time.Now())
	}
}

// chatRefuse answers a refusal and audits it.
func (s *Server) chatRefuse(w http.ResponseWriter, actor, route string, status int, code, msg string) {
	if actor == "" {
		actor = "anonymous"
	}
	s.chatAudit(actor, "chat_refused", code+" "+route)
	refuseJSON(w, status, code, msg)
}

// chatPerson is whose conversation a request is: the signed-in person (a user,
// or an admin as themselves). code != "" refuses.
func (s *Server) chatPerson(r *http.Request) (person string, status int, code, msg string) {
	id, ok := s.sshRelayHTTPIdentity(r)
	switch {
	case !ok:
		return "", http.StatusUnauthorized, "signin", "sign in first"
	case id.Admin:
		person = id.Actor
	case id.Operator:
		return "", http.StatusForbidden, "operator", "the operator's door has no conversation; sign in as yourself"
	default:
		person = id.Principal
	}
	if person == "" {
		return "", http.StatusForbidden, "forbidden", "no person to talk as"
	}
	if p, err := s.Store.Principal(person); err == nil {
		person = p.ID
	}
	// Only one's own conversation exists here — an admin's included (D5).
	for _, k := range []string{"principal", "person"} {
		if q := strings.TrimSpace(r.URL.Query().Get(k)); q != "" && !strings.EqualFold(q, person) {
			return person, http.StatusForbidden, "not_yours", "only your own conversation"
		}
	}
	return person, 0, "", ""
}

// handleChat serves ChatPathPrefix + one of chatRoutes, or home.
func (s *Server) handleChat(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	name := strings.TrimPrefix(r.URL.Path, ChatPathPrefix)
	if name == "connect" {
		s.handleChatAttachment(w, r)
		return
	}
	if name == chatHomeRoute {
		s.handleChatHome(w, r)
		return
	}
	method, ok := chatRoutes[name]
	if !ok {
		httpError(w, http.StatusNotFound, "no such chat route")
		return
	}
	if r.Method != method {
		w.Header().Set("Allow", method)
		httpError(w, http.StatusMethodNotAllowed, method+" only")
		return
	}
	person, status, code, msg := s.chatPerson(r)
	if code == "" {
		_ = s.Store.TouchTrial(person, time.Now()) // a trial in use is not idle (claude-fleet#3590)
	}
	if code != "" {
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		}
		s.chatRefuse(w, person, name, status, code, msg)
		return
	}
	// A state-changing call must come from the page itself: fetch sets this
	// header, a cross-site form cannot (the service checks it again).
	if r.Method == http.MethodPost && r.Header.Get("X-Fleet-Webchat") != "1" {
		s.chatRefuse(w, person, name, http.StatusForbidden, "forbidden", "X-Fleet-Webchat: 1 is required")
		return
	}
	home, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !ok || home.Machine == "" || home.Login == "" {
		s.chatRefuse(w, person, name, http.StatusConflict, "no_home", "你还没有家：先在「我的连接」里选一台机器")
		return
	}
	where := home.Machine + "/" + home.Login
	// A conversation kept apart from a trial (claude-fleet#4060) goes into
	// the person's home before its first read there.
	if name == "conversation" {
		s.seedKeptConvo(person, time.Now())
	}
	// The login's link ends in another replica (claude-fleet#3847): hand it
	// the whole request, before any bound or audit here — it signs the person
	// in again, opens the relay and audits it as its own.
	if peer, ok := s.chatRelayPeer(r, home.Machine, home.Login); ok {
		s.proxyRelay(w, r, peer, "a chat relay to "+where)
		return
	}
	if settings, err := s.Store.FleetSettings(); err == nil {
		if _, flagged := maintenanceOf(home.Machine, settings); flagged {
			s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "你的机器在维护中，现在连不上")
			return
		}
	}
	max, perMin := s.ChatMaxPerPerson, s.ChatPerMinute
	if max == 0 {
		max = defaultChatPerPerson
	}
	if perMin == 0 {
		perMin = defaultChatPerMinute
	}
	if why := s.chatGate.admit(person, max, perMin, time.Now()); why != "" {
		s.chatRefuse(w, person, name, http.StatusTooManyRequests, why, "too many chat requests; wait a moment")
		return
	}
	defer s.chatGate.release(person)
	// A trial line counted for this turn goes back when the turn gets no reply
	// (claude-fleet#4248); nil for anything else.
	var refund func(why string)
	if name == "turn" {
		// A trial's lines and time (claude-fleet#4059): past either, no more.
		code, msg, counted := s.trialTurn(w, person, time.Now())
		if code != "" {
			s.chatRefuse(w, person, name, http.StatusForbidden, code, msg)
			return
		}
		if counted {
			var once sync.Once
			refund = func(why string) { once.Do(func() { s.trialRefund(person, why) }) }
		}
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, chatBodyMax)
	}

	var (
		mu      sync.Mutex
		dialErr error
	)
	// The one address the transport reaches: the person's own relay. A relay
	// kept open (ChatRelayKeepSecs) is dialled by whichever request needs it;
	// that request's holder records the dial's error.
	holder := &chatDialHolder{}
	dial := func(ctx context.Context) (net.Conn, error) {
		c, err := s.dialChatRelay(ctx, person, home.Machine, home.Login)
		h, _ := ctx.Value(chatDialKey{}).(*chatDialHolder)
		if h == nil {
			h = holder
		}
		mu.Lock()
		h.err = err
		mu.Unlock()
		if err == nil {
			s.chatAudit(person, "chat_relay", "OPENED "+name+" "+where)
		}
		return c, err
	}
	var tr http.RoundTripper
	if keep := time.Duration(s.ChatRelayKeepSecs) * time.Second; keep > 0 {
		// One person's relays to one home login, kept open between requests
		// (task V9DJ B): a request on a kept relay is one round trip to the
		// home instead of asking its agent to dial back each time (~0.8 s
		// across the Pacific). The statement the agent verified at the relay's
		// opening names this person; the transport is theirs alone.
		tr = s.chatPool.transport(person+"\x00"+home.Machine+"\x00"+home.Login, keep, dial)
	} else {
		one := &http.Transport{
			DialContext:        func(ctx context.Context, _, _ string) (net.Conn, error) { return dial(ctx) },
			DisableKeepAlives:  true,
			DisableCompression: true,
		}
		defer one.CloseIdleConnections()
		tr = one
	}
	// A stream is held to who may read it while it lasts (the attachment's
	// lease, claude-fleet#4408): signed out, another home, maintenance ⇒ cut.
	ctx, stop := context.WithCancel(context.WithValue(r.Context(), chatDialKey{}, holder))
	defer stop()
	go s.chatRecheck(ctx, stop, r, person, home.Machine, home.Login)
	r = r.WithContext(ctx)
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			out := pr.Out
			out.URL.Scheme, out.URL.Host, out.Host = "http", "webchat", "webchat"
			out.URL.Path, out.URL.RawPath, out.URL.RawQuery = "/api/"+name, "", ""
			// Nothing of the browser's goes on but what the service reads: never
			// its cookies, never a person it names.
			in := pr.In.Header
			out.Header = http.Header{}
			for _, k := range []string{"Content-Type", "Accept", "X-Fleet-Webchat"} {
				if v := in.Get(k); v != "" {
					out.Header.Set(k, v)
				}
			}
			out.Header.Set(control.ChatPersonHeader, person)
			if c := s.chatClientHeader(pr.In); c != "" {
				out.Header.Set(control.ChatClientHeader, c)
			}
		},
		Transport: tr,
		// NDJSON: each line reaches the page as the service writes it.
		FlushInterval: -1,
		ModifyResponse: func(resp *http.Response) error {
			if refund == nil {
				return nil
			}
			if resp.StatusCode != http.StatusOK {
				refund("the service refused the turn: " + resp.Status)
				return nil
			}
			resp.Body = &turnWatch{ReadCloser: resp.Body, onFail: func() { refund("the turn ended on an error") }}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if refund != nil && r.Context().Err() == nil {
				refund("the relay did not reach the service")
			}
			mu.Lock()
			derr := dialErr
			if derr == nil {
				derr = holder.err
			}
			mu.Unlock()
			if derr == nil && r.Context().Err() == nil {
				// a kept relay's dial may have been another request's: ask the link
				if _, _, err := s.chatRelayNode(home.Machine, home.Login); err != nil {
					derr = err
				}
			}
			var re *sshRelayError
			switch {
			case derr != nil && errors.As(derr, &re) && re.code == "TOO_MANY":
				s.chatRefuse(w, person, name+" "+where, http.StatusTooManyRequests, "too_many", re.msg)
			case derr != nil:
				s.chatRefuse(w, person, name+" "+where, http.StatusServiceUnavailable, "home_down", "你的机器现在连不上")
			case r.Context().Err() != nil:
				// The page went away; nobody is reading an answer.
			default:
				s.chatAudit(person, "chat_relay", "BROKEN "+name+" "+where)
				refuseJSON(w, http.StatusBadGateway, "relay", "the conversation service did not answer")
			}
		},
	}
	rp.ServeHTTP(w, r)
}

// chatDialKey carries a request's chatDialHolder to the dial it waits on.
type chatDialKey struct{}

// chatDialHolder is where a dial records its error for the request that waited.
type chatDialHolder struct{ err error }

// chatRecheckEvery is how often a running chat request is held to its person.
var chatRecheckEvery = 5 * time.Second

// chatRecheck cancels a request still running once its person no longer
// signs in, their home moved or went into maintenance.
func (s *Server) chatRecheck(ctx context.Context, stop func(), r *http.Request, person, machine, login string) {
	t := time.NewTicker(chatRecheckEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		p, _, code, _ := s.chatPerson(r)
		h, ok, err := s.Store.EntryHomeOf(person)
		gone := code != "" || p != person || err != nil || !ok || h.Machine != machine || h.Login != login
		if !gone {
			if settings, err := s.Store.FleetSettings(); err == nil {
				_, gone = maintenanceOf(machine, settings)
			}
		}
		if gone {
			s.chatAudit(person, "chat_relay", "REVOKED "+machine+"/"+login)
			stop()
			return
		}
	}
}

// chatRelayPool holds the kept relay transports, one per person and home login.
type chatRelayPool struct {
	mu sync.Mutex
	m  map[string]*chatPooled
}

type chatPooled struct {
	tr   *http.Transport
	used time.Time
}

// transport is key's transport, made on first use; one unused for ten times
// its keep is closed and forgotten.
func (p *chatRelayPool) transport(key string, keep time.Duration, dial func(context.Context) (net.Conn, error)) *http.Transport {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	for k, e := range p.m {
		if k != key && now.Sub(e.used) > 10*keep {
			e.tr.CloseIdleConnections()
			delete(p.m, k)
		}
	}
	if p.m == nil {
		p.m = map[string]*chatPooled{}
	}
	e := p.m[key]
	if e == nil {
		e = &chatPooled{tr: &http.Transport{
			DialContext:         func(ctx context.Context, _, _ string) (net.Conn, error) { return dial(ctx) },
			MaxIdleConnsPerHost: 2,
			IdleConnTimeout:     keep,
			DisableCompression:  true,
		}}
		p.m[key] = e
	}
	e.used = now
	return e.tr
}
