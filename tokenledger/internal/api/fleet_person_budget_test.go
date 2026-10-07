package api

import (
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
)

// Per-person budgets (claude-fleet#1977, EPIC #1967 R2): the issue's three
// checks — over the budget is refused with person_budget_exceeded, somebody
// else is not touched, and the window passing lets the person back in.

type budgetClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *budgetClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *budgetClock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// issueOn issues a pass for session fid on a node (its token + fleet id).
func (r *cpRig) issueOn(t *testing.T, tok, fleet, fid string) string {
	t.Helper()
	c := assertClaims(fleet, time.Now())
	c.Fid, c.WorkerID, c.Key = fid, fleetid.WorkerID(fleet, fid), "issue-"+fid[:4]
	st, out := sessDo(t, r.h, http.MethodPost, "/v1/fleet/session-cred", tok, signWorkerAssertion(c, HashToken(tok)), nil)
	if st != 200 {
		t.Fatalf("issue: %d %v", st, out)
	}
	return out["cred"].(string)
}

func personUsed(t *testing.T, h *harness, principal string) float64 {
	t.Helper()
	st, out := sessDo(t, h, http.MethodGet, "/v1/fleet/person-usage?principal="+principal, viewerToken, "", nil)
	if st != 200 {
		t.Fatalf("person-usage: %d %v", st, out)
	}
	people, _ := out["people"].([]any)
	if len(people) != 1 {
		return 0
	}
	return people[0].(map[string]any)["used_5h"].(float64)
}

func TestPersonBudgetCentral(t *testing.T) {
	r := newCPRig(t)
	clk := &budgetClock{t: time.Now()}
	r.h.srv.budgetNow = clk.now
	// a second person, login zx on m3, with a Claude account of their own
	m3 := connectWriteNode(t, r.h, "m3")
	f3 := fakeFleet(t, machineC, "fleet-m3", writeRepo, "/u/zx/claude-fleet", 3)
	m3.beatLoad("m3", "zx", machineC, 0.1, 0, f3)
	waitFor(t, 3*time.Second, "m3's fleet registered", func() bool {
		return len(getFleet(t, r.h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 3
	})
	p, err := r.h.srv.Store.AdoptPrincipal("gh:1004", "zx", "ZX", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := r.h.srv.Store.AdoptAccount(p, "m3", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := r.h.srv.Vault.Put("gh:1004", credvault.Claude, "zx1", credvault.Secret{RefreshToken: "rt-zx"}); err != nil {
		t.Fatal(err)
	}
	verk := r.issueOn(t, r.tok5, r.f5, fidA)
	zx := r.issueOn(t, r.h.tokens["m3"], f3.FleetID, fidB)

	// a bad budget is refused; a good one is stored normalized
	putSetting(t, r.h, PersonBudgetPrefix+"gh:1005", "5h=lots", http.StatusBadRequest)
	out := putSetting(t, r.h, PersonBudgetPrefix+"gh:1005", "5h=300, week=1k", http.StatusOK)
	if got := out["settings"].(map[string]any)[PersonBudgetPrefix+"gh:1005"]; got != "5h=300,week=1000" {
		t.Fatalf("stored budget = %v", got)
	}

	for i, want := range []float64{150, 300} {
		if st, body := r.call(t, credvault.Claude, verk); st != 200 {
			t.Fatalf("request %d under budget → %d %s", i+1, st, body)
		}
		waitFor(t, 3*time.Second, "usage reported", func() bool { return personUsed(t, r.h, "gh:1005") == want })
	}
	// over: refused, the hub's line under its own code, nothing upstream
	r.mu.Lock()
	before := len(r.upAuth)
	r.mu.Unlock()
	r.pastCache()
	st, body := r.call(t, credvault.Claude, verk)
	if st != http.StatusForbidden || !strings.Contains(body, PersonBudgetExceeded) || !strings.Contains(body, "已达个人额度") {
		t.Fatalf("over budget → %d %s; want 403 person_budget_exceeded", st, body)
	}
	t.Logf("over budget, the session sees: %d %s", st, body)
	if st, body := r.call(t, credvault.Codex, verk); st != http.StatusForbidden || !strings.Contains(body, `"code":"`+PersonBudgetExceeded+`"`) {
		t.Fatalf("over budget (codex) → %d %s", st, body)
	}
	r.mu.Lock()
	after := len(r.upAuth)
	r.mu.Unlock()
	if after != before {
		t.Fatalf("an over-budget request reached the upstream")
	}
	// somebody else: untouched
	if st, body := r.call(t, credvault.Claude, zx); st != 200 {
		t.Fatalf("another person → %d %s", st, body)
	}
	// the 5h window passes: back in (the week's 1000 still has room)
	clk.add(5*time.Hour + 11*time.Minute)
	r.pastCache()
	if st, body := r.call(t, credvault.Claude, verk); st != 200 {
		t.Fatalf("after the window → %d %s", st, body)
	}
}

// The local proxy's road: a node reports with its token, the hub files it
// under the login's person and answers their standing; a login with no
// person is counted against nobody and never refused.
func TestPersonBudgetNode(t *testing.T) {
	h, tok5, tok4, _, _ := sessHarness(t)
	clk := &budgetClock{t: time.Now()}
	h.srv.budgetNow = clk.now
	rep := map[string]any{"usage": []map[string]any{{"provider": "claude", "tokens": 600, "requests": 2}, {"provider": "codex", "tokens": 400, "requests": 1}}}
	st, out := sessDo(t, h, http.MethodPost, "/v1/node/usage", tok5, "", rep)
	if st != 200 || out["principal"] != "gh:1005" || out["used_5h"].(float64) != 1000 || out["over"] != false {
		t.Fatalf("report with no budget: %d %v", st, out)
	}
	putSetting(t, h, PersonBudgetPrefix+"gh:1005", "week=1k", http.StatusOK)
	st, out = sessDo(t, h, http.MethodGet, "/v1/node/usage", tok5, "", nil)
	if st != 200 || out["over"] != true || out["window"] != "week" || out["error"] != PersonBudgetExceeded ||
		!strings.Contains(out["message"].(string), "近 7 天") {
		t.Fatalf("over the week: %d %v", st, out)
	}
	// m4's login is nobody's: reported, not counted, never over
	st, out = sessDo(t, h, http.MethodPost, "/v1/node/usage", tok4, "", rep)
	if st != 200 || out["over"] != false || out["principal"] != "" {
		t.Fatalf("a login with no person: %d %v", st, out)
	}
	if st, _ := sessDo(t, h, http.MethodGet, "/v1/node/usage", "not-a-token", "", nil); st != http.StatusUnauthorized {
		t.Fatalf("no node token → %d", st)
	}
	// the operator's list carries the person with their budget
	st, out = sessDo(t, h, http.MethodGet, "/v1/fleet/person-usage", viewerToken, "", nil)
	people, _ := out["people"].([]any)
	if st != 200 || len(people) != 1 || people[0].(map[string]any)["display_name"] != "Verk" ||
		people[0].(map[string]any)["limit_week"].(float64) != 1000 {
		t.Fatalf("person-usage: %d %v", st, out)
	}
	// a week on, it has all left the window
	clk.add(7*24*time.Hour + 11*time.Minute)
	if _, out = sessDo(t, h, http.MethodGet, "/v1/node/usage", tok5, "", nil); out["over"] != false || out["used_week"].(float64) != 0 {
		t.Fatalf("a week later: %v", out)
	}
}

func TestParsePersonBudget(t *testing.T) {
	for in, want := range map[string]string{"5h=200k": "5h=200000", "week=2M 5h=1.5k": "5h=1500,week=2000000", "7d=10": "week=10"} {
		b, err := parsePersonBudget(in)
		if err != nil || b.String() != want {
			t.Errorf("%q → %q %v; want %q", in, b.String(), err, want)
		}
	}
	for _, in := range []string{"", "5h", "day=3", "5h=-1", "5h=x"} {
		if _, err := parsePersonBudget(in); err == nil {
			t.Errorf("%q parsed", in)
		}
	}
}
