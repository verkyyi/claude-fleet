package api

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// fakeGHAuth is github.com's half of the sign-in: the token exchange (which
// checks the PKCE verifier against the challenge the hub sent) and GET
// /user, GET /users/<name>.
type fakeGHAuth struct {
	srv *httptest.Server
	mu  sync.Mutex
	// codes: code → who it signs in, and the challenge it was issued for.
	codes map[string]fakeGrant
	// tokens: access token → who it is.
	tokens map[string]fakeGHUser
	// public: username → who holds it, for /users/<name>.
	public map[string]fakeGHUser
	// exchanged counts token exchanges.
	exchanged int
}

type fakeGHUser struct {
	ID    int64
	Login string
}

type fakeGrant struct {
	user      fakeGHUser
	challenge string
}

func newFakeGHAuth(t *testing.T) *fakeGHAuth {
	f := &fakeGHAuth{codes: map[string]fakeGrant{}, tokens: map[string]fakeGHUser{}, public: map[string]fakeGHUser{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/login/oauth/access_token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		f.mu.Lock()
		defer f.mu.Unlock()
		f.exchanged++
		g, ok := f.codes[r.PostForm.Get("code")]
		sum := sha256.Sum256([]byte(r.PostForm.Get("code_verifier")))
		if !ok || r.PostForm.Get("client_secret") != "shh" ||
			base64.RawURLEncoding.EncodeToString(sum[:]) != g.challenge {
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "bad_verification_code"})
			return
		}
		delete(f.codes, r.PostForm.Get("code"))
		tok := "gho_" + r.PostForm.Get("code")
		f.tokens[tok] = g.user
		_ = json.NewEncoder(w).Encode(map[string]string{"access_token": tok, "token_type": "bearer"})
	})
	mux.HandleFunc("/user", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		u, ok := f.tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
		f.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"id": u.ID, "login": u.Login})
	})
	mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		u, ok := f.public[strings.ToLower(strings.TrimPrefix(r.URL.Path, "/users/"))]
		f.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"id": u.ID, "login": u.Login})
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

type ghHarness struct {
	srv  *Server
	http *httptest.Server
	gh   *fakeGHAuth
	n    int
}

func newGitHubHarness(t *testing.T, admins ...string) *ghHarness {
	t.Helper()
	return newGitHubHarnessWith(t, nil, admins...)
}

// newGitHubHarnessWith lets a test set more of the Server (the fleet module,
// /mcp) before its routes are mounted.
func newGitHubHarnessWith(t *testing.T, more func(*Server), admins ...string) *ghHarness {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	gh := newFakeGHAuth(t)
	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken, LiveStore: NewLive(),
		GitHub: &GitHubAuth{ClientID: "Iv1.test", ClientSecret: "shh", Admins: admins,
			AuthorizeURL: gh.srv.URL + "/login/oauth/authorize", TokenURL: gh.srv.URL + "/login/oauth/access_token",
			APIBase: gh.srv.URL}}
	if more != nil {
		more(srv)
	}
	mux := http.NewServeMux()
	// A route behind adminOnly that needs no fleet module, for the role table.
	mux.Handle("/test/admin", srv.viewerOnly(srv.adminOnly(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(roleOf(r.Context())))
	}))))
	mux.Handle("/", srv.Handler())
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return &ghHarness{srv: srv, http: ts, gh: gh}
}

var noFollow = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func cookieNamed(resp *http.Response, name string) *http.Cookie {
	for _, c := range resp.Cookies() {
		if c.Name == name {
			return c
		}
	}
	return nil
}

// signIn runs the whole flow as GitHub account u: start, GitHub's consent
// (the fake), callback. Returns the callback's response and the session
// cookie it set, if any.
func (h *ghHarness) signIn(t *testing.T, u fakeGHUser) (*http.Response, *http.Cookie) {
	t.Helper()
	resp, err := noFollow.Get(h.http.URL + "/auth/github/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("start = %d", resp.StatusCode)
	}
	loc, _ := url.Parse(resp.Header.Get("Location"))
	q := loc.Query()
	if q.Get("code_challenge_method") != "S256" || q.Get("client_id") != "Iv1.test" || q.Get("scope") != "" {
		t.Fatalf("authorize URL = %s", loc)
	}
	if q.Get("redirect_uri") != h.http.URL+"/auth/github/callback" {
		t.Fatalf("redirect_uri = %q", q.Get("redirect_uri"))
	}
	flow := cookieNamed(resp, githubFlowCookie)
	if flow == nil || !flow.HttpOnly || flow.Path != githubFlowPath {
		t.Fatalf("flow cookie = %+v", flow)
	}
	h.n++
	code := "c" + strconv.Itoa(h.n)
	h.gh.mu.Lock()
	h.gh.codes[code] = fakeGrant{user: u, challenge: q.Get("code_challenge")}
	h.gh.mu.Unlock()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/auth/github/callback?code="+code+"&state="+url.QueryEscape(q.Get("state")), nil)
	req.Header.Set("Accept", "text/html")
	req.AddCookie(flow)
	cb, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	cb.Body.Close()
	return cb, cookieNamed(cb, authz.CookieName)
}

// me is /v1/me with a session cookie: the status and, on 200, the body.
func (h *ghHarness) me(t *testing.T, sess *http.Cookie) (int, Me) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/me", nil)
	req.Header.Set("Accept", "application/json")
	req.AddCookie(sess)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var m Me
	if resp.StatusCode == http.StatusOK {
		_ = json.NewDecoder(resp.Body).Decode(&m)
	}
	return resp.StatusCode, m
}

func (h *ghHarness) addUser(t *testing.T, u fakeGHUser) {
	t.Helper()
	if _, err := h.srv.Store.PinLogin(u.Login, u.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: u.ID, Login: u.Login, Role: store.RoleUser, AddedBy: "gh:100"}); err != nil {
		t.Fatal(err)
	}
}

func (h *ghHarness) audit(t *testing.T) []store.HubAuditEntry {
	t.Helper()
	log, err := h.srv.Store.HubAuditLog(50)
	if err != nil {
		t.Fatal(err)
	}
	return log
}

func hasAudit(log []store.HubAuditEntry, outcome, detailPart string) bool {
	for _, e := range log {
		if e.Action == "signin" && e.Outcome == outcome && strings.Contains(e.Detail, detailPart) {
			return true
		}
	}
	return false
}

var (
	ghAdmin   = fakeGHUser{ID: 100, Login: "verkyyi"}
	ghAlice   = fakeGHUser{ID: 200, Login: "alice"}
	ghMallory = fakeGHUser{ID: 300, Login: "mallory"}
	// ghNewAlice took the username "alice" after the listed alice let it go.
	ghNewAlice = fakeGHUser{ID: 201, Login: "alice"}
)

// Who gets in, and as what (EPIC #1982 C2's completion table).
func TestGitHubSignIn_WhoGetsIn(t *testing.T) {
	cases := []struct {
		name     string
		admins   []string
		users    []fakeGHUser
		as       fakeGHUser
		wantRole string // "" = refused with 403
		audit    string // a refused sign-in's audit detail
	}{
		{name: "admin from the deploy", admins: []string{"VerkYYi"}, as: ghAdmin, wantRole: "admin"},
		{name: "user on the list", admins: []string{"verkyyi"}, users: []fakeGHUser{ghAlice}, as: ghAlice, wantRole: "user"},
		{name: "not on the list", admins: []string{"verkyyi"}, users: []fakeGHUser{ghAlice}, as: ghMallory, audit: "not on the list"},
		{name: "listed name, different ID", admins: []string{"verkyyi"}, users: []fakeGHUser{ghAlice}, as: ghNewAlice, audit: "pinned to GitHub ID 200"},
		{name: "empty list, the admin's own account", admins: nil, as: ghAdmin, audit: "not on the list"},
		{name: "empty list, anyone", admins: nil, as: ghMallory, audit: "not on the list"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newGitHubHarness(t, tc.admins...)
			for _, u := range tc.users {
				h.addUser(t, u)
			}
			cb, sess := h.signIn(t, tc.as)
			if tc.wantRole == "" {
				if cb.StatusCode != http.StatusForbidden {
					t.Fatalf("callback = %d; want 403", cb.StatusCode)
				}
				if sess != nil && sess.MaxAge >= 0 {
					t.Fatalf("a refused sign-in set a session: %+v", sess)
				}
				if !hasAudit(h.audit(t), "refused", tc.audit) {
					t.Errorf("no refused audit row saying %q: %+v", tc.audit, h.audit(t))
				}
				return
			}
			if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != "/" {
				t.Fatalf("callback = %d → %q; want 302 → /", cb.StatusCode, cb.Header.Get("Location"))
			}
			if sess == nil || !sess.HttpOnly || sess.Domain != "" {
				t.Fatalf("session cookie = %+v", sess)
			}
			code, m := h.me(t, sess)
			if code != http.StatusOK {
				t.Fatalf("/v1/me = %d", code)
			}
			want := Me{Via: "github", Role: tc.wantRole, Person: githubPrincipal(tc.as.ID), Name: tc.as.Login, CanLogout: true,
				Pages: pagesFor(tc.wantRole)}
			if !reflect.DeepEqual(m, want) {
				t.Errorf("/v1/me = %+v; want %+v", m, want)
			}
			if !hasAudit(h.audit(t), "ok", "as "+tc.wantRole) {
				t.Errorf("no ok audit row: %+v", h.audit(t))
			}
		})
	}
}

// The list is read on every request: removal, or losing admin in the
// deploy, takes effect on the very next one.
func TestGitHubSignIn_RemovalTakesEffectNextRequest(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	h.addUser(t, ghAlice)
	_, alice := h.signIn(t, ghAlice)
	_, admin := h.signIn(t, ghAdmin)
	if code, _ := h.me(t, alice); code != http.StatusOK {
		t.Fatalf("alice before removal = %d", code)
	}
	if _, err := h.srv.Store.DeleteHubUser(ghAlice.ID); err != nil {
		t.Fatal(err)
	}
	if code, _ := h.me(t, alice); code != http.StatusForbidden {
		t.Errorf("alice after removal = %d; want 403", code)
	}

	// The deploy drops the admin: the same cookie is worth nothing now, even
	// though the hub_users row still says admin.
	h.srv.GitHub.Admins = nil
	if code, _ := h.me(t, admin); code != http.StatusForbidden {
		t.Errorf("ex-admin = %d; want 403", code)
	}
}

// adminOnly lets an admin and the operator's token through, refuses a user.
func TestGitHubSignIn_AdminOnlyByRole(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	h.addUser(t, ghAlice)
	_, admin := h.signIn(t, ghAdmin)
	_, user := h.signIn(t, ghAlice)
	cases := []struct {
		name string
		auth func(*http.Request)
		code int
		body string
	}{
		{"admin", func(r *http.Request) { r.AddCookie(admin) }, http.StatusOK, "admin"},
		{"user", func(r *http.Request) { r.AddCookie(user) }, http.StatusForbidden, ""},
		{"viewer token", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+viewerToken) }, http.StatusOK, "operator"},
		{"nobody", func(*http.Request) {}, http.StatusUnauthorized, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/test/admin", nil)
			req.Header.Set("Accept", "application/json")
			tc.auth(req)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			var b strings.Builder
			buf := make([]byte, 64)
			n, _ := resp.Body.Read(buf)
			b.Write(buf[:n])
			if resp.StatusCode != tc.code || (tc.body != "" && b.String() != tc.body) {
				t.Errorf("= %d %q; want %d %q", resp.StatusCode, b.String(), tc.code, tc.body)
			}
		})
	}
}

// A signed-out browser goes to /signin; an API caller keeps its 401.
func TestGitHubSignIn_SignedOutBrowserGoesToSignin(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/", nil)
	req.Header.Set("Accept", "text/html")
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/signin" {
		t.Errorf("browser / = %d → %q; want 302 → /signin", resp.StatusCode, resp.Header.Get("Location"))
	}
	resp, err = http.Get(h.http.URL + "/v1/me")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("API /v1/me = %d; want 401", resp.StatusCode)
	}
	page, err := http.Get(h.http.URL + "/signin")
	if err != nil {
		t.Fatal(err)
	}
	defer page.Body.Close()
	buf := new(strings.Builder)
	b := make([]byte, 32<<10)
	n, _ := page.Body.Read(b)
	buf.Write(b[:n])
	if page.StatusCode != http.StatusOK || !strings.Contains(buf.String(), `href="/auth/github/start"`) {
		t.Errorf("/signin = %d, no Continue with GitHub link", page.StatusCode)
	}
}

// A callback whose state does not match the flow cookie signs no one in.
func TestGitHubSignIn_StateMismatchRefused(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	resp, err := noFollow.Get(h.http.URL + "/auth/github/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	flow := cookieNamed(resp, githubFlowCookie)
	for _, cb := range []struct {
		name   string
		cookie *http.Cookie
		state  string
	}{
		{"wrong state", flow, "not-the-state"},
		{"no flow cookie", nil, "anything"},
	} {
		t.Run(cb.name, func(t *testing.T) {
			req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/auth/github/callback?code=x&state="+cb.state, nil)
			if cb.cookie != nil {
				req.AddCookie(cb.cookie)
			}
			r, err := noFollow.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			r.Body.Close()
			if r.StatusCode != http.StatusFound || r.Header.Get("Location") != "/signin?e=expired" {
				t.Errorf("= %d → %q", r.StatusCode, r.Header.Get("Location"))
			}
			if c := cookieNamed(r, authz.CookieName); c != nil && c.MaxAge >= 0 {
				t.Errorf("set a session: %+v", c)
			}
		})
	}
	if h.gh.exchanged != 0 {
		t.Errorf("a refused callback still exchanged %d code(s) with GitHub", h.gh.exchanged)
	}
}

// Start-up resolution pins each admin name to the ID GitHub holds it under;
// someone else signing in under that name later is refused.
func TestGitHubSignIn_ResolveAdminsPins(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi", "ghost")
	h.gh.public["verkyyi"] = ghAdmin
	h.srv.ResolveGitHubAdmins(context.Background())
	if id, ok, _ := h.srv.Store.PinnedID("verkyyi"); !ok || id != ghAdmin.ID {
		t.Fatalf("verkyyi pinned = %d %v", id, ok)
	}
	if _, ok, _ := h.srv.Store.PinnedID("ghost"); ok {
		t.Errorf("an unresolvable admin name was pinned")
	}
	if u, _ := h.srv.Store.HubUserByID(ghAdmin.ID); u == nil || u.Role != store.RoleAdmin || u.AddedBy != "deploy" {
		t.Errorf("admin row = %+v", u)
	}
	cb, _ := h.signIn(t, fakeGHUser{ID: 999, Login: "verkyyi"})
	if cb.StatusCode != http.StatusForbidden {
		t.Errorf("impostor under a pinned admin name = %d; want 403", cb.StatusCode)
	}
	if cb, _ := h.signIn(t, ghAdmin); cb.StatusCode != http.StatusFound {
		t.Errorf("the real admin = %d; want 302", cb.StatusCode)
	}
}

// A WeCom session can never carry a gh: principal past the list.
func TestGitHubSignIn_WeComCannotClaimGitHubPrincipal(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	h.srv.SSO = &SSO{AppID: "ccquota", TicketSecret: "t", SessionSecret: "wecom-key", EnterURL: "https://ai.example/enter"}
	forged := authz.SignPerson("staff", "gh:100", "verkyyi", "wecom-key", time.Now(), time.Hour)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/me", nil)
	req.Header.Set("Accept", "application/json")
	req.AddCookie(&http.Cookie{Name: authz.CookieName, Value: forged})
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("WeCom session naming gh:100 = %d; want 401", resp.StatusCode)
	}
}

// Not configured: the routes 404, like /enter without SSO.
func TestGitHubSignIn_OffIs404(t *testing.T) {
	h := newHarness(t)
	for _, p := range []string{"/signin", "/auth/github/start", "/auth/github/callback"} {
		resp, err := noFollow.Get(h.http.URL + p)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s = %d; want 404", p, resp.StatusCode)
		}
	}
}
