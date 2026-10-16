package store

import (
    "encoding/json"
    "errors"
    "testing"
    "time"
)

// Fixture only: both machines use issue 7; identity is the task + generation.
func TestTaskChildReportsFenced(t *testing.T) {
    s := taskStore(t)
    parent := startTask(t, s, acceptedTask(t, s, "parent", ""))
    makeChild := func(token, ticket, worker, endpoint string) FleetTask {
        rec, err := s.CreateFleetTask(FleetTask{Owner: "alice", Title: token, AuthorityVersion: 1,
            RequestedAgent: "codex", ResolvedAgent: "codex", TicketRef: ticket,
            ParentTask: parent.Ref, ParentSession: parent.ExecutionOwner}, token, time.Now())
        if err != nil { t.Fatal(err) }
        rec = mutateTask(t, s, rec, TaskMutation{Key: "claim", Kind: "claim", WorkerID: worker, FleetID: "fleet", EndpointID: endpoint})
        return mutateTask(t, s, rec, TaskMutation{Key: "start", Kind: "transition", State: TaskRunning, ActualAgent: "codex", Evidence: "native fixture", EndpointID: endpoint})
    }
    a := makeChild("child-a", "gh:one/repo#7", "fleet-a/child", "node-a")
    b := makeChild("child-b", "gh:two/repo#7", "fleet-b/child", "node-b")
    children, err := s.FleetTaskChildren("alice", parent.Ref, parent.ExecutionOwner, parent.Generation)
    if err != nil || len(children) != 2 { t.Fatalf("children: %+v %v", children, err) }
    report := TaskReport{EventID: "completion-a", Task: a.Ref, Owner: a.Owner, TicketRef: a.TicketRef,
        Generation: a.Generation, WorkerID: a.ExecutionOwner, ParentTask: parent.Ref,
        ParentSession: parent.ExecutionOwner, ParentGeneration: parent.Generation,
        Outcome: TaskSucceeded, Evidence: "fixture work and confirmed stop", ExecutionStopped: true}
    first, err := s.RecordFleetTaskReport(a.Owner, "node-a", report, time.Now())
    if err != nil || first.Disposition != "committed" || first.Task.Outcome != TaskSucceeded { t.Fatalf("report: %+v %v", first, err) }
    dup, err := s.RecordFleetTaskReport(a.Owner, "node-a", report, time.Now())
    if err != nil || !dup.Task.UpdatedAt.Equal(first.Task.UpdatedAt) { t.Fatalf("repeat: %+v %v", dup, err) }
    report.Outcome = TaskFailed
    if _, err = s.RecordFleetTaskReport(a.Owner, "node-a", report, time.Now()); !errors.Is(err, ErrTaskConflict) { t.Fatalf("changed event: %v", err) }
    report.EventID = "late-a"
    next := mutateTask(t, s, first.Task, TaskMutation{Key: "retry", Kind: "retry", RequestedAgent: "codex", ResolvedAgent: "codex", Evidence: "explicit retry"})
    late, err := s.RecordFleetTaskReport(a.Owner, "node-a", report, time.Now())
    if err != nil || late.Disposition != "historical" { t.Fatalf("late: %+v %v", late, err) }
    current, _ := s.FleetTask(a.ID)
    if current.Generation != next.Generation || current.Outcome != "" || current.ExecutionOwner != "" { t.Fatalf("old report changed new generation: %+v", current) }
    report.EventID = "wrong-repo"
    report.TicketRef = b.TicketRef
    if _, err = s.RecordFleetTaskReport(a.Owner, "node-a", report, time.Now()); !errors.Is(err, ErrTaskFence) { t.Fatalf("ticket crossed: %v", err) }
    report.TicketRef = a.TicketRef
    if _, err = s.RecordFleetTaskReport("bob", "node-a", report, time.Now()); !errors.Is(err, ErrTaskFence) { t.Fatalf("foreign owner: %v", err) }
    if _, err = s.RecordFleetTaskReport(a.Owner, "node-b", report, time.Now()); !errors.Is(err, ErrTaskFence) { t.Fatalf("foreign endpoint: %v", err) }
    before, _ := json.Marshal(children); after, _ := json.Marshal(late)
    t.Logf("fixture before=%s after=%s", before, after)
}

func TestTaskCancelNeedsAcknowledgement(t *testing.T) {
    s := taskStore(t)
    rec := startTask(t, s, acceptedTask(t, s, "cancel", "gh:org/repo#7"))
    request := TaskMutation{Key: "cancel-request", Kind: "cancel_request", Generation: rec.Generation,
        ExpectedWorker: rec.ExecutionOwner, EndpointID: "parent-node", Evidence: "operator asks to stop"}
    pending, err := s.MutateFleetTask(rec.ID, rec.Owner, request, time.Now())
    if err != nil || pending.Outcome != "" || pending.CancelRequest != request.Key || pending.ExecutionOwner != rec.ExecutionOwner { t.Fatalf("fabricated cancel: %+v %v", pending, err) }
    ack := TaskMutation{Key: "cancel-ack", Kind: "cancel_ack", Generation: rec.Generation,
        ExpectedWorker: rec.ExecutionOwner, EndpointID: "node-a", CancelRequest: request.Key, Evidence: "stopped"}
    if _, err = s.MutateFleetTask(rec.ID, rec.Owner, ack, time.Now()); !errors.Is(err, ErrTaskConflict) { t.Fatalf("unconfirmed stop: %v", err) }
    // Expiry and an unreachable executor cannot hand the task to another node.
    if yes, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/repo", Issue: 7, WorkerID: "other", FleetID: "other", EndpointID: "other", Force: true}, time.Minute, time.Now().Add(24*time.Hour)); err != nil || yes { t.Fatalf("expiry takeover: %v %v", yes, err) }
    done := mutateTask(t, s, pending, TaskMutation{Key: "complete", Kind: "transition", State: TaskSucceeded, Evidence: "completion and stop", ExecutionStopped: true})
    ack.ExecutionStopped = true
    if _, err = s.MutateFleetTask(rec.ID, rec.Owner, ack, time.Now()); !errors.Is(err, ErrTaskConflict) { t.Fatalf("cancel overwrote completion: %v", err) }
    current, _ := s.FleetTask(done.ID)
    if current.Outcome != TaskSucceeded { t.Fatalf("wrong winner: %+v", current) }
}
