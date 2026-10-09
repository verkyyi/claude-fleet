package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

// 我的用量 (claude-fleet#2519): /v1/fleet/person-usage is cut by role — bob
// reads his own standing and his days, never carol's, whatever ?principal=
// says; an admin still reads everyone, and their own with ?mine=1; the
// operator's token is unchanged. The page is in both menus.
func TestPersonUsage_UserReadsOwn(t *testing.T) {
	h := newGitHubHarnessWith(t, fullServer, "verkyyi")
	now := time.Now()
	h.srv.budgetNow = func() time.Time { return now }
	for _, u := range []fakeGHUser{ghBob, ghCarol} {
		h.addUser(t, u)
		if _, err := h.srv.Store.AdoptPrincipal(githubPrincipal(u.ID), u.Login, u.Login, now); err != nil {
			t.Fatal(err)
		}
	}
	bobID, carolID := githubPrincipal(ghBob.ID), githubPrincipal(ghCarol.ID)
	for _, u := range []struct {
		pid string
		n   int64
		at  time.Time
	}{{bobID, 700, now.Add(-time.Hour)}, {bobID, 300, now.Add(-49 * time.Hour)}, {carolID, 9000, now.Add(-time.Hour)}} {
		if err := h.srv.Store.AddPersonUsage(u.pid, "claude", u.n, 1, u.at); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.SetFleetSetting(PersonBudgetPrefix+bobID, "5h=1k,week=2k", now); err != nil {
		t.Fatal(err)
	}
	_, bob := h.signIn(t, ghBob)
	_, admin := h.signIn(t, fakeGHUser{ID: 100, Login: "verkyyi"})

	type answer struct {
		People []PersonBudgetState `json:"people"`
		Days   []PersonUsageDay    `json:"days"`
	}
	read := func(c *http.Cookie, path string) (answer, string) {
		t.Helper()
		code, b := rolesGet(t, h, c, path)
		if code != http.StatusOK {
			t.Fatalf("%s: HTTP %d %s", path, code, b)
		}
		var a answer
		if err := json.Unmarshal(b, &a); err != nil {
			t.Fatalf("%v: %s", err, b)
		}
		return a, string(b)
	}

	for _, path := range []string{"/v1/fleet/person-usage", "/v1/fleet/person-usage?principal=" + carolID, "/v1/fleet/person-usage?mine=1"} {
		a, raw := read(bob, path)
		if len(a.People) != 1 || a.People[0].Principal != bobID || a.People[0].Used5h != 700 ||
			a.People[0].UsedWeek != 1000 || a.People[0].Limit5h != 1000 || a.People[0].LimitWeek != 2000 {
			t.Errorf("bob %s = %s; want his own standing", path, raw)
		}
		if strings.Contains(raw, carolID) || strings.Contains(raw, "9000") {
			t.Errorf("bob %s carries carol: %s", path, raw)
		}
		var sum int64
		for _, d := range a.Days {
			sum += d.Tokens
		}
		if len(a.Days) != 7 || sum != 1000 || a.Days[6].Day != now.UTC().Format("2006-01-02") {
			t.Errorf("bob %s days = %+v; want 7 days ending today, 1000 in all", path, a.Days)
		}
	}

	// An admin keeps the list; their own is ?mine=1.
	if a, raw := read(admin, "/v1/fleet/person-usage"); len(a.People) != 2 {
		t.Errorf("admin list = %s; want bob and carol", raw)
	}
	if a, raw := read(admin, "/v1/fleet/person-usage?mine=1"); len(a.People) != 1 || a.People[0].Principal == bobID ||
		a.People[0].Principal == carolID || a.People[0].UsedWeek != 0 {
		t.Errorf("admin mine = %s; want their own, empty", raw)
	}
	// The operator's door: everyone, as before; asking for its own is nobody.
	operator := func(path string) (int, answer) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var a answer
		_ = json.NewDecoder(resp.Body).Decode(&a)
		return resp.StatusCode, a
	}
	if st, a := operator("/v1/fleet/person-usage"); st != 200 || len(a.People) != 2 {
		t.Errorf("operator list: %d %+v", st, a)
	}
	if st, a := operator("/v1/fleet/person-usage?mine=1"); st != 200 || len(a.People) != 0 {
		t.Errorf("operator mine: %d %+v", st, a)
	}

	// The page, and the menu entry.
	if routeAccess["/usage"] != accessUser || routeAccess["/v1/fleet/person-usage"] != accessUser {
		t.Errorf("/usage %v, person-usage %v; want both a user's", routeAccess["/usage"], routeAccess["/v1/fleet/person-usage"])
	}
	h.srv.UI = fstest.MapFS{
		"usage.html": &fstest.MapFile{Data: []byte("<!doctype html><title>我的用量</title>")},
		"index.html": &fstest.MapFile{Data: []byte("<!doctype html><title>dashboard</title>")},
	}
	if code, b := rolesGet(t, h, bob, "/usage"); code != http.StatusOK || !strings.Contains(string(b), "我的用量") {
		t.Errorf("bob GET /usage = %d %q; want usage.html", code, b)
	}
	for _, c := range []*http.Cookie{bob, admin} {
		var me Me
		_, mb := rolesGet(t, h, c, "/v1/me")
		_ = json.Unmarshal(mb, &me)
		if !containsString(me.Pages, "usage") {
			t.Errorf("/v1/me pages = %v; want usage", me.Pages)
		}
	}
}
