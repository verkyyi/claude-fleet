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

// claude-fleet#4945: a worker_start the hub cannot check is settled by an admin
// only while it is still that unknown / running worker_start, older than the
// age, naming no worker; it ends failed with the prior status and result kept.
func TestSettleStartByOperator(t *testing.T) {
	s := taskStore(t)
	t0 := time.Date(2026, 10, 8, 3, 33, 0, 0, time.UTC)
	day := 24 * time.Hour
	unknown := `{"error":{"code":"UNKNOWN_OUTCOME","message":"Spawn returned but no matching worker is visible"}}`
	op := func(id, action, status string) {
		t.Helper()
		if err := s.InsertFleetOperation(FleetOperation{ID: id, FleetID: "f1", Actor: "alice", Idem: id, Action: action,
			Request: `{"params":{"kind":"scratch"}}`, Status: status, Result: unknown, Created: t0, Updated: t0}); err != nil {
			t.Fatal(id, err)
		}
	}
	res := func(prior, priorResult string) string {
		return `{"error":{"code":"SETTLED_BY_OPERATOR","prior_status":"` + prior + `","prior_result":` + priorResult + `}}`
	}
	settle := func(id string, w StartWorker, now time.Time) (string, string) {
		t.Helper()
		f, why, err := s.SettleStartByOperator(id, w, day, res, now)
		if err != nil {
			t.Fatal(id, err)
		}
		return f, why
	}
	late := t0.Add(2 * day)
	op("o1", "worker_start", "unknown")
	if _, why := settle("o1", StartWorker{Issue: 7}, late); !strings.Contains(why, "settles on its own") {
		t.Fatal(why)
	}
	if _, why := settle("o1", StartWorker{Identity: "11111111-2222-3333-4444-555555555555"}, late); !strings.Contains(why, "settles on its own") {
		t.Fatal(why)
	}
	if _, why := settle("o1", StartWorker{}, t0.Add(time.Hour)); !strings.Contains(why, "younger than") {
		t.Fatal(why)
	}
	op("o2", "worker_stop", "unknown")
	if _, why := settle("o2", StartWorker{}, late); !strings.Contains(why, "only a worker_start") {
		t.Fatal(why)
	}
	op("o3", "worker_start", "succeeded")
	if _, why := settle("o3", StartWorker{}, late); !strings.Contains(why, "not unknown or running") {
		t.Fatal(why)
	}
	if f, why := settle("o1", StartWorker{}, late); f != "f1" || why != "" {
		t.Fatal(f, why)
	}
	o, err := s.FleetOperation("o1")
	if err != nil {
		t.Fatal(err)
	}
	if o.Status != "failed" || !strings.Contains(o.Result, `"SETTLED_BY_OPERATOR"`) ||
		!strings.Contains(o.Result, `"prior_status":"unknown"`) || !strings.Contains(o.Result, "UNKNOWN_OUTCOME") {
		t.Fatal(o.Status, o.Result)
	}
	// Settled once: a second call is refused, nothing rewritten.
	if _, why := settle("o1", StartWorker{}, late); !strings.Contains(why, "failed, not unknown") {
		t.Fatal(why)
	}
	op("o4", "worker_start", "running")
	if f, why := settle("o4", StartWorker{}, late); f != "f1" || why != "" {
		t.Fatal(f, why)
	}
}

// claude-fleet#4978: an 11-day-old running worker_start its node never ran
// ends failed (START_ABANDONED) on the node's word; one that is too young,
// another person's, already settled, or whose worker the hub's books still
// show (a live window in the inventory) is kept.
func TestAbandonStaleStart(t *testing.T) {
	s := taskStore(t)
	t0 := time.Date(2026, 10, 8, 5, 32, 18, 0, time.UTC)
	day := 24 * time.Hour
	now := t0.Add(11 * day)
	if err := s.Enroll("ep", "ep", "hash-ep"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RecordFleetSnapshot("ep", "host", "u", "m-1", []FleetReport{{FleetID: "f1", Name: "fleet",
		Repo: "org/repo", State: "running", WorkersJSON: `[{"worker_id":"f1/issue-7","issue":7,"repo":"org/repo"}]`}}, now); err != nil {
		t.Fatal(err)
	}
	op := func(id, owner, status, request string) {
		t.Helper()
		if err := s.InsertFleetOperation(FleetOperation{ID: id, FleetID: "f1", Actor: "gh:2987262", TaskOwner: owner, Idem: id,
			Action: "worker_start", Request: request, Status: status, Created: t0, Updated: t0}); err != nil {
			t.Fatal(id, err)
		}
	}
	res := func(prior, priorResult string) string {
		return `{"error":{"code":"START_ABANDONED","prior_status":"` + prior + `"}}`
	}
	abandon := func(id string, w StartWorker, at time.Time) (string, string) {
		t.Helper()
		f, why, err := s.AbandonStaleStart(id, "gh:2987262", w, day, res, at)
		if err != nil {
			t.Fatal(id, err)
		}
		return f, why
	}
	scratch := `{"params":{"agent":"claude","kind":"scratch","no_repo":true}}`
	op("stale", "", "running", scratch)
	op("bob", "gh:bob", "running", scratch)
	op("live", "gh:2987262", "unknown", `{"params":{"kind":"issue","issue":7,"repo":"org/repo"}}`)

	open, err := s.OwnerOpenStarts("gh:2987262")
	if err != nil {
		t.Fatal(err)
	}
	ids := []string{}
	for _, o := range open {
		ids = append(ids, o.ID)
	}
	if strings.Join(ids, ",") != "stale,live" && strings.Join(ids, ",") != "live,stale" {
		t.Fatal("open starts", ids)
	}
	if _, why := abandon("stale", StartWorker{}, t0.Add(time.Hour)); !strings.Contains(why, "younger than") {
		t.Fatal(why)
	}
	if _, why := abandon("bob", StartWorker{}, now); why != "the start is another person's" {
		t.Fatal(why)
	}
	// Its worker is still in the fleet's inventory: a live window, never abandoned.
	if _, why := abandon("live", StartWorker{Issue: 7, Repo: "org/repo"}, now); !strings.Contains(why, "in inventory") {
		t.Fatal(why)
	}
	if f, why := abandon("stale", StartWorker{}, now); f != "f1" || why != "" {
		t.Fatal(f, why)
	}
	o, err := s.FleetOperation("stale")
	if err != nil {
		t.Fatal(err)
	}
	if o.Status != "failed" || !strings.Contains(o.Result, `"START_ABANDONED"`) || !strings.Contains(o.Result, `"prior_status":"running"`) {
		t.Fatal(o.Status, o.Result)
	}
	if _, why := abandon("stale", StartWorker{}, now); !strings.Contains(why, "already settled") {
		t.Fatal(why)
	}
	// It no longer blocks its owner's cutover; the live one still does.
	blockers, _, err := s.OwnerAuthorityBlockers("gh:2987262", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(blockers, "|")
	if strings.Contains(got, "unsettled start: stale") || !strings.Contains(got, "unsettled start: live") {
		t.Fatal("blockers", blockers)
	}
}
