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

// The lease's credential-separation gate (claude-fleet#2295, EPIC #2293 C2):
// a role=user person's login gets real tokens only when its newest heartbeat
// says credsep=separated; an admin's login leases as before; an agent that
// does not report the field counts as not separated for a user.

// credsepHarness: the vault harness plus a GitHub admin (verkyyi, id 100)
// and a listed user (carol, id 400), each with an active login on m4, and a
// pool credential every lease carries.
func credsepHarness(t *testing.T) (h *harness, user, admin string) {
	t.Helper()
	h, _, _ = newVaultHarness(t)
	h.srv.GitHub = &GitHubAuth{Admins: []string{"verkyyi"}}
	now := time.Now()
	if _, err := h.srv.Store.PinLogin("verkyyi", 100, now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.UpsertHubUser(store.HubUser{GitHubID: 400, Login: "carol", Role: store.RoleUser, AddedBy: "gh:100"}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct{ id, login string }{{githubPrincipal(400), "carol"}, {githubPrincipal(100), "verkyyi"}} {
		pr, err := h.srv.Store.AdoptPrincipal(p.id, p.login, p.login, now)
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.AdoptAccount(pr, "m4", now); err != nil {
			t.Fatal(err)
		}
	}
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put",
		PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "pool1", Secret: credvault.Secret{RefreshToken: "rt-pool"}})
	if code != http.StatusOK {
		t.Fatalf("put pool: %d %v", code, out)
	}
	return h, enrollAs(t, h, "carol-m4", "m4", "carol"), enrollAs(t, h, "verkyyi-m4", "m4", "verkyyi")
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
	if err := h.srv.Store.NodeConnected(ep.ID, "m4", osUser, "test", control.Proto, 60000, now); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(control.Heartbeat{Hostname: "m4", OSUser: osUser, Credsep: credsep, ObservedAt: now})
	if err := h.srv.Store.NodeHeartbeat(ep.ID, "m4", osUser, "", control.Proto, string(raw), now); err != nil {
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
		{"admin, not separated", "verkyyi", admin, control.CredsepNot, http.StatusOK},
		{"admin, old agent", "verkyyi", admin, "", http.StatusOK},
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
	credsepBeat(t, h, admin, "verkyyi", control.CredsepNot)
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
