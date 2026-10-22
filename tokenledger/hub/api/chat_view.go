package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
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
	// where the page is in the record (task YP39): ?at=<byte>&s=<conversation> a
	// page back from a drop, ?before=<byte> one page further back (JSON) — each a
	// byte offset, s a conversation id; ?from=<count> is an older page's, passed on
	fwd := url.Values{}
	for _, k := range []string{"at", "before", "from"} {
		if v := r.URL.Query().Get(k); v != "" {
			if n, err := strconv.ParseInt(v, 10, 64); err != nil || n < 0 {
				s.chatRefuse(w, person, chatViewRoute, http.StatusBadRequest, "bad_from", k+" is a byte offset")
				return
			}
			fwd.Set(k, v)
		}
	}
	// ?tool=<id>: one step's whole output, when the page opens it (JSON)
	if v := r.URL.Query().Get("tool"); v != "" {
		if !chatViewTool.MatchString(v) {
			s.chatRefuse(w, person, chatViewRoute, http.StatusBadRequest, "bad_target", "tool is a step id")
			return
		}
		fwd.Set("tool", v)
	}
	if v := r.URL.Query().Get("s"); v != "" {
		if !chatViewSID.MatchString(v) {
			s.chatRefuse(w, person, chatViewRoute, http.StatusBadRequest, "bad_from", "s is a conversation id")
			return
		}
		fwd.Set("s", v)
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
	historical := false
	// History has an owner-scoped identity even after WorkersJSON forgets it.
	// Only a full FID is accepted; recycled keys never resolve closed history.
	ref := strings.TrimPrefix(q.Get("worker"), "fid:")
	if i := strings.LastIndexByte(ref, '/'); i >= 0 {
		ref = ref[i+1:]
	}
	if code != "" && store.IsFleetID(ref) {
		if rec, err := s.Store.FleetIDOf(person, ref); err == nil && rec.ClosedAt > 0 {
			wid, target = "fid:"+ref, control.TermWorkerTarget(ref)
			dest = store.EntryHome{Person: person, Machine: rec.Machine, Login: rec.Login}
			status, code, msg, historical = 0, "", "", true
			fwd.Set("history", "1")
			if r.URL.Query().Get("status") == "1" {
				fwd.Set("status", "1")
			}
		}
	}
	if code != "" {
		s.chatRefuse(w, person, chatViewRoute, status, code, msg)
		return
	}
	fid := target[len(control.TermWorkerTarget("")):]
	// the copy beside the entry (task YP39): what the page drew last time, from
	// here, before the session's machine is reached at all
	if r.URL.Query().Get("cached") == "1" {
		s.handleChatViewCached(w, r, person, wid)
		return
	}
	// Native reads still require that the destination login belongs to this
	// person today. Cached reads above remain available when a machine is offline.
	if historical {
		own, err := s.ownScope(person)
		if err != nil || !own(dest.Machine, dest.Login) {
			s.chatRefuse(w, person, chatViewRoute, http.StatusServiceUnavailable, "offline_unknown", "历史所在登录目前不可访问")
			return
		}
	}
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
			q := url.Values{"fid": {fid}}
			for k, v := range fwd {
				q[k] = v
			}
			out.URL.RawQuery = q.Encode()
			out.Header = http.Header{}
			out.Header.Set("Accept", "text/event-stream")
			out.Header.Set(control.ChatPersonHeader, person)
		},
		Transport:     one,
		FlushInterval: -1,
		ModifyResponse: func(resp *http.Response) error {
			// the first frame of a fresh read — the newest stretch, in place — is
			// kept as the copy (the record stays the session's machine's)
			if resp.StatusCode == http.StatusOK && fwd.Get("before") == "" && fwd.Get("tool") == "" && viewAsAsked(r) == "" && !s.consoleTicketCookie(r) && s.chatMirrorOn(person) {
				taken := time.Now()
				resp.Body = &chatViewTee{ReadCloser: resp.Body, done: func(b []byte) {
					s.chatViewKeep(person, "fid:"+fid, b, taken)
					if !historical {
						s.chatViewKeep(person, wid, b, taken)
					}
				}}
			}
			return nil
		},
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
	gz := &chatViewGzip{ResponseWriter: w}
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		rp.ModifyResponse = chainModify(rp.ModifyResponse, func(resp *http.Response) error {
			if resp.StatusCode == http.StatusOK && resp.Header.Get("Content-Encoding") == "" {
				resp.Header.Del("Content-Length")
				resp.Header.Set("Content-Encoding", "gzip")
				resp.Header.Add("Vary", "Accept-Encoding")
				gz.on = true
			}
			return nil
		})
	}
	rp.ServeHTTP(gz, r)
	gz.close()
}

// chatViewGzip compresses a view's answer on its way to the page (task YP39:
// the entry is far from the person; a first frame is mostly repeated words),
// flushed event by event so the stream stays live. Off until the answer is
// one to compress, so a refusal goes out as written.
type chatViewGzip struct {
	http.ResponseWriter
	on bool
	zw *gzip.Writer
}

func (g *chatViewGzip) Write(b []byte) (int, error) {
	if !g.on {
		return g.ResponseWriter.Write(b)
	}
	if g.zw == nil {
		g.zw = gzip.NewWriter(g.ResponseWriter)
	}
	return g.zw.Write(b)
}

func (g *chatViewGzip) Flush() {
	if g.zw != nil {
		_ = g.zw.Flush()
	}
	if f, ok := g.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (g *chatViewGzip) close() {
	if g.zw != nil {
		_ = g.zw.Close()
	}
}

// chainModify runs a, then b, on a proxied answer.
func chainModify(a, b func(*http.Response) error) func(*http.Response) error {
	if a == nil {
		return b
	}
	return func(resp *http.Response) error {
		if err := a(resp); err != nil {
			return err
		}
		return b(resp)
	}
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

// chatViewSID is a conversation id as the session's machine names one;
// chatViewTool a step's id.
var (
	chatViewSID  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,80}$`)
	chatViewTool = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,120}$`)
)

// chatViewFirstMax bounds the first frame the entry reads to copy.
const chatViewFirstMax = 2 << 20

// chatViewTee passes a view's stream through to the page and hands its first
// fresh frame ({"t":"items","replace":true,…}) to done, once.
type chatViewTee struct {
	io.ReadCloser
	buf  bytes.Buffer
	done func([]byte)
}

func (t *chatViewTee) Read(p []byte) (int, error) {
	n, err := t.ReadCloser.Read(p)
	if n > 0 && t.done != nil {
		t.buf.Write(p[:n])
		for t.done != nil {
			i := bytes.Index(t.buf.Bytes(), []byte("\n\n"))
			if i < 0 {
				if t.buf.Len() > chatViewFirstMax {
					t.done, t.buf = nil, bytes.Buffer{}
				}
				break
			}
			ev := t.buf.Next(i + 2)
			for _, line := range bytes.Split(ev, []byte("\n")) {
				data, ok := bytes.CutPrefix(line, []byte("data: "))
				if !ok || !bytes.HasPrefix(data, []byte(`{"t":"items"`)) {
					continue
				}
				var f struct {
					Replace bool `json:"replace"`
				}
				d := t.done
				t.done, t.buf = nil, bytes.Buffer{}
				// a page come back gets what was added only: nothing to copy
				if json.Unmarshal(data, &f) == nil && f.Replace {
					d(append([]byte(nil), data...))
				}
				break
			}
			if t.done == nil {
				break
			}
		}
	}
	return n, err
}

// chatViewKeep copies a terminal session's first frame for person, the
// conversation copy's rules item for item (chatMirrorItem: words, replies, one
// line a step — never a step's output), sealed to them under its worker id.
func (s *Server) chatViewKeep(person, wid string, frame []byte, now time.Time) {
	var in struct {
		Session string            `json:"session"`
		Items   []json.RawMessage `json:"items"`
	}
	if json.Unmarshal(frame, &in) != nil {
		return
	}
	doc := chatMirrorDoc{Session: in.Session, Items: []json.RawMessage{}}
	left := chatMirrorThumbMax
	for i := len(in.Items) - 1; i >= 0; i-- {
		if it, ok := chatMirrorItem(in.Items[i], &left); ok {
			doc.Items = append(doc.Items, it)
		}
	}
	slices.Reverse(doc.Items)
	sealed, err := s.Vault.SealPerson(doc, person, chatMirrorPurpose)
	if err != nil {
		log.Printf("fleet: chat view copy of %s: seal: %v", person, err)
		return
	}
	if err := s.Store.PutChatMirrorOf(person, store.ChatMirrorViewPrefix+wid, sealed, now.Add(chatMirrorKeep), now); err != nil {
		log.Printf("fleet: chat view copy of %s: keep: %v", person, err)
	}
}

// handleChatViewCached answers GET /v1/chat/view?worker=<id>&cached=1: the
// person's copy of that session, as JSON — or no items and "mirror": null.
func (s *Server) handleChatViewCached(w http.ResponseWriter, r *http.Request, person, wid string) {
	w.Header().Set("Cache-Control", "no-store")
	if viewAsAsked(r) != "" {
		s.chatRefuse(w, person, chatViewRoute+" cached", http.StatusForbidden, "not_yours", "only your own conversation")
		return
	}
	if !s.chatMirrorOn(person) {
		chatNoCopy(w)
		return
	}
	c, err := s.Store.ChatMirrorOf(person, store.ChatMirrorViewPrefix+wid, time.Now())
	if strings.HasPrefix(wid, "fid:") {
		c, err = s.Store.ChatHistoryMirrorOf(person, strings.TrimPrefix(wid, "fid:"), time.Now())
	}
	if err != nil || c == nil {
		chatNoCopy(w)
		return
	}
	var doc chatMirrorDoc
	if err := s.Vault.OpenPerson(c.Sealed, &doc, person, chatMirrorPurpose); err != nil {
		chatNoCopy(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session": doc.Session, "items": doc.Items,
		"mirror": map[string]any{"at": c.UpdatedAt.UTC().Format(time.RFC3339)},
	})
}
