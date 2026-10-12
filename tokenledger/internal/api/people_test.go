package api

import (
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// People in tests sign in the one way a person can: GitHub (claude-fleet#1984).
// A person is gh:<GitHub ID>, on the hub's list as a user.

// The people the fleet tests act as.
const (
	pAlice = "gh:1001"
	pBob   = "gh:1002"
	pCarol = "gh:1003"
	pGhost = "gh:1099" // never on the list
)

const testGitHubSecret = "dev-only-test-github-client-secret"

// enablePeople turns GitHub sign-in on and puts principals on the list as
// users, so personCookie / asSession for them are admitted.
func enablePeople(t *testing.T, h *harness, principals ...string) {
	t.Helper()
	if h.srv.GitHub == nil {
		h.srv.GitHub = &GitHubAuth{ClientID: "Iv1.test", ClientSecret: testGitHubSecret}
	}
	for _, p := range principals {
		listPerson(t, h, p, "")
	}
}

// listPerson adds principal (gh:<id>, or p:<uuid>) to the list as a user
// named login. A p: person already on the list keeps their row.
func listPerson(t *testing.T, h *harness, principal, login string) {
	t.Helper()
	id, ok := githubIDOf(principal)
	if !ok {
		if !isPerson(principal) {
			t.Fatalf("%q is not a person's principal", principal)
		}
		if u, _ := h.srv.Store.HubUserByPrincipal(principal); u != nil {
			return
		}
		if login == "" {
			login = "person"
		}
		if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: principal, Login: login, Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
		return
	}
	if login == "" {
		login = "user" + strconv.FormatInt(id, 10)
	}
	if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: id, Login: login, Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
}

// personSession is the session value GitHub sign-in mints for principal.
func personSession(principal, name string) string {
	return authz.SignRole(store.IdentityGitHub, principal, name, roleUser,
		(&GitHubAuth{ClientSecret: testGitHubSecret}).sessionKey(), time.Now(), time.Hour)
}

// personCookie is that session as the browser presents it.
func personCookie(principal, name string) *http.Cookie {
	return &http.Cookie{Name: authz.CookieName, Value: personSession(principal, name)}
}

// raw makes a request that does NOT follow redirects and carries no cookie jar,
// so each test says exactly which credential it is presenting.
func (h *harness) raw(t *testing.T, path string, hdr map[string]string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	c := *h.http.Client()
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}
