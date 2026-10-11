package api

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Subscription allowlists (claude-fleet#3043): node ∩ person over the
// existing eligibility, one resolver for every road to a credential.

const (
	uuidGmail  = "11111111-1111-4111-8111-111111111111"
	uuidICloud = "22222222-2222-4222-8222-222222222222"
	uuidOwn    = "33333333-3333-4333-8333-333333333333"
	uuidCodex  = "codex:account:0123456789abcdef0123456789abcdef"
)

// policyRig: alice and bob both log in on m4; the pool holds gmail, icloud
// (Claude, with account UUIDs), legacy (Claude, no UUID — an old import) and
// a Codex default; alice also has her own Claude "own".
func policyRig(t *testing.T) (h *harness, alice, bob string) {
	t.Helper()
	h, alice, _ = newVaultHarness(t)
	p, err := h.srv.Store.AdoptPrincipal(pBob, "bob", "Bob", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	bob = enrollAs(t, h, "bob-m4", "m4", "bob")
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	for _, c := range []struct{ who, provider, account, uuid string }{
		{store.PoolPrincipal, credvault.Claude, "gmail", uuidGmail},
		{store.PoolPrincipal, credvault.Claude, "icloud", strings.ToUpper(uuidICloud)},
		{store.PoolPrincipal, credvault.Claude, "legacy", ""},
		{pAlice, credvault.Claude, "own", uuidOwn},
	} {
		if err := h.srv.Vault.Put(c.who, c.provider, c.account, credvault.Secret{SetupToken: "sk-ant-oat01-" + c.account,
			ExpiresAt: &exp, AccountUUID: c.uuid}); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Vault.Put(store.PoolPrincipal, credvault.Codex, "default", credvault.Secret{RefreshToken: "rt-cx",
		AccountID: "aid", AccountUUID: uuidCodex}); err != nil {
		t.Fatal(err)
	}
	return h, alice, bob
}

func setPolicy(t *testing.T, h *harness, scope, id string, allow any) {
	t.Helper()
	if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": scope, "id": id, "allow": allow}); code != http.StatusOK {
		t.Fatalf("policy %s %s: %d %v", scope, id, code, out)
	}
}

// leased is the sorted owner/account of every credential a lease issued, and
// of every one it withdrew.
func leased(t *testing.T, h *harness, tok string) (got, withdrawn []string, resp NodeCredentialsResponse) {
	t.Helper()
	code, resp, body := lease(t, h, tok)
	if code != http.StatusOK {
		t.Fatalf("lease: %d %v", code, body)
	}
	for _, c := range resp.Credentials {
		got = append(got, c.Provider+"/"+c.Account)
	}
	for _, c := range resp.Withdrawn {
		withdrawn = append(withdrawn, c.Provider+"/"+c.Account)
		if c.Error == "" || c.Access != nil {
			t.Fatalf("a withdrawal says why and carries no access: %+v", c)
		}
	}
	sort.Strings(got)
	sort.Strings(withdrawn)
	return got, withdrawn, resp
}

func eq(a []string, b ...string) bool { return strings.Join(a, ",") == strings.Join(b, ",") }

func TestCredPolicyOffAddsNothing(t *testing.T) {
	h, alice, bob := policyRig(t)
	got, wd, resp := leased(t, h, alice)
	if !eq(got, "claude/gmail", "claude/icloud", "claude/legacy", "claude/own", "codex/default") || len(wd) != 0 || resp.RecheckSecs != 0 {
		t.Fatalf("no policy: %v withdrawn %v recheck %d", got, wd, resp.RecheckSecs)
	}
	if got, wd, _ := leased(t, h, bob); len(got) != 4 || len(wd) != 0 {
		t.Fatalf("bob, no policy: %v %v", got, wd)
	}
	_, _, raw := getPool(t, h, alice)
	if !strings.Contains(raw, "gmail") || !strings.Contains(raw, "legacy") {
		t.Fatalf("manifest, no policy: %s", raw)
	}
}

func TestCredPolicyNodeUserIntersection(t *testing.T) {
	h, alice, bob := policyRig(t)

	// node only: m4 may use gmail + the Codex account (and alice's own).
	setPolicy(t, h, "node", "m4.local", []string{uuidGmail, uuidCodex, uuidOwn})
	got, wd, resp := leased(t, h, alice)
	if !eq(got, "claude/gmail", "claude/own", "codex/default") || !eq(wd, "claude/icloud", "claude/legacy") {
		t.Fatalf("node only: %v withdrawn %v", got, wd)
	}
	if resp.RecheckSecs != int(credPolicyRecheck/time.Second) {
		t.Fatalf("recheck_secs = %d", resp.RecheckSecs)
	}
	for _, c := range resp.Withdrawn {
		if c.Account == "legacy" && !strings.Contains(c.Error, "no account UUID") {
			t.Fatalf("legacy's reason: %q", c.Error)
		}
		if c.Account == "icloud" && !strings.Contains(c.Error, "not in machine m4's allowlist") {
			t.Fatalf("icloud's reason: %q", c.Error)
		}
	}
	// The manifest is the machine's: node scope.
	_, man, _ := getPool(t, h, bob)
	if len(man.Pool) != 1 || man.Pool[0].Account != "gmail" {
		t.Fatalf("manifest under m4's list: %+v", man.Pool)
	}

	// user on top, partial overlap: alice may use icloud + Codex → only Codex.
	setPolicy(t, h, "user", pAlice, []string{uuidICloud, uuidCodex})
	if got, wd, _ := leased(t, h, alice); !eq(got, "codex/default") || len(wd) != 4 {
		t.Fatalf("intersection: %v withdrawn %v", got, wd)
	}
	// bob shares the machine and has no list of his own: m4's alone.
	if got, _, _ := leased(t, h, bob); !eq(got, "claude/gmail", "codex/default") {
		t.Fatalf("bob on m4: %v", got)
	}
	// disjoint: nothing.
	setPolicy(t, h, "user", pAlice, []string{uuidICloud})
	if got, _, _ := leased(t, h, alice); len(got) != 0 {
		t.Fatalf("disjoint: %v", got)
	}
	// node cleared: the person's list alone (case-insensitive UUIDs).
	setPolicy(t, h, "node", "m4", nil)
	if got, _, _ := leased(t, h, alice); !eq(got, "claude/icloud") {
		t.Fatalf("user only: %v", got)
	}
	if got, wd, _ := leased(t, h, bob); len(got) != 4 || len(wd) != 0 {
		t.Fatalf("bob unrestricted again: %v %v", got, wd)
	}
	// explicit empty denies everything.
	setPolicy(t, h, "user", pAlice, []string{})
	got, wd, _ = leased(t, h, alice)
	if len(got) != 0 || len(wd) != 5 {
		t.Fatalf("deny all: %v %v", got, wd)
	}
	// Every denial and every write is audited, no secret in either.
	rows, err := h.srv.Store.CredAuditLog("", 500)
	if err != nil {
		t.Fatal(err)
	}
	var policyRows, denyRows int
	for _, r := range rows {
		b, _ := json.Marshal(r)
		if strings.Contains(string(b), "sk-ant-") || strings.Contains(string(b), "rt-cx") {
			t.Fatalf("a secret in the audit: %s", b)
		}
		switch {
		case r.Action == store.CredPolicy:
			policyRows++
		case r.Action == store.CredDeny && strings.Contains(r.Detail, "policy: "):
			denyRows++
		}
	}
	if policyRows != 5 || denyRows == 0 {
		t.Fatalf("audit: %d policy rows, %d policy denials", policyRows, denyRows)
	}
}

func TestCredPolicyMalformedFailsClosed(t *testing.T) {
	h, alice, _ := policyRig(t)
	// Written past the API (an old hub, a hand edit): never "unrestricted".
	if err := h.srv.Store.SetFleetSetting(credUserKey(pAlice), `["gmail"]`, time.Now()); err != nil {
		t.Fatal(err)
	}
	got, wd, resp := leased(t, h, alice)
	if len(got) != 0 || len(wd) != 5 || !strings.Contains(resp.Withdrawn[0].Error, "malformed") {
		t.Fatalf("malformed: %v %+v", got, resp.Withdrawn)
	}
	// The API refuses labels, unknown people, nonsense scopes.
	for _, body := range []map[string]any{
		{"scope": "user", "id": pAlice, "allow": []string{"gmail"}},
		{"scope": "user", "id": "gh:999999", "allow": []string{}},
		{"scope": "user", "id": store.PoolPrincipal, "allow": []string{}},
		{"scope": "login", "id": "alice", "allow": []string{}},
		{"scope": "node", "id": "../m4", "allow": []string{}},
	} {
		if code, _ := h.post(t, CredPolicyPath, body); code != http.StatusBadRequest {
			t.Fatalf("%v → %d", body, code)
		}
	}
	// Nor can the generic settings PUT write one.
	if code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": credNodeKey("m4"), "value": "[]"}); code == http.StatusOK {
		t.Fatal("the generic settings PUT wrote an allowlist")
	}
}

func TestCredPolicyUnknownMachineFailsClosed(t *testing.T) {
	settings := map[string]string{credNodeKey("m9"): `["` + uuidGmail + `"]`}
	p := credPolicyOf(settings, "", pAlice)
	if !p.Restricted() || p.check(credvault.Claude, uuidGmail) == "" {
		t.Fatalf("an unnamed machine under machine allowlists: %+v", p)
	}
	if p.check(credvault.GitHub, "") != "" {
		t.Fatal("a GitHub token is not a subscription")
	}
	if p := credPolicyOf(map[string]string{CredPolicyModeKey: "legacy"}, "", pAlice); p.Restricted() {
		t.Fatal("no lists: unrestricted")
	}
	// A machine is its enrolled name, not what it reports now.
	h, alice, _ := policyRig(t)
	setPolicy(t, h, "node", "m4", []string{})
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(alice))
	if err != nil {
		t.Fatal(err)
	}
	if m := h.srv.policyMachine(ep.ID); m != "m4" {
		t.Fatalf("policy machine %q", m)
	}
}

func TestCredPolicyEffectiveView(t *testing.T) {
	h, _, _ := policyRig(t)
	setPolicy(t, h, "node", "m4", []string{uuidGmail, uuidOwn})
	setPolicy(t, h, "user", pAlice, []string{uuidOwn, uuidICloud})
	res, body := h.get(t, CredPolicyPath+"?machine=m4&principal="+pAlice)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("%d %s", res.StatusCode, body)
	}
	var out struct {
		Nodes []struct {
			ID    string   `json:"id"`
			Allow []string `json:"allow"`
		} `json:"nodes"`
		Effective struct {
			Restricted bool              `json:"restricted"`
			Accounts   []CredPolicyEntry `json:"accounts"`
		} `json:"effective"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	allowed := map[string]string{}
	for _, e := range out.Effective.Accounts {
		allowed[e.Account] = e.Reason
		if e.Account == "own" && (!e.Allowed || e.AccountUUID != uuidOwn) {
			t.Fatalf("own: %+v", e)
		}
	}
	if len(out.Nodes) != 1 || out.Nodes[0].ID != "m4" || !out.Effective.Restricted ||
		allowed["own"] != "" || !strings.Contains(allowed["gmail"], "person "+pAlice) ||
		!strings.Contains(allowed["icloud"], "machine m4") || strings.Contains(string(body), "sk-ant-") {
		t.Fatalf("view: %s", body)
	}
}

// The central proxy's every road chooses inside the lists: an explicit bind,
// a retained binding after the lists narrow, the 429 rebind.
func TestCredPolicySessionBind(t *testing.T) {
	r := newCPRig(t)
	h := r.h
	for _, c := range []struct{ acct, uuid string }{{"acct1", uuidOwn}, {"acct2", uuidGmail}} {
		if err := h.srv.Vault.Put("gh:1005", credvault.Claude, c.acct, credvault.Secret{RefreshToken: "rt-" + c.acct, AccountUUID: c.uuid}); err != nil {
			t.Fatal(err)
		}
	}
	cred, wid := r.issue(t, fidA)
	if st, out := sessDo(t, h, http.MethodPut, "/v1/fleet/session-cred/bind", r.tok5, "",
		map[string]any{"worker_id": wid, "provider": "claude", "account": "acct2"}); st != 200 {
		t.Fatalf("bind acct2: %d %v", st, out)
	}
	a1, a2 := r.leased(t, "gh:1005", credvault.Claude, "acct1"), r.leased(t, "gh:1005", credvault.Claude, "acct2")
	r.call(t, credvault.Claude, cred)
	if r.lastAuth() != a2 {
		t.Fatal("bound to acct2 first")
	}
	// The person may use acct1 only: the retained binding is re-picked.
	setPolicy(t, h, "user", "gh:1005", []string{uuidOwn})
	if st, _ := sessDo(t, h, http.MethodPut, "/v1/fleet/session-cred/bind", r.tok5, "",
		map[string]any{"worker_id": wid, "provider": "claude", "account": "acct2"}); st != http.StatusNotFound {
		t.Fatalf("an explicit bind outside the list → %d", st)
	}
	r.pastCache()
	r.call(t, credvault.Claude, cred)
	if r.lastAuth() != a1 {
		t.Fatalf("after narrowing → %q; want acct1", r.lastAuth())
	}
	// The machine allows nothing: no account at all, never a fallback.
	setPolicy(t, h, "node", "m5", []string{})
	r.pastCache()
	if st, body := r.call(t, credvault.Claude, cred); st == http.StatusOK || r.lastAuth() != a1 {
		t.Fatalf("deny-all machine: %d %s", st, body)
	}
	b, err := h.srv.sessionBindChoices("gh:1005", h.srv.passEndpoint(passID(h, cred), time.Now()), credvault.Claude)
	if err != nil || len(b) != 0 {
		t.Fatalf("choices under a deny-all machine: %v %v", b, err)
	}
}

// passID is a pass's id, read off its verified claims.
func passID(h *harness, cred string) string {
	if _, c := h.srv.verifySessionCred(cred, "", "", false, time.Now()); c != nil {
		return c.ID
	}
	return ""
}

// A list names subscriptions, not labels: a rename keeps its place, a new
// credential under an old label does not inherit it.
func TestCredPolicyRenameReplace(t *testing.T) {
	h, alice, _ := policyRig(t)
	setPolicy(t, h, "node", "m4", []string{uuidGmail})
	exp := time.Now().Add(24 * time.Hour).UTC()
	if err := h.srv.Store.DeleteCredential(store.PoolPrincipal, credvault.Claude, "gmail"); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Vault.Put(store.PoolPrincipal, credvault.Claude, "gmail-renamed", credvault.Secret{SetupToken: "sk-ant-oat01-g2", ExpiresAt: &exp, AccountUUID: uuidGmail}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Vault.Put(store.PoolPrincipal, credvault.Claude, "icloud", credvault.Secret{SetupToken: "sk-ant-oat01-i2", ExpiresAt: &exp, AccountUUID: uuidOwn}); err != nil {
		t.Fatal(err)
	}
	if got, _, _ := leased(t, h, alice); !eq(got, "claude/gmail-renamed") {
		t.Fatalf("rename / replace: %v", got)
	}
}

func TestCredPolicyStrictRequiresBothScopes(t *testing.T) {
	h, alice, bob := policyRig(t)
	if err := h.srv.Store.SetFleetSetting(CredPolicyModeKey, "strict", time.Now()); err != nil {
		t.Fatal(err)
	}
	if got, wd, resp := leased(t, h, alice); len(got) != 0 || len(wd) != 5 || resp.RecheckSecs == 0 {
		t.Fatalf("unconfigured: %v %v %+v", got, wd, resp)
	}
	setPolicy(t, h, "user", pAlice, []string{uuidGmail})
	if got, _, _ := leased(t, h, alice); len(got) != 0 {
		t.Fatalf("missing machine grant: %v", got)
	}
	if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": "node", "id": "m4", "all": true}); code != 200 {
		t.Fatalf("all: %d %v", code, out)
	}
	if got, _, _ := leased(t, h, alice); !eq(got, "claude/gmail") {
		t.Fatalf("intersection: %v", got)
	}
	if got, _, _ := leased(t, h, bob); len(got) != 0 {
		t.Fatalf("missing person grant: %v", got)
	}
	// Manifest deliberately evaluates machine scope only, even without a user grant.
	_, man, _ := getPool(t, h, bob)
	if len(man.Pool) == 0 {
		t.Fatal("machine manifest unexpectedly required person grant")
	}
	setPolicy(t, h, "user", pAlice, nil)
	if got, _, _ := leased(t, h, alice); len(got) != 0 {
		t.Fatalf("cleared grants must deny: %v", got)
	}
	p := credPolicyOf(map[string]string{credNodeKey("m4"): `"*"`, credUserKey(pAlice): `"*"`}, "m4", pAlice)
	if p.check(credvault.Claude, uuidOwn) != "" || p.check(credvault.Claude, "") != "" {
		t.Fatal("explicit all must include future and old unidentified subscriptions")
	}
	if p := credPolicyOf(map[string]string{credUserKey(pAlice): `"*"`}, "", pAlice); p.check(credvault.Claude, uuidGmail) == "" {
		t.Fatal("unknown machine escaped strict policy")
	}
}

func TestCredPolicyMigrationReview(t *testing.T) {
	h, alice, bob := policyRig(t)
	var view struct {
		Mode      string          `json:"mode"`
		Migration policyMigration `json:"migration"`
	}
	h.getJSON(t, CredPolicyPath, &view)
	if view.Mode != "legacy" || len(view.Migration.Objects) != 3 {
		t.Fatalf("review: %+v", view)
	}
	// Viewing does not change current access.
	if got, _, _ := leased(t, h, alice); len(got) != 5 {
		t.Fatal("review changed access")
	}
	req := map[string]any{"action": "activate", "revision": view.Migration.Revision, "retain": []string{credNodeKey("m4"), credUserKey(pAlice)}}
	setPolicy(t, h, "user", pBob, []string{})
	if code, _ := h.post(t, CredPolicyPath, req); code != 409 {
		t.Fatalf("stale review: %d", code)
	}
	h.getJSON(t, CredPolicyPath, &view)
	req["revision"] = view.Migration.Revision
	if code, out := h.post(t, CredPolicyPath, req); code != 200 {
		t.Fatalf("activate: %d %v", code, out)
	}
	if got, _, _ := leased(t, h, alice); len(got) != 5 {
		t.Fatalf("retained: %v", got)
	}
	if got, _, _ := leased(t, h, bob); len(got) != 0 {
		t.Fatalf("existing deny was overwritten: %v", got)
	}
	settings, _ := h.srv.Store.FleetSettings()
	if settings[CredPolicyModeKey] != "strict" || settings[credNodeKey("m4")] != `"*"` {
		t.Fatalf("settings: %v", settings)
	}
	if p := credPolicyOf(settings, "new-machine", "gh:999"); p.check(credvault.Claude, uuidGmail) == "" {
		t.Fatal("new object got legacy access")
	}
	if code, _ := h.post(t, CredPolicyPath, req); code != 409 {
		t.Fatalf("replayed activation: %d", code)
	}
	if code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": CredPolicyModeKey, "value": "legacy"}); code == 200 {
		t.Fatal("generic settings bypassed migration")
	}
}

func TestCredPolicyBeforeFirstLoginAndRevokedMigration(t *testing.T) {
	h, alice, _ := policyRig(t)
	if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: 98765, Login: "invited", Role: roleUser, AddedAt: time.Now(), AddedBy: "test"}); err != nil {
		t.Fatal(err)
	}
	setPolicy(t, h, "user", "gh:98765", []string{uuidGmail})
	settings, _ := h.srv.Store.FleetSettings()
	if settings[credUserKey("gh:98765")] == "" {
		t.Fatal("preauthorization was not stored")
	}
	review, err := h.srv.credPolicyReview(settings)
	if err != nil {
		t.Fatal(err)
	}
	req := map[string]any{"action": "activate", "revision": review.Revision, "retain": []string{"fleet.cred_allow.node.not-in-review"}}
	if code, _ := h.post(t, CredPolicyPath, req); code != 400 {
		t.Fatalf("unreviewed grant: %d", code)
	}
	req["retain"] = []string{}
	if code, out := h.post(t, CredPolicyPath, req); code != 200 {
		t.Fatalf("revoke migration: %d %v", code, out)
	}
	if got, _, _ := leased(t, h, alice); len(got) != 0 {
		t.Fatalf("revoked user/machine still leased: %v", got)
	}
	audits, err := h.srv.Store.CredAuditLog("", 100)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range audits {
		if a.Action == store.CredPolicy && strings.Contains(a.Detail, "activate strict") {
			found = true
		}
	}
	if !found {
		t.Fatal("migration missing from credential audit")
	}
}

func TestCredPolicyStrictSessionChoices(t *testing.T) {
	h, alice, _ := policyRig(t)
	if err := h.srv.Store.SetFleetSetting(CredPolicyModeKey, "strict", time.Now()); err != nil {
		t.Fatal(err)
	}
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(alice))
	if err != nil {
		t.Fatal(err)
	}
	grantAll := func(scope, id string) {
		t.Helper()
		if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": scope, "id": id, "all": true}); code != 200 {
			t.Fatalf("grant: %d %v", code, out)
		}
	}
	grantAll("node", "m4")
	if choices, err := h.srv.sessionBindChoices(pAlice, ep.ID, credvault.Claude); err != nil || len(choices) != 0 {
		t.Fatalf("missing user: %v %v", choices, err)
	}
	if _, err := h.srv.sessionBindChoices("", ep.ID, credvault.Claude); err == nil {
		t.Fatal("empty session owner became node-only policy")
	}
	grantAll("user", pAlice)
	if choices, err := h.srv.sessionBindChoices(pAlice, ep.ID, credvault.Claude); err != nil || len(choices) != 4 {
		t.Fatalf("all grants: %v %v", choices, err)
	}
	setPolicy(t, h, "node", "m4", nil)
	if choices, err := h.srv.sessionBindChoices(pAlice, ep.ID, credvault.Claude); err != nil || len(choices) != 0 {
		t.Fatalf("missing machine: %v %v", choices, err)
	}
}
