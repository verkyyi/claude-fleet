package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// By person, one person a row; the pool, who is on each subscription
// (claude-fleet#3228, EPIC #3225 C3).

// One person with three logins on two machines is ONE row: every login's
// sessions and every pool row land on it, and the logins are listed for the
// drawer. A session on a login no person holds makes no row.
func TestAdminPeople_OneRowPerPerson(t *testing.T) {
	now := time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)
	day := now.Truncate(24 * time.Hour)
	act := func(pid, host, login string) store.FleetAccount {
		return store.FleetAccount{PrincipalID: pid, Hostname: host, Login: login, State: store.AccountActive}
	}
	in := adminPeopleIn{
		Since: now.Add(-7 * 24 * time.Hour), Today: day,
		Usage: []store.PoolUsage{
			{Principal: "gh:1", In: 100, Out: 50, CacheRead: 999, At: now, Repo: "o/a", Issue: 7},
			{Principal: "gh:1", CacheWrite: 30, At: now.Add(-30 * time.Hour), Repo: "o/b", Issue: 9},
			{Principal: "gh:1", In: 20, At: now.Add(-2 * time.Hour), Repo: "o/a"},
			{Principal: "gh:1", In: 1000, At: now.Add(-8 * 24 * time.Hour), Repo: "o/b"}, // before the range
			{Principal: "gh:2", In: 5, At: now},
		},
		Accounts: []store.FleetAccount{
			act("gh:1", "mini", "verkyyi"), act("gh:1", "mini", "verk2"), act("gh:1", "m5", "verkyyi"),
			act("gh:2", "box", "alice"),
			{PrincipalID: "gh:3", Hostname: "box", Login: "gone", State: "closed"},
		},
		Sessions: []adminSession{
			{Host: "mini", Login: "verkyyi", Running: true},
			{Host: "mini", Login: "verk2"},
			{Host: "m5", Login: "verkyyi", Running: true},
			{Host: "box", Login: "nobody", Running: true}, // a login no person holds
			{Host: "box", Login: "gone"},                  // a closed login
		},
		Names:   map[string]string{"gh:1": "verkyyi"},
		Budgets: map[string]PersonBudget{"gh:1": {Week: 2_000_000}},
		Subs:    map[string][]string{"gh:2": {"icloud"}},
	}
	got := adminPeople(in)
	if len(got) != 2 {
		t.Fatalf("rows = %+v; want 2 (one a person, none for a login nobody holds)", got)
	}
	v := got[0]
	if v.Principal != "gh:1" || v.Name != "verkyyi" {
		t.Fatalf("first row = %+v; want gh:1 verkyyi (most tokens first)", v)
	}
	if v.Today != 170 || v.Week != 200 {
		t.Errorf("gh:1 today/week = %d/%d; want 170/200 (cache reads and rows before the range left out)", v.Today, v.Week)
	}
	if v.Sessions != 3 || v.Running != 2 {
		t.Errorf("gh:1 sessions = %d running %d; want 3 / 2, all three logins'", v.Sessions, v.Running)
	}
	want := [][2]string{{"m5", "verkyyi"}, {"mini", "verk2"}, {"mini", "verkyyi"}}
	if len(v.Logins) != 3 || v.Logins[0] != want[0] || v.Logins[1] != want[1] || v.Logins[2] != want[2] {
		t.Errorf("gh:1 logins = %v; want %v", v.Logins, want)
	}
	if v.Limit == nil || v.Limit.Week != 2_000_000 {
		t.Errorf("gh:1 limit = %+v; want week 2M", v.Limit)
	}
	if v.Doing == nil || v.Doing.Repo != "o/a" || v.Doing.Issue != 7 || v.Doing.Tokens != 170 {
		t.Errorf("gh:1 doing = %+v; want o/a #7, 170", v.Doing)
	}
	a := got[1]
	if a.Principal != "gh:2" || a.Name != "gh:2" || a.Week != 5 || a.Limit != nil || a.Doing != nil ||
		len(a.Subs) != 1 || a.Subs[0] != "icloud" || a.Sessions != 0 {
		t.Errorf("gh:2 = %+v; want 5 tokens, 不限额, no task, on icloud, no session", a)
	}
}

// A subscription's people are exactly the holders of a live pass bound to it
// — owner, provider and account all matching; one nobody is on is idle.
func TestAdminPool_PeopleAreLivePassHolders(t *testing.T) {
	h5, reset := 40.0, time.Now().Add(time.Hour)
	creds := []store.Credential{
		{PrincipalID: store.PoolPrincipal, Provider: "claude", Account: "icloud"},
		{PrincipalID: store.PoolPrincipal, Provider: "claude", Account: "gmail"},
		{PrincipalID: "gh:1", Provider: "claude", Account: "icloud"}, // same name, someone's own
		{PrincipalID: store.PoolPrincipal, Provider: "codex", Account: "icloud"},
		{PrincipalID: store.PoolPrincipal, Provider: "claude", Account: "stale", ReauthRequired: true},
	}
	bind := func(prov, owner, acct string) store.SessionBind {
		return store.SessionBind{Provider: prov, Owner: owner, Account: acct}
	}
	passes := []adminPass{
		{Principal: "gh:1", WorkerID: "w1", Binds: []store.SessionBind{bind("claude", store.PoolPrincipal, "icloud")}},
		{Principal: "gh:1", WorkerID: "w2", Binds: []store.SessionBind{bind("claude", store.PoolPrincipal, "icloud")}},
		{Principal: "gh:2", WorkerID: "w3", Binds: []store.SessionBind{bind("claude", store.PoolPrincipal, "icloud"), bind("codex", store.PoolPrincipal, "icloud")}},
	}
	names := map[string]string{"gh:1": "verkyyi", "gh:2": "alice"}
	reading := func(c store.Credential) (string, *model.LimitsSnapshot) {
		if c.Account != "icloud" || c.Provider != "claude" {
			return "", nil
		}
		return "verky@icloud.com", &model.LimitsSnapshot{FiveHour: model.Window{Utilization: h5, ResetsAt: &reset}}
	}
	atLimit := func(c store.Credential) string {
		if c.Provider == "codex" {
			return "7d"
		}
		return ""
	}
	got := adminPool(creds, passes, names, reading, atLimit)
	if len(got) != len(creds) {
		t.Fatalf("pool = %+v; want one entry a vault account", got)
	}
	ic := got[0]
	if len(ic.People) != 2 || ic.People[0] != "alice" || ic.People[1] != "verkyyi" || ic.Sessions != 3 || ic.State != "in_use" {
		t.Errorf("pool icloud = %+v; want alice + verkyyi, 3 sessions, in_use", ic)
	}
	if ic.Label != "verky@icloud.com" || ic.Used5hPct == nil || *ic.Used5hPct != 40 || ic.Resets5h == nil {
		t.Errorf("pool icloud reading = %+v", ic)
	}
	if g := got[1]; len(g.People) != 0 || g.Sessions != 0 || g.State != "idle" || g.Used5hPct != nil {
		t.Errorf("pool gmail = %+v; want nobody, idle, no reading", g)
	}
	if o := got[2]; len(o.People) != 0 || o.Owner != "gh:1" {
		t.Errorf("gh:1's own icloud = %+v; want nobody (the passes are bound to the pool's)", o)
	}
	if c := got[3]; c.State != "limited" || c.Limited != "7d" || len(c.People) != 1 || c.People[0] != "alice" {
		t.Errorf("codex icloud = %+v; want limited 7d, alice", c)
	}
	if s := got[4]; s.State != "reauth" {
		t.Errorf("stale = %+v; want reauth", s)
	}
}

// livePasses leaves out a revoked and an expired pass: their holders are no
// longer on the subscription.
func TestAdminPool_LivePassesOnly(t *testing.T) {
	h := newHarness(t)
	st, now := h.srv.Store, time.Now()
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	add := func(id, pid, wid string, exp time.Time) {
		t.Helper()
		if err := st.AddSessionCred(store.SessionCred{ID: id, PrincipalID: pid, WorkerID: wid, Machine: "mini",
			EndpointID: "ep", Providers: []string{"claude"}, IssuedAt: now.Add(-time.Hour), ExpiresAt: exp}); err != nil {
			t.Fatal(err)
		}
		if _, err := st.PickSessionBind(store.SessionBind{WorkerID: wid, Provider: "claude", Owner: store.PoolPrincipal, Account: "icloud"}, now); err != nil {
			t.Fatal(err)
		}
	}
	add("p-live", "gh:1", "w-live", now.Add(time.Hour))
	add("p-old", "gh:2", "w-old", now.Add(-time.Minute))
	add("p-rev", "gh:3", "w-rev", now.Add(time.Hour))
	if _, err := st.RevokeSessionCred("p-rev", "test", "test", now); err != nil {
		t.Fatal(err)
	}
	passes, err := h.srv.livePasses(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(passes) != 1 || passes[0].Principal != "gh:1" || len(passes[0].Binds) != 1 {
		t.Fatalf("live passes = %+v; want gh:1's only", passes)
	}
	if subs := passSubs(passes); len(subs) != 1 || len(subs["gh:1"]) != 1 || subs["gh:1"][0] != "icloud" {
		t.Errorf("subs = %v", subs)
	}
}
