package api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestTaskCurrentBoardIgnoresHistoricalQuestion(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	rec, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "question history", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "question-history", now)
	if err != nil {
		t.Fatal(err)
	}
	views, err := s.taskViews([]store.FleetTask{rec})
	if err != nil {
		t.Fatal(err)
	}
	wire, err := json.Marshal(views[0])
	if err != nil {
		t.Fatal(err)
	}
	var legacy map[string]any
	if err := json.Unmarshal(wire, &legacy); err != nil {
		t.Fatal(err)
	}
	if _, present := legacy["execution_owner"]; present {
		t.Fatalf("legacy record advertised controlled binding: %s", wire)
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET asked = 'old question' WHERE id = ?`, rec.ID); err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"idle", "done", "needs", ""} {
		var live []FleetSession
		if state != "" {
			live = []FleetSession{{Availability: "online", Worker: map[string]any{"identity": rec.FID, "state": state, "reap_why": "waiting:9999999999"}}}
		}
		board, err := s.buildBoard(rec.Owner, live, now)
		if err != nil {
			t.Fatal(err)
		}
		if len(board.Rows) != 1 {
			t.Fatalf("rows: %+v", board)
		}
		got := board.Rows[0]
		if state == "needs" {
			if got.Tag != "asking" {
				t.Fatalf("native ask hidden: %+v", got)
			}
		} else if got.Tag == "waiting_you" || got.Tag == "asking" {
			t.Fatalf("history invented question for %q: %+v", state, got)
		}
	}
}

func TestTaskCurrentBoardBindingOrderAndPending(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	rec, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "continued", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "current-view", now)
	if err != nil {
		t.Fatal(err)
	}
	fleet := "11111111-1111-4111-8111-111111111111"
	current := "22222222-2222-4222-8222-222222222222"
	for _, id := range []string{rec.FID, current} {
		_, err = st.ApplyFleetIDEvents(store.FleetIDPush{Owner: rec.Owner, EndpointID: "ep", ID: id, Events: []map[string]any{{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "task": rec.Ref, "task_id": rec.FID, "agent": "claude"}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET execution_endpoint = 'ep', execution_owner = ?, worker_id = ?, state = 'closed', outcome = 'succeeded', generation = 3, operation_id = 'current-start' WHERE id = ?`, fleet+"/"+current, fleet+"/"+rec.FID, rec.ID); err != nil {
		t.Fatal(err)
	}
	at := now.UTC().Format(time.RFC3339Nano)
	if _, err = st.DB().Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,task_owner,task_ref,task_generation) VALUES ('current-start',?,'worker_start','{"control_version":1}',?,'current-view','pending',?,?,?,?,3)`, fleet, rec.Owner, at, at, rec.Owner, rec.Ref); err != nil {
		t.Fatal(err)
	}
	sess := func(id, state string) FleetSession {
		wid := fleet + "/" + id
		return FleetSession{WorkerID: &wid, Availability: "online", Worker: map[string]any{"identity": id, "worker_id": wid, "state": state}}
	}
	for _, live := range [][]FleetSession{{sess(rec.FID, "needs"), sess(current, "working")}, {sess(current, "working"), sess(rec.FID, "needs")}} {
		b, err := s.buildBoard(rec.Owner, live, now)
		if err != nil {
			t.Fatal(err)
		}
		count := 0
		for _, row := range b.Rows {
			if row.Task == rec.Ref {
				count++
				if row.WorkerID != fleet+"/"+current || !row.Running || row.Tag == "asking" || row.Code != rec.Short {
					t.Fatalf("wrong current row: %+v", row)
				}
			}
		}
		if count != 1 {
			t.Fatalf("Task appears %d times: %+v", count, b)
		}
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET execution_owner = '' WHERE id = ?`, rec.ID); err != nil {
		t.Fatal(err)
	}
	read := func() BoardRow {
		b, e := s.buildBoard(rec.Owner, []FleetSession{sess(rec.FID, "needs")}, now)
		if e != nil {
			t.Fatal(e)
		}
		for _, r := range b.Rows {
			if r.Task == rec.Ref {
				return r
			}
		}
		t.Fatal("missing Task")
		return BoardRow{}
	}
	if row := read(); row.WorkerID != "" || !row.PendingStart || row.Tag != "starting" {
		t.Fatalf("unclaimed picked history or hid start: %+v", row)
	}
	if _, err = st.DB().Exec(`UPDATE fleet_operations SET task_generation = 1 WHERE id = 'current-start'`); err != nil {
		t.Fatal(err)
	}
	if read().PendingStart {
		t.Fatal("old generation shown pending")
	}
	for _, outcome := range []string{"succeeded", "failed", "cancelled", "refused"} {
		if _, err = st.DB().Exec(`UPDATE fleet_operations SET task_generation = 3 WHERE id = 'current-start'`); err != nil {
			t.Fatal(err)
		}
		if _, err = st.DB().Exec(`UPDATE fleet_tasks SET outcome = ? WHERE id = ?`, outcome, rec.ID); err != nil {
			t.Fatal(err)
		}
		if !read().PendingStart {
			t.Fatalf("historical %s hid current start", outcome)
		}
	}
	if _, err = st.DB().Exec(`UPDATE fleet_operations SET task_ref = 'T999' WHERE id = 'current-start'`); err != nil {
		t.Fatal(err)
	}
	if read().PendingStart {
		t.Fatal("another Task start shown pending")
	}
	if old, e := st.FleetIDOf(rec.Owner, rec.FID); e != nil || old.ID != rec.FID {
		t.Fatal("history discarded", e)
	}

}

func TestTaskCurrentAPIUsesExecutionOwner(t *testing.T) {
	h, _, node, _, f := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "current-api", "coding_agent": "codex", "control_version": 1}, 200)
	node.mu.Lock()
	ref := node.writes[0]["task_execution"].(map[string]any)["task_ref"].(string)
	node.mu.Unlock()
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if err != nil {
		t.Fatal(err)
	}
	current := "22222222-2222-4222-8222-222222222222"
	if _, err = h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET execution_owner = ?, worker_id = ? WHERE id = ?`, f.FleetID+"/"+current, f.FleetID+"/"+task.FID, task.ID); err != nil {
		t.Fatal(err)
	}
	f.Workers, _ = json.Marshal([]map[string]any{{"identity": task.FID, "worker_id": f.FleetID + "/" + task.FID, "state": "needs"}, {"identity": current, "worker_id": f.FleetID + "/" + current, "state": "working"}})
	node.beatLoad("mac-c", "frank", machineB, 1, 1, f)
	waitFor(t, 3*time.Second, "current inventory", func() bool {
		got, e := h.srv.Store.Fleet(f.FleetID)
		return e == nil && got.WorkersJSON == string(f.Workers)
	})
	out := getFleet(t, h, FleetTasksPath+"/"+ref, 200)
	if out["execution_owner"] != f.FleetID+"/"+current {
		t.Fatalf("current owner missing from API: %v", out)
	}
	if live, ok := out["live"].(map[string]any); !ok || live["state"] != "working" {
		t.Fatalf("API selected old live: %v", out)
	}
	if _, err = h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET execution_owner = '', execution_endpoint = '' WHERE id = ?`, task.ID); err != nil {
		t.Fatal(err)
	}
	out = getFleet(t, h, FleetTasksPath+"/"+ref, 200)
	if owner, ok := out["execution_owner"].(string); !ok || owner != "" {
		t.Fatalf("released current binding omitted: %v", out)
	}
	if out["live"] != nil {
		t.Fatalf("unclaimed API selected old live: %v", out)
	}
}
