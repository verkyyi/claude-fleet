package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Organizations and pools (task PNWW).

// orgSnapshot is everything that decides which accounts a person may use:
// each lease's issued and withdrawn rows, and each provider's session
// choices in order.
func orgSnapshot(t *testing.T, h *harness, tok, principal string) string {
	t.Helper()
	got, wd, resp := leased(t, h, tok)
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	b.WriteString("lease=" + strings.Join(got, ",") + " withdrawn=" + strings.Join(wd, ","))
	b.WriteString(" recheck=" + time.Duration(resp.RecheckSecs).String())
	for _, p := range []string{credvault.Claude, credvault.Codex} {
		cs, err := h.srv.sessionBindChoices(principal, ep.ID, p)
		if err != nil {
			t.Fatal(err)
		}
		b.WriteString(" " + p + "=")
		for _, c := range cs {
			b.WriteString(c.PrincipalID + "/" + c.Account + ";")
		}
	}
	return b.String()
}

func onList(t *testing.T, h *harness, pid, login string) {
	t.Helper()
	if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: login, Role: store.RoleUser}); err != nil {
		t.Fatal(err)
	}
}

// After the bootstrap, every person may use exactly the accounts they could
// before it — the same rows, in the same order, withdrawn the same — with no
// policy and under strict lists alike.
func TestOrgBootstrapKeepsEveryonesAccounts(t *testing.T) {
	h, alice, bob := policyRig(t)
	onList(t, h, pAlice, "alice")
	// rows written after Open sit in no pool yet: the "before" of a hub upgrading
	var stamped int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_credentials WHERE pool_id != ''`).Scan(&stamped); err != nil {
		t.Fatal(err)
	}
	if stamped != 0 {
		t.Fatalf("%d rows already stamped before the bootstrap", stamped)
	}
	before := map[string]string{"alice": orgSnapshot(t, h, alice, pAlice), "bob": orgSnapshot(t, h, bob, pBob)}
	if !strings.Contains(before["alice"], "claude=gh:1001/own;pool/") {
		t.Fatalf("alice's own first: %s", before["alice"])
	}
	if err := h.srv.Store.BootstrapOrgs(time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.BootstrapOrgs(time.Now()); err != nil { // idempotent
		t.Fatal(err)
	}
	for who, tok := range map[string]string{"alice": alice, "bob": bob} {
		pid := map[string]string{"alice": pAlice, "bob": pBob}[who]
		if after := orgSnapshot(t, h, tok, pid); after != before[who] {
			t.Errorf("%s changed:\nbefore %s\nafter  %s", who, before[who], after)
		}
	}
	rows, err := h.srv.Store.Credentials("")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range rows {
		want := store.PoolPlatformDefault
		if c.PrincipalID != store.PoolPrincipal {
			want = store.PersonalPoolID(c.PrincipalID)
		}
		if c.PoolID != want {
			t.Errorf("%s/%s in %q; want %q", c.PrincipalID, c.Account, c.PoolID, want)
		}
	}
	if p, err := h.srv.Store.PoolByID(store.PersonalPoolID(pAlice)); err != nil || p.Implicit || p.OwnerID != pAlice {
		t.Fatalf("alice's personal pool: %+v %v", p, err)
	}
	if org, role, err := h.srv.Store.PersonOrg(pAlice); err != nil || org != store.OrgPlatform || role != store.OrgRoleMember {
		t.Fatalf("alice: %s %s %v", org, role, err)
	}
	// a trial person not on the list reads as trial; once converted, platform
	if _, err := h.srv.Store.DB().Exec(`INSERT INTO fleet_trials (principal, state, started_at) VALUES ('p:trial1', 'active', 1)`); err != nil {
		t.Fatal(err)
	}
	if org, _ := h.srv.Store.DefaultOrgFor("p:trial1"); org != store.OrgTrial {
		t.Fatalf("trial person: %s", org)
	}
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_trials SET state = 'converted' WHERE principal = 'p:trial1'`); err != nil {
		t.Fatal(err)
	}
	if org, _ := h.srv.Store.DefaultOrgFor("p:trial1"); org != store.OrgPlatform {
		t.Fatalf("converted trial: %s", org)
	}

	// strict lists granting everything: still the same before and after
	h2, alice2, bob2 := policyRig(t)
	if err := h2.srv.Store.SetFleetSetting(CredPolicyModeKey, "strict", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, sc := range [][2]string{{"node", "mac-c"}, {"user", pAlice}, {"user", pBob}} {
		if code, out := h2.post(t, CredPolicyPath, map[string]any{"scope": sc[0], "id": sc[1], "all": true}); code != 200 {
			t.Fatalf("grant: %d %v", code, out)
		}
	}
	setPolicy(t, h2, "user", pBob, []string{uuidGmail})
	b1 := orgSnapshot(t, h2, alice2, pAlice) + orgSnapshot(t, h2, bob2, pBob)
	if err := h2.srv.Store.BootstrapOrgs(time.Now()); err != nil {
		t.Fatal(err)
	}
	if b2 := orgSnapshot(t, h2, alice2, pAlice) + orgSnapshot(t, h2, bob2, pBob); b1 != b2 {
		t.Errorf("strict changed:\nbefore %s\nafter  %s", b1, b2)
	}
}

// The order is the person's pools → their organization's → the platform's,
// a pool out of reach is withdrawn, and allow_platform_pool / a disabled pool
// take effect on every road.
func TestOrgPoolSelectionOrder(t *testing.T) {
	h, alice, bob := policyRig(t)
	onList(t, h, pAlice, "alice")
	onList(t, h, pBob, "bob")
	ok := func(path string, body any) {
		t.Helper()
		if code, out := h.post(t, path, body); code != 200 {
			t.Fatalf("POST %s %v: %d %v", path, body, code, out)
		}
	}
	ok(OrgsPath, map[string]any{"org_id": "acme", "name": "Acme"})
	ok(OrgMembersPath, map[string]any{"principal": pBob, "org_id": "acme"})
	ok(PoolsPath, map[string]any{"pool_id": "acme-pro", "owner_kind": "org", "owner_id": "acme"})
	ok(PoolMovePath, map[string]any{"provider": "claude", "account": "legacy", "pool_id": "acme-pro"})

	// bob: acme's legacy before the platform's gmail / icloud
	if s := orgSnapshot(t, h, bob, pBob); !strings.Contains(s, "claude=pool/legacy;pool/gmail;pool/icloud;") {
		t.Fatalf("bob's order: %s", s)
	}
	// alice (platform): acme's pool is not hers — withdrawn and never chosen
	s := orgSnapshot(t, h, alice, pAlice)
	if !strings.Contains(s, "withdrawn=claude/legacy ") || strings.Contains(s, "pool/legacy;") ||
		!strings.Contains(s, "claude=gh:1001/own;pool/gmail;pool/icloud;") {
		t.Fatalf("alice: %s", s)
	}
	// a pool made for bob alone comes before his organization's
	ok(PoolsPath, map[string]any{"pool_id": "bob-dedicated", "owner_kind": "person", "owner_id": pBob})
	ok(PoolMovePath, map[string]any{"provider": "claude", "account": "icloud", "pool_id": "bob-dedicated"})
	if s := orgSnapshot(t, h, bob, pBob); !strings.Contains(s, "claude=pool/icloud;pool/legacy;pool/gmail;") {
		t.Fatalf("bob with a dedicated pool: %s", s)
	}
	if s := orgSnapshot(t, h, alice, pAlice); !strings.Contains(s, "claude=gh:1001/own;pool/gmail;") || strings.Contains(s, "pool/icloud;") {
		t.Fatalf("alice without bob's pool: %s", s)
	}
	// priority inside a level: a second acme pool with a smaller number first
	ok(PoolsPath, map[string]any{"pool_id": "acme-first", "owner_kind": "org", "owner_id": "acme", "priority": -1})
	ok(PoolMovePath, map[string]any{"provider": "codex", "account": "default", "pool_id": "acme-first"})
	ok(PoolMovePath, map[string]any{"provider": "claude", "account": "gmail", "pool_id": "acme-first"})
	if s := orgSnapshot(t, h, bob, pBob); !strings.Contains(s, "claude=pool/icloud;pool/gmail;pool/legacy;") ||
		!strings.Contains(s, "codex=pool/default;") {
		t.Fatalf("bob with priorities: %s", s)
	}
	// acme stops using the platform's pools: nothing left there anyway, so
	// move gmail back and see it go
	ok(PoolMovePath, map[string]any{"provider": "claude", "account": "gmail", "pool_id": store.PoolPlatformDefault})
	ok(OrgsPath, map[string]any{"org_id": "acme", "allow_platform_pool": false})
	if s := orgSnapshot(t, h, bob, pBob); strings.Contains(s, "pool/gmail;") || !strings.Contains(s, "withdrawn=claude/gmail") {
		t.Fatalf("bob without the platform: %s", s)
	}
	// a disabled pool is nobody's
	ok(PoolsPath, map[string]any{"pool_id": "acme-pro", "enabled": false})
	if s := orgSnapshot(t, h, bob, pBob); strings.Contains(s, "pool/legacy;") {
		t.Fatalf("bob with acme-pro off: %s", s)
	}
	// the effective view says why
	resp, out := h.get(t, CredPolicyPath+"?principal="+pBob)
	if resp.StatusCode != 200 || !strings.Contains(string(out), "acme-pro is disabled") {
		t.Fatalf("effective view: %d %s", resp.StatusCode, out)
	}
	// a person's own subscription stays theirs
	if code, _ := h.post(t, PoolMovePath, map[string]any{"owner": pAlice, "provider": "claude", "account": "own", "pool_id": "acme-pro"}); code != 400 {
		t.Fatalf("own row into an org pool: %d", code)
	}
	// a pool with subscriptions in it is not removed
	if code, _ := h.post(t, PoolsPath, map[string]any{"action": "delete", "pool_id": "acme-pro"}); code != 409 {
		t.Fatalf("delete a non-empty pool: %d", code)
	}
}

// An organization's budget refuses its members with its own code, beside
// the person's own; usage rows carry the org and pool they were written in.
func TestOrgBudget(t *testing.T) {
	h, _, _ := policyRig(t)
	onList(t, h, pAlice, "alice")
	onList(t, h, pBob, "bob")
	if code, out := h.post(t, OrgsPath, map[string]any{"org_id": "acme"}); code != 200 {
		t.Fatal(code, out)
	}
	for _, p := range []string{pAlice, pBob} {
		if code, out := h.post(t, OrgMembersPath, map[string]any{"principal": p, "org_id": "acme"}); code != 200 {
			t.Fatal(code, out)
		}
	}
	now := time.Now()
	h.srv.budgetNow = func() time.Time { return now }
	for _, u := range []store.PoolUsage{
		{Principal: pAlice, Provider: credvault.Claude, Account: "gmail", In: 600, At: now.Add(-time.Hour)},
		{Principal: pBob, Provider: credvault.Claude, Account: "gmail", In: 500, At: now.Add(-30 * time.Minute)},
	} {
		if err := h.srv.Store.AddPoolUsage(u); err != nil {
			t.Fatal(err)
		}
	}
	rows, err := h.srv.Store.PoolUsageFor(pBob, now.Add(-time.Hour*2), time.Time{})
	if err != nil || len(rows) != 1 || rows[0].OrgID != "acme" || rows[0].PoolID != store.PoolPlatformDefault {
		t.Fatalf("stamped row: %+v %v", rows, err)
	}
	st, err := h.srv.personBudgetState(pBob, now)
	if err != nil || st.Over {
		t.Fatalf("no budget: %+v %v", st, err)
	}
	if code, out := h.post(t, OrgBudgetPath, map[string]any{"org_id": "acme", "budget": "5h=1k,month=1M"}); code != 200 {
		t.Fatal(code, out)
	}
	st, err = h.srv.personBudgetState(pBob, now)
	if err != nil || !st.Over || st.Error != OrgBudgetExceeded || st.Window != "org_5h" || !strings.Contains(st.Message, OrgBudgetExceeded) {
		t.Fatalf("over the org's 5h: %+v %v", st, err)
	}
	// a person over their own budget answers with theirs
	if err := h.srv.Store.SetFleetSetting(PersonBudgetPrefix+pAlice, "5h=100", now); err != nil {
		t.Fatal(err)
	}
	if st, _ := h.srv.personBudgetState(pAlice, now); st.Error != PersonBudgetExceeded {
		t.Fatalf("alice's own first: %+v", st)
	}
	// someone outside acme is untouched
	if st, _ := h.srv.personBudgetState("gh:9999", now); st.Over {
		t.Fatalf("outsider: %+v", st)
	}
	if code, _ := h.post(t, OrgBudgetPath, map[string]any{"org_id": "acme", "budget": "5h=lots"}); code != 400 {
		t.Fatalf("bad budget: %d", code)
	}
	var gs OrgBudgetState
	resp, raw := h.get(t, OrgBudgetPath+"?org_id=acme")
	if resp.StatusCode != 200 || json.Unmarshal(raw, &gs) != nil || gs.Used5h != 1100 || !gs.Over {
		t.Fatalf("budget read: %d %s", resp.StatusCode, raw)
	}
}

// An organization's admin manages their own organization only; a member
// reads their own; an admin everything.
func TestOrgAccessControl(t *testing.T) {
	h, admin, user := rolesHarness(t)
	alice := "gh:200"
	do := func(c *http.Cookie, path string, body any) int {
		t.Helper()
		code, _ := requestsDo(t, h, c, http.MethodPost, path, body)
		return code
	}
	if code := do(user, OrgsPath, map[string]any{"org_id": "acme"}); code != http.StatusForbidden {
		t.Fatalf("member creates an org: %d", code)
	}
	for _, o := range []string{"acme", "globex"} {
		if code := do(admin, OrgsPath, map[string]any{"org_id": o}); code != 200 {
			t.Fatalf("admin creates %s: %d", o, code)
		}
	}
	if code := do(admin, OrgMembersPath, map[string]any{"principal": alice, "org_id": "acme"}); code != 200 {
		t.Fatalf("admin moves alice: %d", code)
	}
	// a member: no pool, no role, no budget
	if code := do(user, PoolsPath, map[string]any{"pool_id": "acme-x", "owner_kind": "org", "owner_id": "acme"}); code != http.StatusForbidden {
		t.Fatalf("member makes a pool: %d", code)
	}
	if code := do(user, OrgBudgetPath, map[string]any{"org_id": "acme", "budget": "5h=1M"}); code != http.StatusForbidden {
		t.Fatalf("member sets the budget: %d", code)
	}
	code, b := requestsDo(t, h, user, http.MethodGet, OrgsPath, nil)
	if code != 200 || strings.Contains(string(b), "globex") || !strings.Contains(string(b), `"acme"`) {
		t.Fatalf("member reads orgs: %d %s", code, b)
	}
	// made acme's admin
	if code := do(admin, OrgMembersPath, map[string]any{"principal": alice, "org_id": "acme", "org_role": "admin"}); code != 200 {
		t.Fatalf("admin makes alice acme's admin: %d", code)
	}
	for _, c := range []struct {
		path string
		body map[string]any
		want int
	}{
		{PoolsPath, map[string]any{"pool_id": "acme-x", "owner_kind": "org", "owner_id": "acme"}, 200},
		{PoolsPath, map[string]any{"pool_id": "acme-x", "priority": 3}, 200},
		{PoolsPath, map[string]any{"pool_id": "globex-x", "owner_kind": "org", "owner_id": "globex"}, http.StatusForbidden},
		{PoolsPath, map[string]any{"pool_id": "plat-x", "owner_kind": "platform"}, http.StatusForbidden},
		{PoolsPath, map[string]any{"pool_id": store.PoolPlatformDefault, "enabled": false}, http.StatusForbidden},
		{OrgBudgetPath, map[string]any{"org_id": "acme", "budget": "week=2M"}, 200},
		{OrgBudgetPath, map[string]any{"org_id": "globex", "budget": "week=2M"}, http.StatusForbidden},
		{OrgMembersPath, map[string]any{"principal": alice, "org_id": "globex"}, http.StatusForbidden},
		{OrgsPath, map[string]any{"org_id": "acme", "allow_platform_pool": false}, http.StatusForbidden},
	} {
		if code := do(user, c.path, c.body); code != c.want {
			t.Errorf("acme's admin POST %s %v = %d; want %d", c.path, c.body, code, c.want)
		}
	}
	code, b = requestsDo(t, h, user, http.MethodGet, PoolsPath, nil)
	if code != 200 || !strings.Contains(string(b), "acme-x") || strings.Contains(string(b), "globex-x") {
		t.Fatalf("acme's admin reads pools: %d %s", code, b)
	}
	code, b = requestsDo(t, h, user, http.MethodGet, OrgMembersPath+"?org_id=globex", nil)
	if code != 200 || !strings.Contains(string(b), alice) {
		t.Fatalf("acme's admin reads members (cut to acme): %d %s", code, b)
	}
}
