package store

import (
	"strings"
	"testing"
	"time"
)

// claude-fleet#4932: a worker_start an online node keeps answering
// UNKNOWN_OUTCOME for ends failed only when the hub's own books show its worker
// never appeared — past the grace, on an inventory read past the grace, with
// no inventory row, lease or open local start that could be it. Anything that
// could be it, or a start that names no worker, keeps it unknown.
func TestSettleNeverAppearedStart(t *testing.T) {
	s := taskStore(t)
	t0 := time.Date(2026, 10, 8, 3, 33, 0, 0, time.UTC)
	grace := time.Hour
	if err := s.Enroll("ep", "ep", "hash-ep"); err != nil {
		t.Fatal(err)
	}
	snapshot := func(workers string, at time.Time) {
		t.Helper()
		if _, err := s.RecordFleetSnapshot("ep", "host", "u", "m-1", []FleetReport{{FleetID: "f1", Name: "fleet",
			Repo: "org/repo", State: "running", WorkersJSON: workers}}, at); err != nil {
			t.Fatal(err)
		}
	}
	unknown := `{"error":{"code":"UNKNOWN_OUTCOME","message":"Spawn returned but no matching worker is visible"}}`
	op := func(id, request string) {
		t.Helper()
		if err := s.InsertFleetOperation(FleetOperation{ID: id, FleetID: "f1", Actor: "alice", Idem: id, Action: "worker_start",
			Request: request, Status: "unknown", Result: unknown, Created: t0, Updated: t0}); err != nil {
			t.Fatal(id, err)
		}
	}
	issue7 := StartWorker{Issue: 7, Repo: "org/repo"}
	ev := func(why string) string { return `{"error":{"code":"WORKER_NEVER_APPEARED","message":"` + why + `"}}` }
	settle := func(id string, w StartWorker, now time.Time) (bool, string) {
		t.Helper()
		ok, why, err := s.SettleNeverAppearedStart(id, w, grace, ev, now)
		if err != nil {
			t.Fatal(id, err)
		}
		return ok, why
	}
	status := func(id string) string {
		var st, res string
		if err := s.read.QueryRow(`SELECT status, COALESCE(result,'') FROM fleet_operations WHERE id = ?`, id).Scan(&st, &res); err != nil {
			t.Fatal(err)
		}
		return st + "|" + res
	}
	op("o1", `{"params":{"kind":"issue","issue":7,"repo":"org/repo"}}`)
	late := t0.Add(2 * grace)

	// Inside the grace, or with no inventory read since: kept.
	snapshot(`[]`, t0.Add(time.Minute))
	if ok, why := settle("o1", issue7, t0.Add(30*time.Minute)); ok || why != "inside the grace" {
		t.Fatal(ok, why)
	}
	if ok, why := settle("o1", issue7, late); ok || !strings.Contains(why, "no inventory read") {
		t.Fatal(ok, why)
	}
	// The worker is in the inventory (its own repo's issue 7): kept.
	snapshot(`[{"worker_id":"f1/org-repo:issue-7","issue":7,"repo":"org/repo"}]`, late)
	if ok, why := settle("o1", issue7, late); ok || !strings.Contains(why, "in inventory") {
		t.Fatal(ok, why)
	}
	// Another repo's issue 7 is not it.
	snapshot(`[{"worker_id":"f1/other-x:issue-7","issue":7,"repo":"other/x"}]`, late)
	// A lease on issue 7: kept.
	if granted, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/repo", Issue: 7, WorkerID: "f1/org-repo:issue-7", FleetID: "f1", EndpointID: "ep"}, time.Hour, late); err != nil || !granted {
		t.Fatal(granted, err)
	}
	if ok, why := settle("o1", issue7, late); ok || !strings.Contains(why, "lease held") {
		t.Fatal(ok, why)
	}
	if _, err := s.ReleaseLease("org/repo", 7, "f1/org-repo:issue-7"); err != nil {
		t.Fatal(err)
	}
	// An unclosed local start that could be it: kept; once stopped, it is not.
	start := func(phase string) {
		t.Helper()
		if _, err := s.write.Exec(`DELETE FROM fleet_operations WHERE id = 'ls1'`); err != nil {
			t.Fatal(err)
		}
		res := `{"reservation":"ls1","repo":"org/repo","owner":"alice","endpoint_id":"ep","worker_id":"f1/org-repo:issue-7","phase":"` + phase + `"}`
		if err := s.InsertFleetOperation(FleetOperation{ID: "ls1", FleetID: "f1", Actor: "alice", Idem: "ls1", Action: "repo_local_start",
			Request: "{}", Status: "running", Result: res, Created: t0, Updated: t0}); err != nil {
			t.Fatal(err)
		}
	}
	start("starting")
	if ok, why := settle("o1", issue7, late); ok || !strings.Contains(why, "local start retained") {
		t.Fatal(ok, why)
	}
	start("stopped")
	if blockers, _, _ := s.OwnerAuthorityBlockers("alice", nil, false); !strings.Contains(strings.Join(blockers, "\n"), "unsettled start: o1") {
		t.Fatal("o1 should block before it settles", blockers)
	}
	// Nothing holds it: failed, with the evidence; the blocker lifts.
	if ok, why := settle("o1", issue7, late); !ok {
		t.Fatal(why)
	}
	if st := status("o1"); !strings.HasPrefix(st, `failed|{"error":{"code":"WORKER_NEVER_APPEARED"`) || !strings.Contains(st, "inventory observed") {
		t.Fatal(st)
	}
	if blockers, _, _ := s.OwnerAuthorityBlockers("alice", nil, false); strings.Contains(strings.Join(blockers, "\n"), "o1") {
		t.Fatal("o1 still blocks", blockers)
	}
	// Settled once: a second call keeps it as it is.
	if ok, why := settle("o1", issue7, late); ok || why != "no longer an unknown worker_start" {
		t.Fatal(ok, why)
	}

	// A start the node named by window identity: matched by it.
	const fid = "11111111-2222-4333-8444-555555555555"
	op("o2", `{"params":{"kind":"scratch"}}`)
	snapshot(`[{"worker_id":"f1/`+fid+`","identity":"`+fid+`"}]`, late)
	if ok, why := settle("o2", StartWorker{Identity: fid}, late); ok || !strings.Contains(why, "in inventory") {
		t.Fatal(ok, why)
	}
	snapshot(`[]`, late)
	if ok, why := settle("o2", StartWorker{Identity: fid}, late); !ok {
		t.Fatal(why)
	}
	// A scratch start that names nothing cannot be checked: kept.
	op("o3", `{"params":{"kind":"scratch"}}`)
	if ok, why := settle("o3", StartWorker{}, late); ok || !strings.Contains(why, "names no worker") {
		t.Fatal(ok, why)
	}
	if st := status("o3"); !strings.HasPrefix(st, "unknown|") {
		t.Fatal(st)
	}
}
