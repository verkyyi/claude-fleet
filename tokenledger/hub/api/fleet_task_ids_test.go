package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// EPIC T644 C1 «任务一建好就有编号», the node road: a record answers its ID
// and code at once, every /<ref> reads it by the code, the full ID or T<n>,
// a code naming several is 409 AMBIGUOUS with them, records from before C1
// get their ID from a dry-first backfill, and /version says task_ids.
func TestNodeTaskIDs(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"} // bob is pBob's, alice her endpoint's
	bob, alice := n["bob4"].token, n["alice4"].token

	st, rec := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath, map[string]any{"token": "orch:c1", "title": "probe"})
	fid, _ := rec["fid"].(string)
	short, _ := rec["short"].(string)
	if st != 200 || !store.IsFleetID(fid) || len(short) < store.IDShortMin || rec["task"] != "T1" || rec["id"] != "T1" {
		t.Fatalf("create = %d %v", st, rec)
	}
	for _, ref := range []string{short, strings.ToLower(short[:2]), fid, "T1"} {
		st, got := nodeTaskCall(t, h, bob, http.MethodGet, NodeTasksPath+"/"+ref, nil)
		if task, _ := got["task"].(map[string]any); st != 200 || task["fid"] != fid || task["short"] != short || task["task"] != "T1" {
			t.Fatalf("GET %s = %d %v", ref, st, got)
		}
	}
	if st, _ := nodeTaskCall(t, h, alice, http.MethodGet, NodeTasksPath+"/"+short, nil); st != 404 {
		t.Fatalf("another owner's machine reads %s: HTTP %d", short, st)
	}
	if st, got := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/"+short, map[string]any{"asked": "合吗？"}); st != 200 || got["asked"] != "合吗？" {
		t.Fatalf("POST by code = %d %v", st, got)
	}

	// two of bob's tasks sharing two places: the two-place code is refused with both
	seen := map[string]string{}
	pair := ""
	for i := 0; i < 3000 && pair == ""; i++ {
		_, r := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath, map[string]any{"token": fmt.Sprintf("orch:a%d", i), "title": "x"})
		f, _ := r["fid"].(string)
		p := store.FleetIDCode(f)[:2]
		if store.ParseTaskRef(p) > 0 {
			continue // `T8` reads as the alias T8, never a code
		}
		if _, ok := seen[p]; ok {
			pair = p
		}
		seen[p] = f
	}
	if pair == "" {
		t.Fatal("no two IDs shared two places")
	}
	st, got := nodeTaskCall(t, h, bob, http.MethodGet, NodeTasksPath+"/"+pair, nil)
	if c, _ := got["candidates"].([]any); st != 409 || got["code"] != "AMBIGUOUS" || len(c) < 2 {
		t.Fatalf("GET %s (two tasks) = %d %v", pair, st, got)
	}

	// a record from before C1: dry first, then apply
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET fid = '' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	st, dry := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/ids-backfill", map[string]any{})
	if st != 200 || dry["apply"] != false || dry["minted"] != float64(1) {
		t.Fatalf("dry backfill = %d %v", st, dry)
	}
	st, done := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/ids-backfill", map[string]any{"apply": true})
	if st != 200 || done["minted"] != float64(1) {
		t.Fatalf("apply backfill = %d %v", st, done)
	}
	_, got = nodeTaskCall(t, h, bob, http.MethodGet, NodeTasksPath+"/T1", nil)
	if task, _ := got["task"].(map[string]any); task["fid"] == "" || task["fid"] == fid {
		t.Fatalf("T1 after backfill = %v", got)
	}

	// EPIC T644 C6: the reconcile road — dry by default, a cutoff is T<n>, undo answers
	if st, got := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/reconcile", map[string]any{"before": "T3"}); st != 200 ||
		got["apply"] != false || got["before"] != float64(3) || got["cancelled"] != float64(2) {
		t.Fatalf("dry reconcile = %d %v", st, got)
	}
	if st, _ := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/reconcile", map[string]any{"before": "3"}); st != 400 {
		t.Fatalf("reconcile with a bare number = %d; want 400", st)
	}
	if st, got := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/reconcile", map[string]any{"before": "T3", "apply": true}); st != 200 || got["cancelled"] != float64(2) {
		t.Fatalf("apply reconcile = %d %v", st, got)
	}
	if _, got := nodeTaskCall(t, h, bob, http.MethodGet, NodeTasksPath+"/T1", nil); got["task"].(map[string]any)["state"] != store.TaskCancelled {
		t.Fatalf("T1 after reconcile = %v", got)
	}
	if st, got := nodeTaskCall(t, h, bob, http.MethodPost, NodeTasksPath+"/reconcile", map[string]any{"undo": true}); st != 200 || got["undone"] != float64(2) {
		t.Fatalf("undo = %d %v", st, got)
	}

	resp, err := h.http.Client().Get(h.http.URL + "/version")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var v struct {
		Capabilities []string `json:"capabilities"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil || !strings.Contains(strings.Join(v.Capabilities, " "), "task_ids") ||
		!strings.Contains(strings.Join(v.Capabilities, " "), "task_state") {
		t.Fatalf("/version capabilities = %v %v", v.Capabilities, err)
	}
}
