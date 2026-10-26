package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"golang.org/x/net/publicsuffix"
)

const previewCookie = "__Host-fleet-preview"
const previewStateCookie = "__Host-fleet-preview-state"
const previewCallback = "/.fleet-preview/callback"
const previewAuthorize = "/preview/authorize"
const previewAPI = "/v1/fleet/previews"
const nodePreviewAPI = "/v1/node/previews"

var previewIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var previewTokenRE = regexp.MustCompile(`^[0-9a-f]{64}$`)
var previewDomainRE = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$`)

// ValidatePreviewConfig refuses a same-site deployment: hostile development
// code must never share a cookie site with the control plane. Empty is off.
func (s *Server) ValidatePreviewConfig() error {
	if s.PreviewDomain == "" {
		return nil
	}
	u, e := url.Parse(s.FleetPublicURL)
	if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || !previewDomainRE.MatchString(s.PreviewDomain) || len(s.PreviewDomain) > 190 {
		return errors.New("preview needs an explicit DNS base domain and HTTPS hub origin")
	}
	for _, label := range strings.Split(s.PreviewDomain, ".") {
		if len(label) > 63 {
			return errors.New("preview DNS label exceeds 63 bytes")
		}
	}
	a, e := publicsuffix.EffectiveTLDPlusOne(u.Hostname())
	if e != nil {
		return e
	}
	b, e := publicsuffix.EffectiveTLDPlusOne(s.PreviewDomain)
	if e != nil || a == b {
		return errors.New("preview base domain must use a different registrable domain from the hub")
	}
	// a per-host public address (CCQUOTA_PUBLIC_HOSTS, task PNWW) is the hub
	// too, on its own site — never the preview's
	for h := range s.PublicHosts {
		if site, err := publicsuffix.EffectiveTLDPlusOne(h); err != nil || site == b {
			return errors.New("preview base domain must use a different registrable domain from every public host")
		}
	}
	for _, alias := range s.PreviewHubAliases {
		site, err := publicsuffix.EffectiveTLDPlusOne(alias)
		if err != nil || site != a || !previewDomainRE.MatchString(alias) || len(alias) > 253 {
			return errors.New("preview Hub aliases must be exact DNS hosts on the Hub site")
		}
		for _, label := range strings.Split(alias, ".") {
			if len(label) > 63 {
				return errors.New("invalid Hub alias label")
			}
		}
	}
	return nil
}
func (s *Server) previewOn() bool             { return s.PreviewDomain != "" && s.ValidatePreviewConfig() == nil }
func (s *Server) previewURL(id string) string { return "https://" + id + "." + s.PreviewDomain }
func previewNoCache(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store, private")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
}

// previewClusterHost is whether host (an HTTP Host, port allowed) names the hub
// by an in-cluster Service name rather than a DNS host on the internet:
//
//	ccquota-hub                                  one label — the namespace's own search domain
//	ccquota-hub.new-deploy                       <service>.<namespace>: two labels, the last no ICANN TLD
//	ccquota-hub.new-deploy.svc[.cluster.local]   the Service's full names
//
// The cluster credential proxy dials the hub as http://ccquota-hub
// (CCQUOTA_CREDPROXY_HUB_URL) and other pods as …svc.cluster.local; with
// previews on, those got 421 and every pass resolve failed. Such a name is
// reachable only from inside the cluster: the preview ingress forwards only
// *.<preview domain> hosts and every public ingress rule names a real DNS host,
// so a browser — and a preview's hostile code — can never arrive with one.
// An IP literal and anything with a public TLD (evil.example.com) stay 421,
// and a host under the preview domain is never this (the caller checks).
func previewClusterHost(host string) bool {
	h := host
	if hh, _, err := net.SplitHostPort(host); err == nil {
		h = hh
	}
	h = strings.ToLower(h)
	if h == "" || net.ParseIP(strings.Trim(h, "[]")) != nil || strings.HasSuffix(h, ".") {
		return false
	}
	labels := strings.Split(h, ".")
	for _, l := range labels {
		if l == "" || len(l) > 63 || !previewLabelRE.MatchString(l) {
			return false
		}
	}
	switch {
	case len(labels) == 1:
		return true
	case strings.HasSuffix(h, ".svc") || strings.HasSuffix(h, ".svc.cluster.local"):
		return len(labels) == 3 || len(labels) == 5 // <service>.<namespace>.svc[.cluster.local]
	case len(labels) == 2:
		ps, icann := publicsuffix.PublicSuffix(h)
		return !icann && ps == labels[1]
	}
	return false
}

var previewLabelRE = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`)

// This sits OUTSIDE appMount, so preview hosts never serve the Hub SPA or APIs.
func (s *Server) previewHosts(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.previewOn() {
			next.ServeHTTP(w, r)
			return
		}
		u, _ := url.Parse(s.FleetPublicURL)
		previewHost := r.Host == s.PreviewDomain || strings.HasSuffix(strings.Split(r.Host, ":")[0], "."+s.PreviewDomain)
		hubHost := r.Host == u.Host || (!previewHost && previewClusterHost(r.Host)) || (!previewHost && s.PublicHosts[strings.ToLower(r.Host)] != "")
		for _, alias := range s.PreviewHubAliases {
			hubHost = hubHost || r.Host == alias
		}
		probe := (r.Method == "GET" || r.Method == "HEAD") && (r.URL.Path == "/healthz" || r.URL.Path == "/readyz")
		if hubHost || (!previewHost && ((s.Replica != nil && s.relayHopped(r)) || probe)) {
			next.ServeHTTP(w, r)
			return
		}
		previewNoCache(w)
		suffix := "." + s.PreviewDomain
		id := strings.TrimSuffix(r.Host, suffix)
		if !strings.HasSuffix(r.Host, suffix) || !previewIDRE.MatchString(id) || r.Host != id+suffix {
			http.Error(w, "unknown preview host", 421)
			return
		}
		s.servePreview(w, r, id)
	})
}
func (s *Server) previewSessionOK(hash string, p store.Preview, now time.Time) bool {
	a, e := s.Store.PreviewSession(hash, p.ID, now)
	if e != nil || a.Owner != p.Owner {
		return false
	}
	if !s.previewOwnerOK(a.Owner, p.Machine, now) {
		return false
	}
	cutoff, e := s.Store.SessionCutoff(a.Owner)
	if e != nil || (cutoff > 0 && a.Issued <= cutoff) {
		return false
	}
	revoked, e := s.Store.SessionRevoked(a.SID)
	return e == nil && !revoked
}
func previewSetCookie(w http.ResponseWriter, name, value string, max int) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: max})
}
func (s *Server) servePreview(w http.ResponseWriter, r *http.Request, id string) {
	now := time.Now()
	p, e := s.Store.Preview(id, now)
	if e != nil {
		http.NotFound(w, r)
		return
	}
	if r.URL.Path == previewCallback {
		if r.Method != "GET" {
			http.Error(w, "GET required", 405)
			return
		}
		state, e := r.Cookie(previewStateCookie)
		q := r.URL.Query()
		if e != nil || len(state.Value) != 64 || q.Get("state") != state.Value || len(q.Get("ticket")) != 64 {
			http.Error(w, "invalid preview state", 403)
			return
		}
		session := previewRandom()
		if e = s.Store.ExchangePreview(HashToken(state.Value), id, s.previewURL(id)+previewCallback, HashToken(q.Get("ticket")), HashToken(session), now); e != nil {
			http.Error(w, "invalid or spent preview ticket", 403)
			return
		}
		previewSetCookie(w, previewCookie, session, 7200)
		previewSetCookie(w, previewStateCookie, "", -1)
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	c, e := r.Cookie(previewCookie)
	if e != nil || !s.previewSessionOK(HashToken(c.Value), p, now) {
		if r.Method != "GET" || strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			http.Error(w, "sign in to this preview first", 401)
			return
		}
		state := previewRandom()
		if s.Store.BeginPreviewAuth(HashToken(state), id, s.previewURL(id)+previewCallback, now) != nil {
			http.Error(w, "preview authorization unavailable", 503)
			return
		}
		previewSetCookie(w, previewStateCookie, state, 120)
		http.Redirect(w, r, strings.TrimRight(s.FleetPublicURL, "/")+previewAuthorize+"?preview="+id+"&state="+state, http.StatusFound)
		return
	}
	if r.Method == "CONNECT" || r.Method == "TRACE" || r.URL.IsAbs() {
		http.Error(w, "unsupported preview request", 405)
		return
	}
	// Block cross-origin writes/WS, including requests initiated by a different
	// preview. A normal same-origin resource GET needs no Origin header.
	origin := r.Header.Get("Origin")
	if origin != "" && origin != s.previewURL(id) {
		http.Error(w, "preview origin refused", 403)
		return
	}
	if r.Header.Get("Sec-Fetch-Site") == "cross-site" && (r.Method != "GET" && r.Method != "HEAD" || r.Header.Get("Upgrade") != "") {
		http.Error(w, "cross-site preview request refused", 403)
		return
	}
	if peer, ok := s.previewPeer(r, p); ok {
		s.proxyPreviewPeer(w, r, peer)
		return
	}
	if _, _, e = s.previewNode(p); e != nil {
		http.Error(w, "preview offline", 503)
		return
	}
	limits := s.previewLimits(p)
	if r.ContentLength > limits.body {
		http.Error(w, "preview body exceeds limit", 413)
		return
	}
	idc := previewRandom()
	if e = s.Store.TakePreviewConnection(idc, p, limits.connections, now); e != nil {
		status := 503
		if errors.Is(e, store.ErrPreviewLimit) {
			status = 429
		}
		http.Error(w, "preview connection limit or authority unavailable", status)
		return
	}
	defer s.Store.DropPreviewConnection(idc)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	// A missed database heartbeat or revoked browser, login, node or preview
	// cancels even an upgraded/hijacked stream through the dialed net.Conn.
	watchdog := time.AfterFunc(5*time.Second, cancel)
	defer watchdog.Stop()
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-t.C:
				if _, e := s.Store.Preview(p.ID, now); e != nil {
					cancel()
					return
				}
				if !s.previewSessionOK(HashToken(c.Value), p, now) || s.Store.TouchPreviewConnection(idc, now) != nil {
					cancel()
					return
				}
				watchdog.Reset(5 * time.Second)
			}
		}
	}()
	r = r.WithContext(ctx)
	r.Body = http.MaxBytesReader(w, r.Body, limits.body)
	transport := &http.Transport{DisableKeepAlives: true, ResponseHeaderTimeout: 30 * time.Second, MaxResponseHeaderBytes: 64 << 10,
		DialContext: func(dctx context.Context, _, _ string) (net.Conn, error) { return s.dialPreview(ctx, dctx, p) }}
	defer transport.CloseIdleConnections()
	rp := &httputil.ReverseProxy{Transport: transport, FlushInterval: -1,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = "http"
			pr.Out.URL.Host = "preview.invalid"
			pr.Out.Host = r.Host
			cleanPreviewRequest(pr.Out)
		},
		ModifyResponse: func(resp *http.Response) error { cleanPreviewResponse(resp); return nil },
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "preview offline or stream closed", 502)
		}}
	rp.ServeHTTP(w, r)
}

func (s *Server) handlePreviewAuthorize(w http.ResponseWriter, r *http.Request) {
	previewNoCache(w)
	if !s.previewOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != "GET" {
		http.Error(w, "GET required", 405)
		return
	}
	id, state := r.URL.Query().Get("preview"), r.URL.Query().Get("state")
	if !previewIDRE.MatchString(id) || !previewTokenRE.MatchString(state) {
		http.Error(w, "invalid preview request", 400)
		return
	}
	sess, person, ok := s.personSession(r)
	if !ok || sess.Sid == "" {
		rememberAppReturn(w, r)
		http.Redirect(w, r, appURL("/signin"), 302)
		return
	}
	if sess.RO || !s.previewOwnerOK(person, "", time.Now()) || viewAsAsked(r) != "" {
		http.Error(w, "preview owner required", 403)
		return
	}
	p, e := s.Store.Preview(id, time.Now())
	if e != nil || p.Owner != person || !s.previewOwnerOK(person, p.Machine, time.Now()) {
		http.NotFound(w, r)
		return
	}
	callback := s.previewURL(id) + previewCallback
	// callback is never taken from the browser, even on the Hub origin.
	if v := r.URL.Query().Get("callback"); v != "" && v != callback {
		http.Error(w, "invalid callback", 400)
		return
	}
	ticket := previewRandom()
	expiry := time.Now().Add(2 * time.Hour).Unix()
	if sess.Exp < expiry {
		expiry = sess.Exp
	}
	if s.Store.TicketPreview(HashToken(state), id, callback, HashToken(ticket), store.PreviewSession{Owner: person, SID: sess.Sid, Issued: sess.Iat, Expires: expiry}, time.Now()) != nil {
		http.Error(w, "invalid or spent preview state", 403)
		return
	}
	http.Redirect(w, r, callback+"?state="+state+"&ticket="+ticket, 302)
}

// Platform names are reserved on both sides. Application cookies remain
// usable, but the proxy never allows an application to set a parent domain.
func previewPlatformCookie(name string) bool {
	n := strings.ToLower(name)
	return strings.HasPrefix(n, "__host-fleet-") || strings.HasPrefix(n, "ccq_") || strings.HasPrefix(n, "ccquota_")
}
func cleanPreviewRequest(r *http.Request) {
	cookies := r.Cookies()
	r.Header.Del("Cookie")
	for _, c := range cookies {
		if !previewPlatformCookie(c.Name) {
			r.AddCookie(c)
		}
	}
	for k := range r.Header {
		l := strings.ToLower(k)
		if l == "authorization" || l == "proxy-authorization" || l == "forwarded" || strings.HasPrefix(l, "x-forwarded-") || strings.HasPrefix(l, "x-fleet-") || strings.HasPrefix(l, "x-ccquota-") || l == strings.ToLower(replicaTokenHeader) || l == "x-relay-secret" {
			r.Header.Del(k)
		}
	}
}
func cleanPreviewResponse(r *http.Response) {
	cookies := r.Cookies()
	r.Header.Del("Set-Cookie")
	for _, c := range cookies {
		if c.Domain != "" || previewPlatformCookie(c.Name) || len(c.Unparsed) > 0 {
			continue
		}
		c.Secure = true
		r.Header.Add("Set-Cookie", c.String())
	}
	for k := range r.Header {
		l := strings.ToLower(k)
		if l == "clear-site-data" || l == "www-authenticate" || l == "proxy-authenticate" || l == "service-worker-allowed" || l == "alt-svc" {
			r.Header.Del(k)
		}
	}
	r.Header.Set("Cache-Control", "no-store, private")
	r.Header.Set("Referrer-Policy", "no-referrer")
	// Service workers can replay cached responses without hitting authorization.
	// Development previews deliberately disallow them and embedding by other sites.
	r.Header.Set("Content-Security-Policy", "worker-src 'none'; frame-ancestors 'none'")
	r.Header.Del("ETag")
	r.Header.Del("Last-Modified")
}

// A single exact authorization path is allowed through loginReturn. Nothing
// here accepts a destination URL or arbitrary path/query parameter.
func previewReturnOK(v string) bool {
	u, e := url.ParseRequestURI(v)
	if e != nil || u.Path != previewAuthorize || u.RawPath != "" || u.Host != "" || u.Fragment != "" {
		return false
	}
	q, e := url.ParseQuery(u.RawQuery)
	if e != nil || len(q) != 2 || len(q["preview"]) != 1 || len(q["state"]) != 1 {
		return false
	}
	return previewIDRE.MatchString(q.Get("preview")) && previewTokenRE.MatchString(q.Get("state"))
}

func (s *Server) previewNode(p store.Preview) (string, *nodeConn, error) {
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	nc := s.nodes.conns[p.Endpoint]
	if nc == nil || !nc.canPreview || nc.user() != p.Login || nc.hostname() != p.Machine || nc.tokHash != p.TokenHash || nc.attachmentGeneration == "" {
		return "", nil, errors.New("preview offline")
	}
	return p.Endpoint, nc, nil
}
func (s *Server) previewPeer(r *http.Request, p store.Preview) (store.NodeConn, bool) {
	if s.Replica == nil || s.relayHopped(r) {
		return store.NodeConn{}, false
	}
	if _, _, e := s.previewNode(p); e == nil {
		return store.NodeConn{}, false
	}
	pc, ok := s.peerConns()[p.Endpoint]
	return pc, ok && pc.HasCap(control.CapPreview)
}
func (s *Server) proxyPreviewPeer(w http.ResponseWriter, r *http.Request, peer store.NodeConn) {
	target, e := url.Parse(peer.URL)
	if e != nil {
		http.Error(w, "preview offline", 503)
		return
	}
	// Preserve the exact public Host; the receiving replica repeats every check.
	rp := &httputil.ReverseProxy{FlushInterval: -1, Transport: replicaHopTransport, Rewrite: func(pr *httputil.ProxyRequest) {
		pr.SetURL(target)
		pr.Out.Host = r.Host
		pr.Out.Header.Set(replicaTokenHeader, s.Replica.Token)
	}}
	if s.Replica.Client != nil && s.Replica.Client.Transport != nil {
		rp.Transport = s.Replica.Client.Transport
	}
	rp.ServeHTTP(w, r)
}
func (s *Server) dialPreview(ctx, dctx context.Context, p store.Preview) (net.Conn, error) {
	ep, nc, e := s.previewNode(p)
	if e != nil {
		return nil, e
	}
	// Check again after routing: a reconnect never grants a different endpoint.
	if _, e = s.Store.Preview(p.ID, time.Now()); e != nil {
		return nil, e
	}
	or, e := s.openLoginRelay(dctx, loginRelaySpec{kind: "preview", table: &s.previewRelays, epID: ep, node: nc, key: p.Owner, max: 32, person: p.Owner,
		open: func(id, secret string) (control.Message, error) {
			return control.New(control.TypePreviewOpen, control.ChatRelayOpen{RelayID: id, Secret: secret, Login: p.Login})
		},
		hello: func(id, key string, now time.Time) []byte {
			b, _ := json.Marshal(control.PreviewHello{Grant: control.SignPreview(control.PreviewGrant{V: 1, Person: p.Owner, Login: p.Login, Node: p.Endpoint, Generation: nc.attachmentGeneration, Relay: id, Preview: p.ID, Socket: p.Socket, Iat: now.Unix(), Exp: now.Add(30 * time.Second).Unix()}, key)})
			return b
		}})
	if e != nil {
		return nil, e
	}
	conn := websocket.NetConn(or.ctx, or.ws, websocket.MessageBinary)
	wrapped := &previewConn{Conn: conn, end: or.end}
	go func() {
		select {
		case <-ctx.Done():
			wrapped.Close()
		case <-or.ctx.Done():
			wrapped.Close()
		}
	}()
	return wrapped, nil
}

type previewConn struct {
	net.Conn
	end func(string)
}

func (c *previewConn) Close() error { c.end("closed"); return c.Conn.Close() }

// Node calls require the verified worker assertion AND enrollment authority.
// The request body has no principal, UID, machine, login or upstream address.
func (s *Server) handleNodePreview(w http.ResponseWriter, r *http.Request) {
	previewNoCache(w)
	if !s.previewOn() {
		http.Error(w, "private previews are not configured", 503)
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	a, e := s.Store.PreviewAuthority(ep.ID)
	if e != nil {
		http.Error(w, "managed login enrollment required; an administrator must verify and preview-bind this endpoint to its active account", 403)
		return
	}
	if !s.previewOwnerOK(a.Owner, a.Machine, time.Now()) {
		http.Error(w, "preview owner is not active or eligible on this machine", 403)
		return
	}
	claims, e := verifyWorkerAssertion(r.Header.Get("X-Fleet-Worker"), a.TokenHash, time.Now())
	if e != nil || claims == nil {
		http.Error(w, "verified worker required", 401)
		return
	}
	fl, e := s.Store.Fleet(claims.FleetUUID)
	if e != nil || fl.EndpointID != ep.ID {
		http.Error(w, "wrong worker node", 403)
		return
	}
	task, e := s.Store.ResolveFleetTask(a.Owner, r.URL.Query().Get("task"))
	worker := claims.WorkerID
	if task.ExecutionOwner == "" && claims.speaksAs(task.WorkerID) {
		worker = task.WorkerID // the signed key alias of a legacy Task
	}
	p := store.Preview{Owner: a.Owner, Endpoint: ep.ID, Machine: a.Machine, Login: a.Login, Generation: a.Generation, TokenHash: a.TokenHash, TaskID: task.ID, Worker: worker}
	if e == nil {
		p.TaskBinding, e = s.Store.PreviewTaskBinding(p)
	}
	if e != nil {
		http.Error(w, "task is not this worker's", 403)
		return
	}
	if r.Method == "GET" {
		s.previewList(w, task)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "GET or POST required", 405)
		return
	}
	var in struct {
		Action string `json:"action"`
		Socket string `json:"socket"`
		ID     string `json:"id"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in) != nil {
		http.Error(w, "invalid request", 400)
		return
	}
	if in.Action == "register" {
		if !control.PreviewSocketName(in.Socket) {
			http.Error(w, "use a socket basename in ~/.fleet-preview; TCP/URLs are unsupported", 400)
			return
		}
		p.ID, p.Socket = previewRandom()[:32], in.Socket
		limits := s.previewLimits(p)
		p.Expires = time.Now().Add(limits.lease).Unix()
		if e = s.Store.CreatePreview(p, limits.previews, time.Now()); e != nil {
			status := 403
			if errors.Is(e, store.ErrPreviewLimit) {
				status = 429
			}
			http.Error(w, e.Error(), status)
			return
		}
		p.URL = s.previewURL(p.ID)
		writeJSON(w, 201, p)
		return
	}
	p, e = s.Store.Preview(in.ID, time.Now())
	if e != nil || p.TaskID != task.ID || p.Endpoint != ep.ID {
		http.NotFound(w, r)
		return
	}
	s.previewAction(w, r, p, in.Action)
}
func (s *Server) previewList(w http.ResponseWriter, t store.FleetTask) {
	if !s.previewOn() {
		writeJSON(w, 200, map[string]any{"previews": []store.Preview{}, "enabled": false})
		return
	}
	ps, e := s.Store.ListPreviews(t.Owner, t.ID)
	if e != nil {
		http.Error(w, "previews unavailable", 503)
		return
	}
	out := []store.Preview{}
	for _, p := range ps {
		if _, e := s.Store.Preview(p.ID, time.Now()); e != nil {
			continue
		}
		p.URL = s.previewURL(p.ID)
		_, _, e := s.previewNode(p)
		p.Online = e == nil
		if !p.Online && s.Replica != nil {
			pc, ok := s.peerConns()[p.Endpoint]
			p.Online = ok && pc.HasCap(control.CapPreview)
		}
		out = append(out, p)
	}
	writeJSON(w, 200, map[string]any{"previews": out, "enabled": s.previewOn()})
}
func (s *Server) handlePreviewAPI(w http.ResponseWriter, r *http.Request) {
	previewNoCache(w)
	sess, owner, ok := s.personSession(r)
	if !ok || sess.RO || viewAsAsked(r) != "" {
		http.Error(w, "sign in as the owner", 401)
		return
	}
	if !s.previewOwnerOK(owner, "", time.Now()) {
		http.Error(w, "owner required", 403)
		return
	}
	t, e := s.Store.ResolveFleetTask(owner, r.URL.Query().Get("task"))
	if e != nil {
		http.NotFound(w, r)
		return
	}
	if r.Method == "GET" {
		s.previewList(w, t)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "GET or POST required", 405)
		return
	}
	if !s.previewOn() {
		http.Error(w, "private previews are not configured", 503)
		return
	}
	if r.Header.Get("Origin") != strings.TrimRight(s.FleetPublicURL, "/") {
		http.Error(w, "same-origin request required", 403)
		return
	}
	var in struct {
		ID     string `json:"id"`
		Action string `json:"action"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&in) != nil {
		http.Error(w, "invalid request", 400)
		return
	}
	p, e := s.Store.Preview(in.ID, time.Now())
	if e != nil || p.Owner != owner || p.TaskID != t.ID {
		http.NotFound(w, r)
		return
	}
	s.previewAction(w, r, p, in.Action)
}
func (s *Server) previewAction(w http.ResponseWriter, r *http.Request, p store.Preview, action string) {
	var e error
	switch action {
	case "close":
		e = s.Store.ClosePreview(p.ID, p.Owner)
	case "renew":
		e = s.Store.RenewPreview(p.ID, p.Owner, time.Now(), s.previewLimits(p).lease)
	default:
		http.Error(w, "close or renew required", 400)
		return
	}
	if e != nil {
		http.Error(w, "preview unavailable", 409)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// Auth tokens are random 256-bit values; preview IDs use their first 128 bits.
// Storage keeps only authentication hashes.
func previewRandom() string {
	a, e := MintToken()
	if e != nil {
		panic(fmt.Errorf("preview entropy: %w", e))
	}
	return HashToken(a)
}

// This feature's own gate does not widen trialRoute. A short chat trial must
// still possess a real owned Task on its active managed login to register.
func (s *Server) previewOwnerOK(owner, machine string, now time.Time) bool {
	role, e := s.personRole(owner)
	if e != nil {
		return false
	}
	if role == roleTrial {
		t, e := s.Store.Trial(owner)
		if e != nil || t == nil || t.State != store.TrialPlaced || (machine != "" && t.Host != machine) {
			return false
		}
		secs, msgs := s.trialLeft(t, now)
		return secs > 0 && msgs > 0
	}
	if role != roleUser && role != roleAdmin {
		return false
	}
	settings, e := s.Store.FleetSettings()
	if e != nil {
		return false
	}
	if l, ok := memberLimitsOf(settings, owner); ok && !l.Until.IsZero() && !now.Before(l.Until) {
		return false
	}
	return true
}
