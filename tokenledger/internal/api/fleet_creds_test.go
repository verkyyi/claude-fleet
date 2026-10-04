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
	p, err := h.srv.Store.AdoptPrincipal("wecom-alice", "alice", "Alice", time.Now())
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
		PrincipalID: "wecom-alice", Provider: provider, Account: account, Secret: s})
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
	if got.PrincipalID != "wecom-alice" || len(got.Credentials) != 3 {
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
	audit, _ := h.srv.Store.CredAuditLog("wecom-alice", 100)
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
	for _, rev := range []FleetRevokeRequest{{Hostname: "m4"}, {PrincipalID: "wecom-alice"}, {Hostname: "m4", PrincipalID: "wecom-alice"}} {
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
	if code, _ := h2.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: "wecom-alice",
		Provider: "claude", Account: "../etc", Secret: credvault.Secret{RefreshToken: "x"}}); code != http.StatusBadRequest {
		t.Fatalf("path-like account accepted: %d", code)
	}
	if code, _ := h2.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: "wecom-alice",
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
	p, err := h.srv.Store.AdoptPrincipal("wecom-it", u.Username, "IT", time.Now())
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
		c.Action, c.PrincipalID = "put", "wecom-it"
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
	audit, _ := h.srv.Store.CredAuditLog("wecom-it", 50)
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
