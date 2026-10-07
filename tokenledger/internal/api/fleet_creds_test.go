package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	iofs "io/fs"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

type stubRefresher struct{ n atomic.Int64 }

func (r *stubRefresher) Refresh(_ context.Context, provider string, s credvault.Secret) (credvault.Access, credvault.Secret, error) {
	n := r.n.Add(1)
	exp := time.Now().Add(8 * time.Hour).UTC()
	next := s
	next.RefreshToken = fmt.Sprintf("rotated-%d", n)
	return credvault.Access{AccessToken: fmt.Sprintf("%s-access-%d", provider, n), AccountID: s.AccountID, ExpiresAt: &exp}, next, nil
}

// newVaultHarness is a fleet hub with the vault on, one person ("alice")
// whose active account is login alice on m4, and a node enrolled as that
// login. It returns the harness, the node's token and the refresher.
func newVaultHarness(t *testing.T) (*harness, string, *stubRefresher) {
	t.Helper()
	h := newFleetHarness(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	ref := &stubRefresher{}
	h.srv.Vault = &credvault.Vault{Store: h.srv.Store, Sealer: sealer, Refresher: ref}
	tok := enrollAs(t, h, "alice-m4", "m4", "alice")
	p, err := h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	return h, tok, ref
}

func enrollAs(t *testing.T, h *harness, label, hostname, osUser string) string {
	t.Helper()
	tok := h.enroll(t, label)
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint("ep_"+label, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	return tok
}

func lease(t *testing.T, h *harness, tok string) (int, NodeCredentialsResponse, map[string]string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/credentials", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body bytes.Buffer
	_, _ = body.ReadFrom(res.Body)
	var ok NodeCredentialsResponse
	var refusal map[string]string
	if res.StatusCode == http.StatusOK {
		_ = json.Unmarshal(body.Bytes(), &ok)
	} else {
		_ = json.Unmarshal(body.Bytes(), &refusal)
	}
	return res.StatusCode, ok, refusal
}

func putCred(t *testing.T, h *harness, provider, account string, s credvault.Secret) {
	t.Helper()
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put",
		PrincipalID: pAlice, Provider: provider, Account: account, Secret: s})
	if code != http.StatusOK {
		t.Fatalf("put %s/%s: %d %v", provider, account, code, out)
	}
}

func TestNodeLeaseGetsOnlyShortLivedHalf(t *testing.T) {
	h, tok, ref := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "sk-ant-ort01-SECRET"})
	putCred(t, h, credvault.Codex, "main", credvault.Secret{RefreshToken: "rt-SECRET", AccountID: "acct-1"})
	putCred(t, h, credvault.GitHub, "alice", credvault.Secret{Token: "ghp_x", User: "alice"})

	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/credentials", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var raw bytes.Buffer
	_, _ = raw.ReadFrom(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("lease: %d %s", res.StatusCode, raw.String())
	}
	if strings.Contains(raw.String(), "SECRET") || strings.Contains(raw.String(), "rotated-") {
		t.Fatalf("a refresh token reached the node: %s", raw.String())
	}
	var got NodeCredentialsResponse
	_ = json.Unmarshal(raw.Bytes(), &got)
	if got.PrincipalID != pAlice || len(got.Credentials) != 3 {
		t.Fatalf("lease = %+v", got)
	}
	by := map[string]NodeCredential{}
	for _, c := range got.Credentials {
		by[c.Provider] = c
	}
	if c := by["claude"]; c.Access == nil || c.Access.AccessToken != "claude-access-1" || c.ExpiresAt == nil {
		t.Fatalf("claude lease %+v", c)
	}
	if c := by["codex"]; c.Access == nil || c.Access.AccountID != "acct-1" || c.ExpiresAt == nil {
		t.Fatalf("codex lease %+v", c)
	}
	if c := by["github"]; c.Access == nil || c.Access.Token != "ghp_x" || c.ExpiresAt != nil {
		t.Fatalf("github lease %+v", c)
	}
	// A second lease within the TTL is served from the cache: no refresh.
	if code, _, _ := lease(t, h, tok); code != http.StatusOK || ref.n.Load() != 2 {
		t.Fatalf("second lease: %d, refreshes=%d (want 2: claude + codex once)", code, ref.n.Load())
	}
	audit, _ := h.srv.Store.CredAuditLog(pAlice, 100)
	issues := 0
	for _, a := range audit {
		if a.Action == store.CredIssue {
			issues++
			if a.Hostname != "m4" || a.OSUser != "alice" || a.EndpointID != "ep_alice-m4" {
				t.Fatalf("issue audit row lacks the node: %+v", a)
			}
		}
	}
	if issues != 6 {
		t.Fatalf("%d issue audit rows, want 6 (3 credentials x 2 leases)", issues)
	}
}

func TestNodeLeaseOnlyForOwnLogin(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	// bob's login on the same machine, with no fleet account: refused.
	bob := enrollAs(t, h, "bob-m4", "m4", "bob")
	if code, _, refusal := lease(t, h, bob); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("bob: %d %v", code, refusal)
	}
	// alice's login name on a machine she was never assigned: refused too.
	elsewhere := enrollAs(t, h, "alice-m5", "m5", "alice")
	if code, _, refusal := lease(t, h, elsewhere); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("alice on m5: %d %v", code, refusal)
	}
	if code, _, _ := lease(t, h, "not-a-token"); code != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", code)
	}
}

func TestRevokedNodeCannotLease(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	if code, _, _ := lease(t, h, tok); code != http.StatusOK {
		t.Fatalf("before revoke: %d", code)
	}
	for _, rev := range []FleetRevokeRequest{{Hostname: "m4"}, {PrincipalID: pAlice}, {Hostname: "m4", PrincipalID: pAlice}} {
		rev.Reason = "laptop lost"
		if code, out := h.post(t, "/v1/fleet/credentials/revoke", rev); code != http.StatusOK {
			t.Fatalf("revoke %+v: %d %v", rev, code, out)
		}
		code, _, refusal := lease(t, h, tok)
		if code != http.StatusForbidden || refusal["error"] != LeaseRevoked || !strings.Contains(refusal["message"], "laptop lost") {
			t.Fatalf("after revoke %+v: %d %v", rev, code, refusal)
		}
		rev.Lift = true
		if code, out := h.post(t, "/v1/fleet/credentials/revoke", rev); code != http.StatusOK {
			t.Fatalf("lift %+v: %d %v", rev, code, out)
		}
		if code, _, _ := lease(t, h, tok); code != http.StatusOK {
			t.Fatalf("after lifting %+v: %d", rev, code)
		}
	}
	audit, _ := h.srv.Store.CredAuditLog("", 100)
	denies := 0
	for _, a := range audit {
		if a.Action == store.CredDeny && strings.HasPrefix(a.Detail, LeaseRevoked) {
			denies++
		}
	}
	if denies != 3 {
		t.Fatalf("%d revoked-deny audit rows, want 3", denies)
	}
}

func TestCredentialRoutesAreOperatorOnlyAndVaultGated(t *testing.T) {
	h := newFleetHarness(t)
	// Vault off: 503, not 404 — the module is on, the key is missing.
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put"})
	if code != http.StatusServiceUnavailable || out["error"] != LeaseVaultOff {
		t.Fatalf("vault off: %d %v", code, out)
	}
	h2, _, _ := newVaultHarness(t)
	putCred(t, h2, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt-SECRET"})
	res, body := h2.get(t, "/v1/fleet/credentials")
	if res.StatusCode != http.StatusOK || strings.Contains(string(body), "SECRET") || strings.Contains(string(body), "sealed") {
		t.Fatalf("list: %d %s", res.StatusCode, body)
	}
	if code, _ := h2.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: pAlice,
		Provider: "claude", Account: "../etc", Secret: credvault.Secret{RefreshToken: "x"}}); code != http.StatusBadRequest {
		t.Fatalf("path-like account accepted: %d", code)
	}
	if code, _ := h2.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: pAlice,
		Provider: "claude", Account: "main"}); code != http.StatusBadRequest {
		t.Fatalf("claude without refresh_token accepted: %d", code)
	}
}

// Off is today's hub: no lease route answers, and no vault table exists.
func TestFleetOffHasNoCredentialRoutes(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "m5")
	code, ok, _ := lease(t, h, tok)
	if code == http.StatusOK || ok.Credentials != nil {
		t.Fatalf("fleet off: /v1/node/credentials answered %d %+v", code, ok)
	}
	if _, err := h.srv.Store.Credentials(""); err == nil {
		t.Fatal("credential table exists although the fleet module is off")
	}
}

// The end-to-end check: a hub with the vault and a real agent (CCQUOTA_FLEET=1,
// CCQUOTA_FLEET_CREDS=1) on a machine nobody has logged in on. The agent's
// first heartbeat tells the hub who it is, its lease comes back, and the files
// Claude Code / Codex / gh read are on disk — with no refresh token among them.
func TestCredentialLeaseIntegration(t *testing.T) {
	h := newFleetHarness(t)
	sealer, _ := credvault.NewSealer(bytes.Repeat([]byte{9}, 32))
	h.srv.Vault = &credvault.Vault{Store: h.srv.Store, Sealer: sealer, Refresher: &stubRefresher{}}

	hostname, _ := os.Hostname()
	u, err := user.Current()
	if err != nil {
		t.Skip("no current user")
	}
	p, err := h.srv.Store.AdoptPrincipal("gh:1010", u.Username, "IT", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, hostname, time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, c := range []FleetCredentialRequest{
		{Provider: "claude", Account: "main", Secret: credvault.Secret{RefreshToken: "sk-ant-ort01-HUBONLY", SubscriptionType: "max"}},
		{Provider: "codex", Account: "work", Secret: credvault.Secret{RefreshToken: "rt-HUBONLY", AccountID: "acct-it"}},
	} {
		c.Action, c.PrincipalID = "put", "gh:1010"
		if code, out := h.post(t, "/v1/fleet/credentials", c); code != http.StatusOK {
			t.Fatalf("put: %d %v", code, out)
		}
	}

	home := t.TempDir()
	a, err := agent.New(agent.Config{
		HubURL: h.http.URL, Token: h.enroll(t, "it"), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 150 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetCreds: true, Version: "it",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })

	claude := filepath.Join(home, ".config", "claude-fleet", "accounts", "main.hub", ".credentials.json")
	codex := filepath.Join(home, ".codex-accounts", "work", "auth.json")
	waitFor(t, 10*time.Second, "the agent wrote both leased credentials", func() bool {
		_, e1 := os.Stat(claude)
		_, e2 := os.Stat(codex)
		return e1 == nil && e2 == nil
	})
	cb, _ := os.ReadFile(claude)
	if !strings.Contains(string(cb), `"accessToken":"claude-access-`) || !strings.Contains(string(cb), `"refreshToken":null`) {
		t.Fatalf("claude credentials file: %s", cb)
	}
	marker, _ := os.ReadFile(filepath.Join(home, ".config", "claude-fleet", "accounts", "main"))
	if string(marker) != "hub:main\n" {
		t.Fatalf("pool file = %q", marker)
	}
	xb, _ := os.ReadFile(codex)
	if !strings.Contains(string(xb), `"refresh_token": "hub-managed"`) || !strings.Contains(string(xb), `"account_id": "acct-it"`) {
		t.Fatalf("codex auth.json: %s", xb)
	}
	// The completion criterion's grep: no refresh token anywhere on the node.
	_ = filepath.WalkDir(home, func(path string, d iofs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if b, _ := os.ReadFile(path); bytes.Contains(b, []byte("HUBONLY")) || bytes.Contains(b, []byte("rotated-")) {
				t.Errorf("%s holds a refresh token", path)
			}
		}
		return nil
	})
	audit, _ := h.srv.Store.CredAuditLog("gh:1010", 50)
	issued := 0
	for _, r := range audit {
		if r.Action == store.CredIssue && r.Hostname == hostname && r.OSUser == u.Username {
			issued++
		}
	}
	if issued < 2 {
		t.Fatalf("%d issue audit rows for %s@%s, want 2", issued, u.Username, hostname)
	}
}

// KMS unavailable (claude-fleet#1417): the vault is locked, so the hub
// refuses every lease and store with 503 vault_locked, records each refusal,
// and raises a critical finding — while revocation and the audit still work.
// It never falls back to issuing from anything else.
func TestLockedVaultRefusesAndAlerts(t *testing.T) {
	h, tok, ref := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt-1"})
	key := h.srv.Vault.Sealer
	h.srv.Vault.SetLocked("kms Decrypt: kms 503 ServiceUnavailable", time.Now().Add(-2*time.Minute))

	code, ok, refusal := lease(t, h, tok)
	if code != http.StatusServiceUnavailable || refusal["error"] != LeaseVaultLocked || ok.Credentials != nil {
		t.Fatalf("locked lease: %d %v %+v", code, refusal, ok)
	}
	if !strings.Contains(refusal["message"], "ServiceUnavailable") {
		t.Errorf("refusal should say why: %v", refusal)
	}
	if n := ref.n.Load(); n != 0 {
		t.Errorf("a locked vault refreshed %d time(s)", n)
	}
	audit, _ := h.srv.Store.CredAuditLog("", 10)
	if len(audit) == 0 || audit[0].Action != store.CredDeny || !strings.Contains(audit[0].Detail, LeaseVaultLocked) {
		t.Fatalf("no deny audit: %+v", audit)
	}
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: pAlice,
		Provider: "claude", Account: "other", Secret: credvault.Secret{RefreshToken: "x"}})
	if code != http.StatusServiceUnavailable || out["error"] != LeaseVaultLocked {
		t.Fatalf("locked put: %d %v", code, out)
	}
	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4"}); code != http.StatusOK {
		t.Fatalf("revoke while locked: %d %v", code, out)
	}

	var now findingsEnvelope
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now.Findings) == 0 || now.Findings[0].Kind != "cred_vault_locked" || now.Findings[0].Severity != "critical" {
		t.Fatalf("no critical vault finding first: %+v", now.Findings)
	}

	// Unlocked again: the finding clears and leases flow (the revocation
	// above aside — lift it).
	h.srv.Vault.Unlock(key)
	if code, _ := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4", Lift: true}); code != http.StatusOK {
		t.Fatal("lift")
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	for _, f := range now.Findings {
		if f.Kind == "cred_vault_locked" {
			t.Fatalf("finding outlived the lock: %+v", f)
		}
	}
}

// A shared-pool account (claude-fleet#1463) is stored under principal "pool"
// and rides along in every active principal's lease — a setup token exactly as
// stored, no refresh — while a login that is nobody, or a revoked one, still
// gets nothing. The list shows its kind and expiry, never the token.
func TestPoolSetupTokenLeasedByEveryActivePrincipal(t *testing.T) {
	h, tok, ref := newVaultHarness(t)
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "icloud", Secret: credvault.Secret{SetupToken: "sk-ant-oat01-POOLSECRET", ExpiresAt: &exp}})
	if code != http.StatusOK {
		t.Fatalf("put pool: %d %v", code, out)
	}
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "sk-ant-ort01-SECRET"})

	code, got, refusal := lease(t, h, tok)
	if code != http.StatusOK {
		t.Fatalf("alice: %d %v", code, refusal)
	}
	by := map[string]NodeCredential{}
	for _, c := range got.Credentials {
		by[c.Account] = c
	}
	pool, own := by["icloud"], by["main"]
	if !pool.Pool || pool.Kind != credvault.KindSetupToken || pool.Access == nil || pool.Access.AccessToken != "sk-ant-oat01-POOLSECRET" ||
		pool.ExpiresAt == nil || !pool.ExpiresAt.Equal(exp) {
		t.Fatalf("pool credential = %+v", pool)
	}
	if own.Pool || own.Kind != credvault.KindRefreshToken || own.Access == nil || own.Access.AccessToken != "claude-access-1" {
		t.Fatalf("own credential = %+v", own)
	}
	if n := ref.n.Load(); n != 1 {
		t.Fatalf("%d refreshes, want 1 (alice's own; the setup token is never refreshed)", n)
	}

	// Nobody / revoked: the pool is not a back door.
	bob := enrollAs(t, h, "bob-m4", "m4", "bob")
	if code, _, refusal := lease(t, h, bob); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("bob: %d %v", code, refusal)
	}
	if code, _ := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{PrincipalID: pAlice, Reason: "left"}); code != http.StatusOK {
		t.Fatal("revoke")
	}
	if code, _, refusal := lease(t, h, tok); code != http.StatusForbidden || refusal["error"] != LeaseRevoked {
		t.Fatalf("revoked alice: %d %v", code, refusal)
	}
	if code, _ := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{PrincipalID: pAlice, Lift: true}); code != http.StatusOK {
		t.Fatal("lift")
	}

	// The list: metadata with kind + expiry, and the audit names the person.
	res, body := h.get(t, "/v1/fleet/credentials")
	if res.StatusCode != http.StatusOK || strings.Contains(string(body), "POOLSECRET") {
		t.Fatalf("list: %d %s", res.StatusCode, body)
	}
	var listed struct{ Credentials []store.Credential }
	_ = json.Unmarshal(body, &listed)
	var poolRow *store.Credential
	for i := range listed.Credentials {
		if listed.Credentials[i].PrincipalID == store.PoolPrincipal {
			poolRow = &listed.Credentials[i]
		}
	}
	if poolRow == nil || poolRow.Kind != credvault.KindSetupToken || poolRow.SecretExpiresAt == nil || !poolRow.SecretExpiresAt.Equal(exp) {
		t.Fatalf("listed pool row = %+v", poolRow)
	}
	audit, _ := h.srv.Store.CredAuditLog("", 50)
	issued := 0
	for _, a := range audit {
		if a.Action == store.CredIssue && a.Account == "icloud" {
			issued++
			if a.PrincipalID != pAlice || a.Detail != "pool" || a.Hostname != "m4" {
				t.Fatalf("pool issue audit = %+v", a)
			}
		}
	}
	if issued != 1 {
		t.Fatalf("%d pool issue rows, want 1", issued)
	}

	// The shapes the operator can get wrong.
	for name, req := range map[string]FleetCredentialRequest{
		"expired": {Action: "put", PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "old",
			Secret: credvault.Secret{SetupToken: "sk-ant-oat01-x", ExpiresAt: ptrTime(time.Now().Add(-time.Hour))}},
		"no expiry": {Action: "put", PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "x",
			Secret: credvault.Secret{SetupToken: "sk-ant-oat01-x"}},
		"both": {Action: "put", PrincipalID: pAlice, Provider: credvault.Claude, Account: "x",
			Secret: credvault.Secret{SetupToken: "sk-ant-oat01-x", RefreshToken: "rt", ExpiresAt: &exp}},
		"unknown person": {Action: "put", PrincipalID: "gh:1099", Provider: credvault.Claude, Account: "x",
			Secret: credvault.Secret{SetupToken: "sk-ant-oat01-x", ExpiresAt: &exp}},
	} {
		if code, _ := h.post(t, "/v1/fleet/credentials", req); code != http.StatusBadRequest {
			t.Errorf("%s: %d", name, code)
		}
	}

	// Expiring within a month: the hub's own page carries the reminder.
	soon := time.Now().Add(20 * 24 * time.Hour).UTC()
	if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "gmail", Secret: credvault.Secret{SetupToken: "sk-ant-oat01-SOON", ExpiresAt: &soon}}); code != http.StatusOK {
		t.Fatalf("put soon: %d %v", code, out)
	}
	var now struct {
		Findings []struct{ Kind, Severity, Title string }
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	found := false
	for _, f := range now.Findings {
		if f.Kind == "cred_setup_token" && strings.Contains(f.Title, "gmail") && f.Severity == "warning" {
			found = true
		}
		if f.Kind == "cred_setup_token" && strings.Contains(f.Title, "icloud") {
			t.Fatalf("a token a year out raised a finding: %+v", f)
		}
	}
	if !found {
		t.Fatalf("no setup-token reminder: %+v", now.Findings)
	}
}

func ptrTime(t time.Time) *time.Time { return &t }
