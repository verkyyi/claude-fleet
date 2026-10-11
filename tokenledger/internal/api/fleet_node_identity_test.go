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

// Trust is the machine's (claude-fleet#3300): an endpoint holds the trust of
// the machine it ENROLLED as, whatever name it reports; a trusted name it did
// not enroll as is name_borrowed; its own record (a join code's word) is not
// read; the operator's untrusted on its machine takes it away.
func TestTrustIsTheEnrolledMachines(t *testing.T) {
	set := map[string]string{NodeTrustPrefix + "m5": TrustTrusted}
	if tr, src := nodeTrust("m5.local", store.EndpointTrust{EnrolledHost: "m5"}, set); tr != TrustTrusted || src != TrustSourceMachine {
		t.Fatalf("m5 = %s %s; want trusted machine", tr, src)
	}
	// renamed since: still the machine it enrolled as
	if tr, _ := nodeTrust("renamed", store.EndpointTrust{EnrolledHost: "m5"}, set); tr != TrustTrusted {
		t.Fatalf("a renamed m5 lost its machine's trust")
	}
	if tr, src := nodeTrust("m5", store.EndpointTrust{EnrolledHost: "evil"}, set); tr != TrustUntrusted || src != TrustSourceNameBorrowed {
		t.Fatalf("borrowed m5 = %s %s", tr, src)
	}
	if tr, _ := nodeTrust("m5", store.EndpointTrust{EnrolledHost: "?"}, set); tr != TrustUntrusted {
		t.Fatalf("a never-named endpoint inherited m5's trust")
	}
	own := store.EndpointTrust{Trust: TrustTrusted, Source: store.TrustSourceJoinCode, EnrolledHost: "m9"}
	if tr, _ := nodeTrust("m9", own, map[string]string{}); tr != TrustUntrusted {
		t.Fatalf("an endpoint's own record gave trust its machine does not hold")
	}
	if tr, _ := nodeTrust("m5", store.EndpointTrust{EnrolledHost: "m5"}, map[string]string{NodeTrustPrefix + "m5": TrustUntrusted}); tr != TrustUntrusted {
		t.Fatalf("the operator's untrusted on the machine did not win")
	}
}

// The 托管 route mints a trusted, managed code that lives an hour and
// redeems once; redeeming it puts the trust on the MACHINE the endpoint
// enrolled as (claude-fleet#3300) — and the code is refused after its hour.
func TestManagedJoinCodeTrustsTheMachine(t *testing.T) {
	h := newFleetHarness(t)
	t0 := time.Now()
	now := t0
	h.srv.joinClock = func() time.Time { return now }
	v := mintManaged(t, h, map[string]string{"label": "m9"})
	if v.Trust != TrustTrusted || v.Role != store.NodeRoleManaged {
		t.Fatalf("managed code = %+v; want trusted managed", v)
	}
	// the one line runs the 托管 installer the hub itself serves (claude-fleet#2330)
	if want := "curl -fsSL " + h.http.URL + "/install/" + NodeInstallScript + " | sudo bash -s -- --hub " + h.http.URL + " --join " + v.Code; v.Command != want {
		t.Fatalf("managed command = %q; want %q", v.Command, want)
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
	if err != nil || et.Role != store.NodeRoleManaged || et.EnrolledHost != "m9" {
		t.Fatalf("endpoint = %+v %v", et, err)
	}
	if s, _ := h.srv.Store.FleetSettings(); s[NodeTrustPrefix+"m9"] != TrustTrusted {
		t.Fatalf("a trusted join code did not trust its machine: %v", s)
	}
	resp, body := getWithToken(t, h, "/v1/node/self", out.Token)
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"trust":"trusted"`) || !strings.Contains(string(body), `"trust_source":"machine"`) {
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
	if resp, body := getWithToken(t, h, "/v1/node/self", pout.Token); !strings.Contains(string(body), `"trust":"untrusted"`) {
		t.Fatalf("a plain code gave trust: %d %s", resp.StatusCode, body)
	}
	// A trusted code never lifts the operator's untrusted on its machine.
	putSetting(t, h, NodeTrustPrefix+"m6", TrustUntrusted, 200)
	now = t0.Add(time.Second)
	_, uout := joinWith(t, h, mintManaged(t, h, nil).Code, "m6", "verkyyi")
	if _, body := getWithToken(t, h, "/v1/node/self", uout.Token); !strings.Contains(string(body), `"trust":"untrusted"`) {
		t.Fatalf("a trusted code lifted the operator's untrusted: %s", body)
	}
	// And the managed route takes trusted:false.
	if v := mintManaged(t, h, map[string]any{"trusted": false}); v.Trust != "" || v.Role != store.NodeRoleManaged {
		t.Fatalf("managed untrusted code = %+v", v)
	}
}

// A login the hub opens on a machine (claude-fleet#3300) holds that
// machine's trust: its join code names the machine, so it enrolls as it —
// trusted on a trusted machine, untrusted on an untrusted one, and a login
// that reports another (trusted) name gains nothing by it.
func TestOpenedLoginHoldsItsMachinesTrust(t *testing.T) {
	h := newFleetHarness(t)
	putSetting(t, h, NodeTrustPrefix+"fleet-linux-0", TrustTrusted, 200)
	now := time.Now()
	self := func(tok string) string {
		_, body := getWithToken(t, h, "/v1/node/self", tok)
		return string(body)
	}

	code := h.srv.loginJoinCode(store.FleetAccount{Hostname: "fleet-linux-0", Login: "24haowan"}, now)
	if code == "" {
		t.Fatal("no join code minted")
	}
	st, out := joinWith(t, h, code, "fleet-linux-0", "24haowan")
	if st != 200 {
		t.Fatalf("join: %d", st)
	}
	if b := self(out.Token); !strings.Contains(b, `"trust":"trusted"`) || !strings.Contains(b, `"trust_source":"machine"`) {
		t.Fatalf("a login opened on a trusted machine: %s; want trusted machine", b)
	}

	// An untrusted machine's login is untrusted — even reporting a trusted name.
	code = h.srv.loginJoinCode(store.FleetAccount{Hostname: "m-untrusted", Login: "bob"}, now)
	_, bout := joinWith(t, h, code, "fleet-linux-0", "bob")
	if et, _ := h.srv.Store.EndpointTrustOf(bout.EndpointID); et.EnrolledHost != "m-untrusted" {
		t.Fatalf("enrolled as %q; want the code's machine", et.EnrolledHost)
	}
	if b := self(bout.Token); !strings.Contains(b, `"trust":"untrusted"`) {
		t.Fatalf("a login opened on an untrusted machine: %s; want untrusted", b)
	}

	// The operator marks the machine trusted: every login there follows.
	putSetting(t, h, NodeTrustPrefix+"m-untrusted", TrustTrusted, 200)
	if b := self(bout.Token); !strings.Contains(b, `"trust":"trusted"`) {
		t.Fatalf("after the machine was trusted: %s", b)
	}
}

// The one move (claude-fleet#3300): every endpoint's own trust lands on the
// machine it enrolled as, once; the operator's untrusted wins over a
// sibling's trusted; a machine with a key keeps it.
func TestTrustMigratesOntoMachines(t *testing.T) {
	h := newFleetHarness(t)
	st := h.srv.Store
	now := time.Now()
	enroll := func(id, host, trust, src string) {
		t.Helper()
		code, _ := MintJoinCode()
		if err := st.CreateJoinCodeFor(HashToken(code), "", store.NodeKindFixed, "", "", "", now, time.Hour); err != nil {
			t.Fatal(err)
		}
		tok, _ := MintToken()
		if err := st.RedeemJoinCode(HashToken(code), now, id, id, HashToken(tok), host, "u"); err != nil {
			t.Fatal(err)
		}
		if trust != "" {
			if err := st.SetEndpointTrust(id, trust, src); err != nil {
				t.Fatal(err)
			}
		}
	}
	enroll("ep_a", "ma", TrustTrusted, store.TrustSourceJoinCode)
	enroll("ep_a2", "ma", "", "")
	enroll("ep_b", "mb", TrustTrusted, store.TrustSourceJoinCode)
	enroll("ep_b2", "mb", TrustUntrusted, store.TrustSourceOperator)
	enroll("ep_c", "mc", TrustTrusted, store.TrustSourceOperator)
	if err := st.SetFleetSetting(NodeTrustPrefix+"mc", TrustUntrusted, now); err != nil {
		t.Fatal(err)
	}
	set, err := h.srv.trustSettings(now)
	if err != nil {
		t.Fatal(err)
	}
	if set[NodeTrustPrefix+"ma"] != TrustTrusted || set[NodeTrustPrefix+"mb"] != TrustUntrusted || set[NodeTrustPrefix+"mc"] != TrustUntrusted {
		t.Fatalf("after the move: ma=%q mb=%q mc=%q", set[NodeTrustPrefix+"ma"], set[NodeTrustPrefix+"mb"], set[NodeTrustPrefix+"mc"])
	}
	if set[NodeTrustMachinesMigratedKey] == "" {
		t.Fatal("the move was not stamped")
	}
	if tr, _ := h.srv.endpointTrust("ep_a2", "ma", set); tr != TrustTrusted {
		t.Fatalf("ma's other login = %s; want its machine's trusted", tr)
	}
	// Once: a later endpoint trust is not moved again.
	enroll("ep_d", "md", TrustTrusted, store.TrustSourceJoinCode)
	if set, _ := h.srv.trustSettings(now); set[NodeTrustPrefix+"md"] != "" {
		t.Fatalf("the move ran twice: md=%q", set[NodeTrustPrefix+"md"])
	}
}

// Desired state: only the operator writes, every write bumps the version, a
// stale if_version is refused, trust in the body is its machine's, the
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
	// Trust through the desired state is the operator's, on the machine.
	code, b = operatorDo(t, h, http.MethodPut, path, map[string]any{"release": "abc1234", "trust": "untrusted"})
	if code != 200 || !strings.Contains(string(b), `"trust":"untrusted"`) || !strings.Contains(string(b), `"trust_source":"machine"`) {
		t.Fatalf("trust put: %d %s", code, b)
	}
	if s, _ := h.srv.Store.FleetSettings(); s[NodeTrustPrefix+"m4"] != TrustUntrusted {
		t.Fatalf("desired trust did not land on the machine: %v", s)
	}
	if n := trustAuditCount(t, h, `fleet_id = 'machine:m4' AND outcome LIKE 'trusted → untrusted%'`); n != 1 {
		t.Fatalf("machine trust audit rows = %d", n)
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
