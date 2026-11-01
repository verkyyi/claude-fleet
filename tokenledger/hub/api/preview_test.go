package api

import (
	"encoding/base64"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func setupPreview(t *testing.T, s *Server) store.Preview {
	t.Helper()
	now := time.Now()
	s.Fleet = true
	s.PreviewDomain = "preview.example.net"
	s.FleetPublicURL = "https://hub.example.com"
	if e := s.Store.EnsureNodes(); e != nil {
		t.Fatal(e)
	}
	p, e := s.Store.EnsurePrincipalAs(pAlice, "alice", "alice", 32, func(string) bool { return true }, now)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.Store.AdoptAccount(p, "node", now); e != nil {
		t.Fatal(e)
	}
	if e = s.Store.CreateJoinCodeFor("preview-join", "node-alice", store.NodeKindFixed, "", store.NodeRoleManaged, "node", now, time.Hour); e != nil {
		t.Fatal(e)
	}
	if e = s.Store.RedeemJoinCode("preview-join", now, "preview-node", "node-alice", "nodehash", "node", "alice"); e != nil {
		t.Fatal(e)
	}
	task, e := s.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "Preview", Machine: "node", Login: "alice", WorkerID: "worker"}, "preview-task", now)
	if e != nil {
		t.Fatal(e)
	}
	a, e := s.Store.PreviewAuthority("preview-node")
	if e != nil {
		t.Fatal(e)
	}
	out := store.Preview{ID: previewRandom()[:32], Owner: pAlice, Endpoint: "preview-node", Machine: "node", Login: "alice", Generation: a.Generation, TokenHash: a.TokenHash, TaskID: task.ID, Worker: "worker", Socket: "app.sock", Expires: now.Add(time.Hour).Unix()}
	if e = s.Store.CreatePreview(out, 3, now); e != nil {
		t.Fatal(e)
	}
	return out
}
func previewRequest(s *Server, method, addr string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, addr, nil)
	r.URL.Scheme = ""
	r.URL.Host = ""
	for _, c := range cookies {
		if c != nil {
			r.AddCookie(c)
		}
	}
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	return w
}
func TestPreviewHostsCookiesAndReturn(t *testing.T) {
	s := &Server{PreviewDomain: "preview.example.net", FleetPublicURL: "https://hub.example.com"}
	if e := s.ValidatePreviewConfig(); e != nil {
		t.Fatal(e)
	}
	for _, d := range []string{"hub.example.com", "preview.example.com", "bad:443", "UPPER.test", "foo..net", strings.Repeat("a", 64) + ".net"} {
		s.PreviewDomain = d
		if e := s.ValidatePreviewConfig(); e == nil {
			t.Errorf("accepted domain %s", d)
		}
	}
	s.PreviewDomain = "preview.example.net"
	for _, host := range []string{strings.Repeat("a", 64) + ".preview.example.net", strings.Repeat("a", 32) + ".preview.example.net:443", "evil.example.net", "preview.example.net", strings.Repeat("a", 32) + ".preview.example.net."} {
		r := httptest.NewRequest("GET", "https://"+host+"/", nil)
		w := httptest.NewRecorder()
		s.previewHosts(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Fatal("host reached Hub") })).ServeHTTP(w, r)
		if w.Code != 421 {
			t.Fatal(w.Code)
		}
	}
	good := previewAuthorize + "?preview=" + strings.Repeat("a", 32) + "&state=" + strings.Repeat("b", 64)
	if !appReturnOK(good) {
		t.Fatal("preview return refused")
	}
	for _, v := range []string{good + "&callback=https://evil.test", good + "&state=x", "https://evil.test" + good, strings.Replace(good, "authorize", "other", 1), strings.Replace(good, "preview=", "preview=abc", 1)} {
		if appReturnOK(v) {
			t.Errorf("unsafe return %s", v)
		}
	}
	r := httptest.NewRequest("POST", "https://app.preview.example.net/api", nil)
	r.Header.Set("Cookie", "app_session=hello; __Host-fleet-preview=secret; __Host-fleet-preview-state=nonce; ccq_sess=hub; ccquota_token=platform")
	r.Header.Set("X-My-App", "kept")
	r.Header.Set("X-Fleet-Person", "secret")
	r.Header.Set(replicaTokenHeader, "replica")
	r.Header.Set("Authorization", "secret")
	cleanPreviewRequest(r)
	if r.Header.Get("Cookie") != "app_session=hello" || r.Header.Get("X-My-App") != "kept" || r.Header.Get("Authorization") != "" || r.Header.Get(replicaTokenHeader) != "" || r.Header.Get("X-Fleet-Person") != "" {
		t.Fatalf("headers %v", r.Header)
	}
	response := &http.Response{Header: http.Header{"Set-Cookie": []string{"app=ok; Path=/; HttpOnly", "__Host-fleet-preview=evil; Path=/; Secure", "__Host-fleet-preview-state=evil; Path=/; Secure", "ccq_sess=evil", "parent=evil; Domain=preview.example.net", "parent2=evil; Domain=.example.net"}}}
	cleanPreviewResponse(response)
	if cs := response.Cookies(); len(cs) != 1 || cs[0].Name != "app" || cs[0].Domain != "" || !cs[0].Secure {
		t.Fatalf("cookies %v", cs)
	}
	if response.Header.Get("Cache-Control") != "no-store, private" {
		t.Fatal("cacheable")
	}
}
func TestPreviewAuthFlow(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	p := setupPreview(t, h.srv)
	base := h.srv.previewURL(p.ID)
	first := previewRequest(h.srv, "GET", base+"/static.js")
	if first.Code != 302 {
		t.Fatal(first.Code, first.Body.String())
	}
	state := cookieNamed(first.Result(), previewStateCookie)
	auth := first.Header().Get("Location")
	signedOut := previewRequest(h.srv, "GET", auth)
	if signedOut.Code != 302 || cookieNamed(signedOut.Result(), entryReturnCookie) == nil {
		t.Fatal("lost signed-out return", signedOut.Body.String())
	}
	if bad := previewRequest(h.srv, "GET", auth, personCookie(pBob, "bob")); bad.Code != 404 {
		t.Fatal("other owner", bad.Code)
	}
	owner := personCookie(pAlice, "alice")
	bad := previewRequest(h.srv, "GET", auth+"&callback=https://evil.test", owner)
	if bad.Code != 400 {
		t.Fatal("callback", bad.Code)
	}
	issued := previewRequest(h.srv, "GET", auth, owner)
	if issued.Code != 302 {
		t.Fatal(issued.Code, issued.Body.String())
	}
	cb := issued.Header().Get("Location")
	if bad = previewRequest(h.srv, "GET", cb); bad.Code != 403 {
		t.Fatal("no CSRF state", bad.Code)
	}
	done := previewRequest(h.srv, "GET", cb, state)
	if done.Code != 303 {
		t.Fatal(done.Code, done.Body.String())
	}
	c := cookieNamed(done.Result(), previewCookie)
	if c == nil || !c.Secure || !c.HttpOnly || c.Domain != "" {
		t.Fatal(c)
	}
	if bad = previewRequest(h.srv, "GET", cb, state); bad.Code != 403 {
		t.Fatal("ticket replay", bad.Code)
	}
	offline := previewRequest(h.srv, "GET", base+"/api", c)
	if offline.Code != 503 {
		t.Fatal("offline", offline.Code, offline.Body.String())
	}
	req := httptest.NewRequest("GET", base+"/ws", nil)
	req.Header.Set("Upgrade", "websocket")
	w := httptest.NewRecorder()
	h.srv.Handler().ServeHTTP(w, req)
	if w.Code != 401 {
		t.Fatal("unauth ws", w.Code)
	}
	h.srv.Store.ClosePreview(p.ID, p.Owner)
	if bad = previewRequest(h.srv, "GET", base+"/api", c); bad.Code != 404 {
		t.Fatal("revoked", bad.Code)
	}
}

// The real OAuth start/callback and loginReturn, with only GitHub mocked.
func TestPreviewSignedOutOAuthReturn(t *testing.T) {
	h := newGitHubHarness(t)
	p := setupPreview(t, h.srv)
	if e := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: 1001, Login: "alice", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); e != nil {
		t.Fatal(e)
	}
	first := previewRequest(h.srv, "GET", h.srv.previewURL(p.ID)+"/")
	auth := first.Header().Get("Location")
	state := cookieNamed(first.Result(), previewStateCookie)
	out := previewRequest(h.srv, "GET", auth)
	ret := cookieNamed(out.Result(), entryReturnCookie)
	if ret == nil {
		t.Fatal("no return")
	}
	// A slow QR/OAuth consent must still return to the pending preview.
	if _, e := h.srv.Store.DB().Exec(`UPDATE fleet_preview_auth SET expires=expires-181`); e != nil {
		t.Fatal(e)
	}
	// Issue the consent code for the actual PKCE start.
	start := previewRequest(h.srv, "GET", h.srv.FleetPublicURL+"/auth/github/start")
	loc, _ := url.Parse(start.Header().Get("Location"))
	q := loc.Query()
	h.gh.mu.Lock()
	h.gh.codes["preview-consent"] = fakeGrant{user: fakeGHUser{ID: 1001, Login: "alice"}, challenge: q.Get("code_challenge")}
	h.gh.mu.Unlock()
	callback := previewRequest(h.srv, "GET", h.srv.FleetPublicURL+"/auth/github/callback?code=preview-consent&state="+url.QueryEscape(q.Get("state")), cookieNamed(start.Result(), githubFlowCookie), ret)
	if callback.Code != 302 || callback.Header().Get("Location") != ret.Value {
		t.Fatal("login lost preview", callback.Code, callback.Header(), callback.Body.String())
	}
	issued := previewRequest(h.srv, "GET", h.srv.FleetPublicURL+callback.Header().Get("Location"), cookieNamed(callback.Result(), "ccq_sess"))
	if issued.Code != 302 {
		t.Fatal(issued.Code, issued.Body.String())
	}
	done := previewRequest(h.srv, "GET", issued.Header().Get("Location"), state)
	if done.Code != 303 {
		t.Fatal(done.Code, done.Body.String())
	}
}

func TestPreviewTrialAndDisabled(t *testing.T) {
	h := newFleetHarness(t)
	p := setupPreview(t, h.srv)
	now := time.Now()
	if e := h.srv.Store.StartTrial(p.Owner, now); e != nil {
		t.Fatal(e)
	}
	h.srv.Store.PlaceTrial(p.Owner, p.Machine, now)
	if !h.srv.previewOwnerOK(p.Owner, p.Machine, now) {
		t.Fatal("active trial refused")
	}
	if h.srv.previewOwnerOK(p.Owner, "other", now) || h.srv.previewOwnerOK(p.Owner, p.Machine, now.Add(25*time.Hour)) {
		t.Fatal("trial mismatch/expiry accepted")
	}
	h.srv.Store.ReleaseTrial(p.Owner, "test", now)
	if h.srv.previewOwnerOK(p.Owner, p.Machine, now) {
		t.Fatal("released trial accepted")
	}
	h.srv.PreviewDomain = ""
	w := previewRequest(h.srv, "POST", "https://hub.example.com/v1/node/previews")
	b, _ := io.ReadAll(w.Result().Body)
	if w.Code != 503 || !strings.Contains(string(b), "not configured") {
		t.Fatal(w.Code, string(b))
	}
	if trialRoute(previewAPI) || trialRoute(previewAuthorize) {
		t.Fatal("general trial routes widened")
	}
}

func TestPreviewEnabledProbesReplicasAndAliases(t *testing.T) {
	s := &Server{PreviewDomain: "preview.example.net", FleetPublicURL: "https://hub.example.com", PreviewHubAliases: []string{"ccquota.example.com"}, Replica: &Replica{Token: "test-only-hop"}}
	if e := s.ValidatePreviewConfig(); e != nil {
		t.Fatal(e)
	}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	for _, tc := range []struct {
		host, path, method, token string
		want                      int
	}{
		{"192.0.2.3:8787", "/healthz", "GET", "", 204},
		{"192.0.2.3:8787", "/readyz", "HEAD", "", 204},
		{"192.0.2.3:8787", "/healthz", "POST", "", 421},
		{"192.0.2.9:8787", NodeRoutePath, "POST", "test-only-hop", 204},
		{"192.0.2.9:8787", NodeRoutePath, "POST", "wrong", 421},
		{"192.0.2.9:8787", "/app/", "GET", "", 421},
		{"peer.example.org:8787", "/app/", "GET", "", 421},
		{"ccquota-hub", "/app/", "GET", "", 204}, // an in-cluster Service name (previewClusterHost)
		{"ccquota.example.com", "/v1/node/self", "GET", "", 204},
		{"unlisted.example.com", "/app/", "GET", "", 421},
		{"invalid.preview.example.net", "/healthz", "GET", "test-only-hop", 421},
		{"invalid.preview.example.net", "/app/", "GET", "test-only-hop", 421},
	} {
		r := httptest.NewRequest(tc.method, "http://"+tc.host+tc.path, nil)
		r.Header.Set(replicaTokenHeader, tc.token)
		w := httptest.NewRecorder()
		s.previewHosts(next).ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Errorf("%s %s %s: %d want %d", tc.method, tc.host, tc.path, w.Code, tc.want)
		}
	}
	s.PreviewHubAliases = []string{"app.preview.example.net"}
	if s.ValidatePreviewConfig() == nil {
		t.Fatal("preview-site Hub alias accepted")
	}
}

func TestPreviewRegistrationIdentity(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	p := setupPreview(t, h.srv)
	now := time.Now()
	token := "preview-test-node-token"
	hash := HashToken(token)
	if _, e := h.srv.Store.DB().Exec(`UPDATE endpoints SET token_hash=? WHERE endpoint_id=?`, hash, p.Endpoint); e != nil {
		t.Fatal(e)
	}
	fleet := "11111111-2222-4333-8444-555555555555"
	claims := assertClaims(fleet, now)
	claims.Node = p.Machine
	if _, e := h.srv.Store.RecordFleetSnapshot(p.Endpoint, p.Machine, p.Login, "preview-machine", []store.FleetReport{{FleetID: fleet, Name: "preview", State: "up"}}, now); e != nil {
		t.Fatal(e)
	}
	task, e := h.srv.Store.UpdateFleetTask(p.TaskID, store.FleetTaskUpdate{WorkerID: claims.WorkerID}, now)
	if e != nil {
		t.Fatal(e)
	}
	ask := func(tok, assertion, ref, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "https://hub.example.com/v1/node/previews?task="+ref, strings.NewReader(body))
		r.URL.Scheme = ""
		r.URL.Host = ""
		r.Header.Set("Authorization", "Bearer "+tok)
		r.Header.Set(workerAssertHeader, assertion)
		w := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(w, r)
		return w
	}
	good := signWorkerAssertion(claims, hash)
	for _, tc := range []struct {
		name, tok, assert, ref, body string
		want                         int
	}{
		{"no node", "bad", good, task.Ref, `{"action":"register","socket":"app.sock"}`, 401},
		{"forged assertion", token, good + "x", task.Ref, `{"action":"register","socket":"app.sock"}`, 401},
		{"other task", token, good, "T99999", `{"action":"register","socket":"app.sock"}`, 403},
		{"TCP", token, good, task.Ref, `{"action":"register","socket":"127.0.0.1:3000"}`, 400},
		{"traversal", token, good, task.Ref, `{"action":"register","socket":"../app.sock"}`, 400},
		{"ignore claimed identity", token, good, task.Ref, `{"action":"register","socket":"app.sock","principal":"gh:other","uid":0,"login":"root","node":"other"}`, 201},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := ask(tc.tok, tc.assert, tc.ref, tc.body)
			if w.Code != tc.want {
				t.Fatal(w.Code, w.Body.String())
			}
		})
	}
	claims.Fid = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
	claims.WorkerID = fleet + "/" + claims.Fid
	if w := ask(token, signWorkerAssertion(claims, hash), task.Ref, `{"action":"register","socket":"app.sock"}`); w.Code != 403 {
		t.Fatal("other worker", w.Code, w.Body.String())
	}
	if _, e := h.srv.Store.DB().Exec(`UPDATE fleet_accounts SET state='deleted' WHERE hostname=? AND login=?`, p.Machine, p.Login); e != nil {
		t.Fatal(e)
	}
	if w := ask(token, good, task.Ref, `{"action":"register","socket":"app.sock"}`); w.Code != 403 {
		t.Fatal("old login", w.Code, w.Body.String())
	}
}

// A deep link opened before sign-in lands on that page, not on "/" (the
// first-open-shows-the-root bug): path and query survive the round-trip.
func TestPreviewDeepLinkSurvivesSignIn(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	p := setupPreview(t, h.srv)
	base := h.srv.previewURL(p.ID)
	const deep = "/2026-11-01-design.html?x=1&y=%2F"
	first := previewRequest(h.srv, "GET", base+deep)
	if first.Code != 302 {
		t.Fatal(first.Code, first.Body.String())
	}
	state, next := cookieNamed(first.Result(), previewStateCookie), cookieNamed(first.Result(), previewNextCookie)
	if next == nil || !next.Secure || !next.HttpOnly || next.Domain != "" {
		t.Fatal("deep link not remembered", next)
	}
	issued := previewRequest(h.srv, "GET", first.Header().Get("Location"), personCookie(pAlice, "alice"))
	done := previewRequest(h.srv, "GET", issued.Header().Get("Location"), state, next)
	if done.Code != 303 || done.Header().Get("Location") != deep {
		t.Fatalf("returned to %q (%d)", done.Header().Get("Location"), done.Code)
	}
	if c := cookieNamed(done.Result(), previewNextCookie); c == nil || c.MaxAge >= 0 {
		t.Fatal("next cookie not cleared", c)
	}
	// Without the cookie (or with a forged one) the callback still lands on "/".
	for _, v := range []string{"//evil.test/x", "/\\evil.test", "https://evil.test/", "/a\nb", previewCallback + "?state=x", ""} {
		if got := previewNext(v); got != "" {
			t.Errorf("accepted %q", v)
		}
		r := httptest.NewRequest("GET", base+previewCallback, nil)
		r.AddCookie(&http.Cookie{Name: previewNextCookie, Value: base64.RawURLEncoding.EncodeToString([]byte(v))})
		if got := previewNextFrom(r); got != "/" {
			t.Errorf("forged %q returned %q", v, got)
		}
	}
	// A root visit starts sign-in without forgetting an earlier deep link.
	root := previewRequest(h.srv, "GET", base+"/")
	if root.Code != 302 || cookieNamed(root.Result(), previewNextCookie) != nil {
		t.Fatal("root visit overwrote the deep link")
	}
}
