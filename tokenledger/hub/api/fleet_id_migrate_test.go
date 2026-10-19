package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The migration's node road (EPIC T497 C6): a machine that answers settles its
// records by its windows; a machine that does not answer keeps every one where
// it is («等节点回答»); dry-run writes nothing; apply writes each once; the switch
// is the operator's and flips both ways.
func TestNodeIDMigrateRoad(t *testing.T) {
	h := newFleetHarness(t)
	live := connectFakeNode(t, h, "mac-d", true)
	silent := connectFakeNode(t, h, "mac-c", false) // an agent that serves no reads
	fl := fakeFleet(t, machineA, "live", "", "")
	fo := fakeFleet(t, machineB, "old", "", "")
	const here, gone, there = "2a3d60d7-b6e1-4736-a744-46232728cd3c", "86a316d7-8917-4bb2-a7ec-f0a91c89a298", "81c7af71-9695-4396-bfc1-9697b64d822d"
	asked := 0
	live.serve(func(method string, _ json.RawMessage) (any, *control.Error) {
		if method != "id_presence" {
			return nil, &control.Error{Code: "INVALID_ARGUMENT", Message: "no"}
		}
		asked++
		return map[string]any{"observed_at": 1.0, "fleets": []map[string]any{{"fleet_id": fl.FleetID, "name": "live",
			"state": "running", "observed_at": 1.0, "windows": []map[string]any{{"identity": here, "key": "", "window_id": "@12"}}}}}, nil
	})
	live.beat("mac-d", "alice", machineA, fl)
	silent.beat("mac-c", "bob", machineB, fo)
	waitFor(t, 3*time.Second, "registered", func() bool {
		_, e1 := h.srv.Store.Fleet(fl.FleetID)
		_, e2 := h.srv.Store.Fleet(fo.FleetID)
		return e1 == nil && e2 == nil
	})
	now := time.Now()
	mk := func(token, worker, state string) string {
		rec, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: "operator", Title: token, WorkerID: worker, State: state}, "t:"+token, now)
		if err != nil {
			t.Fatal(err)
		}
		return rec.Ref
	}
	tAlive, tGone, tThere, tNever := mk("alive", fl.FleetID+"/"+here, "open"), mk("gone", fl.FleetID+"/"+gone, "open"),
		mk("there", fo.FleetID+"/"+there, "open"), mk("never", "", "placing")
	tok := h.enroll(t, "caller")

	run := func(apply bool) map[string]map[string]any {
		t.Helper()
		st, got := nodeTaskCall(t, h, tok, http.MethodPost, NodeIDsPath+"/migrate", map[string]any{"apply": apply})
		if st != 200 {
			t.Fatalf("migrate = %d %v", st, got)
		}
		out := map[string]map[string]any{}
		for _, it := range got["items"].([]any) {
			m := it.(map[string]any)
			out[m["task"].(string)] = m
		}
		return out
	}
	dry := run(false)
	for ref, want := range map[string]string{tAlive: "live", tGone: "exited", tThere: "wait", tNever: "not_started"} {
		if dry[ref]["verdict"] != want || dry[ref]["applied"] == true {
			t.Fatalf("dry %s = %v; want %s, not applied", ref, dry[ref], want)
		}
	}
	if asked != 1 {
		t.Fatalf("the live machine was asked %d times; want once", asked)
	}
	if r, _ := h.srv.Store.FleetTask(store.ParseTaskRef(tGone)); r.State != "open" {
		t.Fatalf("dry-run wrote %s: %s", tGone, r.State)
	}
	applied := run(true)
	if applied[tGone]["applied"] != true || applied[tThere]["applied"] == true {
		t.Fatalf("apply = %v", applied)
	}
	if r, _ := h.srv.Store.FleetTask(store.ParseTaskRef(tThere)); r.State != "open" {
		t.Fatalf("the silent machine's record moved: %s", r.State)
	}
	again := run(false)
	if len(again) != 1 || again[tThere] == nil {
		t.Fatalf("after apply = %v; want only the silent machine's record", again)
	}

	// The switch: GET is anyone's; a person's machine may not set it.
	if st, got := nodeTaskCall(t, h, tok, http.MethodGet, NodeIDsPath+"/switch", nil); st != 200 || got["on"] != false {
		t.Fatalf("switch = %d %v", st, got)
	}
	for _, on := range []bool{true, false, true, false} {
		if st, got := nodeTaskCall(t, h, tok, http.MethodPost, NodeIDsPath+"/switch", map[string]any{"on": on}); st != 200 || got["on"] != on {
			t.Fatalf("switch %v = %d %v", on, st, got)
		}
	}
}

// The switch on the old roads (EPIC T497 C6): on, a claim / transition and a
// fenced report are 409 ID_SWITCH (the node takes the ID road), a queued child
// report still reaches its parent, and the record's end is its ID's result;
// off again, the record is what it was — twice round, nothing lost.
func TestIDSwitchOldRoads(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	if _, err := h.srv.Store.RecordFleetSnapshot(nodes["verk4"].id, "verk4", "frank", "verk4",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	tok := nodes["verk4"].token
	worker := wrFleetM4 + "/" + wrFid
	code, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, map[string]any{"authority_version": 1, "token": "sw",
		"title": "sw", "requested_agent": "claude", "resolved_agent": "claude"})
	if code != 200 {
		t.Fatalf("accept: %d %v", code, rec)
	}
	ref := rec["id"].(string)
	claim := map[string]any{"authority_version": 1, "mutation": map[string]any{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": worker}}
	if code, rec = nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/"+ref, claim); code != 200 {
		t.Fatalf("claim with the switch off: %d %v", code, rec)
	}
	r := store.TaskReport{EventID: "r1", Task: ref, Owner: "operator", Generation: 1, WorkerID: worker, Outcome: "succeeded", Evidence: "fixture"}
	payload, _ := json.Marshal(map[string]any{"task_report": r})
	relay := store.FleetRelay{ID: worker + "#r1", Kind: control.RelayChildReport, FromWID: worker, ToWID: wrFleetM5 + "/" + wrFid, Payload: string(payload)}
	ep, err := h.srv.Store.LiveEndpoint(nodes["verk4"].id)
	if err != nil {
		t.Fatal(err)
	}
	// The window's ID carries the task's number (its `opened` names it).
	if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: ep.ID, Machine: "verk4", Login: "frank", ID: wrFid,
		Events: []map[string]any{{"ev": "opened", "task": ref, "id": wrFid, "seq": 1.0, "ts": 1.0}}}); err != nil {
		t.Fatal(err)
	}
	for round := 0; round < 2; round++ {
		if err := h.srv.Store.SetIDSwitch(true, time.Now()); err != nil {
			t.Fatal(err)
		}
		transition := map[string]any{"authority_version": 1, "mutation": map[string]any{"kind": "transition", "idempotency_key": "run", "generation": 1,
			"expected_worker": worker, "state": "running", "actual_agent": "claude", "evidence": "x"}}
		if code, rec = nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/"+ref, transition); code != 409 || rec["code"] != "ID_SWITCH" {
			t.Fatalf("round %d: transition with the switch on = %d %v", round, code, rec)
		}
		if code, rec = nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/"+ref+"/reports", r); code != 409 || rec["code"] != "ID_SWITCH" {
			t.Fatalf("round %d: fenced report with the switch on = %d %v", round, code, rec)
		}
		if skip, err := h.srv.prepareTaskReportRelay(*ep, &relay); err != nil || skip {
			t.Fatalf("round %d: a queued child report with the switch on: skip=%v %v", round, skip, err)
		}
		if code, rec = nodeTaskCall(t, h, tok, http.MethodGet, NodeTasksPath+"/"+ref, nil); code != 200 || rec["task"].(map[string]any)["outcome"] != nil {
			t.Fatalf("round %d: no ID result yet = %d %v", round, code, rec)
		}
		if err := h.srv.Store.SetIDSwitch(false, time.Now()); err != nil {
			t.Fatal(err)
		}
		if code, rec = nodeTaskCall(t, h, tok, http.MethodGet, NodeTasksPath+"/"+ref, nil); code != 200 || rec["task"].(map[string]any)["execution_owner"] != worker {
			t.Fatalf("round %d: the record after switching back = %d %v", round, code, rec)
		}
	}
	if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: ep.ID, Machine: "verk4", Login: "frank", ID: wrFid,
		Events: []map[string]any{{"ev": "result", "state": "merged", "id": wrFid, "seq": 2.0, "ts": 2.0}}}); err != nil {
		t.Fatal(err)
	}
	_ = h.srv.Store.SetIDSwitch(true, time.Now())
	if code, rec = nodeTaskCall(t, h, tok, http.MethodGet, NodeTasksPath+"/"+ref, nil); code != 200 || rec["task"].(map[string]any)["outcome"] != "succeeded" {
		t.Fatalf("the ID merged, switch on → %d %v; want outcome succeeded", code, rec)
	}
	_ = h.srv.Store.SetIDSwitch(false, time.Now())
	if code, rec = nodeTaskCall(t, h, tok, http.MethodGet, NodeTasksPath+"/"+ref, nil); code != 200 || rec["task"].(map[string]any)["outcome"] != nil {
		t.Fatalf("switch off → %d %v; want the record's own (no outcome)", code, rec)
	}
}
