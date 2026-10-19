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
