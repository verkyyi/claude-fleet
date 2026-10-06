package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A session's own cross-machine call (claude-fleet#1810, EPIC #1813 C8): the
// node vouches for which of its sessions asked, the hub checks it and writes
// the session into the audit and the journal.

const assertFid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

func assertClaims(fleet string, now time.Time) workerClaims {
	return workerClaims{V: 1, WorkerID: fleetid.WorkerID(fleet, assertFid), FleetUUID: fleet, Fid: assertFid,
		Key: "issue-1", Repo: writeRepo, Issue: "1", Node: "m5", Iat: now.Unix(), Exp: now.Add(5 * time.Minute).Unix()}
}

func placeAs(t *testing.T, h *harness, token, assertion string, body map[string]any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/place", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(workerAssertHeader, assertion)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

type auditRow struct{ actor, worker, key, outcome string }

func placeAudits(t *testing.T, h *harness) []auditRow {
	t.Helper()
	rows, err := h.srv.Store.DB().Query(`SELECT actor, worker_id, worker_key, outcome FROM fleet_audit WHERE action = 'place' ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []auditRow
	for rows.Next() {
		var a auditRow
		if err := rows.Scan(&a.actor, &a.worker, &a.key, &a.outcome); err != nil {
			t.Fatal(err)
		}
		out = append(out, a)
	}
	return out
}

// The completion check: m5's session issue-1 asks for #7, the hub places it on
// m4 with that session as the parent, and the audit + journal name it.
func TestWorkerAssertionPlaceAudited(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@7"}))
	now := time.Now()
	c := assertClaims(f5.FleetID, now)
	tok5 := h.tokens["m5"]
	st, out := placeAs(t, h, tok5, signWorkerAssertion(c, HashToken(tok5)),
		map[string]any{"repo": writeRepo, "issue": 7, "worker_id": issueWID(f5.FleetID, 7)})
	if st != 200 || out["local"] != false {
		t.Fatalf("place = %d %v; want a remote placement", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes: m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	if p := m4.writes[0]["params"].(map[string]any); p["origin_wid"] != c.WorkerID {
		t.Fatalf("m4 was sent origin_wid %v; want the asserting session %s", p["origin_wid"], c.WorkerID)
	}
	a := placeAudits(t, h)
	if len(a) != 1 || a[0].actor != "node:verk@m5" || a[0].worker != c.WorkerID || a[0].key != "issue-1" ||
		!strings.HasPrefix(a[0].outcome, "REMOTE m4 ") {
		t.Fatalf("audit = %+v; want node:verk@m5 for %s (issue-1) → REMOTE m4", a, c.WorkerID)
	}
	t.Logf("audit: actor=%s worker_id=%s worker_key=%s action=place outcome=%s", a[0].actor, a[0].worker, a[0].key, a[0].outcome)
	op, err := h.srv.Store.FleetOperation(out["operation"].(map[string]any)["operation_id"].(string))
	if err != nil || op.WorkerID != c.WorkerID || op.FleetID != f4.FleetID {
		t.Fatalf("journal = %+v %v; want worker_id %s on m4's fleet", op, err, c.WorkerID)
	}
}

// A statement that does not hold is 401 and nothing is placed: forged (not
// this node's token), tampered, expired, malformed — never read as the node's
// own call.
func TestWorkerAssertionForgedRefused(t *testing.T) {
	h, m5, m4, f5, _ := twoNodes(t)
	now := time.Now()
	tok5 := h.tokens["m5"]
	c := assertClaims(f5.FleetID, now)
	good := signWorkerAssertion(c, HashToken(tok5))
	old := c
	old.Iat, old.Exp = now.Add(-2*time.Hour).Unix(), now.Add(-time.Hour).Unix()
	long := c
	long.Exp = now.Add(48 * time.Hour).Unix()
	cases := map[string]string{
		"another node's key": signWorkerAssertion(c, HashToken(h.tokens["m4"])),
		"tampered":           good[:len(good)-2] + "xx",
		"expired":            signWorkerAssertion(old, HashToken(tok5)),
		"over 24h":           signWorkerAssertion(long, HashToken(tok5)),
		"malformed":          "fwc1.e30.e30",
	}
	for name, a := range cases {
		st, out := placeAs(t, h, tok5, a, map[string]any{"repo": writeRepo, "issue": 8, "worker_id": issueWID(f5.FleetID, 8)})
		if e, _ := out["error"].(map[string]any); st != 401 || e["code"] != "UNAUTHENTICATED" {
			t.Errorf("%s: %d %v; want 401 UNAUTHENTICATED", name, st, out)
		}
	}
	if m5.count()+m4.count() != 0 {
		t.Fatal("a refused assertion sent a write")
	}
	for _, a := range placeAudits(t, h) {
		if a.outcome != "refused:UNAUTHENTICATED" {
			t.Fatalf("audit %+v; want every row refused:UNAUTHENTICATED", a)
		}
	}
}

// Out of scope is NOT_FOUND: a session of a fleet this node does not run, or
// a start whose parent is someone other than the asserting session.
func TestWorkerAssertionOutOfScope(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	now := time.Now()
	tok5 := h.tokens["m5"]
	other := signWorkerAssertion(assertClaims(f4.FleetID, now), HashToken(tok5)) // m4's fleet, signed by m5
	st, out := placeAs(t, h, tok5, other, map[string]any{"repo": writeRepo, "issue": 9, "worker_id": issueWID(f5.FleetID, 9)})
	if e, _ := out["error"].(map[string]any); st != 404 || e["code"] != "NOT_FOUND" {
		t.Fatalf("another fleet's session: %d %v; want 404 NOT_FOUND", st, out)
	}
	mine := signWorkerAssertion(assertClaims(f5.FleetID, now), HashToken(tok5))
	st, out = placeAs(t, h, tok5, mine, map[string]any{"repo": writeRepo, "issue": 9, "worker_id": issueWID(f5.FleetID, 9),
		"origin_wid": issueWID(f5.FleetID, 2)})
	if e, _ := out["error"].(map[string]any); st != 404 || e["code"] != "NOT_FOUND" {
		t.Fatalf("a start for another parent: %d %v; want 404 NOT_FOUND", st, out)
	}
	if m5.count()+m4.count() != 0 {
		t.Fatal("an out-of-scope assertion sent a write")
	}
	// Its own key as the parent (the alias, claude-fleet#1646) is itself.
	if c := assertClaims(f5.FleetID, now); !c.speaksAs(issueWID(f5.FleetID, 1)) || !c.speaksAs(c.WorkerID) {
		t.Fatal("the session does not speak as its own key / identity")
	}
}

// A relay carrying an assertion: verified against the sending node's token,
// from must be that session, and the audit names it.
func TestWorkerAssertionRelay(t *testing.T) {
	h := newFleetHarness(t)
	fa := fakeFleet(t, machineA, "fleet-a", writeRepo, "/u/a/repo", 1)
	fb := fakeFleet(t, machineB, "fleet-b", writeRepo, "/u/b/repo", 2)
	connectFakeNode(t, h, "a", false).beat("m5", "op", machineA, fa)
	connectFakeNode(t, h, "b", false).beat("m4", "op", machineB, fb)
	waitFor(t, 5*time.Second, "fleets registered", func() bool {
		_, ea := h.srv.Store.Fleet(fa.FleetID)
		_, eb := h.srv.Store.Fleet(fb.FleetID)
		return ea == nil && eb == nil
	})
	now := time.Now()
	c := assertClaims(fa.FleetID, now)
	hash := HashToken(h.tokens["a"])
	rel := func(from, assertion string) control.Message {
		m, _ := control.New(control.TypeRelay, control.Relay{ID: from + "#1", Kind: control.RelayMessage, From: from,
			To: fb.FleetID + "/issue-2", Payload: json.RawMessage(`{"text":"hi"}`), Worker: assertion})
		return m
	}
	ep := store.Endpoint{ID: "ep_a"}
	check := func(m control.Message, hash string) (*workerClaims, error) {
		r, err := h.srv.checkRelay(ep, m)
		if err != nil {
			t.Fatalf("checkRelay: %v", err)
		}
		return relayWorker(m, r, hash, now)
	}
	if got, err := check(rel(c.WorkerID, signWorkerAssertion(c, hash)), hash); err != nil || got.WorkerID != c.WorkerID {
		t.Fatalf("own relay: %+v %v", got, err)
	}
	if got, err := check(rel(fa.FleetID+"/issue-1", signWorkerAssertion(c, hash)), hash); err != nil || got == nil {
		t.Fatalf("own relay by key: %+v %v", got, err)
	}
	if got, err := check(rel(c.WorkerID, ""), hash); err != nil || got != nil {
		t.Fatalf("no assertion: %+v %v; want nil, nil (the node's own relay)", got, err)
	}
	if _, err := check(rel(c.WorkerID, signWorkerAssertion(c, HashToken(h.tokens["b"]))), hash); errorObject(err)["code"] != "UNAUTHENTICATED" {
		t.Fatalf("forged: %v; want UNAUTHENTICATED", err)
	}
	if _, err := check(rel(fa.FleetID+"/issue-3", signWorkerAssertion(c, hash)), hash); errorObject(err)["code"] != "NOT_FOUND" {
		t.Fatalf("another session's relay: %v; want NOT_FOUND", err)
	}
}
