package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

// The task record's node road (claude-fleet#3330, EPIC #3178 ⑦).

func nodeTaskCall(t *testing.T, h *harness, tok, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(raw, &out)
	if out == nil {
		out = map[string]any{"raw": string(raw)}
	}
	return res.StatusCode, out
}

// The completion criterion, hub side: a coordinator opens a record with its
// node token (the same token twice is one record), puts a question and a park
// on it and lifts them again; another owner's machine cannot read it; a
// malformed write is refused before anything is stored.
func TestNodeTaskRecordRoad(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.FleetAdmins = []string{"verk"} // bob is pBob's, alice her endpoint's
	bob, alice := n["bob4"].token, n["alice4"].token

	st, rec := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath, map[string]any{
		"token": "orch:scratch-3:abc", "title": "看看风扇\n为什么一直转", "via": "编排", "rule": "n=1 v=ef40626711"})
	if st != 200 || rec["id"] != "T1" || rec["title"] != "看看风扇 为什么一直转" || rec["owner"] != pBob ||
		rec["rule"] != "n=1 v=ef40626711" || rec["state"] != "placing" || rec["machine"] == "" {
		t.Fatalf("create = %d %v", st, rec)
	}
	if st, again := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath, map[string]any{
		"token": "orch:scratch-3:abc", "title": "other"}); st != 200 || again["id"] != "T1" {
		t.Fatalf("the same token again = %d %v; want T1", st, again)
	}
	if st, _ := nodeTaskCall(t, h, alice, http.MethodGet, NodeTasksPath+"/T1", nil); st != 404 {
		t.Fatalf("another owner's machine reads T1: HTTP %d", st)
	}
	st, rec = nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/T1", map[string]any{
		"asked": "要不要合？", "parked": "停放：等 #12", "key": "scratch-7", "issue": "verkyyi/claude-fleet#12"})
	if st != 200 || rec["asked"] != "要不要合？" || rec["parked"] != "停放：等 #12" || rec["session_key"] != "scratch-7" ||
		rec["issue"] != "verkyyi/claude-fleet#12" {
		t.Fatalf("update = %d %v", st, rec)
	}
	st, rec = nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/T1", map[string]any{"clear": []string{"asked", "parked"}})
	if st != 200 || rec["asked"] != "" || rec["parked"] != "" || rec["issue"] != "verkyyi/claude-fleet#12" {
		t.Fatalf("clear = %d %v", st, rec)
	}
	st, got := nodeTaskCall(t, h, bob, http.MethodGet, NodeTasksPath+"/T1", nil)
	if task, _ := got["task"].(map[string]any); st != 200 || task["id"] != "T1" || task["session_key"] != "scratch-7" {
		t.Fatalf("read = %d %v", st, got)
	}
	for _, bad := range []map[string]any{
		{"token": "x", "title": ""}, {"token": "", "title": "t"}, {"token": "x y", "title": "t"},
		{"token": "x", "title": "t", "rule": "1"}, {"token": "x", "title": "t", "issue": "12"},
		{"token": "x", "title": "t", "key": "home"}, {"token": "x", "title": "t", "state": "merged"},
		{"token": "x", "title": "t", "worker_id": wrFleetM5 + "/" + wrFid},
	} {
		if st, out := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath, bad); st != 400 {
			t.Fatalf("%v = %d %v; want 400", bad, st, out)
		}
	}
	if st, _ := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/T1", map[string]any{"clear": []string{"title"}}); st != 400 {
		t.Fatalf("clearing a title: HTTP %d; want 400", st)
	}
	if st, _ := nodeTaskCall(t, h, "nope", http.MethodGet, NodeTasksPath+"/T1", nil); st != 401 {
		t.Fatalf("no node token: HTTP %d; want 401", st)
	}
}
