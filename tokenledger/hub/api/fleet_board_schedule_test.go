package api

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

// Task PV5W: a schedule run whose session the hub never learned is still the
// schedule's — by the runner's window name (sha256(schedule:slot:attempt)[:24])
// exactly, else by the run admitted just before the record whose schedule's name
// starts with the record's title. A session's opener kind survives its close
// (the ID ledger's session_source).
func TestBoardRecognisesOldScheduleRuns(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	spec := store.Schedule{Endpoint: "node", Spec: schedule.Spec{ID: "schedule-abc", Revision: 1, Name: "活页模板现做（每小时）",
		Prompt: "p", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}}
	row, err := st.SaveSchedule("gh:1", "create", "create", spec, 0, now)
	if err != nil {
		t.Fatal(err)
	}
	_ = st.ScheduleSynced(row, "synced", "", "{}")
	admit := func(attempt int, at time.Time) store.ScheduleRun {
		r, err := st.AdmitSchedule("gh:1", "node", row.Spec.ID, "100", 1, attempt, false, at)
		if err != nil {
			t.Fatal(err)
		}
		// finished with no session: the hub never learned it (an older runner)
		if _, err := st.FinishSchedule("gh:1", "node", r.ID, "failed", "", "x", "", at); err != nil {
			t.Fatal(err)
		}
		return r
	}
	byKey := admit(1, now.Add(-2*time.Hour))
	byTime := admit(2, now.Add(-2*time.Minute)) // a retry of the same slot
	rec := func(token, title, name string) store.FleetTask {
		p := `{"action":"worker_start","node":"auto","params":{"kind":"scratch","name":"` + name + `"}}`
		r, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: title, AuthorityVersion: 1,
			RequestedAgent: "default", ResolvedAgent: "claude", RequestPayload: p}, token, now)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	sum := sha256.Sum256([]byte("schedule-abc:100:1"))
	key := "schedule-" + hex.EncodeToString(sum[:])[:24]
	a := rec("a", key, key)
	c := rec("c", "活页模板现做（每… 11-01", "活页模板现做（每… 11-01")
	other := rec("d", "别的任务 11-01", "别的任务 11-01")
	stale := rec("e", "schedule-000000000000000000000000", "schedule-000000000000000000000000")
	// sessions that closed: their opener kind from the ledger
	push := func(id, src string) {
		ev := func(kind string, seq int, more ...string) map[string]any {
			m := map[string]any{"ev": kind, "id": id, "seq": float64(seq), "ts": float64(now.Unix() - 100 + int64(seq))}
			for i := 0; i+1 < len(more); i += 2 {
				m[more[i]] = more[i+1]
			}
			return m
		}
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep1", Machine: "mac-b", Login: "alice", ID: id,
			Events: []map[string]any{ev("opened", 1, "agent", "claude", "title", "daily-2026-11-03", "session_source", src),
				ev("closed", 2, "reason", "reaped")}}); err != nil {
			t.Fatal(err)
		}
	}
	const daily, person, forged = "0b7e8c1a-6666-4222-8333-000000000001", "0b7e8c1a-6666-4222-8333-000000000002", "0b7e8c1a-6666-4222-8333-000000000003"
	push(daily, "schedule")
	push(person, "")
	push(forged, "root")
	b, err := s.buildBoard("gh:1", nil, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]BoardRow{}
	for _, r := range b.Rows {
		got[r.ID] = r
	}
	if r := got[a.FID]; r.ScheduleID != "schedule-abc" || r.RunID != byKey.ID || r.Source != boardSourceSchedule {
		t.Errorf("by window-name key: %+v", r)
	}
	if r := got[c.FID]; r.ScheduleID != "schedule-abc" || r.RunID != byTime.ID || r.Source != boardSourceSchedule {
		t.Errorf("by time and name: %+v", r)
	}
	for _, id := range []string{other.FID, stale.FID} {
		if r := got[id]; r.ScheduleID != "" || r.Source != "" {
			t.Errorf("%s: %+v", r.Title, r)
		}
	}
	if got[daily].Source != boardSourceSchedule || got[person].Source != "" || got[forged].Source != "" {
		t.Errorf("ledger source: daily %q person %q forged %q", got[daily].Source, got[person].Source, got[forged].Source)
	}
	// two runs admitted in the window: none
	admit(3, now.Add(-time.Minute))
	b, _ = s.buildBoard("gh:1", nil, now)
	for _, r := range b.Rows {
		if r.ID == c.FID && r.ScheduleID != "" {
			t.Errorf("two candidate runs must match none: %+v", r)
		}
	}
}
