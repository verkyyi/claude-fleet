package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The console's session tools over /mcp (task T4DN): a connected agent sees
// only its person's sessions, writes only with the scope its person ticked,
// and every write goes through the console's own chat road as that person.

const (
	sessAliceFID = "9caa99de-2736-4711-b61b-ab363f65279e"
	sessAliceAsk = "0d1b5c7e-27aa-4b5e-8f3e-6a1f0e9a2b11"
	sessBobFID   = "4b7f3d20-9c55-4d0e-a1c4-2f8e6d5b7a90"
)

// agentReq is a /mcp call as a connected agent of person holding scopes.
func agentReq(person string, scopes ...string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/mcp", nil)
	r.Header.Set("Authorization", "Bearer tm_test")
	r.Header.Set("Content-Type", "application/json")
	g := &store.AgentGrant{ID: "g-" + person, Person: person, Scopes: append([]string{"fleet:read"}, scopes...)}
	ctx := context.WithValue(withViewer(r.Context(), person), principalKey{}, person)
	ctx = context.WithValue(ctx, agentGrantKey{}, g)
	ctx = withRole(withDoor(ctx, doorAgent), roleUser)
	return r.WithContext(ctx)
}

// sessionsFixture: alice has a working session and one asking a permission on
// her home login; bob has one of his own on his.
func sessionsFixture(t *testing.T) (*harness, *fakeNode, func(aliceState string)) {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	setChatHome(t, h, pAlice, "sess-node", "alice")
	setChatHome(t, h, pBob, "sess-node-b", "bob")
	h.srv.fleetScopeHook = func(r *http.Request) (func(string, string) bool, error) {
		switch principalOf(r.Context()) {
		case pAlice:
			return func(host, user string) bool { return host == "sess-node" && user == "alice" }, nil
		case pBob:
			return func(host, user string) bool { return host == "sess-node-b" && user == "bob" }, nil
		}
		return func(string, string) bool { return false }, nil
	}
	n := connectFakeNode(t, h, "sess-node-alice", false)
	nb := connectFakeNode(t, h, "sess-node-bob", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "o/r", "/a")
	fb := fakeFleet(t, machineB, "bob-fleet", "o/r", "/b")
	fb.Workers, _ = json.Marshal([]map[string]any{{"worker_id": fb.FleetID + "/" + sessBobFID, "fleet_id": sessBobFID,
		"identity": sessBobFID, "state": "needs", "status_kind": "permission", "status_msg": "bob's secret question", "title": "bob's"}})
	fb.Count = 1
	beatAlice := func(state string) {
		f := fa
		f.Workers, _ = json.Marshal([]map[string]any{
			{"worker_id": fa.FleetID + "/" + sessAliceFID, "fleet_id": sessAliceFID, "identity": sessAliceFID, "state": state, "title": "build the page", "repo": "o/r"},
			{"worker_id": fa.FleetID + "/" + sessAliceAsk, "fleet_id": sessAliceAsk, "identity": sessAliceAsk, "state": "needs",
				"status_kind": "permission", "status_msg": "Bash: rm -rf build", "title": "clean up"},
		})
		f.Count = 2
		n.beat("sess-node", "alice", machineA, f)
	}
	beatAlice("working")
	nb.beat("sess-node-b", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		a, errA := h.srv.Store.Fleet(fa.FleetID)
		b, errB := h.srv.Store.Fleet(fb.FleetID)
		return errA == nil && errB == nil && a.Present && b.Present
	})
	return h, n, beatAlice
}

func listOf(t *testing.T, out any) []SessionRow {
	t.Helper()
	m, ok := out.(map[string]any)
	if !ok {
		t.Fatalf("answer %T", out)
	}
	rows, _ := m["sessions"].([]SessionRow)
	return rows
}

func TestSessionToolsListIsOwnOnly(t *testing.T) {
	h, _, _ := sessionsFixture(t)
	all, err := h.srv.CallSessionTool(agentReq(pAlice), "sessions_list", map[string]any{"view": "all"})
	if err != nil {
		t.Fatal(err)
	}
	rows := listOf(t, all)
	if len(rows) != 2 {
		t.Fatalf("alice's sessions = %+v; want her two", rows)
	}
	for _, r := range rows {
		if r.Title == "bob's" || (r.Asking != nil && r.Asking.Text == "bob's secret question") {
			t.Fatalf("bob's session reached alice: %+v", r)
		}
		if r.URL == "" || r.ID == "" {
			t.Fatalf("row without id / url: %+v", r)
		}
	}
	needs, err := h.srv.CallSessionTool(agentReq(pAlice), "sessions_list", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	rows = listOf(t, needs)
	if len(rows) != 1 || rows[0].Status != "needs_you" || rows[0].Asking == nil || rows[0].Asking.Text != "Bash: rm -rf build" {
		t.Fatalf("needs_you = %+v; want the one asking, with its words", rows)
	}
	m := needs.(map[string]any)
	if c := m["counts"].(map[string]int); c["needs_you"] != 1 || c["working"] != 1 || c["total"] != 2 {
		t.Fatalf("counts = %v", c)
	}
	// bob's id is not alice's to get, read or talk to
	bobWID := ""
	if b, err := h.srv.CallSessionTool(agentReq(pBob), "sessions_list", map[string]any{"view": "all"}); err == nil {
		if br := listOf(t, b); len(br) == 1 {
			bobWID = br[0].ID
		}
	}
	if bobWID == "" {
		t.Fatal("bob does not see his own session")
	}
	for _, tool := range []string{"session_get", "session_read", "session_stop"} {
		_, err := h.srv.CallSessionTool(agentReq(pAlice, "worker:stop"), tool, map[string]any{"id": bobWID})
		var f *FleetFault
		if !errors.As(err, &f) || f.Code != "NOT_FOUND" {
			t.Fatalf("%s of bob's session as alice: %v; want NOT_FOUND", tool, err)
		}
	}
}

func TestSessionSayNeedsTheGrantAndRidesTheChatRoad(t *testing.T) {
	h, _, _ := sessionsFixture(t)
	all, err := h.srv.CallSessionTool(agentReq(pAlice), "sessions_list", map[string]any{"view": "all"})
	if err != nil {
		t.Fatal(err)
	}
	rows := listOf(t, all)
	wid := ""
	for _, r := range rows {
		if r.Title == "build the page" {
			wid = r.ID
		}
	}
	args := map[string]any{"id": wid, "text": "go on", "idempotency_key": "k-1"}
	_, err = h.srv.CallSessionTool(agentReq(pAlice), "session_say", args)
	var f *FleetFault
	if !errors.As(err, &f) || f.Code != "FORBIDDEN" {
		t.Fatalf("say without worker:message: %v; want FORBIDDEN", err)
	}
	// With the scope it reaches the console's road AS alice: her own session,
	// on a machine whose agent has no chat relay — the road's own old_agent,
	// which it answers only after termPerson / termTarget let her through.
	_, err = h.srv.CallSessionTool(agentReq(pAlice, "worker:message"), "session_say", args)
	if !errors.As(err, &f) || f.Code != "old_agent" {
		t.Fatalf("say with worker:message: %v; want the chat road's old_agent", err)
	}
	// Reading goes the same road (the read-along view), as alice: her machine's
	// agent has no relay and the hub keeps no copy, so the road's own word.
	if _, err := h.srv.CallSessionTool(agentReq(pAlice), "session_read", map[string]any{"id": wid}); !errors.As(err, &f) || f.Code != "old_agent" {
		t.Fatalf("read: %v; want the view road's old_agent", err)
	}
	// The operator's door is nobody's conversation.
	op := httptest.NewRequest(http.MethodPost, "/mcp", nil)
	op.Header.Set("Authorization", "Bearer "+viewerToken)
	if _, err := h.srv.CallSessionTool(op, "session_stop", map[string]any{"id": wid}); err == nil {
		t.Fatal("the operator's door stopped a session")
	}
}

func TestSessionNewAnswersPerItem(t *testing.T) {
	h, _, _ := sessionsFixture(t)
	args := map[string]any{"idempotency_key": "new-1", "items": []any{
		map[string]any{"text": "first", "agent": "claude"},
		map[string]any{"text": "second", "agent": "codex", "repo": "o/r"},
	}}
	if _, err := h.srv.CallSessionTool(agentReq(pAlice), "session_new", args); err == nil {
		t.Fatal("session_new without worker:start answered")
	}
	out, err := h.srv.CallSessionTool(agentReq(pAlice, "worker:start"), "session_new", args)
	if err != nil {
		t.Fatal(err)
	}
	m := out.(map[string]any)
	res := m["sessions"].([]map[string]any)
	if len(res) != 2 || m["failed"] != 2 {
		t.Fatalf("session_new = %v; want two per-item answers", m)
	}
	for i, r := range res {
		e, _ := r["error"].(map[string]string)
		if r["index"] != i || r["state"] != "failed" || e["code"] == "" || e["code"] == "operator" || e["code"] == "signin" {
			t.Fatalf("item %d = %v; want its own failure from the chat road, as alice", i, r)
		}
	}
	bad := map[string]any{"idempotency_key": "new-2", "items": []any{map[string]any{"text": "x", "agent": "gemini"}}}
	if _, err := h.srv.CallSessionTool(agentReq(pAlice, "worker:start"), "session_new", bad); err == nil {
		t.Fatal("an unknown agent was accepted")
	}
}

func TestSessionWaitWakesOnChangeAndTimesOut(t *testing.T) {
	h, _, beatAlice := sessionsFixture(t)
	old := waitPoll
	waitPoll = 100 * time.Millisecond
	t.Cleanup(func() { waitPoll = old })

	// no cursor, until needs_you: what already asks is news at once
	out, err := h.srv.CallSessionTool(agentReq(pAlice), "wait", map[string]any{"timeout_s": 2})
	if err != nil {
		t.Fatal(err)
	}
	m := out.(map[string]any)
	evs, _ := m["events"].([]map[string]any)
	if len(evs) != 1 || evs[0]["to"] != "needs_you" || m["timed_out"] != false {
		t.Fatalf("first wait = %v; want the session already asking", m)
	}
	cursor := m["cursor"].(string)

	// from that cursor nothing more: it times out, handing a cursor back
	out, err = h.srv.CallSessionTool(agentReq(pAlice), "wait", map[string]any{"timeout_s": 1, "cursor": cursor})
	if err != nil {
		t.Fatal(err)
	}
	m = out.(map[string]any)
	if m["timed_out"] != true || m["cursor"] == "" {
		t.Fatalf("quiet wait = %v; want timed_out with a cursor", m)
	}

	// until done: the working session's turn ends
	type answer struct {
		out any
		err error
	}
	got := make(chan answer, 1)
	go func() {
		o, e := h.srv.CallSessionTool(agentReq(pAlice), "wait", map[string]any{"until": "done", "timeout_s": 10, "cursor": m["cursor"]})
		got <- answer{o, e}
	}()
	time.Sleep(300 * time.Millisecond)
	beatAlice("done")
	select {
	case a := <-got:
		if a.err != nil {
			t.Fatal(a.err)
		}
		m = a.out.(map[string]any)
		evs, _ = m["events"].([]map[string]any)
		if len(evs) != 1 || evs[0]["from"] != "working" || evs[0]["to"] != "idle" {
			t.Fatalf("done wait = %v; want working → idle", m)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("the wait did not wake on the change")
	}

	// at most three at once per person
	sessionWaits.mu.Lock()
	sessionWaits.n[pAlice] = waitSlots
	sessionWaits.mu.Unlock()
	defer func() { sessionWaits.mu.Lock(); delete(sessionWaits.n, pAlice); sessionWaits.mu.Unlock() }()
	if _, err := h.srv.CallSessionTool(agentReq(pAlice), "wait", map[string]any{"timeout_s": 1}); err == nil {
		t.Fatal("a fourth wait was let in")
	}
}

func TestSessionIdemNeverActsTwice(t *testing.T) {
	c := &sessionIdem{byKey: map[string]*idemEntry{}}
	n := 0
	fn := func() (any, error) { n++; return map[string]any{"ok": true}, nil }
	if _, err, replay := c.once("k", "a", fn); err != nil || replay {
		t.Fatal(err, replay)
	}
	if _, err, replay := c.once("k", "a", fn); err != nil || !replay || n != 1 {
		t.Fatalf("the same key again: err %v replay %v calls %d", err, replay, n)
	}
	if _, err, _ := c.once("k", "b", fn); err == nil {
		t.Fatal("the same key with other arguments was not refused")
	}
	if a, b := deliveryID("p", "k"), deliveryID("p", "k"); a != b || len(a) != 36 || deliveryID("q", "k") == a {
		t.Fatalf("delivery ids: %s %s", a, b)
	}
}
