package store

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

// Task PVG9: the operator may raise one owner's limits; everyone else keeps
// the documented 10 / 24 / 30.
func TestScheduleOverridesParse(t *testing.T) {
	if DefaultScheduleLimits != (ScheduleLimits{Tasks: 10, DailySlots: 24, DailyStarts: 30}) {
		t.Fatalf("defaults changed: %+v", DefaultScheduleLimits)
	}
	o, e := ParseScheduleOverrides(`{"gh:1":{"tasks":20,"daily_slots":72,"daily_starts":60},"p:x":{"tasks":12}}`)
	if e != nil {
		t.Fatal(e)
	}
	if got := o.For("gh:1"); got != (ScheduleLimits{20, 72, 60}) {
		t.Fatalf("override: %+v", got)
	}
	if got := o.For("p:x"); got != (ScheduleLimits{12, 24, 30}) {
		t.Fatalf("partial override keeps the rest: %+v", got)
	}
	if got := o.For("gh:2"); got != DefaultScheduleLimits {
		t.Fatalf("other owner: %+v", got)
	}
	if got := ScheduleOverrides(nil).For("gh:1"); got != DefaultScheduleLimits {
		t.Fatalf("nil: %+v", got)
	}
	if o, e := ParseScheduleOverrides("  "); e != nil || o != nil {
		t.Fatal("empty is no overrides", o, e)
	}
	for _, bad := range []string{
		`not json`, `[]`, `{"gh:1":5}`,
		`{"gh:1":{"tasks":0}}`, `{"gh:1":{"tasks":-3}}`, `{"gh:1":{"daily_slots":100000}}`,
		`{"gh:1":{"daily_starts":501}}`, `{"gh:1":{"task":20}}`, `{"gh:1":{"tasks":"20"}}`,
		`{"":{"tasks":20}}`, `{" gh:1":{"tasks":20}}`, `{"gh:1":{"tasks":20},"gh:2":{"tasks":0}}`,
	} {
		if o, e := ParseScheduleOverrides(bad); e == nil {
			t.Fatalf("%s accepted: %+v", bad, o)
		}
	}
}

func hourlyFixture(id string) Schedule {
	r := scheduleFixture(id)
	r.Spec.At, r.Spec.Cron = "", "7 * * * *"
	return r
}

func TestScheduleOverrideCountSlotsAndStarts(t *testing.T) {
	s := newStore(t)
	now := time.Now()
	big := ScheduleLimits{Tasks: 12, DailySlots: 48, DailyStarts: 32}
	// One hourly task holds all 24 default slots: a default owner's next
	// task is refused, the overridden owner's is not.
	for _, owner := range []string{"alice", "olga"} {
		if _, e := s.SaveSchedule(owner, owner+"-h", owner+"-h", hourlyFixture("schedule-"+owner+"-h"), 0, now); e != nil {
			t.Fatal(owner, e)
		}
	}
	if _, e := s.SaveSchedule("alice", "a-1", "a-1", scheduleFixture("schedule-alice-1"), 0, now); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("default owner past 24 slots", e)
	}
	if _, e := s.SaveScheduleWithin(big, "olga", "o-h2", "o-h2", hourlyFixture("schedule-olga-h2"), 0, now); e != nil {
		t.Fatal("override slots", e)
	}
	if _, e := s.SaveScheduleWithin(big, "olga", "o-x", "o-x", scheduleFixture("schedule-olga-x"), 0, now); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("override slots still capped at 48", e)
	}
	// Count: paused tasks hold no slots, so only the count limits them.
	paused := func(id string) Schedule { r := scheduleFixture(id); r.Spec.Enabled = false; return r }
	for i := 0; i < 9; i++ {
		id := fmt.Sprintf("schedule-alice-p%d", i)
		if _, e := s.SaveSchedule("alice", id, id, paused(id), 0, now); e != nil {
			t.Fatal(i, e)
		}
	}
	if _, e := s.SaveSchedule("alice", "a-p9", "a-p9", paused("schedule-alice-p9"), 0, now); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("default owner's 11th task", e)
	}
	for i := 0; i < 10; i++ { // olga holds 2; 10 more is 12
		id := fmt.Sprintf("schedule-olga-p%d", i)
		if _, e := s.SaveScheduleWithin(big, "olga", id, id, paused(id), 0, now); e != nil {
			t.Fatal(i, e)
		}
	}
	if _, e := s.SaveScheduleWithin(big, "olga", "o-p10", "o-p10", paused("schedule-olga-p10"), 0, now); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("override count still capped at 12", e)
	}
	// Daily starts: 30 by default, the override's 32 for olga.
	starts := func(lim ScheduleLimits, owner, id string, n int) error {
		for i := 0; i < n; i++ {
			slot := fmt.Sprintf("manual-%s-%d", owner, i)
			_ = s.ScheduleManual(owner, id, slot, now)
			run, e := s.AdmitScheduleWithin(lim, owner, "node-a", id, slot, 1, 1, true, now)
			if e != nil {
				return fmt.Errorf("start %d: %w", i+1, e)
			}
			if _, e = s.FinishSchedule(owner, "node-a", run.ID, "succeeded", "done", "", "fid", now); e != nil {
				return e
			}
		}
		return nil
	}
	for _, owner := range []string{"alice", "olga"} {
		row, _ := s.Schedule(owner, "schedule-"+owner+"-h")
		_ = s.ScheduleSynced(row, "synced", "", "{}")
	}
	if e := starts(DefaultScheduleLimits, "alice", "schedule-alice-h", 31); !errors.Is(e, ErrScheduleLimit) || e.Error() != "start 31: "+ErrScheduleLimit.Error() {
		t.Fatal("default daily starts", e)
	}
	if e := starts(big, "olga", "schedule-olga-h", 32); e != nil {
		t.Fatal("override daily starts", e)
	}
	_ = s.ScheduleManual("olga", "schedule-olga-h", "manual-olga-over", now)
	if _, e := s.AdmitScheduleWithin(big, "olga", "node-a", "schedule-olga-h", "manual-olga-over", 1, 1, true, now); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("override daily starts still capped at 32", e)
	}
	// The row carries the slots it holds.
	if row, _ := s.Schedule("olga", "schedule-olga-h"); row.Slots != 24 {
		t.Fatal("slots", row.Slots)
	}
}
