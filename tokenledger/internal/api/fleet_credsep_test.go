package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The lease's credential-separation gate (claude-fleet#2295, EPIC #2293 C2;
// mandatory since #4607): every login gets real tokens only when its newest
// heartbeat says credsep=separated — an admin's and the operator's own too; an
// agent that does not report the field counts as not separated. A hub that
// declared itself self-hosted (CredsepOptional — the test harness's default,
// for the lease fixtures) keeps #2295's rule: a role=user person's login only.

// credsepHarness: the vault harness plus a GitHub admin (ivan, id 100)
// and a listed user (carol, id 400), each with an active login on mac-c, and a
// pool credential every lease carries.
func credsepHarness(t *testing.T) (h *harness, user, admin string) {
	t.Helper()
	h, _, _ = newVaultHarness(t)
	h.srv.GitHub = &GitHubAuth{Admins: []string{"ivan"}}
	now := time.Now()
	if _, err := h.srv.Store.PinLogin("ivan", 100, now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: 400, Login: "carol", Role: store.RoleUser, AddedBy: "gh:100"}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct{ id, login string }{{githubPrincipal(400), "carol"}, {githubPrincipal(100), "ivan"}} {
		pr, err := h.srv.Store.AdoptPrincipal(p.id, p.login, p.login, now)
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.AdoptAccount(pr, "mac-c", now); err != nil {
			t.Fatal(err)
		}
	}
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put",
		PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "pool1", Secret: credvault.Secret{RefreshToken: "rt-pool"}})
	if code != http.StatusOK {
		t.Fatalf("put pool: %d %v", code, out)
	}
	return h, enrollAs(t, h, "carol-mac-c", "mac-c", "carol"), enrollAs(t, h, "ivan-mac-c", "mac-c", "ivan")
}

// credsepBeat records a hello and a heartbeat for tok's node; credsep "" is
// an agent that does not report the field.
func credsepBeat(t *testing.T, h *harness, tok, osUser, credsep string) {
	t.Helper()
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := h.srv.Store.NodeConnected(ep.ID, "mac-c", osUser, "test", control.Proto, 60000, now); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(control.Heartbeat{Hostname: "mac-c", OSUser: osUser, Credsep: credsep, ObservedAt: now})
	if err := h.srv.Store.NodeHeartbeat(ep.ID, "mac-c", osUser, "", control.Proto, string(raw), now); err != nil {
		t.Fatal(err)
	}
}

func TestLeaseCredsepGate(t *testing.T) {
	h, user, admin := credsepHarness(t)
	cases := []struct {
		name, osUser, tok, credsep string
		want                       int
	}{
		{"user, old agent (no field)", "carol", user, "", http.StatusForbidden},
		{"user, not separated", "carol", user, control.CredsepNot, http.StatusForbidden},
		{"user, unknown", "carol", user, control.CredsepUnknown, http.StatusForbidden},
		{"user, separated", "carol", user, control.CredsepSeparated, http.StatusOK},
		{"admin, not separated", "ivan", admin, control.CredsepNot, http.StatusOK},
		{"admin, old agent", "ivan", admin, "", http.StatusOK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			credsepBeat(t, h, tc.tok, tc.osUser, tc.credsep)
			code, ok, refusal := lease(t, h, tc.tok)
			if code != tc.want {
				t.Fatalf("lease = %d %v; want %d", code, refusal, tc.want)
			}
			if code == http.StatusForbidden && refusal["error"] != LeaseNotSeparated {
				t.Fatalf("refusal = %v; want %s", refusal, LeaseNotSeparated)
			}
			if code == http.StatusOK && len(ok.Credentials) == 0 {
				t.Fatalf("an OK lease carried nothing: %+v", ok)
			}
		})
	}
	// The audit names both ends: 拒发：未隔离 and, once separated, the issue.
	rows, err := h.srv.Store.CredAuditLog(githubPrincipal(400), 100)
	if err != nil {
		t.Fatal(err)
	}
	var denied, issued int
	for _, a := range rows {
		switch {
		case a.Action == store.CredDeny && strings.Contains(a.Detail, "拒发：未隔离") && a.OSUser == "carol":
			denied++
		case a.Action == store.CredIssue && a.OSUser == "carol":
			issued++
		}
	}
	if denied != 3 || issued != 1 {
		t.Fatalf("carol's audit: %d 拒发：未隔离 rows (want 3), %d issue rows (want 1): %+v", denied, issued, rows)
	}
}

// A person not on the list as a user — the operator's own principals, an id
// GitHub sign-in never named — is untouched: 共同约定 4.
func TestLeaseCredsepGateOnlyForUsers(t *testing.T) {
	h, tok, _ := newVaultHarness(t) // pAlice: a gh: principal with no hub_users row
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	credsepBeat(t, h, tok, "alice", control.CredsepNot)
	if code, _, refusal := lease(t, h, tok); code != http.StatusOK {
		t.Fatalf("lease = %d %v; want 200", code, refusal)
	}
}

// /v1/node/self tells the node's proxy to route central while gated, and
// leaves the operator's trust word alone.
func TestNodeSelfCarriesCredsepGate(t *testing.T) {
	h, user, admin := credsepHarness(t)
	self := func(tok string) NodeView {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/self", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		res, err := h.http.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var v NodeView
		if res.StatusCode != http.StatusOK || json.NewDecoder(res.Body).Decode(&v) != nil {
			t.Fatalf("/v1/node/self = %d", res.StatusCode)
		}
		return v
	}
	credsepBeat(t, h, user, "carol", control.CredsepNot)
	credsepBeat(t, h, admin, "ivan", control.CredsepNot)
	if v := self(user); v.CredsepGate != LeaseNotSeparated || v.Credsep != control.CredsepNot || v.Trust != TrustTrusted {
		t.Fatalf("user not separated: gate=%q credsep=%q trust=%q", v.CredsepGate, v.Credsep, v.Trust)
	}
	if v := self(admin); v.CredsepGate != "" {
		t.Fatalf("admin gated: %q", v.CredsepGate)
	}
	credsepBeat(t, h, user, "carol", control.CredsepSeparated)
	if v := self(user); v.CredsepGate != "" || v.Credsep != control.CredsepSeparated {
		t.Fatalf("user separated: gate=%q credsep=%q", v.CredsepGate, v.Credsep)
	}
}

// Every login is held to it (claude-fleet#4607): an admin's, anyone's —
// refused while not separated, leased once it is.
func TestLeaseCredsepMandatory(t *testing.T) {
	h, user, admin := credsepHarness(t)
	h.srv.CredsepOptional = false
	cases := []struct {
		name, osUser, tok, credsep string
		want                       int
	}{
		{"admin, not separated", "ivan", admin, control.CredsepNot, http.StatusForbidden},
		{"admin, old agent", "ivan", admin, "", http.StatusForbidden},
		{"admin, unknown", "ivan", admin, control.CredsepUnknown, http.StatusForbidden},
		{"admin, separated", "ivan", admin, control.CredsepSeparated, http.StatusOK},
		{"user, not separated", "carol", user, control.CredsepNot, http.StatusForbidden},
		{"user, separated", "carol", user, control.CredsepSeparated, http.StatusOK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			credsepBeat(t, h, tc.tok, tc.osUser, tc.credsep)
			code, ok, refusal := lease(t, h, tc.tok)
			if code != tc.want {
				t.Fatalf("lease = %d %v; want %d", code, refusal, tc.want)
			}
			if code == http.StatusForbidden && refusal["error"] != LeaseNotSeparated {
				t.Fatalf("refusal = %v; want %s", refusal, LeaseNotSeparated)
			}
			if code == http.StatusOK && len(ok.Credentials) == 0 {
				t.Fatalf("an OK lease carried nothing: %+v", ok)
			}
		})
	}
	rows, err := h.srv.Store.CredAuditLog(githubPrincipal(100), 100)
	if err != nil {
		t.Fatal(err)
	}
	denied := 0
	for _, a := range rows {
		if a.Action == store.CredDeny && strings.Contains(a.Detail, "拒发：未隔离") && a.OSUser == "ivan" {
			denied++
		}
	}
	if denied != 3 {
		t.Fatalf("ivan's audit: %d 拒发：未隔离 rows, want 3: %+v", denied, rows)
	}
}

// The operator's own principal (no hub_users row) is no exception either, and
// /v1/node/self tells an admin's unseparated node to route central.
func TestLeaseCredsepMandatoryOperatorAndSelf(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	h.srv.CredsepOptional = false
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	credsepBeat(t, h, tok, "alice", control.CredsepNot)
	if code, _, refusal := lease(t, h, tok); code != http.StatusForbidden || refusal["error"] != LeaseNotSeparated {
		t.Fatalf("lease = %d %v; want 403 %s", code, refusal, LeaseNotSeparated)
	}
	credsepBeat(t, h, tok, "alice", control.CredsepSeparated)
	if code, _, refusal := lease(t, h, tok); code != http.StatusOK {
		t.Fatalf("separated lease = %d %v; want 200", code, refusal)
	}

	h2, _, admin := credsepHarness(t)
	h2.srv.CredsepOptional = false
	credsepBeat(t, h2, admin, "ivan", control.CredsepNot)
	req, _ := http.NewRequest(http.MethodGet, h2.http.URL+"/v1/node/self", nil)
	req.Header.Set("Authorization", "Bearer "+admin)
	res, err := h2.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var v NodeView
	if res.StatusCode != http.StatusOK || json.NewDecoder(res.Body).Decode(&v) != nil {
		t.Fatalf("/v1/node/self = %d", res.StatusCode)
	}
	if v.CredsepGate != LeaseNotSeparated {
		t.Fatalf("admin not separated: gate=%q; want %s", v.CredsepGate, LeaseNotSeparated)
	}
}

// claude-fleet#4622: the gate's cred-ttl item counts only the logins the lease
// would hand pool credentials to — never a client computer (compute off,
// untrusted), a cluster pod's login (central; the hub's u-<nonce> rows carry
// no UserPod flag of their own), a system account (root, _fleetadmin), or a
// deleted user (no active fleet account).
func TestGateCredsepCountsOnlyLeasedLogins(t *testing.T) {
	h, user, admin := credsepHarness(t)
	oldTTL := gateCredLifetimes
	t.Cleanup(func() { gateCredLifetimes = oldTTL })
	gateCredLifetimes = func(*Server) []gateCred { return []gateCred{{"会话通行证", 4 * time.Hour}} }
	epOf := func(tok string) string {
		ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok))
		if err != nil {
			t.Fatal(err)
		}
		return ep.ID
	}
	row := func(host, login, credsep string) NodeView {
		return NodeView{EndpointID: "ep-" + login, Hostname: host, OSUser: login, Status: "online", Trust: TrustTrusted, Credsep: credsep}
	}
	carol := row("mac-c", "carol", control.CredsepNot)
	carol.EndpointID = epOf(user)
	ivan := row("mac-c", "ivan", control.CredsepSeparated)
	ivan.EndpointID = epOf(admin)
	client := row("MacBookPro.example", "carol", "")
	client.ComputeOff, client.Trust = true, TrustUntrusted
	nodes := []NodeView{carol, ivan, client,
		row("u-3wnuf3v654", "carol", control.CredsepNot), // a person's pod
		row("mac-c", "root", ""),
		row("mac-c", "_fleetadmin", control.CredsepUnknown),
		row("mac-c", "ghost", control.CredsepUnknown), // deleted: no fleet account
	}
	ok, why := gateHubJudge["cred-ttl"](h.srv, nodes, true)
	if ok || !strings.Contains(why, "1 个登录") || !strings.HasSuffix(why, "：mac-c/carol") {
		t.Fatalf("cred-ttl = %v %s; want only mac-c/carol", ok, why)
	}
	nodes[0].Credsep = control.CredsepSeparated
	if ok, why := gateHubJudge["cred-ttl"](h.srv, nodes, true); !ok {
		t.Fatalf("cred-ttl with every leased login separated: %s", why)
	}
}
