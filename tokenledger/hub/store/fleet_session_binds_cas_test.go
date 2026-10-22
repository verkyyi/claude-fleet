package store

import (
	"testing"
	"time"
)

// Independent connections model replicas that evaluated the same revision.
// Order the commits explicitly so this always exercises the CAS loser path.
func TestCodexQuotaCASTwoReplicas(t *testing.T) {
	a := newStore(t)
	if err := a.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	b, err := openStore(a.d, a.src, "quota-cas-replica")
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	now := time.Date(2030, 1, 2, 0, 0, 0, 0, time.UTC)
	old, err := a.SetSessionBind(SessionBind{WorkerID: "worker", Provider: "codex", Owner: "pool", Account: "a", SetBy: "auto"}, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	stale, err := b.SessionBindFor(old.WorkerID, old.Provider)
	if err != nil || stale != old {
		t.Fatalf("replica read: %+v %v", stale, err)
	}
	next := old
	next.Account, next.SetBy = "b", "credproxy:quota"
	winner, err := a.CompareSessionBind(next, old.Rev, now)
	if err != nil || winner.Account != "b" || winner.Rev != 2 {
		t.Fatalf("winner: %+v %v", winner, err)
	}
	// A stale, opposite decision must return committed b, not its proposed a.
	for i := 0; i < 3; i++ {
		actual, err := b.CompareSessionBind(stale, stale.Rev, now.Add(time.Duration(i)*time.Second))
		if err != nil || actual != winner {
			t.Fatalf("CAS loser regressed: %+v want %+v: %v", actual, winner, err)
		}
	}
	next.Account, next.SetBy = "manual", "operator"
	manual, err := b.SetSessionBind(next, now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	actual, err := a.CompareSessionBind(winner, winner.Rev, now.Add(2*time.Minute))
	if err != nil || actual != manual || actual.Rev != 3 {
		t.Fatalf("stale replica beat operator: %+v %v", actual, err)
	}
}
