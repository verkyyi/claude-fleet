package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A person is their (machine, login) pairs, never a login name
// (claude-fleet#2514): two machines each have a login `ubuntu`, belonging to
// two people — each sees only their own machine's sessions, usage and live
// rows, and the person with `ubuntu` on two machines sees both.

var (
	ghBob   = fakeGHUser{ID: 400, Login: "bob"}
	ghCarol = fakeGHUser{ID: 500, Login: "carol"}
)

func pairsHarness(t *testing.T) (h *ghHarness, bob, carol *http.Cookie) {
	t.Helper()
	h = newGitHubHarnessWith(t, fullServer, "verkyyi")
	now := time.Now()
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	ingest := func(ep, host, sid string) {
		tok, err := MintToken()
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.Enroll(ep, host, HashToken(tok)); err != nil {
			t.Fatal(err)
		}
		body, _ := json.Marshal(model.Batch{Identity: model.Identity{AccountUUID: "acct-a", Email: "a@example.com",
			Hostname: host, OS: "linux", Arch: "arm64", SubscriptionType: "max", OSUser: "ubuntu"},
			AccountOrigin: model.OriginLogin, Events: []model.UsageEvent{{AccountUUID: "acct-a", EndpointID: ep,
				SessionID: sid, MessageUUID: sid, TS: base, Model: "claude-opus-5", OutputTokens: 100,
				CWD: "/p", OSUser: "ubuntu"}}})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("ingest %s: %d", ep, resp.StatusCode)
		}
	}
	ingest("ep_m1", "m1", "s-bob-m1")
	ingest("ep_m2", "m2", "s-carol-m2")
	ingest("ep_m3", "m3", "s-bob-m3")

	// Both people are mapped to the same machine login, the way an admin
	// sets a default user name: before #2514 that name was the whole cut.
	for _, u := range []fakeGHUser{ghBob, ghCarol} {
		h.addUser(t, u)
		if _, err := h.srv.Store.AdoptPrincipal(githubPrincipal(u.ID), u.Login, u.Login, now); err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: u.ID, Login: u.Login,
			Role: store.RoleUser, MachineLogin: "ubuntu", AddedBy: "gh:100"}); err != nil {
			t.Fatal(err)
		}
	}
	own := func(u fakeGHUser, host, ep string) {
		p, err := h.srv.Store.Principal(githubPrincipal(u.ID))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := h.srv.Store.RecordLoginAccount(p, host, "ubuntu", ep, "test", now); err != nil {
			t.Fatal(err)
		}
	}
	own(ghBob, "m1", "ep_m1")
	own(ghCarol, "m2", "ep_m2")
	own(ghBob, "m3", "ep_m3")

	_, bob = h.signIn(t, ghBob)
	_, carol = h.signIn(t, ghCarol)
	if bob == nil || carol == nil {
		t.Fatal("sign-in failed")
	}
	return h, bob, carol
}

func sessionIDs(t *testing.T, h *ghHarness, c *http.Cookie) []string {
	t.Helper()
	var rows []store.SessionRow
	_, b := rolesGet(t, h, c, "/v1/sessions?account=all&since="+rolesSince+"&until="+rolesUntil)
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	ids := []string{}
	for _, r := range rows {
		ids = append(ids, r.SessionID)
	}
	sort.Strings(ids)
	return ids
}

func TestIdentityPairs_SameLoginTwoPeople(t *testing.T) {
	h, bob, carol := pairsHarness(t)

	if got := sessionIDs(t, h, bob); !equalStrings(got, []string{"s-bob-m1", "s-bob-m3"}) {
		t.Errorf("bob /v1/sessions = %v; want his two machines only", got)
	}
	if got := sessionIDs(t, h, carol); !equalStrings(got, []string{"s-carol-m2"}) {
		t.Errorf("carol /v1/sessions = %v; want m2 only", got)
	}
	if code, _ := rolesGet(t, h, carol, "/v1/sessions/s-bob-m1?account=all"); code != http.StatusNotFound {
		t.Errorf("carol opening bob's session = %d; want 404", code)
	}

	var sum struct {
		Events int64 `json:"events"`
	}
	_, b := rolesGet(t, h, carol, "/v1/summary?account=all&since="+rolesSince+"&until="+rolesUntil)
	_ = json.Unmarshal(b, &sum)
	if sum.Events != 1 {
		t.Errorf("carol /v1/summary events = %d; want 1", sum.Events)
	}
	var page struct {
		Turns    int64 `json:"turns"`
		Machines int64 `json:"machines"`
	}
	_, b = rolesGet(t, h, bob, "/v1/user?since="+rolesSince+"&until="+rolesUntil)
	_ = json.Unmarshal(b, &page)
	if page.Turns != 2 || page.Machines != 2 {
		t.Errorf("bob /v1/user = %s; want 2 turns on 2 machines", b)
	}

	// /v1/me lists the pairs the cut is made of.
	var me Me
	_, b = rolesGet(t, h, bob, "/v1/me")
	_ = json.Unmarshal(b, &me)
	t.Logf("bob /v1/me = %s", b)
	want := []store.LoginPair{{Hostname: "m1", Login: "ubuntu"}, {Hostname: "m3", Login: "ubuntu"}}
	if len(me.Logins) != 2 || me.Logins[0] != want[0] || me.Logins[1] != want[1] {
		t.Errorf("bob /v1/me logins = %s; want m1/ubuntu and m3/ubuntu", b)
	}

	// Live: the same name on another machine is not theirs.
	snap := Snapshot{Sessions: []LiveSession{
		{SessionID: "s-bob-m1", EndpointID: "ep_m1", OSUser: "ubuntu", Account: "acct-a"},
		{SessionID: "s-carol-m2", EndpointID: "ep_m2", OSUser: "ubuntu", Account: "acct-a"},
		{SessionID: "s-bob-m3", EndpointID: "ep_m3", OSUser: "ubuntu", Account: "acct-a"},
	}}
	for _, c := range []struct {
		who  fakeGHUser
		want []string
	}{{ghBob, []string{"s-bob-m1", "s-bob-m3"}}, {ghCarol, []string{"s-carol-m2"}}} {
		who, err := h.srv.UserScope(asUser(c.who))
		if err != nil {
			t.Fatal(err)
		}
		got := []string{}
		for _, l := range h.srv.FilterLiveFor(snap, "all", "", who).Sessions {
			got = append(got, l.SessionID)
		}
		if !equalStrings(got, c.want) {
			t.Errorf("%s live = %v; want %v", c.who.Login, got, c.want)
		}
	}

	// The fleet views (fleet_sessions, the roster, …): FleetScope.
	for _, c := range []struct {
		who           fakeGHUser
		host          string
		sees, notSees bool
	}{{ghBob, "m1", true, false}, {ghBob, "m3", true, false}, {ghCarol, "m2", true, false}, {ghCarol, "m1", false, true}, {ghBob, "m2", false, true}} {
		scope, err := h.srv.FleetScope(asUser(c.who))
		if err != nil {
			t.Fatal(err)
		}
		if got := scope(c.host, "ubuntu"); got != c.sees {
			t.Errorf("%s FleetScope(%s, ubuntu) = %v; want %v", c.who.Login, c.host, got, c.sees)
		}
	}
}

// asUser is a request from u signed in as a user (a principal and no admin
// role reads as one, roleOf).
func asUser(u fakeGHUser) *http.Request {
	ctx := context.WithValue(context.Background(), principalKey{}, githubPrincipal(u.ID))
	r, _ := http.NewRequestWithContext(ctx, http.MethodGet, "/", nil)
	return r
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
