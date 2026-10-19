package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4849 (EPIC #4839 C10): GitHub down is not the hub's door shut.

// deadURL is an address nothing answers: connection refused.
func deadURL(t *testing.T) string {
	t.Helper()
	ts := httptest.NewServer(http.NotFoundHandler())
	u := ts.URL
	ts.Close()
	return u
}

// withEmail turns the mail way in on: the hub then has a way that is not GitHub.
func withEmail(s *Server) {
	s.Email = &EmailAuth{Send: func(context.Context, string, string, string) error { return nil }}
}

// githubGone points the hub's GitHub at nothing.
func (h *ghHarness) githubGone(t *testing.T) {
	t.Helper()
	dead := deadURL(t)
	h.srv.GitHub.TokenURL, h.srv.GitHub.APIBase = dead+"/login/oauth/access_token", dead
}

func (h *ghHarness) page(t *testing.T, path string) string {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	req.Header.Set("Accept", "text/html")
	req.Header.Set("Accept-Language", "en")
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}

// A callback whose GitHub cannot be reached sends the browser back to
// /signin saying which other way works; the page keeps saying it beside the
// GitHub button until GitHub answers again.
func TestGitHubDown_SigninNamesTheOtherWay(t *testing.T) {
	h := newGitHubHarnessWith(t, withEmail, "ivan")
	h.addUser(t, ghAlice)
	h.githubGone(t)
	cb, sess := h.signIn(t, ghAlice)
	if sess != nil && sess.MaxAge >= 0 {
		t.Fatalf("signed in with GitHub unreachable: %+v", sess)
	}
	if loc := cb.Header.Get("Location"); cb.StatusCode != http.StatusFound || loc != "/app/signin?e=github-down-email" {
		t.Fatalf("callback = %d → %q; want /app/signin?e=github-down-email", cb.StatusCode, loc)
	}
	const words = "GitHub sign-in isn't available right now — sign in with email instead."
	if body := h.page(t, "/app/signin?e=github-down-email"); !strings.Contains(body, "sign in with email instead") {
		t.Errorf("signin?e=github-down-email does not say %q:\n%s", words, body)
	}
	if body := h.page(t, "/app/signin"); !strings.Contains(body, "sign in with email instead") {
		t.Errorf("plain /signin while GitHub is down does not say it")
	}
	if got := pageT("zh-CN", "signin.note.github-down"); got != "GitHub 登录暂时不可用，用邮箱或微信登录。" {
		t.Errorf("zh words = %q", got)
	}
	// GitHub back: the next answer clears the mark at once.
	h.srv.GitHub.TokenURL, h.srv.GitHub.APIBase = h.gh.srv.URL+"/login/oauth/access_token", h.gh.srv.URL
	if cb, sess := h.signIn(t, ghAlice); sess == nil || cb.StatusCode != http.StatusFound {
		t.Fatalf("GitHub back: sign-in = %d", cb.StatusCode)
	}
	if body := h.page(t, "/app/signin"); strings.Contains(body, "isn't available right now") {
		t.Errorf("GitHub answers again, /signin still says it is down")
	}
}

// A hub with GitHub its only way in keeps its old words: nothing else to name.
func TestGitHubDown_GitHubOnlyHubUnchanged(t *testing.T) {
	h := newGitHubHarness(t, "ivan")
	h.addUser(t, ghAlice)
	h.githubGone(t)
	cb, _ := h.signIn(t, ghAlice)
	if loc := cb.Header.Get("Location"); loc != "/app/signin?e=github" {
		t.Fatalf("callback → %q; want /app/signin?e=github", loc)
	}
	if body := h.page(t, "/app/signin"); strings.Contains(body, "isn't available right now") {
		t.Errorf("a GitHub-only hub's /signin changed")
	}
}

// An admin the deploy names, pinned once, stays admin through a restart
// whose GitHub cannot be reached: start-up asks GitHub only for names never
// pinned.
func TestGitHubDown_PinnedAdminSurvivesRestart(t *testing.T) {
	h := newGitHubHarness(t, "ivan", "ghost")
	h.gh.public["ivan"] = ghAdmin
	h.srv.ResolveGitHubAdmins(context.Background())
	_, sess := h.signIn(t, ghAdmin)
	if sess == nil {
		t.Fatal("admin did not sign in")
	}
	// The restart: a new hub on the same database, GitHub gone.
	dead := deadURL(t)
	srv := &Server{Store: h.srv.Store, Pricing: pricing.Default(), ViewerToken: viewerToken, LiveStore: NewLive(),
		GitHub: &GitHubAuth{ClientID: "Iv1.test", ClientSecret: "shh", Admins: []string{"ivan", "ghost"},
			AuthorizeURL: dead + "/login/oauth/authorize", TokenURL: dead + "/login/oauth/access_token", APIBase: dead}}
	srv.ResolveGitHubAdmins(context.Background())
	if id, ok, _ := srv.Store.PinnedID("ivan"); !ok || id != ghAdmin.ID {
		t.Fatalf("ivan's pin after the restart = %d %v", id, ok)
	}
	if role, err := srv.personRole(githubPrincipal(ghAdmin.ID)); err != nil || role != roleAdmin {
		t.Fatalf("ivan after the restart = %q %v; want admin", role, err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	h2 := &ghHarness{srv: srv, http: ts, gh: h.gh}
	if code, me := h2.me(t, sess); code != http.StatusOK || me.Role != roleAdmin {
		t.Fatalf("ivan's session after the restart = %d %q; want 200 admin", code, me.Role)
	}
	if c := srv.signInCount(); c == nil || c.AdminsUnpinned != 1 {
		t.Errorf("signInCount = %+v; want ghost unpinned", c)
	}
}

// Adding someone by GitHub name with GitHub unreachable: 503 and the way
// round it, never a blank 502.
func TestGitHubDown_UsersAddSays503(t *testing.T) {
	h := newUsersHarness(t)
	h.githubGone(t)
	code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"alice"}`, nil)
	if code != http.StatusServiceUnavailable {
		t.Fatalf("add with GitHub gone = %d %v; want 503", code, body)
	}
	if msg, _ := body["error"].(string); !strings.Contains(msg, "GitHub 不通，改用邮箱邀请") {
		t.Errorf("error = %q; want it to say 改用邮箱邀请", msg)
	}
	if users, _ := h.srv.Store.HubUsers(); len(users) != 0 {
		t.Errorf("someone was added: %+v", users)
	}
}

// Someone whose only way in is GitHub is sent to 登录方式 once, after a
// sign-in that worked; never again, and never someone with a second way.
func TestGitHubDown_AddWayNudgedOnce(t *testing.T) {
	h := newGitHubHarnessWith(t, withEmail, "ivan")
	h.addUser(t, ghAlice)
	h.addUser(t, ghMallory)
	if n, err := h.srv.Store.HubGitHubOnly(); err != nil || n != 2 {
		t.Fatalf("HubGitHubOnly = %d %v; want 2", n, err)
	}
	cb, sess := h.signIn(t, ghAlice)
	if sess == nil || cb.Header.Get("Location") != "/app/settings?e=add-way#logins" {
		t.Fatalf("first sign-in → %q; want the 登录方式 card", cb.Header.Get("Location"))
	}
	if cb, _ := h.signIn(t, ghAlice); cb.Header.Get("Location") != "/app" {
		t.Errorf("second sign-in → %q; want /app (once only)", cb.Header.Get("Location"))
	}
	// mallory has an address too: no nudge, and not counted.
	pid := githubPrincipal(ghMallory.ID)
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "m@example.com",
		PrincipalID: pid, VerifiedAt: time.Now(), AddedBy: "test"}); err != nil {
		t.Fatal(err)
	}
	if cb, _ := h.signIn(t, ghMallory); cb.Header.Get("Location") != "/app" {
		t.Errorf("mallory (two ways) → %q; want /app", cb.Header.Get("Location"))
	}
	if n, _ := h.srv.Store.HubGitHubOnly(); n != 1 {
		t.Errorf("HubGitHubOnly = %d; want 1 (alice)", n)
	}
	if c := h.srv.signInCount(); c == nil || c.GitHubOnly != 1 {
		t.Errorf("signInCount = %+v", c)
	}
}

// A GitHub-only hub nudges nobody: there is no other way to add.
func TestGitHubDown_NoNudgeWithoutAnotherWay(t *testing.T) {
	h := newGitHubHarness(t, "ivan")
	h.addUser(t, ghAlice)
	if cb, _ := h.signIn(t, ghAlice); cb.Header.Get("Location") != "/app" {
		t.Errorf("→ %q; want /app", cb.Header.Get("Location"))
	}
}
