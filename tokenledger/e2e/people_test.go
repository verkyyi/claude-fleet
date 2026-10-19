package e2e

import (
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"

	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// enablePeople turns GitHub sign-in on and puts principals on the list as
// users, so personCookie / asSession for them are admitted.
func enablePeople(t *testing.T, h *harness, principals ...string) {
	t.Helper()
	if h.Srv.GitHub == nil {
		h.Srv.GitHub = &GitHubAuth{ClientID: "Iv1.test", ClientSecret: testGitHubSecret}
	}
	for _, p := range principals {
		listPerson(t, h, p, "")
	}
}

// listPerson adds principal (gh:<id>, or p:<uuid>) to the list as a user
// named login. A p: person already on the list keeps their row.
func listPerson(t *testing.T, h *harness, principal, login string) {
	t.Helper()
	id, ok := GitHubIDOfForTest(principal)
	if !ok {
		if !IsPersonForTest(principal) {
			t.Fatalf("%q is not a person's principal", principal)
		}
		if u, _ := h.Srv.Store.HubUserByPrincipal(principal); u != nil {
			return
		}
		if login == "" {
			login = "person"
		}
		if err := h.Srv.Store.UpsertHubUser(store.HubUser{PrincipalID: principal, Login: login, Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
		return
	}
	if login == "" {
		login = "user" + strconv.FormatInt(id, 10)
	}
	if err := h.Srv.Store.UpsertHubUser(store.HubUser{GitHubID: id, Login: login, Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
}

// personCookie is that session as the browser presents it.
func personCookie(principal, name string) *http.Cookie {
	return &http.Cookie{Name: authz.CookieName, Value: personSession(principal, name)}
}

const testGitHubSecret = "dev-only-test-github-client-secret"

// personSession is the session value GitHub sign-in mints for principal.
func personSession(principal, name string) string {
	return authz.SignRole(store.IdentityGitHub, principal, name, RoleUserForTest,
		(&GitHubAuth{ClientSecret: testGitHubSecret}).SessionKeyForTest(), time.Now(), time.Hour)
}
