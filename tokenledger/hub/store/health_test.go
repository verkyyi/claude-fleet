package store

import (
	"testing"
	"time"
)

func TestHealthLifecycle(t *testing.T) {
	s := poolStore(t)
	now := time.Now().Truncate(time.Minute)
	for i := 0; i < 5; i++ {
		made, err := s.RecordHealthProbe(HealthProbe{Component: "wechat", At: now.Add(time.Duration(i) * time.Minute).UnixMilli(), State: "failed"}, 3)
		if err != nil || made != (i == 2) {
			t.Fatalf("tick %d: %v %v", i, made, err)
		}
	}
	made, err := s.RecordHealthProbe(HealthProbe{Component: "wechat", At: now.Add(4 * time.Minute).UnixMilli(), State: "failed"}, 3)
	if err != nil || made {
		t.Fatalf("duplicate: %v %v", made, err)
	}
	es, err := s.HealthEvents(now.Add(-time.Hour))
	if err != nil || len(es) != 1 || es[0].Ended != 0 {
		t.Fatalf("events: %+v %v", es, err)
	}
	if ok, e := s.AnnotateHealthEvent(es[0].ID, "正在修复", "Investigating"); e != nil || !ok {
		t.Fatal(e)
	}
	_, err = s.RecordHealthProbe(HealthProbe{Component: "wechat", At: now.Add(5 * time.Minute).UnixMilli(), State: "ok"}, 3)
	if err != nil {
		t.Fatal(err)
	}
	es, _ = s.HealthEvents(now.Add(-time.Hour))
	if es[0].Ended == 0 || es[0].NoteEN != "Investigating" {
		t.Fatalf("resolution: %+v", es)
	}
	// A missing minute cannot count as a consecutive failure.
	for _, i := range []int{10, 12, 13} {
		made, err = s.RecordHealthProbe(HealthProbe{Component: "wechat", At: now.Add(time.Duration(i) * time.Minute).UnixMilli(), State: "failed"}, 3)
		if err != nil || made {
			t.Fatalf("gap: %v %v", made, err)
		}
	}
	made, err = s.RecordHealthProbe(HealthProbe{Component: "wechat", At: now.Add(14 * time.Minute).UnixMilli(), State: "failed"}, 3)
	if err != nil || !made {
		t.Fatalf("second incident: %v %v", made, err)
	}
}
func TestChatTimingMillisecondsAndRetry(t *testing.T) {
	s := poolStore(t)
	now := time.Now().Truncate(time.Millisecond)
	_, e := s.write.Exec(`INSERT INTO fleet_chat_timings(at,ms) VALUES(?,?)`, now.Unix(), 1000)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.ensureChatTimings(); e != nil {
		t.Fatal(e)
	}
	if e = s.ensureChatTimings(); e != nil {
		t.Fatal(e)
	} // idempotent migration
	c := ChatTiming{ID: "retry", At: now, MS: 2000, Agent: "codex"}
	for i := 0; i < 2; i++ {
		if e = s.RecordChatTiming(c); e != nil {
			t.Fatal(e)
		}
	}
	// An old replica still writing seconds during a rolling release is readable.
	_, e = s.write.Exec(`INSERT INTO fleet_chat_timings(at,ms) VALUES(?,?)`, now.Unix(), 3000)
	if e != nil {
		t.Fatal(e)
	}
	xs, e := s.ChatTimings(now.Add(-time.Minute))
	if e != nil || len(xs) != 3 {
		t.Fatalf("read: %+v %v", xs, e)
	}
	var at int64
	if e = s.read.QueryRow(`SELECT at FROM fleet_chat_timings WHERE ms=2000`).Scan(&at); e != nil || at != now.UnixMilli() {
		t.Fatalf("at=%d: %v", at, e)
	}
}
