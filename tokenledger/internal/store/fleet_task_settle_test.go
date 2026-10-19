package store

import (
	"errors"
	"testing"
	"time"
)

// claude-fleet#4867: the worker half of a legacy settle — a lease row or an
// unclosed local start keeps the record, and the write re-reads it.
func TestSettleLegacyTaskWorkerLive(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	const w = "11111111-1111-4111-8111-111111111111/issue-4"
	rec, err := s.CreateFleetTask(FleetTask{Owner: "alice", Title: "t", Repo: "org/a", WorkerID: w, State: TaskOpen, Issue: "org/a#4"}, "k1", now)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 4, WorkerID: w, FleetID: "11111111-1111-4111-8111-111111111111"}, time.Minute, now); err != nil || !ok {
		t.Fatal(ok, err)
	}
	if why, err := s.LegacyWorkerLive("org/a", w); err != nil || why != "lease held" {
		t.Fatalf("lease: %q %v", why, err)
	}
	if err := s.SettleLegacyTask(rec.ID, w, "e", now); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("settled under a lease: %v", err)
	}
	if _, err := s.ReleaseLease("org/a", 4, w); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RepoLocalStart("org/a", "alice", "node-a", "r1", "reserve", "", nil, now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RepoLocalStart("org/a", "alice", "node-a", "r1", "begin", w, nil, now); err != nil {
		t.Fatal(err)
	}
	if why, _ := s.LegacyWorkerLive("org/a", w); why != "local start retained" {
		t.Fatalf("start: %q", why)
	}
	if _, err := s.RepoLocalStart("org/a", "alice", "node-a", "r1", "unobserved", w, nil, now); err != nil {
		t.Fatal(err)
	}
	if why, _ := s.LegacyWorkerLive("org/a", w); why != "" {
		t.Fatalf("nothing held: %q", why)
	}
	if err := s.SettleLegacyTask(rec.ID, "other/w", "e", now); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("another worker's record: %v", err)
	}
	if err := s.SettleLegacyTask(rec.ID, w, "e", now); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.FleetTask(rec.ID); got.State != TaskClosed || got.Note != "e" {
		t.Fatalf("settled = %+v", got)
	}
	if left, _ := s.LegacySettleCandidates("org/a", ""); len(left) != 0 {
		t.Fatalf("still a candidate: %v", left)
	}
}
