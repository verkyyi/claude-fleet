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

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
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

	// RelayURL, when set, sends the token exchange through the Singapore
	// relay's /github-oauth/ route (CCQUOTA_GITHUB_OAUTH_VIA=relay,
	// claude-fleet#3392): github.com is unreliable from the hub's cluster,
	// api.github.com is not, so only this one POST moves. RelayPass mints
	// the hub's own pass for it (Server.HubRelayPass). A relay that does not
	// answer within RelayTimeout falls back to github.com directly, within
	// DirectTimeout — so a dead relay still ends in the usual "could not
	// reach GitHub" well inside 15 seconds. Zero means githubRelayTimeout /
	// githubDirectTimeout.
	RelayURL      string
	RelayPass     func() (string, error)
	RelayTimeout  time.Duration
	DirectTimeout time.Duration
}

const (
	githubAuthorizeURL = "https://github.com/login/oauth/authorize"
	githubTokenURL     = "https://github.com/login/oauth/access_token"
	githubAPIBase      = "https://api.github.com"

	// githubPrincipalPrefix makes a GitHub person's principal: gh:<id> —
	// the GitHub identity's spelling, made and parsed only here
	// (githubPrincipal / githubIDOf); "is a person" is isPerson.
	githubPrincipalPrefix = store.GitHubPrincipalPrefix
	// githubFlowCookie carries the state and the PKCE verifier from start to
	// callback, and nowhere else.
	githubFlowCookie = "ccq_gh_flow"
	githubFlowPath   = "/auth/github/"
	githubFlowTTL    = 10 * time.Minute

	// The token exchange through the relay, then github.com once
	// (claude-fleet#3392): together under the 15 s a person waited before.
	githubRelayTimeout  = 5 * time.Second
	githubDirectTimeout = 8 * time.Second
)

// Roles, as roleOf names them. admin and user are a GitHub person's (and the
// list's); operator is the shared doors — the viewer token, a hub with no
// auth — which have always seen everything. trial is someone the list does
// not name who came in through /app/try (claude-fleet#4058): the chat, their
// trial and /apply, nothing else (trialRoute).
const (
	roleAdmin    = store.RoleAdmin
	roleUser     = store.RoleUser
	roleTrial    = "trial"
	roleOperator = "operator"
)

// memberRole: a role cut to its own — a user's, a trial person's — never an
// admin's or the operator's.
func memberRole(role string) bool { return role == roleUser || role == roleTrial }

func (g *GitHubAuth) ready() bool {
	return g != nil && g.ClientID != "" && g.ClientSecret != ""
}

func (g *GitHubAuth) ttl() time.Duration {
	if g.TTL <= 0 {
		return sessionTTLDefault
	}
	return g.TTL
}

func (g *GitHubAuth) client() *http.Client {
	if g.HTTP != nil {
		return g.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (g *GitHubAuth) viaRelay() bool { return g.RelayURL != "" && g.RelayPass != nil }

func durOr(d, def time.Duration) time.Duration {
	if d <= 0 {
		return def
	}
	return d
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
// admin or user for a GitHub person, operator for the shared doors (viewer
// token, --no-auth). "" only for a request no gate has admitted.
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

// personSession is the signed-in person behind r, if its cookie verifies.
// It says nothing about the list; viewerOnly asks personRole.
func (s *Server) personSession(r *http.Request) (*authz.Session, string, bool) {
	if !s.signinOn() {
		return nil, "", false
	}
	c, err := r.Cookie(authz.CookieName)
	if err != nil {
		return nil, "", false
	}
	return s.personSessionValue(c.Value)
}

// personSessionTicket is personSession that also takes a read-only console
// ticket's session (task T844) — for the gate's two doors only (personAdmit,
// sshRelayHTTPIdentity), which hold it to reads. Everywhere else such a
// cookie reads as no session at all.
func (s *Server) personSessionTicket(r *http.Request) (*authz.Session, string, bool) {
	if !s.signinOn() {
		return nil, "", false
	}
	c, err := r.Cookie(authz.CookieName)
	if err != nil {
		return nil, "", false
	}
	return s.personSessionAny(c.Value, true)
}

// personSessionValue verifies one session value — a cookie's, or a CLI's
// bearer (sshRelayHTTPIdentity) — and reads the person out of it: the
// session's UID is their principal, its Sub the way they signed in
// (claude-fleet#3603). A cookie from before says Sub "github" and UID
// gh:<id> — exactly a GitHub sign-in's today, so it reads as one.
func (s *Server) personSessionValue(v string) (*authz.Session, string, bool) {
	return s.personSessionAny(v, false)
}

// personSessionAny is personSessionValue; ro says a read-only ticket's
// session (authz.Session.RO) is taken too.
func (s *Server) personSessionAny(v string, ro bool) (*authz.Session, string, bool) {
	if !s.signinOn() || v == "" {
		return nil, "", false
	}
	sess, err := authz.VerifySession(v, s.sessionKey(), time.Now())
	if err != nil || !store.SignInKind(sess.Sub) || !isPerson(sess.UID) || (sess.RO && !ro) {
		return nil, "", false
	}
	// Cut off with «sign out everywhere» (claude-fleet#3701): a value signed
	// at or before the person's cut-off is worth nothing. A list that cannot
	// be read admits no one, like personRole.
	if s.Store != nil {
		if nb, err := s.Store.SessionCutoff(sess.UID); err != nil || (nb > 0 && sess.Iat <= nb) {
			return nil, "", false
		}
		// Revoked by 退出 (task J091): every value of that browser's sign-in.
		if sess.Sid != "" {
			if gone, err := s.Store.SessionRevoked(sess.Sid); err != nil || gone {
				return nil, "", false
			}
		}
	}
	return sess, sess.UID, true
}

// personAdmit is viewerOnly's signed-in-person branch: ok=false when r
// carries no person's session (the gate goes on to its other doors);
// handled=true when it answered the request itself (a refusal or an error).
func (s *Server) personAdmit(w http.ResponseWriter, r *http.Request) (ctx context.Context, ok, handled bool) {
	sess, pid, ok := s.personSessionTicket(r)
	if !ok {
		return nil, false, false
	}
	role, err := s.personRole(pid)
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
	if role == roleTrial && !trialRoute(r.URL.Path) {
		// A trial person reaches the chat, their trial and /apply only
		// (claude-fleet#4058): everything else is an unknown address.
		s.notFoundPage(w, r)
		return nil, true, true
	}
	if sess.RO {
		// A read-only console ticket (task T844): the person's own pages,
		// reads only, never an admin's, never renewed, never a view.
		return s.consoleTicketAdmit(w, r, sess, role)
	}
	s.slideSession(w, r, sess, role)
	if role == roleAdmin {
		// 以他的视角看 (claude-fleet#3944): an admin's own session only.
		if target := viewAsAsked(r); target != "" {
			if ctx, ok, handled := s.viewAsAdmit(w, r, sess, target); ok || handled {
				return ctx, ok, handled
			}
		}
	}
	sub := sess.Principal()
	ctx = context.WithValue(withViewer(r.Context(), sub), principalKey{}, sub)
	ctx = withRole(withDoor(withSession(ctx, sess), doorGitHub), role)
	return ctx, true, false
}

// slideSession re-signs a person's cookie once less than sessionSlide of its
// life is left (claude-fleet#3701): a browser in use never reaches the end of
// its 24 hours, one left alone for a day signs in again. Only the cookie the
// browser sent — a CLI's bearer is not re-issued here.
func (s *Server) slideSession(w http.ResponseWriter, r *http.Request, sess *authz.Session, role string) {
	c, err := r.Cookie(authz.CookieName)
	if err != nil || c.Value == "" {
		return
	}
	now := time.Now()
	ttl := s.sessionTTL()
	if time.Unix(sess.Exp, 0).Sub(now) >= time.Duration(float64(ttl)*sessionSlide) {
		return
	}
	sid := sess.Sid
	if sid == "" {
		sid = authz.NewSid()
	}
	http.SetCookie(w, s.sidCookie(r, sid, sess.Sub, sess.UID, sess.Name, role, now))
}

// personCookie is the session cookie for a person signed in by kind: a new
// sign-in, so a new Sid.
func (s *Server) personCookie(r *http.Request, kind, pid, name, role string, now time.Time) *http.Cookie {
	return s.sidCookie(r, authz.NewSid(), kind, pid, name, role, now)
}

// sidCookie is personCookie for the sign-in sid.
func (s *Server) sidCookie(r *http.Request, sid, kind, pid, name, role string, now time.Time) *http.Cookie {
	return &http.Cookie{
		Name:  authz.CookieName,
		Value: authz.SignSid(sid, kind, pid, name, role, s.sessionKey(), now, s.sessionTTL()),
		Path:  "/",
		// Host-only: no Domain.
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   isHTTPS(r),
		MaxAge:   int(s.sessionTTL().Seconds()),
	}
}

// handleSignin is the sign-in page. Public: it is the way in.
func (s *Server) handleSignin(w http.ResponseWriter, r *http.Request) {
	if !s.signinOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	// Already in: the page has nothing to offer.
	if _, pid, ok := s.personSession(r); ok {
		if role, err := s.personRole(pid); err == nil && role != "" {
			http.Redirect(w, r, AppPrefix, http.StatusFound)
			return
		}
	}
	if s.otherWaysOn() {
		e, step := r.URL.Query().Get("e"), r.URL.Query().Get("step")
		// WeChat's own browser signs in by the service account, no scan:
		// straight there, unless the page has something to say.
		if inWeChat(r) && (s.WeChat.mpReady() || s.wxRelayOn()) && e == "" && step == "" {
			http.Redirect(w, r, "/auth/wechat/start", http.StatusFound)
			return
		}
		loc := s.pageLocale(w, r)
		if s.wxScanOn() && step == "" {
			// The service account's code up front, the rest folded
			// (claude-fleet#4054).
			if d := s.githubDownNote(); e == "" && s.githubDown(time.Now()) {
				e = d
			}
			s.renderSigninScan(w, r, loc, e)
			return
		}
		note := ""
		if signinNotes[e] || signinWayNotes[e] {
			note = pageT(loc, "signin.note."+e)
		} else if d := s.githubDownNote(); e == "" && d != "" && s.githubDown(time.Now()) {
			note = pageT(loc, "signin.note."+d)
		}
		s.renderSigninWays(w, r, loc, note)
		return
	}
	loc := s.pageLocale(w, r)
	page := signinPage{pageView: newPageView(r, loc), Apply: toApply(r)}
	if e := r.URL.Query().Get("e"); signinNotes[e] {
		page.Note = pageT(loc, "signin.note."+e)
	}
	writeAuthPage(w, http.StatusOK, signinTmpl, loc, page)
}

// signinNotes are the only things /signin?e= can say: a fixed set, so the
// page never reflects a query string. Each one's words are pageText's
// signin.note.<e>.
var signinNotes = map[string]bool{"expired": true, "cancelled": true, "github": true}

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
	f := githubFlow{State: state, Verifier: verifier, Exp: time.Now().Add(githubFlowTTL).Unix()}
	if r.URL.Query().Get("link") == "1" {
		// 登录方式 · 加 GitHub (claude-fleet#3603): the account this comes
		// back with is hung on the person signed in now, not signed in as.
		if _, pid, ok := s.personSession(r); ok {
			f.Link = pid
		}
	}
	flow, _ := json.Marshal(f)
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
	// Link is the person a ?link=1 start was made by: the GitHub account
	// is added to them (githubLink) instead of signing anyone in.
	Link string `json:"l,omitempty"`
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
		http.Redirect(w, r, appURL("/signin")+"?e=cancelled", http.StatusFound)
		return
	}
	state, code := q.Get("state"), q.Get("code")
	if flow.State == "" || flow.Exp < time.Now().Unix() || state == "" || code == "" ||
		!constantTimeEqual(state, flow.State) {
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	id, login, err := s.githubWho(r.Context(), code, flow.Verifier, s.githubCallbackURL(r))
	now := time.Now()
	s.githubSaw(err, now)
	if err != nil {
		log.Printf("github sign-in: %v", err)
		e := "github"
		if d := s.githubDownNote(); d != "" && githubUnreachable(err) {
			e = d // GitHub cannot be reached: say which other way works
		}
		http.Redirect(w, r, appURL("/signin")+"?e="+e, http.StatusFound)
		return
	}
	if flow.Link != "" {
		// Still the same person, still on the list — else it is an ordinary
		// sign-in.
		if _, pid, ok := s.personSession(r); ok && pid == flow.Link {
			if role, err := s.personRole(pid); err == nil && role != "" {
				http.Redirect(w, r, s.githubLink(pid, id, login, now), http.StatusFound)
				return
			}
		}
	}
	invite := s.takeInviteCookie(w, r)
	principal, role, refusal, err := s.githubAdmitSignIn(id, login, now, invite)
	if err != nil {
		log.Printf("github sign-in of %s (%d): %v", login, id, err)
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	if role == "" && refusal == denyNotListed &&
		s.trialSignIn(w, r, s.trialAsked(r), store.IdentityGitHub, fmt.Sprint(id), login, principal, now) {
		return // on its way to a trial (claude-fleet#4058)
	}
	if role == "" {
		if notListed(refusal) {
			// Nobody named them yet: not a dead end, the way to ask
			// (claude-fleet#4050).
			s.notListedSignIn(w, r, store.IdentityGitHub, fmt.Sprint(id), login, now)
			return
		}
		// A `fleet login` is waiting on this browser: its terminal hears the
		// refusal too, in the same words, instead of waiting ten minutes.
		if to := s.loginRefusedHop(w, r, refusal, login, now); to != "" {
			http.Redirect(w, r, to, http.StatusFound)
			return
		}
		s.githubDeny(w, r, refusal, login)
		return
	}
	http.SetCookie(w, s.personCookie(r, store.IdentityGitHub, principal, login, role, now))
	// The first sign-in records the person and places their logins: the
	// machine login an admin set for them (claude-fleet#1986), adopted on
	// every machine that runs it.
	s.onPrincipalSignIn(principal, login)
	// A `fleet login` code scanned while signed out comes back to its
	// confirmation page; everything else goes to the console — once, for
	// someone whose only way in is GitHub, to 登录方式 (claude-fleet#4849).
	to := loginReturn(w, r)
	if to == AppPrefix && s.addWayNudge(principal, now) {
		to = settingsBack("add-way")
	}
	http.Redirect(w, r, to, http.StatusFound)
}

// The refusals, as the 403 page words them.
const (
	denyNotListed = "not-listed"
	denyRenamed   = "renamed"
	denyRemoved   = "removed"
	// denyInvitePrefix + an invite reason (store.Invite*): the invite the
	// sign-in carried cannot be used (claude-fleet#2261).
	denyInvitePrefix = "invite-"
)

// githubAdmitSignIn decides a sign-in by GitHub ID and username, pins the
// name the first time it is seen, and audits the outcome. The person is the
// one whose github identity the ID is, else gh:<id> (claude-fleet#3603).
// role "" is a refusal, named by refusal. invite is the code the sign-in
// carried (claude-fleet#2261), "" for none: it lets in a person the list does
// not name yet, and is never spent on one it does.
func (s *Server) githubAdmitSignIn(id int64, login string, now time.Time, invite string) (pid, role, refusal string, err error) {
	pid, err = s.githubPersonOf(id)
	if err != nil {
		return "", "", "", err
	}
	role, refusal, err = s.githubAdmitAs(pid, id, login, now, invite)
	return pid, role, refusal, err
}

func (s *Server) githubAdmitAs(actor string, id int64, login string, now time.Time, invite string) (role, refusal string, err error) {
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
	role, err = s.personRole(actor)
	if err != nil {
		return "", "", err
	}
	if role == "" && invite != "" {
		if refusal, err := s.admitInviteAs(actor, store.IdentityGitHub, fmt.Sprint(id), login, invite, now); err != nil || refusal != "" {
			return "", refusal, err
		}
		role = roleUser
	}
	if role == "" {
		_ = s.Store.HubAudit(actor, "signin", target, "refused", notListedAudit, now)
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
		if err := s.recordAdminAs(actor, id, login, now); err != nil {
			return "", "", err
		}
	}
	if err := s.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityGitHub, Subject: fmt.Sprint(id),
		PrincipalID: actor, VerifiedAt: now, AddedBy: "signin"}); err != nil {
		return "", "", err
	}
	if _, isGH := githubIDOf(actor); isGH {
		err = s.Store.TouchHubUser(id, login, now)
	} else {
		// Someone who came in another way and hung GitHub on: their name
		// on the list is theirs, not GitHub's.
		err = s.Store.TouchHubPrincipal(actor, "", now)
	}
	if err != nil {
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

// recordAdmin keeps a GitHub admin's row on the list, for the people page:
// the deploy decides who is admin (personRole), the row records them.
func (s *Server) recordAdmin(id int64, login string, now time.Time) error {
	pid, err := s.githubPersonOf(id)
	if err != nil {
		return err
	}
	return s.recordAdminAs(pid, id, login, now)
}

// recordAdminAs is recordAdmin for the person pid; id is their GitHub ID, 0
// for none.
func (s *Server) recordAdminAs(pid string, id int64, login string, now time.Time) error {
	u, err := s.Store.HubUserByPrincipal(pid)
	if err != nil {
		return err
	}
	row := store.HubUser{PrincipalID: pid, Login: login, Role: roleAdmin, AddedBy: "deploy", AddedAt: now}
	if gid, ok := githubIDOf(pid); ok && gid == id {
		row.GitHubID = id
	}
	if u != nil {
		if u.Role == roleAdmin && (u.Login == login || login == "") {
			return nil
		}
		row.MachineLogin, row.AddedBy, row.AddedAt = u.MachineLogin, u.AddedBy, u.AddedAt
		if _, isGH := githubIDOf(pid); login == "" || !isGH {
			row.Login = u.Login // a name they chose is theirs, not GitHub's
		}
	}
	return s.Store.AdmitHubUser(row)
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
		s.githubSaw(err, time.Now())
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
	tok, err := s.githubExchange(ctx, form)
	if err != nil {
		return 0, "", err
	}
	return s.githubUser(ctx, "/user", tok)
}

// githubExchange posts the token exchange: through the relay first when
// one is set, then github.com directly once. An answer from GitHub — a token
// or an error code — ends it; only a relay that cannot be asked (no answer,
// or one of its own refusals) is retried directly. The access token is
// returned, never logged.
func (s *Server) githubExchange(ctx context.Context, form url.Values) (string, error) {
	g := s.GitHub
	if !g.viaRelay() {
		tok, _, err := g.postToken(ctx, g.tokenURL(), "", form)
		return tok, err
	}
	relayURL := strings.TrimRight(g.RelayURL, "/") + relayGitHubTokenPath
	pass, err := g.RelayPass()
	if err == nil {
		rctx, cancel := context.WithTimeout(ctx, durOr(g.RelayTimeout, githubRelayTimeout))
		var answered bool
		var tok string
		tok, answered, err = g.postToken(rctx, relayURL, pass, form)
		cancel()
		if answered {
			if err == nil {
				log.Printf("github sign-in: token exchanged through the relay %s", g.RelayURL)
			}
			return tok, err
		}
	}
	log.Printf("github sign-in: relay %s: %v — trying github.com directly", g.RelayURL, err)
	dctx, cancel := context.WithTimeout(ctx, durOr(g.DirectTimeout, githubDirectTimeout))
	defer cancel()
	tok, _, err := g.postToken(dctx, g.tokenURL(), "", form)
	return tok, err
}

// postToken is one token-exchange POST. answered is true when GitHub itself
// answered (HTTP 200 and its JSON) — a token or an error code; false for
// anything that never reached it: no connection, a timeout, any non-200 (the
// relay's own 403/404/5xx).
func (g *GitHubAuth) postToken(ctx context.Context, to, pass string, form url.Values) (tok string, answered bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, to, strings.NewReader(form.Encode()))
	if err != nil {
		return "", false, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	if pass != "" {
		req.Header.Set(RelayHeader, pass)
	}
	resp, err := g.client().Do(req)
	if err != nil {
		return "", false, fmt.Errorf("token exchange: %w", err)
	}
	var out struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	derr := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// GitHub answers the exchange with 200, even for a bad code; anything
		// else is not its answer (the relay's 403, a 502, …).
		return "", false, errors.New(strings.TrimSpace(fmt.Sprintf("token exchange: HTTP %d %s", resp.StatusCode, out.Error)))
	}
	if derr != nil {
		return "", false, fmt.Errorf("token exchange: HTTP %d, unreadable answer", resp.StatusCode)
	}
	if out.AccessToken == "" {
		// The error code only (bad_verification_code, …): the description
		// can echo request details.
		return "", true, fmt.Errorf("token exchange: HTTP %d, %s", resp.StatusCode, orDefault(out.Error, "no token"))
	}
	return out.AccessToken, true, nil
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
// browser, a JSON 403 for anything else. No session is created. Since
// claude-fleet#4050 it is only for a real refusal — removed, renamed, an
// invite that cannot be used; nobody-named-you is notListedSignIn.
func (s *Server) githubDeny(w http.ResponseWriter, r *http.Request, why, login string) {
	if !wantsHTML(r) {
		httpError(w, http.StatusForbidden, "this GitHub account is not on this hub's list")
		return
	}
	loc := s.pageLocale(w, r)
	page := denyPage{pageView: newPageView(r, loc), Why: why, Login: login}
	writeAuthPage(w, http.StatusForbidden, denyTmpl, loc, page)
}

// denyText is a refusal as one plain sentence, for a terminal: the same
// words as the page, with nothing bolded. hub is this hub's address: a
// person nobody named is told where to apply (claude-fleet#4050).
func denyText(loc, why, login, hub string) string {
	if notListed(why) {
		return i18n.Interpolate(pageT(loc, "deny.notlisted.cli"), map[string]string{"url": hub + ApplyPath})
	}
	key := "deny.notlisted"
	switch why {
	case denyRenamed:
		key = "deny.renamed"
	case denyRemoved:
		key = "deny.removed"
	default:
		if r, ok := strings.CutPrefix(why, denyInvitePrefix); ok {
			if _, known := pageText["deny.invite."+r]; known {
				key = "deny.invite." + r
			}
		}
	}
	return i18n.Interpolate(pageT(loc, key), map[string]string{"v": login})
}

// notListed: the refusal is "nobody has invited you" — denyNotListed, or no
// reason at all, which the page words the same way.
func notListed(why string) bool { return why == denyNotListed || why == "" }

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

func writeAuthPage(w http.ResponseWriter, status int, t *template.Template, loc string, data any) {
	entryHeaders(w, loc)
	w.Header().Add("Vary", "Accept-Language, Cookie")
	w.WriteHeader(status)
	if c, err := t.Clone(); err == nil {
		_ = c.Funcs(pageFuncs(loc)).Execute(w, data)
	}
}

type signinPage struct {
	pageView
	// Note is one of signinNotes, or "".
	Note string
	// Apply: the person came to apply (?next=/apply, claude-fleet#4049).
	Apply bool
}

type denyPage struct {
	pageView
	Why   string
	Login string
	// Heading replaces the GitHub heading for a way that is not GitHub
	// (claude-fleet#3604).
	Heading string
}

// The sign-in and refusal pages are way-in pages (entry_pages.go): the
// theme, the header, one column.
const authPageHead = entryHead

var signinTmpl = template.Must(template.New("signin").Funcs(pageFuncs(i18n.EN)).Parse(authPageHead + `
<title>{{t "signin.title"}}</title></head><body><div class="page">` + entryTop + `
<main class="col">` + limitedPill + `<h1>{{t "signin.h1"}}<span class="dot">.</span></h1><p class="lead">{{if .Apply}}{{t "signin.lead.apply"}}{{else}}{{t "signin.lead"}}{{end}}</p>
{{if .Note}}<p class="alert" role="status">` + alertIcon + `<span>{{.Note}}</span></p>{{end}}
<a class="btn primary" href="/auth/github/start">` + gitIcon + `{{t "signin.button"}}</a>
<p class="fine">{{t "signin.fine"}}</p>
</main></div></body></html>`))

var denyTmpl = template.Must(template.New("deny").Funcs(pageFuncs(i18n.EN)).Parse(authPageHead + `
<title>{{t "deny.title"}}</title></head><body><div class="page">` + entryTop + `
<main class="col"><div class="tile">` + lockIcon + `</div>
<h1>{{if .Heading}}{{.Heading}}{{else}}{{t "deny.h1"}}{{end}}<span class="dot">.</span></h1>
<p class="lead">{{if eq .Why "renamed"}}{{tb "deny.renamed" .Login}}{{else if eq .Why "removed"}}{{tb "deny.removed" .Login}}{{else if eq .Why "invite-expired"}}{{tb "deny.invite.expired" .Login}}{{else if eq .Why "invite-used"}}{{tb "deny.invite.used" .Login}}{{else if eq .Why "invite-revoked"}}{{tb "deny.invite.revoked" .Login}}{{else if eq .Why "invite-unknown"}}{{tb "deny.invite.unknown" .Login}}{{else if eq .Why "invite-other-user"}}{{tb "deny.invite.other-user" .Login}}{{else}}{{tb "deny.notlisted" .Login}}{{end}}</p>
<div class="stack"><a class="btn primary" href="/app/signin">{{t "deny.another"}}</a><a class="btn ghost" href="/app">{{t "deny.back"}}</a></div>
<p class="fine">{{t "deny.fine"}}</p>
</main></div></body></html>`))
