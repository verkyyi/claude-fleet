package api

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Sign in with GitHub; only the people on the list get in (claude-fleet#1984).
//
// # The flow
//
// /signin is the page a signed-out browser is sent to. Its one button is
// /auth/github/start, which mints a state and a PKCE verifier, keeps both in
// a ten-minute cookie scoped to /auth/github/, and sends the browser to
// GitHub. GitHub sends it back to /auth/github/callback with a code; the hub
// checks the state, trades the code (with the verifier) for a user token,
// asks GET /user who that is — the numeric ID and the username — and drops
// the token. It is used once and never stored, and no scope is asked for:
// the hub needs to know who you are, nothing about your repositories.
//
// # Who gets in
//
// A person is their GitHub numeric ID. The list (store.HubUser) is keyed on
// it; usernames are only how people are NAMED: the first time the hub learns
// which ID holds a username, it pins the pair (hub_user_names), and a sign-in
// under a pinned name from any other ID is refused and audited — a username
// freed and taken by someone else does not inherit the access. Admins come
// from the deploy (CCQUOTA_GITHUB_ADMINS, usernames, resolved to IDs at start
// and pinned); users are added on the web (C4). An empty list lets nobody in.
//
// # Every request, not just the sign-in
//
// The session is the hub's own ccq_sess cookie with UID gh:<id>, the username
// as its name and the role it was admitted as. The role in the cookie is a
// record, never the authority: viewerOnly reads the list by ID on every
// request (githubRole), so a person taken off it — or out of
// CCQUOTA_GITHUB_ADMINS — is refused on their next request, with no wait for
// the cookie to expire.

// GitHubAuth is the GitHub sign-in's configuration. Nil means not wired up:
// /signin and /auth/github/* answer 404 and nothing else changes.
type GitHubAuth struct {
	// ClientID / ClientSecret are the GitHub App's (CCQUOTA_GITHUB_CLIENT_ID
	// / CCQUOTA_GITHUB_CLIENT_SECRET, from the k8s Secret only). A GitHub
	// App's user sign-in uses the same /login/oauth/* endpoints as an OAuth
	// App, so nothing here tells them apart.
	ClientID     string
	ClientSecret string
	// Admins is CCQUOTA_GITHUB_ADMINS: GitHub usernames, matched
	// case-insensitively, each meaning the ID it is pinned to.
	Admins []string
	// TTL is how long a session cookie lives; zero means a week. The list is
	// re-read on every request, so this bounds how often a person clicks
	// "Continue with GitHub", not how long a removed person keeps access.
	TTL time.Duration

	// The GitHub endpoints; empty means github.com. Tests point them at a
	// fake.
	AuthorizeURL string
	TokenURL     string
	APIBase      string
	// HTTP is the client for the token exchange and the API; nil means one
	// with a 15-second timeout.
	HTTP *http.Client
}

const (
	githubAuthorizeURL = "https://github.com/login/oauth/authorize"
	githubTokenURL     = "https://github.com/login/oauth/access_token"
	githubAPIBase      = "https://api.github.com"

	// githubPrincipalPrefix makes a GitHub person's principal: gh:<id>.
	githubPrincipalPrefix = "gh:"
	// githubSessionSub is the session's subject: the issuer, as a WeCom
	// session's is the role the ticket admitted.
	githubSessionSub = "github"
	// githubFlowCookie carries the state and the PKCE verifier from start to
	// callback, and nowhere else.
	githubFlowCookie = "ccq_gh_flow"
	githubFlowPath   = "/auth/github/"
	githubFlowTTL    = 10 * time.Minute
)

// Roles, as roleOf names them. admin and user are a GitHub person's (and the
// list's); operator is the shared doors — the viewer token, a tailnet peer,
// a hub with no auth — which have always seen everything.
const (
	roleAdmin    = store.RoleAdmin
	roleUser     = store.RoleUser
	roleOperator = "operator"
)

func (g *GitHubAuth) ready() bool {
	return g != nil && g.ClientID != "" && g.ClientSecret != ""
}

func (g *GitHubAuth) ttl() time.Duration {
	if g.TTL <= 0 {
		return 7 * 24 * time.Hour
	}
	return g.TTL
}

func (g *GitHubAuth) client() *http.Client {
	if g.HTTP != nil {
		return g.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (g *GitHubAuth) authorizeURL() string { return orDefault(g.AuthorizeURL, githubAuthorizeURL) }
func (g *GitHubAuth) tokenURL() string     { return orDefault(g.TokenURL, githubTokenURL) }
func (g *GitHubAuth) apiBase() string {
	return strings.TrimRight(orDefault(g.APIBase, githubAPIBase), "/")
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// sessionKey signs this hub's GitHub sessions and the flow cookie. Derived
// from the client secret rather than configured on its own: the deploy has
// exactly three new settings (EPIC #1982), and rotating the secret signing
// everyone out is the right side effect of rotating it. The label keeps the
// derived key from ever being the secret itself.
func (g *GitHubAuth) sessionKey() string {
	m := hmac.New(sha256.New, []byte(g.ClientSecret))
	m.Write([]byte("ccquota github session v1"))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// isAdminName reports whether login is one of CCQUOTA_GITHUB_ADMINS.
func (g *GitHubAuth) isAdminName(login string) bool {
	if g == nil {
		return false
	}
	for _, a := range g.Admins {
		if strings.EqualFold(strings.TrimSpace(a), login) {
			return true
		}
	}
	return false
}

func githubPrincipal(id int64) string { return githubPrincipalPrefix + strconv.FormatInt(id, 10) }

// githubIDOf parses gh:<id>; ok=false for anything else.
func githubIDOf(principal string) (int64, bool) {
	rest, ok := strings.CutPrefix(principal, githubPrincipalPrefix)
	if !ok {
		return 0, false
	}
	id, err := strconv.ParseInt(rest, 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

// roleKey carries the role viewerOnly admitted a GitHub person as.
type roleKey struct{}

func withRole(ctx context.Context, role string) context.Context {
	return context.WithValue(ctx, roleKey{}, role)
}

// roleOf is the ONE reading of what the caller may do (EPIC #1982 rule 3):
// admin or user for a GitHub person, user for a WeCom person, operator for
// the shared doors (viewer token, tailnet, --no-auth). "" only for a request
// no gate has admitted.
func roleOf(ctx context.Context) string {
	if r, _ := ctx.Value(roleKey{}).(string); r != "" {
		return r
	}
	if principalOf(ctx) != "" {
		return roleUser
	}
	if doorOf(ctx) != "" {
		return roleOperator
	}
	return ""
}

// githubRole is what the list says about id RIGHT NOW: admin when id is
// pinned to a name in CCQUOTA_GITHUB_ADMINS, user when it has a user row,
// "" when neither — refused. A hub_users row saying admin for an ID the
// deploy no longer names grants nothing: the deploy decides who is admin.
func (s *Server) githubRole(id int64) (string, error) {
	for _, name := range s.githubAdmins() {
		pinned, ok, err := s.Store.PinnedID(name)
		if err != nil {
			return "", err
		}
		if ok && pinned == id {
			return roleAdmin, nil
		}
	}
	u, err := s.Store.HubUserByID(id)
	if err != nil {
		return "", err
	}
	if u != nil && u.Role == roleUser {
		return roleUser, nil
	}
	return "", nil
}

// githubSession is the GitHub session behind r, if its cookie verifies. It
// says nothing about the list; viewerOnly asks githubRole.
func (s *Server) githubSession(r *http.Request) (*authz.Session, int64, bool) {
	if !s.GitHub.ready() {
		return nil, 0, false
	}
	c, err := r.Cookie(authz.CookieName)
	if err != nil {
		return nil, 0, false
	}
	sess, err := authz.VerifySession(c.Value, s.GitHub.sessionKey(), time.Now())
	if err != nil || sess.Sub != githubSessionSub {
		return nil, 0, false
	}
	id, ok := githubIDOf(sess.UID)
	if !ok {
		return nil, 0, false
	}
	return sess, id, true
}

// githubAdmit is viewerOnly's GitHub branch: ok=false when r carries no
// GitHub session (the gate goes on to its other doors); handled=true when
// it answered the request itself (a refusal or an error).
func (s *Server) githubAdmit(w http.ResponseWriter, r *http.Request) (ctx context.Context, ok, handled bool) {
	sess, id, ok := s.githubSession(r)
	if !ok {
		return nil, false, false
	}
	role, err := s.githubRole(id)
	if err != nil {
		// Fail closed: a list that cannot be read admits no one.
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return nil, true, true
	}
	if role == "" {
		// Taken off the list since signing in. The cookie is worth nothing
		// now; drop it so the browser stops presenting it.
		clearCookie(w, r, authz.CookieName, "/")
		_ = s.Store.HubAudit(sess.UID, "request", sess.Name+" ("+sess.UID+")", "refused",
			"no longer on the list; session dropped", time.Now())
		s.githubDeny(w, r, denyRemoved, sess.Name)
		return nil, true, true
	}
	sub := sess.Principal()
	ctx = context.WithValue(withViewer(r.Context(), sub), principalKey{}, sub)
	ctx = withRole(withDoor(withSession(ctx, sess), doorGitHub), role)
	return ctx, true, false
}

// handleSignin is the sign-in page. Public: it is the way in.
func (s *Server) handleSignin(w http.ResponseWriter, r *http.Request) {
	if !s.GitHub.ready() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	// Already in: the page has nothing to offer.
	if _, id, ok := s.githubSession(r); ok {
		if role, err := s.githubRole(id); err == nil && role != "" {
			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
	}
	page := signinPage{Note: signinNotes[r.URL.Query().Get("e")]}
	if u, ok := s.ssoGateURL(); ok {
		page.WeCom = u
	}
	writeAuthPage(w, http.StatusOK, signinTmpl, page)
}

// signinNotes are the only things /signin?e= can say: a fixed set, so the
// page never reflects a query string.
var signinNotes = map[string]string{
	"expired":   "That sign-in took too long or was started in another tab. Try again.",
	"cancelled": "GitHub didn't sign you in. Try again when you're ready.",
	"github":    "GitHub couldn't be reached to finish signing you in. Try again in a minute.",
}

// handleGitHubStart sends the browser to GitHub with a fresh state and PKCE
// challenge.
func (s *Server) handleGitHubStart(w http.ResponseWriter, r *http.Request) {
	if !s.GitHub.ready() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	state, err1 := randomToken(24)
	verifier, err2 := randomToken(32)
	if err1 != nil || err2 != nil {
		httpError(w, http.StatusInternalServerError, "could not start sign-in")
		return
	}
	flow, _ := json.Marshal(githubFlow{State: state, Verifier: verifier, Exp: time.Now().Add(githubFlowTTL).Unix()})
	http.SetCookie(w, &http.Cookie{
		Name: githubFlowCookie, Value: signBlob(flow, s.GitHub.sessionKey()), Path: githubFlowPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(githubFlowTTL.Seconds()),
	})
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"client_id":             {s.GitHub.ClientID},
		"redirect_uri":          {s.githubCallbackURL(r)},
		"state":                 {state},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(sum[:])},
		"code_challenge_method": {"S256"},
		"allow_signup":          {"false"},
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, s.GitHub.authorizeURL()+"?"+q.Encode(), http.StatusFound)
}

func (s *Server) githubCallbackURL(r *http.Request) string {
	return s.hubURL(r) + "/auth/github/callback"
}

// githubFlow is the flow cookie's body.
type githubFlow struct {
	State    string `json:"s"`
	Verifier string `json:"v"`
	Exp      int64  `json:"e"`
}

// handleGitHubCallback finishes the sign-in: state, code exchange, who it
// is, the list, and the session cookie — or the refusal page.
func (s *Server) handleGitHubCallback(w http.ResponseWriter, r *http.Request) {
	if !s.GitHub.ready() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var flow githubFlow
	c, err := r.Cookie(githubFlowCookie)
	if err == nil {
		if raw, ok := verifyBlob(c.Value, s.GitHub.sessionKey()); ok {
			_ = json.Unmarshal(raw, &flow)
		}
	}
	// One use: whatever happens next, this flow is over.
	clearCookie(w, r, githubFlowCookie, githubFlowPath)
	q := r.URL.Query()
	if q.Get("error") != "" {
		http.Redirect(w, r, "/signin?e=cancelled", http.StatusFound)
		return
	}
	state, code := q.Get("state"), q.Get("code")
	if flow.State == "" || flow.Exp < time.Now().Unix() || state == "" || code == "" ||
		!constantTimeEqual(state, flow.State) {
		http.Redirect(w, r, "/signin?e=expired", http.StatusFound)
		return
	}
	id, login, err := s.githubWho(r.Context(), code, flow.Verifier, s.githubCallbackURL(r))
	if err != nil {
		log.Printf("github sign-in: %v", err)
		http.Redirect(w, r, "/signin?e=github", http.StatusFound)
		return
	}
	now := time.Now()
	role, refusal, err := s.githubAdmitSignIn(id, login, now)
	if err != nil {
		log.Printf("github sign-in of %s (%d): %v", login, id, err)
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	if role == "" {
		s.githubDeny(w, r, refusal, login)
		return
	}
	principal := githubPrincipal(id)
	http.SetCookie(w, &http.Cookie{
		Name:  authz.CookieName,
		Value: authz.SignRole(githubSessionSub, principal, login, role, s.GitHub.sessionKey(), now, s.GitHub.ttl()),
		Path:  "/",
		// Host-only, like the WeCom session: no Domain.
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   isHTTPS(r),
		MaxAge:   int(s.GitHub.ttl().Seconds()),
	})
	// The same placement a WeCom sign-in runs: the machine login an admin set
	// for them (claude-fleet#1986), adopted on every machine that runs it.
	s.onPrincipalSignIn(principal, login)
	// A `fleet login` code scanned while signed out comes back to its
	// confirmation page; everything else goes to "/".
	http.Redirect(w, r, loginReturn(w, r), http.StatusFound)
}

// The refusals, as the 403 page words them.
const (
	denyNotListed = "not-listed"
	denyRenamed   = "renamed"
	denyRemoved   = "removed"
)

// githubAdmitSignIn decides a sign-in by GitHub ID and username, pins the
// name the first time it is seen, and audits the outcome. role "" is a
// refusal, named by the second result.
func (s *Server) githubAdmitSignIn(id int64, login string, now time.Time) (role, refusal string, err error) {
	actor := githubPrincipal(id)
	target := login + " (" + actor + ")"
	pinned, known, err := s.Store.PinnedID(login)
	if err != nil {
		return "", "", err
	}
	if known && pinned != id {
		// The name means someone else here. Whoever holds it on GitHub now
		// is not the person the list was written for.
		_ = s.Store.HubAudit(actor, "signin", target, "refused",
			fmt.Sprintf("username %s is pinned to GitHub ID %d", login, pinned), now)
		return "", denyRenamed, nil
	}
	// An admin name the start-up resolution could not pin (GitHub was
	// unreachable, or rate-limited it) is pinned now, from GitHub's own
	// answer for the person signing in: the first time the name is seen.
	if !known && s.GitHub.isAdminName(login) {
		if err := s.pinName(login, id, "deploy", now); err != nil {
			if errors.Is(err, store.ErrPinConflict) {
				return "", denyRenamed, nil
			}
			return "", "", err
		}
		known = true
	}
	role, err = s.githubRole(id)
	if err != nil {
		return "", "", err
	}
	if role == "" {
		_ = s.Store.HubAudit(actor, "signin", target, "refused", "not on the list", now)
		return "", denyNotListed, nil
	}
	if !known {
		// On the list by ID under a name the hub has not seen: they renamed
		// themselves on GitHub. The new name is theirs from now on.
		if err := s.pinName(login, id, actor, now); err != nil && !errors.Is(err, store.ErrPinConflict) {
			return "", "", err
		}
	}
	if role == roleAdmin {
		if err := s.recordAdmin(id, login, now); err != nil {
			return "", "", err
		}
	}
	if err := s.Store.TouchHubUser(id, login, now); err != nil {
		return "", "", err
	}
	_ = s.Store.HubAudit(actor, "signin", target, "ok", "as "+role, now)
	return role, "", nil
}

// pinName pins login to id and audits a new pin.
func (s *Server) pinName(login string, id int64, actor string, now time.Time) error {
	created, err := s.Store.PinLogin(login, id, now)
	if err != nil {
		if errors.Is(err, store.ErrPinConflict) {
			_ = s.Store.HubAudit(actor, "pin", login, "refused", "already pinned to another GitHub ID", now)
		}
		return err
	}
	if created {
		_ = s.Store.HubAudit(actor, "pin", login, "ok", "pinned to "+githubPrincipal(id), now)
	}
	return nil
}

// recordAdmin keeps an admin's row on the list, for the people page: the
// deploy decides who is admin (githubRole), the row records them.
func (s *Server) recordAdmin(id int64, login string, now time.Time) error {
	u, err := s.Store.HubUserByID(id)
	if err != nil {
		return err
	}
	row := store.HubUser{GitHubID: id, Login: login, Role: roleAdmin, AddedBy: "deploy", AddedAt: now}
	if u != nil {
		if u.Role == roleAdmin && u.Login == login {
			return nil
		}
		row.MachineLogin, row.AddedBy, row.AddedAt = u.MachineLogin, u.AddedBy, u.AddedAt
	}
	return s.Store.UpsertHubUser(row)
}

// ResolveGitHubAdmins pins every CCQUOTA_GITHUB_ADMINS name not pinned yet to
// the ID GitHub's public API says holds it. Run once at start, in the
// background. A name that cannot be resolved is logged and left unpinned —
// it lets no one in until it is (at start-up, or by its owner's own sign-in).
func (s *Server) ResolveGitHubAdmins(ctx context.Context) {
	if !s.GitHub.ready() || s.Store == nil {
		return
	}
	if len(s.GitHub.Admins) == 0 {
		log.Printf("WARN github sign-in: CCQUOTA_GITHUB_ADMINS is empty — no admin can sign in")
	}
	for _, name := range s.GitHub.Admins {
		name = strings.TrimSpace(name)
		if _, ok, err := s.Store.PinnedID(name); err != nil || ok {
			if err != nil {
				log.Printf("WARN github sign-in: admin %s: %v", name, err)
			}
			continue
		}
		id, login, err := s.githubLookup(ctx, name)
		if err != nil {
			log.Printf("WARN github sign-in: could not resolve admin %s to a GitHub ID: %v (not let in until resolved)", name, err)
			continue
		}
		now := time.Now()
		if err := s.pinName(name, id, "deploy", now); err != nil {
			log.Printf("WARN github sign-in: admin %s: %v", name, err)
			continue
		}
		if err := s.recordAdmin(id, login, now); err != nil {
			log.Printf("WARN github sign-in: admin %s: %v", name, err)
			continue
		}
		log.Printf("github sign-in: admin %s is GitHub ID %d", login, id)
	}
}

// githubWho trades a callback code for a user token, asks GitHub who it
// belongs to, and lets the token go. It is never stored or logged.
func (s *Server) githubWho(ctx context.Context, code, verifier, redirect string) (int64, string, error) {
	form := url.Values{
		"client_id":     {s.GitHub.ClientID},
		"client_secret": {s.GitHub.ClientSecret},
		"code":          {code},
		"redirect_uri":  {redirect},
		"code_verifier": {verifier},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.GitHub.tokenURL(), strings.NewReader(form.Encode()))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := s.GitHub.client().Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("token exchange: %w", err)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	err = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&tok)
	resp.Body.Close()
	if err != nil {
		return 0, "", fmt.Errorf("token exchange: HTTP %d, unreadable answer", resp.StatusCode)
	}
	if tok.AccessToken == "" {
		// The error code only (bad_verification_code, …): the description
		// can echo request details.
		return 0, "", fmt.Errorf("token exchange: HTTP %d, %s", resp.StatusCode, orDefault(tok.Error, "no token"))
	}
	return s.githubUser(ctx, "/user", tok.AccessToken)
}

// githubLookup is the public profile of a username, unauthenticated.
func (s *Server) githubLookup(ctx context.Context, name string) (int64, string, error) {
	return s.githubUser(ctx, "/users/"+url.PathEscape(name), "")
}

func (s *Server) githubUser(ctx context.Context, path, token string) (int64, string, error) {
	g := s.GitHub
	if g == nil {
		// The people list without GitHub sign-in configured: github.com.
		g = &GitHubAuth{}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.apiBase()+path, nil)
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "claudefleet-hub")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := g.client().Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("GET %s: %w", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, "", fmt.Errorf("GET %s: HTTP %d", path, resp.StatusCode)
	}
	var u struct {
		ID    int64  `json:"id"`
		Login string `json:"login"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&u); err != nil {
		return 0, "", fmt.Errorf("GET %s: unreadable answer", path)
	}
	if u.ID <= 0 || u.Login == "" {
		return 0, "", fmt.Errorf("GET %s: no id or login in the answer", path)
	}
	return u.ID, u.Login, nil
}

// githubDeny answers a refusal: the "can't use this hub" page for a
// browser, a JSON 403 for anything else. No session is created.
func (s *Server) githubDeny(w http.ResponseWriter, r *http.Request, why, login string) {
	if !wantsHTML(r) {
		httpError(w, http.StatusForbidden, "this GitHub account is not on this hub's list")
		return
	}
	writeAuthPage(w, http.StatusForbidden, denyTmpl, denyPage{Why: why, Login: login})
}

func clearCookie(w http.ResponseWriter, r *http.Request, name, path string) {
	http.SetCookie(w, &http.Cookie{
		Name: name, Value: "", Path: path, MaxAge: -1,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
	})
}

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// signBlob / verifyBlob: body.mac, both base64url. The flow cookie only.
func signBlob(body []byte, key string) string {
	enc := base64.RawURLEncoding.EncodeToString(body)
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte("flow." + enc))
	return enc + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func verifyBlob(v, key string) ([]byte, bool) {
	enc, sig64, ok := strings.Cut(v, ".")
	if !ok {
		return nil, false
	}
	sig, err := base64.RawURLEncoding.DecodeString(sig64)
	if err != nil {
		return nil, false
	}
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte("flow." + enc))
	if !hmac.Equal(sig, m.Sum(nil)) {
		return nil, false
	}
	body, err := base64.RawURLEncoding.DecodeString(enc)
	return body, err == nil
}

func writeAuthPage(w http.ResponseWriter, status int, t *template.Template, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.WriteHeader(status)
	_ = t.Execute(w, data)
}

type signinPage struct {
	// Note is one of signinNotes, or "".
	Note string
	// WeCom is the WeCom gate while that way in still exists, else "".
	WeCom string
}

type denyPage struct {
	Why   string
	Login string
}

// The two pages follow the prototype's sign-in and "can't use this hub"
// cards (EPIC #1982): its palette, its fonts, its words.
const authPageHead = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,700&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Crect width='24' height='24' rx='6' fill='%230e6e5e'/%3E%3Cpath d='M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18' stroke='%23fff' stroke-width='2.2' fill='none' stroke-linecap='round'/%3E%3C/svg%3E">
<style>
:root{--bg:#f4f6f5;--panel:#fff;--ink:#15201d;--ink-2:#3c4945;--muted:#6a7773;--line:#e0e6e3;--line-2:#ecf0ee;--brand:#0e6e5e;--brand-ink:#fff;--bad:#b5361f;--bad-soft:#fbe6e1;--warn:#a86a00;--warn-soft:#fbefd6;
--shadow:0 1px 2px rgba(16,30,26,.06),0 4px 16px -6px rgba(16,30,26,.10);--f-display:"Bricolage Grotesque","Avenir Next","Segoe UI",system-ui,sans-serif;--f-ui:"IBM Plex Sans","Segoe UI",system-ui,sans-serif;--gh:#1f2328;--gh-ink:#fff;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#0e1412;--panel:#151d1b;--ink:#e5ece9;--ink-2:#c1ccc8;--muted:#8b9894;--line:#26302d;--line-2:#1e2725;--brand:#3fc2a6;--brand-ink:#062019;--bad:#f08a76;--bad-soft:#3a1c16;--warn:#e8b85a;--warn-soft:#33290f;--shadow:0 1px 2px rgba(0,0,0,.3),0 6px 20px -8px rgba(0,0,0,.5);--gh:#f0f3f6;--gh-ink:#1f2328;color-scheme:dark}}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14.5px/1.5 var(--f-ui);-webkit-font-smoothing:antialiased}
.pub{min-height:100%;display:grid;grid-template-rows:auto 1fr}
nav{display:flex;align-items:center;padding:18px clamp(16px,4vw,48px);max-width:1180px;width:100%;margin:0 auto}
.logo{display:inline-flex;align-items:center;gap:9px;font:700 18px var(--f-display);letter-spacing:-.01em;color:var(--ink);text-decoration:none}
.mark{width:26px;height:26px;border-radius:7px;background:var(--brand);display:grid;place-items:center}
.mark svg{width:16px;height:16px;stroke:var(--brand-ink);stroke-width:2.2;fill:none;stroke-linecap:round}
.center{display:grid;place-items:center;padding:40px 16px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);padding:30px;width:100%;max-width:420px;display:grid;gap:18px}
h1{margin:0;font:700 1.5rem var(--f-display);letter-spacing:-.02em}
p{margin:0}.lead{color:var(--ink-2)}.fine{font-size:12.5px;color:var(--muted)}
.big{width:40px;height:40px;border-radius:10px;background:var(--brand);display:grid;place-items:center}
.big svg{width:22px;height:22px;stroke:var(--brand-ink);stroke-width:2.2;fill:none;stroke-linecap:round;stroke-linejoin:round}
.big.bad{width:46px;height:46px;border-radius:12px;background:var(--bad-soft)}.big.bad svg{stroke:var(--bad);stroke-width:2}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;font:500 13.5px var(--f-ui);border:1px solid var(--line);background:var(--panel);color:var(--ink);padding:7px 13px;border-radius:7px;text-decoration:none;white-space:nowrap}
.btn:hover{border-color:var(--muted)}.btn.ghost{border-color:transparent;background:transparent;color:var(--ink-2)}
.btn.lg{padding:11px 18px;font-size:15px;border-radius:9px}
.btn.gh{background:var(--gh);border-color:var(--gh);color:var(--gh-ink)}
.btn svg{width:17px;height:17px;stroke:currentColor;stroke-width:2;fill:none;stroke-linecap:round}
.note{background:var(--warn-soft);color:var(--warn);border-radius:8px;padding:9px 12px;font-size:13.5px}
.row{display:flex;gap:8px;flex-wrap:wrap}
a.alt{color:var(--muted);font-size:13px}
</style>`

const authNav = `<nav><a class="logo" href="/"><span class="mark"><svg viewBox="0 0 24 24"><path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/></svg></span>claudefleet</a></nav>`

const gitIcon = `<svg viewBox="0 0 24 24"><circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="8" r="2.5"/><path d="M6 8.5v7M18 10.5c0 4-6 3-10 6"/></svg>`

var signinTmpl = template.Must(template.New("signin").Parse(authPageHead + `
<title>Sign in · claudefleet</title></head><body><div class="pub">` + authNav + `
<div class="center"><main class="card">
<div class="big"><svg viewBox="0 0 24 24"><path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/></svg></div>
<div style="display:grid;gap:6px"><h1>Sign in to claudefleet</h1><p class="lead">This hub is private. Use the GitHub account an admin added.</p></div>
{{if .Note}}<p class="note" role="status">{{.Note}}</p>{{end}}
<a class="btn gh lg" href="/auth/github/start">` + gitIcon + `Continue with GitHub</a>
<p class="fine">claudefleet asks GitHub only who you are. It gets no access to your repositories or organizations.</p>
{{if .WeCom}}<a class="alt" href="{{.WeCom}}">Sign in with WeCom instead</a>{{end}}
</main></div></div></body></html>`))

var denyTmpl = template.Must(template.New("deny").Parse(authPageHead + `
<title>Can't use this hub · claudefleet</title></head><body><div class="pub">` + authNav + `
<div class="center"><main class="card">
<div class="big bad"><svg viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/></svg></div>
<div style="display:grid;gap:6px"><h1>This GitHub account can't use this hub</h1>
<p class="lead">{{if eq .Why "renamed"}}The username <b>{{.Login}}</b> is on this hub's list, but it now belongs to a different GitHub account. An admin can check the Users page.{{else if eq .Why "removed"}}<b>{{.Login}}</b> is no longer on this hub's list. Ask an admin to add your GitHub username again.{{else}}<b>{{.Login}}</b> isn't on this hub's list. Ask an admin to add your GitHub username.{{end}}</p></div>
<div class="row"><a class="btn" href="/signin">Use another account</a><a class="btn ghost" href="/">Back to claudefleet</a></div>
<p class="fine">Response 403 · no session created · the attempt is in the audit log.</p>
</main></div></div></body></html>`))
