package api

import (
	"net/http"
	"testing"
)

// The ID mirror's node road (EPIC T497 C2): a node pushes its ledger with its
// own token; two machines of one owner whose codes share 5 characters (S12) —
// the later grows and the 5-character code is ambiguous; a cloned full ID from
// another machine is 409 DUPLICATE_ID (S13); another owner reads nothing.
func TestNodeIDMirrorRoad(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	v5, v4, alice := n["verk5"].token, n["verk4"].token, n["alice4"].token
	const a, b = "3fa85f64-5717-4562-b3fc-2c963f66afa6", "3fa85f74-5717-4562-b3fc-2c963f66afa6"
	ev := func(id string, seq int, kind string) map[string]any {
		return map[string]any{"ev": kind, "id": id, "seq": seq, "ts": 1000 + seq, "agent": "claude", "title": "t " + id[:4]}
	}

	st, got := nodeTaskCall(t, h, v5, http.MethodPost, NodeIDsPath, map[string]any{"id": a,
		"events": []any{ev(a, 1, "opened"), map[string]any{"ev": "native", "id": a, "seq": 2, "ts": 1, "agent": "claude", "native": "s1", "trigger": "startup"}}})
	if st != 200 || got["short"] != "T-7ym5y" || got["seq"] != float64(2) {
		t.Fatalf("A = %d %v", st, got)
	}
	st, got = nodeTaskCall(t, h, v4, http.MethodPost, NodeIDsPath, map[string]any{"id": b, "events": []any{ev(b, 1, "opened")}})
	if st != 200 || got["short"] != "T-7ym5yx" {
		t.Fatalf("B = %d %v; want T-7ym5yx (S12)", st, got)
	}
	if st, got = nodeTaskCall(t, h, v4, http.MethodGet, NodeIDsPath+"/T-7ym5y", nil); st != 409 || got["code"] != "AMBIGUOUS" {
		t.Fatalf("5 characters = %d %v; want AMBIGUOUS", st, got)
	}
	if st, got = nodeTaskCall(t, h, v4, http.MethodGet, NodeIDsPath+"/T-7ym5yx", nil); st != 200 || got["id"] != b {
		t.Fatalf("6 characters = %d %v", st, got)
	}
	if st, got = nodeTaskCall(t, h, v4, http.MethodGet, NodeIDsPath+"/"+a, nil); st != 200 || got["machine"] == "" || len(got["natives"].([]any)) != 1 {
		t.Fatalf("A read from the other machine = %d %v", st, got)
	}
	if st, got = nodeTaskCall(t, h, v4, http.MethodGet, NodeIDsPath, nil); st != 200 || len(got["ids"].([]any)) != 2 {
		t.Fatalf("list = %d %v", st, got)
	}
	// S13: the other machine carrying A's full ID.
	if st, got = nodeTaskCall(t, h, v4, http.MethodPost, NodeIDsPath, map[string]any{"id": a, "events": []any{ev(a, 1, "opened")}}); st != 409 || got["code"] != "DUPLICATE_ID" {
		t.Fatalf("clone = %d %v; want 409 DUPLICATE_ID", st, got)
	}
	if st, _ := nodeTaskCall(t, h, alice, http.MethodGet, NodeIDsPath+"/"+a, nil); st != 404 {
		t.Fatalf("another owner reads A: HTTP %d", st)
	}
	for _, bad := range []map[string]any{{"id": "nope", "events": []any{ev(a, 1, "opened")}}, {"id": a, "events": []any{}}} {
		if st, _ := nodeTaskCall(t, h, v5, http.MethodPost, NodeIDsPath, bad); st != 400 {
			t.Fatalf("%v = %d; want 400", bad, st)
		}
	}
	if st, _ := nodeTaskCall(t, h, "", http.MethodGet, NodeIDsPath, nil); st != 401 {
		t.Fatalf("no token: HTTP %d", st)
	}
}

// An EPIC driver's batch in one read (EPIC T497 C5): ?parent=<ID> answers the
// IDs it spawned and every ID that continued one of them down `prev` (a member's
// redo), with their results; another owner's IDs never appear.
func TestNodeIDFamily(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	v5, alice := n["verk5"].token, n["alice4"].token
	const drv, c1, c2, redo, stray = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
		"33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555"
	open := func(tok, id string, ts int, extra map[string]any) {
		ev := map[string]any{"ev": "opened", "id": id, "seq": 1, "ts": ts, "agent": "claude", "title": "t " + id[:2]}
		for k, v := range extra {
			ev[k] = v
		}
		if st, got := nodeTaskCall(t, h, tok, http.MethodPost, NodeIDsPath, map[string]any{"id": id, "events": []any{ev}}); st != 200 {
			t.Fatalf("open %s = %d %v", id, st, got)
		}
	}
	open(v5, drv, 10, nil)
	open(v5, c1, 20, map[string]any{"parent": drv, "task": "T2"})
	open(v5, c2, 30, map[string]any{"parent": drv, "task": "T3"})
	open(v5, redo, 40, map[string]any{"prev": c2}) // 「从这一段继续」: no parent, prev only
	open(alice, stray, 50, map[string]any{"parent": drv})
	if st, got := nodeTaskCall(t, h, v5, http.MethodPost, NodeIDsPath, map[string]any{"id": redo,
		"events": []any{map[string]any{"ev": "result", "id": redo, "seq": 2, "ts": 41, "state": "merged", "pr": "7"}}}); st != 200 {
		t.Fatalf("result = %d %v", st, got)
	}
	st, got := nodeTaskCall(t, h, v5, http.MethodGet, NodeIDsPath+"?parent="+drv, nil)
	if _, ok := got["ids"].([]any); st != 200 || !ok {
		t.Fatalf("family = %d %v", st, got)
	}
	var ids []string
	for _, x := range got["ids"].([]any) {
		ids = append(ids, x.(map[string]any)["id"].(string))
	}
	if len(ids) != 3 || ids[0] != c1 || ids[1] != c2 || ids[2] != redo {
		t.Fatalf("family = %v; want c1 c2 redo (alice's never)", ids)
	}
	last := got["ids"].([]any)[2].(map[string]any)
	if last["prev"] != c2 || len(last["results"].([]any)) != 1 {
		t.Fatalf("the redo = %v; want prev c2 and its result", last)
	}
	// a member whose ledger names no parent is found by its ID (a seed), with its redo;
	// another owner's ID given as a seed is not read.
	const orphan, orphanRedo = "66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"
	open(v5, orphan, 60, nil)
	open(v5, orphanRedo, 70, map[string]any{"prev": orphan})
	st, got = nodeTaskCall(t, h, v5, http.MethodGet, NodeIDsPath+"?parent="+drv+"&id="+orphan+"&id="+stray, nil)
	if ids, _ := got["ids"].([]any); st != 200 || len(ids) != 5 {
		t.Fatalf("with seeds = %d %v; want 5 ids (c1 c2 redo orphan orphanRedo)", st, got)
	}
	// C18: the driver continued (a new ID, prev = drv) spawns c3 — the family of drv
	// is the whole line's, the line is named and never a member
	const drv2, c3 = "88888888-8888-4888-8888-888888888888", "99999999-9999-4999-8999-999999999999"
	open(v5, drv2, 80, map[string]any{"prev": drv, "task": "T1"})
	open(v5, c3, 90, map[string]any{"parent": drv2, "task": "T4"})
	st, got = nodeTaskCall(t, h, v5, http.MethodGet, NodeIDsPath+"?parent="+drv, nil)
	ids = nil
	for _, x := range got["ids"].([]any) {
		ids = append(ids, x.(map[string]any)["id"].(string))
	}
	if st != 200 || len(ids) != 4 || ids[3] != c3 {
		t.Fatalf("a continued driver's family = %d %v; want c1 c2 redo c3", st, ids)
	}
	if line, _ := got["lineage"].([]any); len(line) != 2 || line[0] != drv || line[1] != drv2 {
		t.Fatalf("lineage = %v; want drv drv2", got["lineage"])
	}
	if st, _ := nodeTaskCall(t, h, v5, http.MethodGet, NodeIDsPath+"?parent=nope", nil); st != 400 {
		t.Fatalf("a bad parent: HTTP %d", st)
	}
}
