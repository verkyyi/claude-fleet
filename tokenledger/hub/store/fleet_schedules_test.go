package store

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

func scheduleFixture(id string) Schedule {
	return Schedule{Endpoint: "node-a", Hostname: "host-a", Login: "alice", Spec: schedule.Spec{ID: id, Revision: 1, Name: "Daily", Prompt: "Summarize", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}
}
func TestScheduleConcurrentLimitsAndOwnership(t *testing.T) {
	s := newStore(t)
	now := time.Now()
	var wg sync.WaitGroup
	var mu sync.Mutex
	accepted := 0
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := fmt.Sprintf("schedule-%d", i)
			_, e := s.SaveSchedule("alice", id, id, scheduleFixture(id), 0, now)
			mu.Lock()
			defer mu.Unlock()
			if e == nil {
				accepted++
			} else if !errors.Is(e, ErrScheduleLimit) {
				t.Errorf("registration: %v", e)
			}
		}(i)
	}
	wg.Wait()
	if accepted != 10 {
		t.Fatalf("accepted %d", accepted)
	}
	rows, e := s.Schedules("bob")
	if e != nil || len(rows) != 0 {
		t.Fatalf("cross owner list: %v %v", rows, e)
	}
	rows, _ = s.Schedules("alice")
	row := rows[0]
	if _, e = s.Schedule("bob", row.Spec.ID); e == nil {
		t.Fatal("cross owner read")
	}
	row.Spec.Revision++
	if _, e = s.SaveSchedule("bob", "edit", "edit", row, 1, now); e == nil {
		t.Fatal("cross owner write")
	}
	if _, e = s.SaveSchedule("alice", "edit", "edit", row, 9, now); !errors.Is(e, ErrScheduleConflict) {
		t.Fatal("revision fence", e)
	}
}
func TestScheduleAdmissionRestartAndResult(t *testing.T) {
	s := newStore(t)
	now := time.Now()
	row, e := s.SaveSchedule("alice", "create", "create", scheduleFixture("schedule-test"), 0, now)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.ScheduleSynced(row, "synced", "", "{}"); e != nil {
		t.Fatal(e)
	}
	r, e := s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot1", 1, 1, false, now)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot1", 1, 1, false, now)
	if e != nil || again.ID != r.ID {
		t.Fatal("restart duplicated run", e)
	}
	if _, e = s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot2", 1, 1, false, now.Add(time.Hour)); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("active run overlap", e)
	}
	if _, e = s.FinishSchedule("alice", "node-a", r.ID, "succeeded", "", "", "fid", now); e == nil {
		t.Fatal("opened mistaken for success")
	}
	if _, e = s.FinishSchedule("alice", "node-b", r.ID, "succeeded", "result", "", "fid", now); e == nil {
		t.Fatal("another node finished run")
	}
	if _, e = s.FinishSchedule("alice", "node-a", r.ID, "succeeded", "result", "", "fid", now); e != nil {
		t.Fatal(e)
	}
	if _, e = s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot2", 1, 1, false, now.Add(time.Minute)); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("minute burst", e)
	}
	if _, e = s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot3", 1, 1, true, now); e == nil {
		t.Fatal("unauthorized manual run")
	}
}
func TestScheduleIdempotencyAndDailyBudget(t *testing.T) {
	s := newStore(t)
	now := time.Now()
	row, e := s.SaveSchedule("alice", "create", "create", scheduleFixture("schedule-test"), 0, now)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.SaveSchedule("alice", "create", "create", scheduleFixture("schedule-test"), 0, now)
	if e != nil || again.Spec.ID != row.Spec.ID {
		t.Fatal("duplicate create", e)
	}
	if _, e = s.SaveSchedule("alice", "create", "different", scheduleFixture("schedule-test"), 0, now); !errors.Is(e, ErrScheduleConflict) {
		t.Fatal("changed key", e)
	}
	_ = s.ScheduleSynced(row, "synced", "", "{}")
	for i := 0; i < 30; i++ {
		slot := fmt.Sprintf("manual-%d", i)
		_ = s.ScheduleManual("alice", row.Spec.ID, slot, now)
		run, e := s.AdmitSchedule("alice", "node-a", row.Spec.ID, slot, 1, 1, true, now)
		if e != nil {
			t.Fatal(i, e)
		}
		if _, e = s.FinishSchedule("alice", "node-a", run.ID, "succeeded", "done", "", "fid", now); e != nil {
			t.Fatal(e)
		}
	}
	_ = s.ScheduleManual("alice", row.Spec.ID, "manual-over", now)
	if _, e = s.AdmitSchedule("alice", "node-a", row.Spec.ID, "manual-over", 1, 1, true, now); !errors.Is(e, ErrScheduleLimit) {
		t.Fatal("daily cap", e)
	}
}

func TestScheduleSessionBindingAndSnapshot(t *testing.T) {
	s := newStore(t)
	now := time.Now()
	row, err := s.SaveSchedule("alice", "create", "create", scheduleFixture("schedule-test"), 0, now)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.ScheduleSynced(row, "synced", "", "{}"); err != nil {
		t.Fatal(err)
	}
	run, err := s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot1", 1, 1, false, now)
	// Python uuid.uuid5(uuid.NAMESPACE_URL, 'schedule-test:slot1:1').
	if err != nil || run.SessionID != "78193701-6fac-5c18-bc40-62be38235c5b" {
		t.Fatalf("admission identity: %+v %v", run, err)
	}
	again, err := s.AdmitSchedule("alice", "node-a", row.Spec.ID, "slot1", 1, 1, false, now.Add(time.Minute))
	if err != nil || again.SessionID != run.SessionID {
		t.Fatal("replay changed identity", err)
	}
	other, err := s.ScheduleSessions("bob")
	if err != nil || len(other) != 0 {
		t.Fatal("cross-owner provenance", other, err)
	}
	finished, err := s.FinishSchedule("alice", "node-a", run.ID, "succeeded", "answer", "", "arbitrary-other-session", now)
	if err != nil || finished.SessionID != run.SessionID {
		t.Fatal("finish rebound admitted session", finished, err)
	}
	row.Spec.Name = "Renamed"
	row.Spec.Revision++
	row.Spec.Deleted = true
	row.Spec.Enabled = false
	if _, err = s.SaveSchedule("alice", "delete", "delete", row, 1, now); err != nil {
		t.Fatal(err)
	}
	own, err := s.ScheduleSessions("alice")
	if err != nil || own[run.SessionID].ID != run.ID || own[run.SessionID].Title != "Daily "+now.In(time.FixedZone("Shanghai", 8*3600)).Format("01-02") {
		t.Fatal("rename/delete changed historical source", own, err)
	}
}
