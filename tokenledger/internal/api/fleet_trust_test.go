package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 可信 / 不可信 (claude-fleet#1968, EPIC #1967 C1): only a machine the operator
// trusts leases subscription credentials.

func rawLease(t *testing.T, h *harness, tok string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/credentials", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var b bytes.Buffer
	_, _ = b.ReadFrom(res.Body)
	return res.StatusCode, b.Bytes()
}

func trustAuditCount(t *testing.T, h *harness, where string) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_trust' AND ` + where).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func credAuditActions(t *testing.T, h *harness) []string {
	t.Helper()
	rows, err := h.srv.Store.CredAuditLog("", 1000)
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, a := range rows {
		out = append(out, a.Action+"|"+a.Provider+"|"+a.Hostname+"|"+a.Detail)
	}
	sort.Strings(out)
	return out
}

// The degenerate case is sacred: a machine that had an active fleet account
// when trust shipped is migrated to trusted on the first read, and its lease
// is what it was — the same fields, the same credentials, the same audit
// rows, no new refusal — while the only settings that appear are its trust
// key and the migration stamp.
func TestTrustOffAddsNothing(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	putCred(t, h, credvault.GitHub, "alice", credvault.Secret{Token: "ghp_x", User: "alice"})
	if s, _ := h.srv.Store.FleetSettings(); len(s) != 0 {
		t.Fatalf("settings before the first read: %v", s)
	}

	code, body := rawLease(t, h, tok)
	if code != http.StatusOK {
		t.Fatalf("migrated m4 lease: %d %s", code, body)
	}
	var top map[string]json.RawMessage
	_ = json.Unmarshal(body, &top)
	keys := []string{}
	for k := range top {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if strings.Join(keys, ",") != "credentials,issued_at,principal_id" || bytes.Contains(body, []byte("trust")) {
		t.Fatalf("lease answer changed shape: %s", body)
	}
	var got NodeCredentialsResponse
	_ = json.Unmarshal(body, &got)
	if got.PrincipalID != pAlice || len(got.Credentials) != 2 {
		t.Fatalf("lease = %+v", got)
	}
	for _, c := range got.Credentials {
		if c.Access == nil || c.Error != "" {
			t.Fatalf("credential %+v", c)
		}
	}
	// A second lease answers byte for byte the same apart from its clock.
	_, again := rawLease(t, h, tok)
	strip := func(b []byte) string {
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		delete(m, "issued_at")
		out, _ := json.Marshal(m)
		return string(out)
	}
	if strip(body) != strip(again) {
		t.Fatalf("second lease differs:\n%s\n%s", body, again)
	}
	for _, a := range credAuditActions(t, h) {
		if strings.HasPrefix(a, store.CredDeny) {
			t.Fatalf("a trusted machine's lease wrote a deny: %v", credAuditActions(t, h))
		}
	}

	s, _ := h.srv.Store.FleetSettings()
	if len(s) != 2 || s[NodeTrustPrefix+"m4"] != TrustTrusted || s[NodeTrustMigratedKey] == "" {
		t.Fatalf("settings after the migration: %v", s)
	}
	if n := trustAuditCount(t, h, `actor = 'migration' AND fleet_id = 'machine:m4'`); n != 1 {
		t.Fatalf("migration audit rows = %d, want 1", n)
	}
	// The migration runs once: a later read writes nothing more.
	before := s[NodeTrustMigratedKey]
	time.Sleep(1100 * time.Millisecond)
	rawLease(t, h, tok)
	if s2, _ := h.srv.Store.FleetSettings(); s2[NodeTrustMigratedKey] != before || len(s2) != 2 {
		t.Fatalf("the migration ran twice: %v", s2)
	}
}

// A machine that joins after the migration is untrusted until the operator
// says otherwise; marking a trusted one untrusted stops its next lease. Every
// refusal is a 403 untrusted_node and a fleet_cred_audit deny row.
func TestTrustUntrustedRefusedAndAudited(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	if code, _, _ := lease(t, h, m4); code != http.StatusOK {
		t.Fatalf("m4 before: %d", code)
	}

	// alice gets a login on a new machine, m9, after the migration ran.
	p, err := h.srv.Store.Principal(pAlice)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m9", time.Now()); err != nil {
		t.Fatal(err)
	}
	m9 := enrollAs(t, h, "alice-m9", "m9", "alice")
	code, ok, refusal := lease(t, h, m9)
	if code != http.StatusForbidden || refusal["error"] != LeaseUntrusted || ok.Credentials != nil {
		t.Fatalf("new machine m9: %d %v %+v", code, refusal, ok)
	}

	// The operator marks m4 untrusted: its next lease is refused.
	putSetting(t, h, NodeTrustPrefix+"m4", TrustUntrusted, 200)
	if code, _, refusal := lease(t, h, m4); code != http.StatusForbidden || refusal["error"] != LeaseUntrusted {
		t.Fatalf("m4 untrusted: %d %v", code, refusal)
	}
	// …and trusting m9 (by its full name) lets it lease.
	putSetting(t, h, NodeTrustPrefix+"m9.local", TrustTrusted, 200)
	if code, _, refusal := lease(t, h, m9); code != http.StatusOK {
		t.Fatalf("m9 trusted: %d %v", code, refusal)
	}
	putSetting(t, h, NodeTrustPrefix+"m4", TrustTrusted, 200)
	if code, _, _ := lease(t, h, m4); code != http.StatusOK {
		t.Fatalf("m4 trusted again: %d", code)
	}

	denies := 0
	rows, _ := h.srv.Store.CredAuditLog("", 1000)
	for _, a := range rows {
		if a.Action == store.CredDeny && strings.HasPrefix(a.Detail, LeaseUntrusted) {
			denies++
			if a.PrincipalID != pAlice || a.EndpointID == "" {
				t.Fatalf("deny row lacks who / which node: %+v", a)
			}
		}
	}
	if denies != 2 {
		t.Fatalf("%d untrusted deny rows, want 2 (m9, then m4)", denies)
	}
	if n := trustAuditCount(t, h, `actor = 'operator'`); n != 3 {
		t.Fatalf("operator trust audit rows = %d, want 3", n)
	}

	// The node's own read carries the word.
	putSetting(t, h, NodeTrustPrefix+"m9", "", 200)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/self", nil)
	req.Header.Set("Authorization", "Bearer "+m9)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var self map[string]any
	_ = json.NewDecoder(res.Body).Decode(&self)
	res.Body.Close()
	if self["trust"] != TrustUntrusted {
		t.Fatalf("m9's own read after clearing: %v", self)
	}
}

// Untrusted is checked AFTER the principal and the revocation: a login with no
// account still reads no_principal, a revoked machine still reads revoked.
func TestTrustCheckedAfterPrincipalAndRevocation(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	putSetting(t, h, NodeTrustPrefix+"m4", TrustUntrusted, 200)
	bob := enrollAs(t, h, "bob-m4", "m4", "bob")
	if code, _, refusal := lease(t, h, bob); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("bob: %d %v", code, refusal)
	}
	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4", Reason: "lost"}); code != http.StatusOK {
		t.Fatalf("revoke: %d %v", code, out)
	}
	if code, _, refusal := lease(t, h, m4); code != http.StatusForbidden || refusal["error"] != LeaseRevoked {
		t.Fatalf("revoked + untrusted: %d %v", code, refusal)
	}
}

// A client holding only a connection certificate (or a person's session, or
// the viewer token) has no enrollment token, so it never leases — whatever
// the trust settings say.
func TestTrustClientCertNeverLeases(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	putSetting(t, h, NodeTrustPrefix+"m4", TrustTrusted, 200)
	cert := "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29t alice@laptop"
	for name, tok := range map[string]string{"certificate": cert, "viewer token": viewerToken, "empty": ""} {
		if code, body := rawLease(t, h, tok); code != http.StatusUnauthorized {
			t.Fatalf("%s leased: %d %s", name, code, body)
		}
	}
	enablePeople(t, h, pAlice, pBob, pCarol)
	if code, body := asPerson(t, h, http.MethodPost, "/v1/node/credentials", pAlice, nil); code != http.StatusUnauthorized {
		t.Fatalf("a signed-in person leased: %d %s", code, body)
	}
}

// Trust is the operator's word alone: a signed-in person cannot set it, a
// node has no route that does, a bad value or name is refused, and the
// migration stamp is not a setting anyone writes.
func TestTrustSettingOperatorOnly(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	enablePeople(t, h, pAlice, pBob, pCarol)
	body, _ := json.Marshal(map[string]string{"key": NodeTrustPrefix + "m9", "value": TrustTrusted})
	if code, _ := asPerson(t, h, http.MethodPut, "/v1/fleet/settings", pAlice, body); code != http.StatusForbidden {
		t.Fatalf("a person set trust: HTTP %d, want 403", code)
	}
	req, _ := http.NewRequest(http.MethodPut, h.http.URL+"/v1/fleet/settings", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+m4)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode == http.StatusOK {
		t.Fatal("a node's enrollment token set trust")
	}
	// The node's own maintenance route takes no trust.
	if code, _ := maintCall(t, h, m4, http.MethodPost, map[string]any{"action": "trust", "trust": TrustTrusted}); code == http.StatusOK {
		t.Fatal("the node route accepted a trust action")
	}
	if s, _ := h.srv.Store.FleetSettings(); s[NodeTrustPrefix+"m9"] != "" {
		t.Fatalf("m9 trusted by someone other than the operator: %v", s)
	}
	putSetting(t, h, NodeTrustPrefix+"m4", "maybe", 400)
	putSetting(t, h, NodeTrustPrefix+"bad name!", TrustTrusted, 400)
	putSetting(t, h, NodeTrustMigratedKey, "x", 400)
	out := putSetting(t, h, NodeTrustPrefix+"m9", TrustTrusted, 200)
	if eff := out["effective"].(map[string]any); eff[NodeTrustPrefix+"m9"] != TrustTrusted {
		t.Fatalf("effective after the operator's write: %v", eff)
	}
}

// The roster carries trust per node: the migrated machine trusted, a machine
// that connected later untrusted.
func TestTrustOnRoster(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	connectNode(t, h, "m4-agent", "m4", "alice", false)
	connectNode(t, h, "m7-agent", "m7", "carol", false)
	waitFor(t, 5*time.Second, "both nodes on the roster", func() bool { _, n := nodeStatuses(t, h); return n["m4"] != nil && n["m7"] != nil })
	_, nodes := nodeStatuses(t, h)
	if nodes["m4"]["trust"] != TrustTrusted || nodes["m7"]["trust"] != TrustUntrusted {
		t.Fatalf("roster trust: m4=%v m7=%v", nodes["m4"]["trust"], nodes["m7"]["trust"])
	}
}
