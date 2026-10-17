package api

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

// claude-fleet#4601: every pod of the cluster uses Codex only. A person's pod
// read its owner's allowance as the machine's (#4290), so the owner opened to
// "*" handed every new pod Claude too. The machine layer of a cluster pod now
// passes fleet.cred_pod_providers (default codex) first: an owner's "*" is
// every Codex subscription, an owner's list only its Codex entries, Claude is
// refused with the reason; an ordinary machine is unchanged.
func TestClusterPodCodexOnly(t *testing.T) {
	h, _, _ := policyRig(t)
	now := time.Now()
	if err := h.srv.Store.SetFleetSetting(CredPolicyModeKey, "strict", now); err != nil {
		t.Fatal(err)
	}
	pa, err := h.srv.Store.Principal(pAlice)
	if err != nil {
		t.Fatal(err)
	}
	const pod = "u-pod4601a"
	if err := h.srv.Store.AdoptAccount(pa, pod, now); err != nil {
		t.Fatal(err)
	}
	alicePod := enrollAs(t, h, "alice-"+pod, pod, pa.Login)
	if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": "user", "id": pAlice, "all": true}); code != http.StatusOK {
		t.Fatalf("alice \"*\": %d %v", code, out)
	}
	// The owner is "*": the new pod gets every Codex subscription, no Claude.
	got, wd, resp := leased(t, h, alicePod)
	if !eq(got, "codex/default") {
		t.Fatalf("owner \"*\" pod leased %v, want only codex", got)
	}
	if !eq(wd, "claude/gmail", "claude/icloud", "claude/legacy", "claude/own") {
		t.Fatalf("owner \"*\" pod withdrew %v", wd)
	}
	for _, c := range resp.Withdrawn {
		if !strings.Contains(c.Error, "cluster pods are Codex-only") || !strings.Contains(c.Error, CredPodProvidersKey) {
			t.Fatalf("withdrawal reason %q does not name the rule", c.Error)
		}
	}
	// The owner's list: only its Codex entries count on the pod.
	setPolicy(t, h, "user", pAlice, []string{uuidGmail, uuidCodex})
	if got, _, _ := leased(t, h, alicePod); !eq(got, "codex/default") {
		t.Fatalf("owner list pod: %v", got)
	}
	setPolicy(t, h, "user", pAlice, []string{uuidGmail})
	if got, _, _ := leased(t, h, alicePod); len(got) != 0 {
		t.Fatalf("owner with no Codex entry: pod leased %v", got)
	}
	// An ordinary machine is not a cluster pod: Claude as before.
	setAll(t, h, "user", pAlice)
	if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": "node", "id": "mac-c", "all": true}); code != http.StatusOK {
		t.Fatalf("mac-c \"*\": %d %v", code, out)
	}
	if err := h.srv.Store.AdoptAccount(pa, "mac-c", now); err != nil {
		t.Fatal(err)
	}
	if got, _, _ := leased(t, h, enrollAs(t, h, "alice-mac-c4601", "mac-c", pa.Login)); !eq(got, "claude/gmail", "claude/icloud", "claude/legacy", "claude/own", "codex/default") {
		t.Fatalf("ordinary machine: %v", got)
	}
	// The shared ACK worker: a hand-written list naming Claude still gets Codex only.
	const ack = "fleet-linux-3"
	if err := h.srv.Store.AdoptAccount(pa, ack, now); err != nil {
		t.Fatal(err)
	}
	setPolicy(t, h, "node", ack, []string{uuidGmail, uuidCodex})
	if err := h.srv.Store.SetFleetSetting(trustKey(ack), TrustTrusted, now); err != nil {
		t.Fatal(err)
	}
	ackTok := enrollAs(t, h, "alice-"+ack, ack, pa.Login)
	if got, _, _ := leased(t, h, ackTok); !eq(got, "codex/default") {
		t.Fatalf("fleet-linux-3: %v", got)
	}
	// The setting widens it on purpose, audited like any hub setting.
	if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": CredPodProvidersKey, "value": "claude , codex"}); code != http.StatusOK {
		t.Fatalf("set %s: %d %v", CredPodProvidersKey, code, out)
	}
	if got, _, _ := leased(t, h, alicePod); !eq(got, "claude/gmail", "claude/icloud", "claude/legacy", "claude/own", "codex/default") {
		t.Fatalf("codex,claude: %v", got)
	}
	if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": CredPodProvidersKey, "value": "claude"}); code != http.StatusOK {
		t.Fatalf("set claude: %d %v", code, out)
	}
	if got, _, _ := leased(t, h, alicePod); eq(got, "codex/default") || len(got) != 4 {
		t.Fatalf("claude only: %v", got)
	}
	if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": CredPodProvidersKey, "value": ""}); code != http.StatusOK {
		t.Fatalf("clear: %d %v", code, out)
	}
	if got, _, _ := leased(t, h, alicePod); !eq(got, "codex/default") {
		t.Fatalf("back to the default: %v", got)
	}
}

// A list written for the pod itself still applies (#4290), under the gate.
func TestClusterPodOwnListKept(t *testing.T) {
	h, _, _ := policyRig(t)
	now := time.Now()
	if err := h.srv.Store.SetFleetSetting(CredPolicyModeKey, "strict", now); err != nil {
		t.Fatal(err)
	}
	pa, err := h.srv.Store.Principal(pAlice)
	if err != nil {
		t.Fatal(err)
	}
	const pod = "u-pod4601b"
	if err := h.srv.Store.AdoptAccount(pa, pod, now); err != nil {
		t.Fatal(err)
	}
	tok := enrollAs(t, h, "alice-"+pod, pod, pa.Login)
	setAll(t, h, "user", pAlice)
	setPolicy(t, h, "node", pod, []string{uuidCodex})
	if got, _, _ := leased(t, h, tok); !eq(got, "codex/default") {
		t.Fatalf("pod's own Codex list: %v", got)
	}
	setPolicy(t, h, "node", pod, []string{})
	if got, _, _ := leased(t, h, tok); len(got) != 0 {
		t.Fatalf("pod's own [] list: %v", got)
	}
}

func TestCheckCredPodProviders(t *testing.T) {
	for in, want := range map[string]string{
		"codex": "codex", " Codex ": "codex", "claude,codex": "claude,codex", "codex, claude,codex": "claude,codex", "*": "*",
	} {
		if got, why := checkCredPodProviders(nil, in); got != want || why != "" {
			t.Errorf("%q → %q %q, want %q", in, got, why, want)
		}
	}
	for _, in := range []string{"github", "codex,", "all", "codex;claude"} {
		if got, why := checkCredPodProviders(nil, in); why == "" {
			t.Errorf("%q accepted as %q", in, got)
		}
	}
	for m, want := range map[string]bool{
		"u-abcd1234": true, "u-drillx1": true, "fleet-linux-3": true, "fleet-linux-3.fleet-workers": true,
		"ccquota-spot-ab12": true, "mac-c": false, "fleet-linux-": false, "mac-b": false, "": false,
	} {
		if got := isClusterPodMachine(m); got != want {
			t.Errorf("isClusterPodMachine(%q) = %v", m, got)
		}
	}
	// A stored value that does not parse never widens it.
	if p := podProvidersOf(map[string]string{CredPodProvidersKey: "bogus"}, "u-abcd1234"); len(p) != 1 || !p["codex"] {
		t.Errorf("bad stored value: %v", p)
	}
	if p := podProvidersOf(map[string]string{CredPodProvidersKey: "*"}, "u-abcd1234"); p != nil {
		t.Errorf("* still gates: %v", p)
	}
	if p := podProvidersOf(nil, "mac-c"); p != nil {
		t.Errorf("ordinary machine gated: %v", p)
	}
}

func setAll(t *testing.T, h *harness, scope, id string) {
	t.Helper()
	if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": scope, "id": id, "all": true}); code != http.StatusOK {
		t.Fatalf("policy %s %s \"*\": %d %v", scope, id, code, out)
	}
}
