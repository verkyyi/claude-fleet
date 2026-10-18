package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Machine allowlists (claude-fleet#3824): which machines a person may use —
// one reader, every door a person meets a machine through.

func setMachinePolicy(t *testing.T, h *harness, principal string, body map[string]any) map[string]any {
	t.Helper()
	body["principal"] = principal
	code, out := h.post(t, MachinePolicyPath, body)
	if code != http.StatusOK {
		t.Fatalf("machine policy %s %v: %d %v", principal, body, code, out)
	}
	return out
}

func TestMachinePolicyGrammar(t *testing.T) {
	p := "gh:7"
	for _, c := range []struct {
		raw, machine string
		denied       bool
		why          string
	}{
		{"", "mac-a", false, ""},                              // no key
		{`"*"`, "mac-a", false, ""},                           // explicit all
		{`["mac-a","Mac-E.local"]`, "MAC-A.local", false, ""}, // first label, any case
		{`["mac-a","Mac-E.local"]`, "mac-e", false, ""},       // the list's own first label
		{`["mac-a"]`, "mac-b", true, "可用：mac-a"},              // off the list: names what is open
		{`[]`, "mac-a", true, "暂未给你开放任何机器"},                   // none
		{`{"x":1}`, "mac-a", true, "写坏了"},                     // malformed: none, never all
		{`null`, "mac-a", true, "写坏了"},                        // null is not a list
		{`["bad name!"]`, "mac-a", true, "写坏了"},               // not a machine name
	} {
		settings := map[string]string{}
		if c.raw != "" {
			settings[machineAllowKey(p)] = c.raw
		}
		why := machineDenied(settings, c.machine, p)
		if (why != "") != c.denied || !strings.Contains(why, c.why) {
			t.Errorf("%s on %s: %q; want denied=%v containing %q", c.raw, c.machine, why, c.denied, c.why)
		}
		// the operator is never narrowed
		if w := machineDenied(settings, c.machine, ""); w != "" {
			t.Errorf("%s: the operator denied: %q", c.raw, w)
		}
	}
	if anyMachinePolicy(map[string]string{"fleet.cred_allow.user.gh:7": `"*"`}) {
		t.Fatal("a subscription list is not a machine list")
	}
}

// The degenerate case: no list anywhere — the lease is what it was, with no
// recheck asked for.
func TestMachinePolicyOffAddsNothing(t *testing.T) {
	h, alice, _ := policyRig(t)
	got, wd, resp := leased(t, h, alice)
	if !eq(got, "claude/gmail", "claude/icloud", "claude/legacy", "claude/own", "codex/default") || len(wd) != 0 || resp.RecheckSecs != 0 {
		t.Fatalf("no machine list: %v withdrawn %v recheck %d", got, wd, resp.RecheckSecs)
	}
}

func TestMachinePolicyPutGet(t *testing.T) {
	h, _, _ := policyRig(t)
	out := setMachinePolicy(t, h, pAlice, map[string]any{"allow": []string{"Linux-A.local", "mac-e", "mac-e"}})
	if out["key"] != MachineAllowUserPrefix+pAlice {
		t.Fatalf("put: %v", out)
	}
	settings, _ := h.srv.Store.FleetSettings()
	if v := settings[machineAllowKey(pAlice)]; v != `["linux-a","mac-e"]` {
		t.Fatalf("stored %q; want the normalised, deduplicated, sorted list", v)
	}
	for _, bad := range []map[string]any{
		{"principal": "not a principal!", "allow": []string{"mac-e"}},
		{"principal": pAlice, "allow": []string{"no such name!"}},
		{"principal": pAlice, "allow": []string{"mac-e"}, "all": true},
		{"principal": "gh:424242", "allow": []string{"mac-e"}},
	} {
		if code, o := h.post(t, MachinePolicyPath, bad); code != http.StatusBadRequest {
			t.Errorf("%v: %d %v; want 400", bad, code, o)
		}
	}
	// the generic settings door never writes one
	if code, _ := h.post(t, "/v1/fleet/settings", map[string]any{"key": machineAllowKey(pAlice), "value": `"*"`}); code != http.StatusBadRequest {
		t.Fatalf("generic settings PUT of a machine list: %d; want 400", code)
	}
	res, raw := h.get(t, MachinePolicyPath+"?principal="+pAlice)
	got := map[string]any{}
	if res.StatusCode != http.StatusOK || json.Unmarshal(raw, &got) != nil {
		t.Fatalf("get: %d %s", res.StatusCode, raw)
	}
	users, _ := got["users"].([]any)
	if len(users) != 1 || users[0].(map[string]any)["principal"] != pAlice {
		t.Fatalf("users: %v", got["users"])
	}
	eff, _ := got["effective"].(map[string]any)
	if eff["restricted"] != true {
		t.Fatalf("effective: %v", eff)
	}
	ms, _ := eff["machines"].([]any)
	found := false
	for _, m := range ms {
		mm := m.(map[string]any)
		if mm["machine"] == "mac-c" {
			found = true
			if mm["allowed"] != false || !strings.Contains(mm["reason"].(string), "可用：linux-a、mac-e") {
				t.Fatalf("mac-c: %v", mm)
			}
		}
	}
	if !found {
		t.Fatalf("mac-c not in the effective view: %v", ms)
	}
	// clear: no key at all
	setMachinePolicy(t, h, pAlice, map[string]any{"allow": nil})
	settings, _ = h.srv.Store.FleetSettings()
	if anyMachinePolicy(settings) {
		t.Fatalf("cleared, still a list: %v", settings[machineAllowKey(pAlice)])
	}
}

// A machine off the person's list leases them nothing there and withdraws what
// the node holds; another person on the same machine is untouched; cleared,
// everything comes back.
func TestMachinePolicyLeaseWithdraws(t *testing.T) {
	h, alice, bob := policyRig(t)
	setMachinePolicy(t, h, pAlice, map[string]any{"allow": []string{"mac-e"}})
	got, wd, resp := leased(t, h, alice)
	if len(got) != 0 || !eq(wd, "claude/gmail", "claude/icloud", "claude/legacy", "claude/own", "codex/default") {
		t.Fatalf("alice off mac-c: leased %v withdrawn %v", got, wd)
	}
	for _, c := range resp.Withdrawn {
		if !strings.Contains(c.Error, MachineDisabledWord) || !strings.Contains(c.Error, "可用：mac-e") {
			t.Fatalf("withdrawal reason %q", c.Error)
		}
	}
	if resp.RecheckSecs == 0 {
		t.Fatal("a machine list exists: the node must recheck")
	}
	if got, wd, _ := leased(t, h, bob); len(got) != 4 || len(wd) != 0 {
		t.Fatalf("bob on the same machine: %v %v", got, wd)
	}
	setMachinePolicy(t, h, pAlice, map[string]any{"allow": []string{"MAC-C"}})
	if got, wd, _ := leased(t, h, alice); len(got) != 5 || len(wd) != 0 {
		t.Fatalf("alice back on mac-c: %v %v", got, wd)
	}
	setMachinePolicy(t, h, pAlice, map[string]any{"all": true})
	if got, _, _ := leased(t, h, alice); len(got) != 5 {
		t.Fatalf("alice, all: %v", got)
	}
}

// A session pass: none is minted on a machine off the list, and one already
// out stops at its next verify (not its expiry) — and works again once the
// list lets the machine back, never marked revoked.
func TestMachinePolicySessionPass(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, nil)
	cred := out["cred"].(string)
	now := time.Now()
	if v, _ := h.srv.verifySessionCred(cred, "", "", false, now); !v.Valid {
		t.Fatalf("before: %+v", v)
	}
	setMachinePolicy(t, h, "gh:1005", map[string]any{"allow": []string{"mac-c"}})
	v, _ := h.srv.verifySessionCred(cred, "", "", false, now)
	if v.Valid || v.Revoked || !strings.Contains(v.Reason, MachineDisabledWord) {
		t.Fatalf("after the list (cache dropped by the PUT): %+v; want refused, not revoked", v)
	}
	a := signWorkerAssertion(assertClaims(f5, time.Now()), HashToken(tok5))
	st, body := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred", tok5, a, nil)
	if st != http.StatusForbidden || body["error"] != LeaseMachineOff || !strings.Contains(body["message"].(string), MachineDisabledWord) {
		t.Fatalf("mint on mac-d off the list: %d %v", st, body)
	}
	setMachinePolicy(t, h, "gh:1005", map[string]any{"allow": nil})
	if v, _ := h.srv.verifySessionCred(cred, "", "", false, now); !v.Valid {
		t.Fatalf("cleared: %+v; want valid again", v)
	}
}

// Placement: a machine off the person's list is out for auto (another one
// is chosen, the reason names it) AND for a start that names it.
func TestMachinePolicyPlacement(t *testing.T) {
	h, macD, _, f5, _ := twoNodes(t)
	macD.beatLoad("mac-d", "frank", machineA, 2, 1, f5) // room on mac-d too
	waitLoad(t, h, "mac-d", 2)
	p, err := h.srv.Store.AdoptPrincipal("gh:1005", "frank", "Frank", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, host := range []string{"mac-d", "mac-c"} {
		if err := h.srv.Store.AdoptAccount(p, host, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if pl, err := h.srv.PickNode("gh:1005", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("no list: %q %v; want mac-c", pl.Machine, err)
	}
	setMachinePolicy(t, h, "gh:1005", map[string]any{"allow": []string{"mac-d"}})
	pl, err := h.srv.PickNode("gh:1005", writeRepo)
	if err != nil || pl.Machine != "mac-d" || !strings.Contains(pl.Reason, MachineDisabledWord) {
		t.Fatalf("mac-c off the list: %q %q %v; want mac-d, mac-c excluded as disabled", pl.Machine, pl.Reason, err)
	}
	scope, err := h.srv.scopeFor("gh:1005")
	if err != nil {
		t.Fatal(err)
	}
	_, err = h.srv.pickNode(fleetPrincipal{Actor: "gh:1005", Person: "gh:1005", scope: scope}, writeRepo, "mac-c", "", time.Now())
	if err == nil || !strings.Contains(err.Error(), MachineDisabledWord) {
		t.Fatalf("named mac-c off the list: %v; want refused naming it", err)
	}
	// the operator is never narrowed by a person's list
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("operator: %q %v; want mac-c", pl.Machine, err)
	}
}

// `fleet` / `fleet <machine>`: a machine off the list is no candidate, no
// route — it is listed under disabled with why; every machine off ⇒ the
// policy's refusal, never «no login» (which would open them a new one).
func TestMachinePolicyHomeAndRoutes(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "mac-d", Routes: []FleetRoute{{Name: "lan", Host: "mac-d.lan"}}},
		{Hostname: "mac-c", Routes: []FleetRoute{{Name: "lan", Host: "mac-c.lan"}}},
	}
	p, err := h.srv.Store.AdoptPrincipal("gh:1005", "frank", "Frank", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, host := range []string{"mac-d", "mac-c"} {
		if err := h.srv.Store.AdoptAccount(p, host, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	out, err := h.srv.homePick("gh:1005", "", now)
	if err != nil || len(out.Machines) != 2 || len(out.Disabled) != 0 {
		t.Fatalf("no list: %+v (%v); want both machines, none disabled", out.Machines, err)
	}
	setMachinePolicy(t, h, "gh:1005", map[string]any{"allow": []string{"mac-d"}})
	out, err = h.srv.homePick("gh:1005", "mac-c", now)
	if err != nil || len(out.Machines) != 1 || out.Machines[0].Hostname != "mac-d" || out.Machine == nil || out.Machine.Hostname != "mac-d" {
		t.Fatalf("mac-c off: %+v pick %+v (%v); want mac-d only", out.Machines, out.Machine, err)
	}
	if len(out.Disabled) != 1 || out.Disabled[0].Hostname != "mac-c" || !strings.Contains(out.Disabled[0].Reason, "这台机器暂未对你开放，可用：mac-d") {
		t.Fatalf("disabled: %+v", out.Disabled)
	}
	_, logins, hosts, err := h.srv.fleetLoginsOf("gh:1005")
	if err != nil || hosts["mac-c"] || !hosts["mac-d"] || len(logins) != 1 {
		t.Fatalf("certificate logins %v hosts %v (%v); want mac-d's only", logins, hosts, err)
	}
	if err := h.srv.sshRelayAllowed(sshRelayIdentity{Principal: "gh:1005"}, "mac-c"); err == nil || !strings.Contains(err.Error(), MachineDisabledWord) {
		t.Fatalf("relay to mac-c: %v; want refused naming the policy", err)
	}
	if err := h.srv.sshRelayAllowed(sshRelayIdentity{Principal: "gh:1005"}, "mac-d"); err != nil {
		t.Fatalf("relay to mac-d: %v", err)
	}
	setMachinePolicy(t, h, "gh:1005", map[string]any{"allow": []string{}})
	if _, err := h.srv.homePick("gh:1005", "", now); !errors.Is(err, errMachineOff) || !errors.Is(err, errNoAccount) || !strings.Contains(err.Error(), "暂未给你开放任何机器") {
		t.Fatalf("every machine off: %v; want the policy's refusal", err)
	}
}

// The entry door: a home off the list keeps its login on the machine's list
// with no key; back on the list, the keys return.
func TestMachinePolicyEntryKeys(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	now := time.Now()
	if _, err := h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "mac-c", Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := h.srv.Store.AddEntryKey(store.EntryKey{ID: "k1", Person: pAlice, FP: "SHA256:x", Type: "ssh-ed25519", B64: "AAAA", Name: "phone", Created: now}); err != nil {
		t.Fatal(err)
	}
	keys := func() int {
		l, err := h.srv.entryNodeList("mac-c")
		if err != nil {
			t.Fatal(err)
		}
		lg, ok := l.Logins["alice"]
		if !ok {
			t.Fatalf("alice's login left mac-c's list: %+v", l)
		}
		return len(lg.Keys)
	}
	if n := keys(); n != 1 {
		t.Fatalf("no list: %d keys", n)
	}
	setMachinePolicy(t, h, pAlice, map[string]any{"allow": []string{"mac-d"}})
	if n := keys(); n != 0 {
		t.Fatalf("mac-c off alice's list: %d keys; want none", n)
	}
	setMachinePolicy(t, h, pAlice, map[string]any{"allow": nil})
	if n := keys(); n != 1 {
		t.Fatalf("cleared: %d keys", n)
	}
}
