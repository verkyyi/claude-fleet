package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Trust rides the endpoint, not the name (claude-fleet#2214, EPIC #2329 C2).

func operatorDo(t *testing.T, h *harness, method, path string, body any) (int, []byte) {
	t.Helper()
	var rd io.Reader = http.NoBody
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	r, _ := http.NewRequest(method, h.http.URL+path, rd)
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func mintManaged(t *testing.T, h *harness, body any) JoinCodeView {
	t.Helper()
	code, b := operatorDo(t, h, http.MethodPost, "/v1/fleet/nodes/join-codes", body)
	if code != 200 {
		t.Fatalf("mint managed join code: HTTP %d %s", code, b)
	}
	var v JoinCodeView
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// A node that reports a trusted machine's name it did not join as inherits
// nothing: its lease is refused with the reason, the roster says
// name_borrowed, its hello writes an audit row — and the real machine is
// untouched.
func TestTrustBorrowedNameGetsNothing(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	if code, body := rawLease(t, h, tok); code != http.StatusOK {
		t.Fatalf("m4's own lease: %d %s", code, body)
	}

	evil := enrollAs(t, h, "evil", "evil", "alice")
	ident := model.Identity{AccountUUID: "acct-evil", Hostname: "m4", OSUser: "alice"}
	if _, _, err := h.srv.Store.TouchEndpoint("ep_evil", ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	code, body := rawLease(t, h, evil)
	if code != http.StatusForbidden || !strings.Contains(string(body), LeaseUntrusted) || !strings.Contains(string(body), "borrowed") {
		t.Fatalf("borrowed-name lease: %d %s; want 403 untrusted_node, borrowed", code, body)
	}
	if code, body := rawLease(t, h, tok); code != http.StatusOK {
		t.Fatalf("m4 after the impostor: %d %s", code, body)
	}

	c := dialNode(t, h, evil)
	defer c.Close(0, "")
	hello(t, c, control.Proto, 200)
	waitFor(t, 3*time.Second, "the borrowed-name audit row", func() bool {
		return trustAuditCount(t, h, `actor = 'node:ep_evil' AND outcome LIKE 'BORROWED NAME%'`) == 1
	})
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m4", OSUser: "alice", ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "the impostor on the roster", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.EndpointID == "ep_evil" {
				return n.Trust == TrustUntrusted && n.TrustSource == TrustSourceNameBorrowed
			}
		}
		return false
	})
	// The relay credential, minted per machine, is refused the same way.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/relay-credential", nil)
	req.Header.Set("Authorization", "Bearer "+evil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	rb, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden || !strings.Contains(string(rb), LeaseUntrusted) {
		t.Fatalf("borrowed-name relay credential: %d %s", resp.StatusCode, rb)
	}
}

// An old node (no trust of its own) keeps the name rule for one version: it
// enrolled under the name it reports, so it reads trusted, source
// machine_name.
func TestTrustOldNodeKeepsItsName(t *testing.T) {
	set := map[string]string{NodeTrustPrefix + "m5": TrustTrusted}
	if tr, src := nodeTrust("m5.local", store.EndpointTrust{EnrolledHost: "m5"}, set); tr != TrustTrusted || src != TrustSourceMachineName {
		t.Fatalf("old m5 = %s %s; want trusted machine_name", tr, src)
	}
	if tr, src := nodeTrust("m5", store.EndpointTrust{EnrolledHost: "evil"}, set); tr != TrustUntrusted || src != TrustSourceNameBorrowed {
		t.Fatalf("borrowed m5 = %s %s", tr, src)
	}
	if tr, _ := nodeTrust("m5", store.EndpointTrust{}, set); tr != TrustUntrusted {
		t.Fatalf("a never-named endpoint inherited m5's trust")
	}
	// Its own trust wins over any name — but the operator's untrusted for
	// the name it reports still takes it away.
	own := store.EndpointTrust{Trust: TrustTrusted, Source: store.TrustSourceJoinCode, EnrolledHost: "m9"}
	if tr, src := nodeTrust("m9", own, map[string]string{}); tr != TrustTrusted || src != store.TrustSourceJoinCode {
		t.Fatalf("join-code m9 = %s %s", tr, src)
	}
	if tr, _ := nodeTrust("m9", own, map[string]string{NodeTrustPrefix + "m9": TrustUntrusted}); tr != TrustUntrusted {
		t.Fatalf("the operator's untrusted did not win over the endpoint's own trust")
	}
}

// The 托管 route mints a trusted, managed code that lives an hour and
// redeems once; the endpoint holds the trust on its identity, with no machine
// setting at all — and the code is refused after its hour.
func TestManagedJoinCodeTrustsTheIdentity(t *testing.T) {
	h := newFleetHarness(t)
	t0 := time.Now()
	now := t0
	h.srv.joinClock = func() time.Time { return now }
	v := mintManaged(t, h, map[string]string{"label": "m9"})
	if v.Trust != TrustTrusted || v.Role != store.NodeRoleManaged {
		t.Fatalf("managed code = %+v; want trusted managed", v)
	}
	if d := v.ExpiresAt.Sub(t0); d < ManagedJoinCodeTTL-time.Second || d > ManagedJoinCodeTTL+time.Second {
		t.Fatalf("expires in %s; want an hour", d)
	}
	late := mintManaged(t, h, nil)

	now = t0.Add(ManagedJoinCodeTTL - time.Minute)
	code, out := joinWith(t, h, v.Code, "m9", "verkyyi")
	if code != 200 {
		t.Fatalf("join: %d", code)
	}
	if code, _ := joinWith(t, h, v.Code, "m9", "verkyyi"); code != http.StatusUnauthorized {
		t.Fatalf("second redemption: %d; want 401", code)
	}
	et, err := h.srv.Store.EndpointTrustOf(out.EndpointID)
	if err != nil || et.Trust != TrustTrusted || et.Source != store.TrustSourceJoinCode || et.Role != store.NodeRoleManaged || et.EnrolledHost != "m9" {
		t.Fatalf("endpoint trust = %+v %v", et, err)
	}
	if s, _ := h.srv.Store.FleetSettings(); s[NodeTrustPrefix+"m9"] != "" {
		t.Fatalf("a join code wrote a machine-name setting: %v", s)
	}
	resp, body := getWithToken(t, h, "/v1/node/self", out.Token)
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"trust":"trusted"`) || !strings.Contains(string(body), `"trust_source":"join_code"`) {
		t.Fatalf("self: %d %s", resp.StatusCode, body)
	}

	now = t0.Add(ManagedJoinCodeTTL + time.Second)
	if code, _ := joinWith(t, h, late.Code, "m8", "verkyyi"); code != http.StatusUnauthorized {
		t.Fatalf("expired managed code: %d; want 401", code)
	}
	// A plain code from the old route still carries no trust.
	now = t0
	plain := mintJoinCode(t, h, "")
	if plain.Trust != "" || plain.Role != "" {
		t.Fatalf("plain code = %+v", plain)
	}
	_, pout := joinWith(t, h, plain.Code, "m7", "verkyyi")
	if et, _ := h.srv.Store.EndpointTrustOf(pout.EndpointID); et.Trust != "" {
		t.Fatalf("a plain code gave trust: %+v", et)
	}
	// And the managed route takes trusted:false.
	if v := mintManaged(t, h, map[string]any{"trusted": false}); v.Trust != "" || v.Role != store.NodeRoleManaged {
		t.Fatalf("managed untrusted code = %+v", v)
	}
}

// Desired state: only the operator writes, every write bumps the version, a
// stale if_version is refused, trust in the body is the endpoint's own, the
// node reads its own and its heartbeat's report lands on the roster.
func TestDesiredStateOperatorWrites(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	_, out := joinWith(t, h, mintManaged(t, h, nil).Code, "m4", "verkyyi")
	path := FleetNodesPrefix + out.EndpointID + "/desired"

	code, b := operatorDo(t, h, http.MethodGet, path, nil)
	if code != 200 || !strings.Contains(string(b), `"version":0`) || !strings.Contains(string(b), `"trust":"trusted"`) {
		t.Fatalf("empty desired: %d %s", code, b)
	}
	want := map[string]any{"release": "abc1234", "components": map[string]string{"ccquota": "prod-1", "claude": "2.1.3"},
		"accounts": []string{"verkyyi", "alice"}, "spare_accounts": 2, "if_version": 0}
	code, b = operatorDo(t, h, http.MethodPut, path, want)
	if code != 200 || !strings.Contains(string(b), `"version":1`) || !strings.Contains(string(b), `"release":"abc1234"`) {
		t.Fatalf("put: %d %s", code, b)
	}
	if code, b := operatorDo(t, h, http.MethodPut, path, want); code != http.StatusConflict {
		t.Fatalf("stale if_version: %d %s; want 409", code, b)
	}
	if code, _ := operatorDo(t, h, http.MethodPut, path, map[string]any{"token": "x"}); code != http.StatusBadRequest {
		t.Fatalf("unknown field: %d; want 400", code)
	}
	if code, _ := operatorDo(t, h, http.MethodPut, path, map[string]any{"accounts": []string{"Bad Name"}}); code != http.StatusBadRequest {
		t.Fatalf("bad account: %d; want 400", code)
	}
	// Not the operator: a person, the node's own token, nobody.
	if code, _ := asPerson(t, h, http.MethodPut, path, pAlice, []byte(`{}`)); code != http.StatusForbidden {
		t.Fatalf("person put: %d; want 403", code)
	}
	r, _ := http.NewRequest(http.MethodPut, h.http.URL+path, strings.NewReader(`{}`))
	r.Header.Set("Authorization", "Bearer "+out.Token)
	if resp, err := http.DefaultClient.Do(r); err != nil || resp.StatusCode == 200 {
		t.Fatalf("node put: %v %v; want refused", resp, err)
	}
	// The node reads its own.
	resp, nb := getWithToken(t, h, "/v1/node/desired", out.Token)
	if resp.StatusCode != 200 || !strings.Contains(string(nb), `"version":1`) || !strings.Contains(string(nb), `"spare_accounts":2`) {
		t.Fatalf("node read: %d %s", resp.StatusCode, nb)
	}
	// Trust through the desired state is the operator's, on this endpoint.
	code, b = operatorDo(t, h, http.MethodPut, path, map[string]any{"release": "abc1234", "trust": "untrusted"})
	if code != 200 || !strings.Contains(string(b), `"trust":"untrusted"`) || !strings.Contains(string(b), `"trust_source":"operator"`) {
		t.Fatalf("trust put: %d %s", code, b)
	}
	if n := trustAuditCount(t, h, `fleet_id = 'endpoint:`+out.EndpointID+`'`); n != 1 {
		t.Fatalf("endpoint trust audit rows = %d", n)
	}

	c := dialNode(t, h, out.Token)
	defer c.Close(0, "")
	hello(t, c, control.Proto, 200)
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m4", OSUser: "verkyyi", ObservedAt: time.Now(),
		Desired: &control.DesiredReport{Version: 1, Release: "abc1234", Diff: "codex 0.9 → 0.10"}})
	waitFor(t, 3*time.Second, "the 期望 / 实际 pair", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.EndpointID == out.EndpointID && n.Desired != nil {
				return n.Desired.Want == 2 && n.Desired.Reached == 1 && n.Desired.Diff != "" && n.Role == store.NodeRoleManaged
			}
		}
		return false
	})
}

// No desired state and no report: the roster row has no desired field.
func TestDesiredAbsentAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m5")
	c := dialNode(t, h, tok)
	defer c.Close(0, "")
	hello(t, c, control.Proto, 200)
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m5", OSUser: "verk", ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "m5 on the roster", func() bool { return len(roster(t, h).Nodes) == 1 })
	b, _ := json.Marshal(roster(t, h).Nodes[0])
	if strings.Contains(string(b), `"desired"`) || strings.Contains(string(b), `"role"`) || strings.Contains(string(b), `"trust_source"`) {
		t.Fatalf("an unmanaged, untrusted node grew fields: %s", b)
	}
}
