package api

import (
	"encoding/json"
	"net/http"
	"net/url"
	"reflect"
	"testing"
)

// claude-fleet#3936: 全队用量's person is the number their own 我的用量 says —
// today, 7 days and the limit, field for field — and the admin's read of one
// person is that person's whole answer. A member reads none of it.
func TestAdminUsage_SameAsOwnPage(t *testing.T) {
	h, bob, carol, admin, now := meUsageHarness(t)
	if err := h.srv.Store.SetFleetSetting(PersonBudgetPrefix+githubPrincipal(ghBob.ID), "5h=1k,week=10k", now); err != nil {
		t.Fatal(err)
	}
	code, b := rolesGet(t, h, admin, AdminUsagePath)
	if code != http.StatusOK {
		t.Fatalf("admin %s = %d %s", AdminUsagePath, code, b)
	}
	var all AdminUsage
	if err := json.Unmarshal(b, &all); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	byP := map[string]AdminUsagePerson{}
	for _, p := range all.People {
		byP[p.Principal] = p
	}
	for _, c := range []struct {
		who    fakeGHUser
		cookie *http.Cookie
	}{{ghBob, bob}, {ghCarol, carol}} {
		own, raw := readMeUsage(t, h, c.cookie, "?range=7d")
		p, ok := byP[githubPrincipal(c.who.ID)]
		if !ok {
			t.Fatalf("%s missing from %s", c.who.Login, b)
		}
		if p.Today != own.Today || p.Week != own.Week || !reflect.DeepEqual(p.Limit, own.Limit) {
			t.Errorf("%s: team row %+v; own page %s", c.who.Login, p, raw)
		}
		code, one := rolesGet(t, h, admin, AdminUsagePath+"?range=7d&principal="+url.QueryEscape(githubPrincipal(c.who.ID)))
		var got MeUsage
		if code != http.StatusOK || json.Unmarshal(one, &got) != nil || !reflect.DeepEqual(got, own) {
			t.Errorf("%s: admin's read of one = %d %s; want their own %s", c.who.Login, code, one, raw)
		}
	}
	if bp := byP[githubPrincipal(ghBob.ID)]; bp.Today == 0 || !bp.Limit.Set || bp.Limit.LimitWeek == nil {
		t.Errorf("bob's row = %+v; want today's tokens and his limit", bp)
	}
	// by model and by machine: the same rows, so each sums to the people's weeks
	var people, models, machines int64
	for _, p := range all.People {
		people += p.Week
	}
	for _, m := range all.Models {
		models += m.Tokens
	}
	for _, m := range all.Machines {
		machines += m.Week
	}
	if people == 0 || models != people || machines != people || len(all.Machines) != 2 {
		t.Errorf("people %d, models %d, machines %d (%d of them); want one sum: %s", people, models, machines, len(all.Machines), b)
	}
	// the largest week first
	for i := 1; i < len(all.People); i++ {
		if all.People[i].Week > all.People[i-1].Week {
			t.Errorf("not sorted by week: %s", b)
		}
	}
	if code, _ := rolesGet(t, h, admin, AdminUsagePath+"?principal=nobody"); code != http.StatusNotFound {
		t.Errorf("unknown person = %d; want 404", code)
	}
	if code, _ := rolesGet(t, h, admin, AdminUsagePath+"?principal="+githubPrincipal(ghBob.ID)+"&range=1y"); code != http.StatusBadRequest {
		t.Errorf("bad range = %d; want 400", code)
	}
	for _, q := range []string{"", "?principal=" + githubPrincipal(ghCarol.ID)} {
		if code, b := rolesGet(t, h, bob, AdminUsagePath+q); code == http.StatusOK {
			t.Errorf("member reads %s%s = %s", AdminUsagePath, q, b)
		}
	}
}
