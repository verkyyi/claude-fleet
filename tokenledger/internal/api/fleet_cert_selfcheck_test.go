package api

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// reloginTo moves pid's row on host to a new login and settles it active the
// way a node reports a finished create (claude-fleet#2210) — leaving the
// person record on the old login: the split #2437 / #2456 are about.
func reloginTo(t *testing.T, h *harness, pid, host, login, ep string) {
	t.Helper()
	now := time.Now()
	if _, err := h.srv.Store.RequestRelogin(pid, host, login, now); err != nil {
		t.Fatal(err)
	}
	op := "op-" + host + "-" + login
	if ok, err := h.srv.Store.MarkAccountSent(pid, host, store.AccountPending, store.AccountCreating, op, ep, now); err != nil || !ok {
		t.Fatalf("MarkAccountSent = %v, %v", ok, err)
	}
	if ok, err := h.srv.Store.FinishAccountOp(op, ep, store.AccountActive, "created", now); err != nil || !ok {
		t.Fatalf("FinishAccountOp = %v, %v", ok, err)
	}
}

// The hub never hands out a certificate its own doors would refuse
// (claude-fleet#2456): issueCert reads what it just signed through the same
// judgement verifySSHRelayCert applies. With the person record on `alice` and
// the machine's account on `alice2` the certificate it mints passes; a split
// forced between signing and checking is a 5xx naming the principal and the
// logins expected, and nothing is recorded or returned.
func TestIssueCertSelfChecks(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mini", now); err != nil {
		t.Fatal(err)
	}
	reloginTo(t, h, p.ID, "mini", "alice2", "ep_a")

	keyLine := string(ssh.MarshalAuthorizedKey(k.user.PublicKey()))
	r := httptest.NewRequest(http.MethodPost, "http://hub/v1/fleet/cert", nil)
	resp, err := h.srv.issueCert(r, p.ID, keyLine, "web")
	if err != nil {
		t.Fatalf("issueCert on the split fixture: %v", err)
	}
	if len(resp.Principals) != 1 || resp.Principals[0] != "alice2" {
		t.Fatalf("principals = %v, want [alice2]", resp.Principals)
	}
	if err := h.srv.selfCheckCert(p.ID, resp.Certificate, now); err != nil {
		t.Fatalf("the issued certificate fails the self-check: %v", err)
	}
	before, _ := h.srv.Store.FleetCerts(p.ID, 100)

	// Force the two halves apart: sign for a login that is in neither the
	// person record nor any account row.
	h.srv.certLoginsHook = func(string, []string) []string { return []string{"zed"} }
	resp, err = h.srv.issueCert(r, p.ID, keyLine, "web")
	if err == nil || resp != nil {
		t.Fatalf("issueCert with a split it would itself refuse = %+v, %v; want refused", resp, err)
	}
	if !errors.Is(err, errCertSelfCheck) || certErrStatus(err) != http.StatusInternalServerError {
		t.Fatalf("err = %v (status %d), want errCertSelfCheck / 500", err, certErrStatus(err))
	}
	for _, want := range []string{`[zed]`, `[alice alice2]`} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("err = %q, want it to name %s", err, want)
		}
	}
	if after, _ := h.srv.Store.FleetCerts(p.ID, 100); len(after) != len(before) {
		t.Errorf("a refused certificate was recorded: %d → %d", len(before), len(after))
	}

	// A certificate the doors would refuse for another reason (not the hub's
	// CA) is refused by the self-check too.
	foreign := newCertKit(t).cert(t, "person:wx-alice", []string{"alice2"}, now.Add(-time.Minute), now.Add(time.Hour))
	if err := h.srv.selfCheckCert(p.ID, string(ssh.MarshalAuthorizedKey(foreign)), now); !errors.Is(err, errCertSelfCheck) {
		t.Errorf("a foreign CA's certificate: %v, want errCertSelfCheck", err)
	}
}

// The credential lease answers by the machine's account login, the same
// (machine → login) source a certificate is minted from: after a relogin the
// NEW login on that machine gets the pool credential, the old one is refused
// (claude-fleet#2456).
func TestNodeLeaseAfterRelogin(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "icloud", Secret: credvault.Secret{SetupToken: "sk-ant-oat01-POOLSECRET", ExpiresAt: &exp}}); code != http.StatusOK {
		t.Fatalf("put pool: %d %v", code, out)
	}
	reloginTo(t, h, pAlice, "m4", "alice2", "ep_alice2-m4")
	if p, err := h.srv.Store.Principal(pAlice); err != nil || p.Login != "alice" {
		t.Fatalf("person record = %+v, %v; want login alice", p, err)
	}

	moved := enrollAs(t, h, "alice2-m4", "m4", "alice2")
	code, got, refusal := lease(t, h, moved)
	if code != http.StatusOK {
		t.Fatalf("the migrated login alice2 on m4: %d %v, want 200", code, refusal)
	}
	pool := false
	for _, c := range got.Credentials {
		if c.Pool && c.Account == "icloud" && c.Access != nil && c.Access.AccessToken == "sk-ant-oat01-POOLSECRET" {
			pool = true
		}
	}
	if !pool {
		t.Fatalf("credentials = %+v, want the pool's", got.Credentials)
	}

	old := enrollAs(t, h, "alice-old-m4", "m4", "alice")
	if code, _, refusal := lease(t, h, old); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal ||
		!strings.Contains(refusal["message"], "alice on m4") {
		t.Fatalf("the old login after the move: %d %v, want 403 %s", code, refusal, LeaseNoPrincipal)
	}
}

// `rename` sets the person record's login to their login on one machine — no
// forget + adopt, the account rows untouched — and audits it
// (claude-fleet#2456). Again is a no-op; a login another person holds, or a
// machine with no active account, is a 409.
func TestAccountsRename(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mini", now); err != nil {
		t.Fatal(err)
	}
	reloginTo(t, h, p.ID, "mini", "alice2", "ep_a")
	acctsBefore, _ := h.srv.Store.FleetAccounts(p.ID)

	code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "rename", PrincipalID: p.ID, Hostname: "mini"})
	if code != http.StatusOK || out["from"] != "alice" || out["login"] != "alice2" || out["changed"] != true {
		t.Fatalf("rename: %d %v", code, out)
	}
	if got, err := h.srv.Store.Principal(p.ID); err != nil || got.Login != "alice2" {
		t.Fatalf("person record = %+v, %v; want alice2", got, err)
	}
	acctsAfter, _ := h.srv.Store.FleetAccounts(p.ID)
	if len(acctsAfter) != len(acctsBefore) || acctsAfter[0].Login != "alice2" || acctsAfter[0].State != store.AccountActive {
		t.Fatalf("account rows changed: %+v → %+v", acctsBefore, acctsAfter)
	}
	log, _ := h.srv.Store.HubAuditLog(10)
	audited := false
	for _, e := range log {
		if e.Action == "account.rename" && e.Target == "wx-alice@mini" && e.Outcome == "ok" && e.Detail == "alice → alice2" {
			audited = true
		}
	}
	if !audited {
		t.Fatalf("no account.rename audit row: %+v", log)
	}

	if code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "rename", PrincipalID: p.ID, Hostname: "mini"}); code != http.StatusOK || out["changed"] != false {
		t.Fatalf("rename again: %d %v, want 200 unchanged", code, out)
	}
	if code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "rename", PrincipalID: p.ID, Hostname: "nowhere"}); code != http.StatusConflict {
		t.Fatalf("rename to a machine with no account: %d %v, want 409", code, out)
	}
	if code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "rename", PrincipalID: "nobody", Hostname: "mini"}); code != http.StatusNotFound {
		t.Fatalf("rename an unknown person: %d %v, want 404", code, out)
	}

	// bob's account on mini2 moves to bob3, which carol's record already
	// holds (fleet_principals.login is UNIQUE): taken.
	b, err := h.srv.Store.AdoptPrincipal("wx-bob", "bob", "Bob", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(b, "mini2", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.AdoptPrincipal("wx-carol", "bob3", "Carol", now); err != nil {
		t.Fatal(err)
	}
	reloginTo(t, h, b.ID, "mini2", "bob3", "ep_b")
	if code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "rename", PrincipalID: b.ID, Hostname: "mini2"}); code != http.StatusConflict {
		t.Fatalf("rename onto carol's login: %d %v, want 409", code, out)
	}
	if got, _ := h.srv.Store.Principal(b.ID); got.Login != "bob" {
		t.Fatalf("bob's record = %q after a refused rename, want bob", got.Login)
	}
}
