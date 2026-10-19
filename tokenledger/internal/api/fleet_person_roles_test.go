package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// A person's rule table, kept and pushed (claude-fleet#2784, EPIC #2781 C3);
// the role overlays left with the person's role layer (claude-fleet#3130).

var personRolesV1 = map[string]any{"bundle": map[string]any{
	"rules": "| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 报价, 金额 |\n",
}}

// rules: a table or a list of rows, at most 32 KiB, no credential in it. The
// team layer takes none.
func TestPersonRulesValidation(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())

	code, out, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), personRolesV1, "")
	if code != 200 || out.Version != 1 || !strings.Contains(string(out.Bundle), `| 101 | steward |`) {
		t.Fatalf("a valid rules layer: HTTP %d %s", code, raw)
	}
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, personRolesV1, ""); code != http.StatusUnprocessableEntity || !strings.Contains(raw, "is not something a team hands out") {
		t.Fatalf("team PUT with rules: HTTP %d %s, want 422", code, raw)
	}
	for name, b := range map[string]map[string]any{
		"rules a number":  {"rules": 3},
		"rules an object": {"rules": map[string]any{"5": "x"}},
		"rule not a row":  {"rules": []any{"x"}},
		"rules over cap":  {"rules": strings.Repeat("b", 33<<10)},
		"rule secret":     {"rules": []any{map[string]any{"n": 101, "action": "curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz' x"}}},
	} {
		code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": b}, "")
		if code != http.StatusUnprocessableEntity {
			t.Errorf("%s: HTTP %d %s, want 422", name, code, raw)
		}
	}
}

// The roles key is no longer rendered: an older client's PUT that still
// carries it is taken (compat-1v — never checked, even a bad overlay), the key
// dropped, and the layer stored and answered exactly as validateBundle makes
// it of the rest. A node that never said CapPerson is never sent anything.
func TestPersonRolesOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-e", Login: "alice"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	old := personNode(t, h, "alice-old", "mac-e", "alice") // no CapPerson
	raw, _ := json.Marshal(personV1["bundle"])
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	_ = dec.Decode(&m)
	want, _ := json.Marshal(m)
	code, out, body, _ := personCall(t, h, http.MethodPut, asSession(pAlice), personV1, "")
	if code != 200 || string(out.Bundle) != string(want) || strings.Contains(body, `"roles"`) || strings.Contains(body, `"rules"`) {
		t.Fatalf("PUT without roles: HTTP %d %s, want the bundle as %s", code, body, want)
	}
	withRoles := map[string]any{}
	for k, v := range m {
		withRoles[k] = v
	}
	withRoles["roles"] = map[string]any{"reviewer": 3, "worker": "---\nmodel: opus\n---\n"}
	code, out, body, _ = personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": withRoles}, "")
	if code != 200 || string(out.Bundle) != string(want) || strings.Contains(body, `"roles"`) {
		t.Fatalf("PUT with roles: HTTP %d %s, want it taken and the bundle as %s", code, body, want)
	}
	if code, _, body, _ := personCall(t, h, http.MethodGet, asSession(pAlice), nil, ""); code != 200 || strings.Contains(body, `"roles"`) {
		t.Fatalf("GET after a roles PUT: HTTP %d %s", code, body)
	}
	if m, ok := readMsg(old.tnode, 400*time.Millisecond); ok && m.Type == control.TypePerson {
		t.Fatalf("a node without CapPerson was sent %s", m.Payload)
	}
}

func personNode(t *testing.T, h *harness, label, hostname, osUser string, caps ...string) *fleetNode {
	t.Helper()
	tok := h.enroll(t, label)
	id := "ep_" + label
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint(id, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	n := &fleetNode{token: tok, id: id}
	n.tnode = dialAdminCaps(t, h, tok, false, caps...)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: hostname, OSUser: osUser})
	waitFor(t, 3*time.Second, label+" on the roster", func() bool {
		r := h.srv.nodeRow(id)
		return r != nil && r.Hostname != ""
	})
	return n
}

// nextPerson wants a TypePerson within a second, skipping anything else.
func nextPerson(t *testing.T, n *fleetNode, what string) control.Person {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		m, ok := readMsg(n.tnode, time.Until(deadline))
		if !ok {
			break
		}
		if m.Type == control.TypePerson {
			var p control.Person
			_ = json.Unmarshal(m.Payload, &p)
			return p
		}
	}
	t.Fatalf("%s: no person message", what)
	return control.Person{}
}

// noPerson wants no TypePerson for a moment.
func noPerson(t *testing.T, n *fleetNode, what string) {
	t.Helper()
	deadline := time.Now().Add(400 * time.Millisecond)
	for time.Now().Before(deadline) {
		m, ok := readMsg(n.tnode, time.Until(deadline))
		if !ok {
			return
		}
		if m.Type == control.TypePerson {
			t.Fatalf("%s: got person %s, want none", what, m.Payload)
		}
	}
}

// The completion criterion, hub side: a PUT reaches every machine its person
// runs sessions on — at once, and only theirs; a machine that was away hears
// it on its first beat back; a login bound to no one hears nothing.
func TestPersonPushOnPutBeatAndReconnect(t *testing.T) {
	h, _ := certHarness(t) // Alice: alice on mac-e + mac-e-mac-c
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "mac-e-mac-c", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	caps := []string{control.CapTeam, control.CapPerson}
	a5 := personNode(t, h, "alice5", "mac-e", "alice", caps...)
	a4 := personNode(t, h, "alice4", "mac-e-mac-c", "alice", caps...)
	b4 := personNode(t, h, "bob4", "mac-e-mac-c", "bob", caps...)
	v5 := personNode(t, h, "verk5", "mac-e", "frank", caps...)

	// nobody wrote yet: nothing is sent (the degenerate case)
	for k, n := range map[string]*fleetNode{"alice5": a5, "alice4": a4, "bob4": b4, "verk5": v5} {
		noPerson(t, n, k+" before any layer")
	}

	if code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), personRolesV1, ""); code != 200 {
		t.Fatalf("Alice PUT: HTTP %d %s", code, raw)
	}
	p5, p4 := nextPerson(t, a5, "alice@mac-e"), nextPerson(t, a4, "alice@mac-e-mac-c")
	if p5.Version != 1 || p4.Version != 1 || p5.Principal == "" || p5.Principal != p4.Principal {
		t.Fatalf("Alice's machines heard %+v and %+v, want her v1 on both", p5, p4)
	}
	noPerson(t, b4, "Bob's login after Alice's PUT")
	noPerson(t, v5, "a login bound to no one")

	// Bob's is Bob's alone
	if code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pBob), personV1, ""); code != 200 {
		t.Fatalf("Bob PUT: HTTP %d %s", code, raw)
	}
	if pb := nextPerson(t, b4, "bob@mac-e-mac-c"); pb.Version != 1 || pb.Principal == p5.Principal {
		t.Fatalf("Bob heard %+v", pb)
	}
	noPerson(t, a4, "Alice's login after Bob's PUT")

	// beats on a link that heard v1 repeat nothing
	beat(t, a5.c, control.Proto, control.Heartbeat{Hostname: "mac-e", OSUser: "alice"})
	noPerson(t, a5, "a beat after v1")

	// a restore is a new version, pushed the same way
	if code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"restore": 1}, ""); code != 200 {
		t.Fatalf("Alice restore: HTTP %d %s", code, raw)
	}
	if p := nextPerson(t, a5, "after restore"); p.Version != 2 {
		t.Fatalf("after restore: %+v, want v2", p)
	}

	// a machine that was away hears the current version on its first beat back
	a4.c.CloseNow()
	a4b := personNode(t, h, "alice4b", "mac-e-mac-c", "alice", caps...)
	if p := nextPerson(t, a4b, "reconnect"); p.Version != 2 {
		t.Fatalf("reconnect: %+v, want v2", p)
	}
}
