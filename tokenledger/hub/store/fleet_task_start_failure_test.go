package store

import (
	"strings"
	"testing"
	"time"
)

func TestTaskStartFailure(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	task := acceptedTask(t, s, "refused-start", "")
	failed, err := s.RecordTaskStartFailure(task.ID, task.Owner, task.Generation, "ALL_DECLINED: no capacity", now)
	if err != nil || failed.StartFailure() != "ALL_DECLINED: no capacity" {
		t.Fatalf("failure: %+v %v", failed, err)
	}
	if ok, err := s.TaskStartRetryable(task); err != nil || !ok {
		t.Fatalf("retry: %v %v", ok, err)
	}
	if _, err := s.RecordTaskStartFailure(task.ID, "other", task.Generation, "bad", now); err == nil {
		t.Fatal("foreign failure accepted")
	}
	if _, err := s.RecordTaskStartFailure(task.ID, task.Owner, task.Generation+1, "bad", now); err == nil {
		t.Fatal("stale failure accepted")
	}
	if sweep, err := s.ReconcileClosedTasks(task.Owner, true, now.Add(48*time.Hour)); err != nil || sweep.NeverStarted != 0 {
		t.Fatalf("failure lost retry after 24 hours: %+v %v", sweep, err)
	}
	cancelled, err := s.CancelUnopenedTask(task.ID, task.Owner, "delete refused start", now)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.TaskStartRetryable(cancelled); ok {
		t.Fatal("cancelled task retryable")
	}
	if _, err := s.RecordTaskStartFailure(task.ID, task.Owner, task.Generation, "late", now); err == nil {
		t.Fatal("late failure rewrote cancellation")
	}
}

func TestTaskPlaceholderTitleRepair(t *testing.T) {
	s := taskStore(t)
	input := FleetTask{Owner: "alice", Title: "dispatch_new_title", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex",
		RequestPayload: `{"title":"dispatch_new_title","body":"keep dispatch_new_title in quoted prose","number":9007199254740993,"attachments":{"title":"dispatch_new_title"},"dispatch":{"version":1}}`}
	task, err := s.CreateFleetTask(input, "title-repair", time.Now())
	if err != nil || task.Title != "新会话" {
		t.Fatalf("normalize: %+v %v", task, err)
	}
	again, err := s.CreateFleetTask(input, "title-repair", time.Now())
	if err != nil || again.ID != task.ID {
		t.Fatalf("normalized replay: %+v %v", again, err)
	}
	// Simulate an installed version's damaged Task and reserved ID.
	if _, err = s.write.Exec(`UPDATE fleet_tasks SET title = ?, request_payload = ? WHERE id = ?`, "dispatch_new_title", input.RequestPayload, task.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = s.write.Exec(`UPDATE fleet_ids SET title = ? WHERE id = ?`, "dispatch_new_title", task.FID); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err = s.repairTaskPlaceholderTitles(); err != nil {
			t.Fatal(err)
		}
	}
	repaired, err := s.FleetTask(task.ID)
	if err != nil || repaired.Title != "新会话" || !strings.Contains(repaired.RequestPayload, `"title":"新会话"`) || !strings.Contains(repaired.RequestPayload, "keep dispatch_new_title in quoted prose") {
		t.Fatalf("repair: %+v %v", repaired, err)
	}
	if !strings.Contains(repaired.RequestPayload, "9007199254740993") || !strings.Contains(repaired.RequestPayload, `"attachments":{"title":"dispatch_new_title"}`) {
		t.Fatal("repair changed opaque user data")
	}
	replay, err := s.CreateFleetTask(input, "title-repair", time.Now())
	if err != nil || replay.ID != task.ID {
		t.Fatalf("replay after migration: %+v %v", replay, err)
	}
	var title string
	if err = s.read.QueryRow(`SELECT title FROM fleet_ids WHERE id = ?`, task.FID).Scan(&title); err != nil || title != "新会话" {
		t.Fatalf("ID title: %q %v", title, err)
	}
	renamed, err := s.RetitleTask(task.ID, task.Owner, "dispatch_new_title", "First prompt", time.Now())
	if err != nil || renamed.Title != "First prompt" {
		t.Fatalf("first prompt: %+v %v", renamed, err)
	}
	if err = s.repairTaskPlaceholderTitles(); err != nil {
		t.Fatal(err)
	}
	renamed, _ = s.FleetTask(task.ID)
	if renamed.Title != "First prompt" {
		t.Fatal("repair overwrote user's prompt")
	}
}
