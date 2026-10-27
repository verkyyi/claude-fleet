package schedule

import (
	"strconv"
	"testing"
	"time"
)

func TestRecurrencePolicy(t *testing.T) {
	s := Spec{ID: "schedule-test", Revision: 1, Name: "Daily", Prompt: "notes", At: "07:00", Timezone: "Asia/Shanghai"}
	if n, e := Validate(s); e != nil || n != 1 {
		t.Fatal(n, e)
	}
	for _, agent := range []string{"", "claude", "codex", "other", "Claude", "--agent=claude"} {
		choice := s
		choice.Agent = agent
		_, e := Validate(choice)
		valid := agent == "" || agent == "claude" || agent == "codex"
		if (e == nil) != valid {
			t.Fatalf("agent %q: %v", agent, e)
		}
	}
	for _, cron := range []string{"* * * * *", "0,30 * * * *", "0 25 * * *", "0 * * 13 *", "0 * * * 8"} {
		bad := s
		bad.At = ""
		bad.Cron = cron
		if _, e := Validate(bad); e == nil {
			t.Fatal("accepted", cron)
		}
	}
	s.At = ""
	s.Cron = "0 */2 * * 1-5"
	if n, e := Validate(s); e != nil || n != 12 {
		t.Fatal(n, e)
	}
}

func TestCalendarPreviewAndAdmission(t *testing.T) {
	for _, tt := range []struct{ zone, at, cron, after, want string }{
		{"Asia/Shanghai", "07:00", "", "2026-10-26T00:00:00Z", "2026-10-26T23:00:00Z"},
		{"America/New_York", "02:30", "", "2026-03-08T00:00:00Z", "2026-03-09T06:30:00Z"},
		{"America/New_York", "01:30", "", "2026-11-01T00:00:00Z", "2026-11-01T05:30:00Z"},
		{"America/New_York", "01:30", "", "2026-11-01T06:00:00Z", "2026-11-02T06:30:00Z"},
		{"Asia/Shanghai", "", "0 7 * * 1-5", "2026-10-30T23:00:00Z", "2026-11-01T23:00:00Z"},
	} {
		s := Spec{ID: "schedule-preview", Revision: 1, Name: "test", Prompt: "test", At: tt.at, Cron: tt.cron, Timezone: tt.zone}
		after, _ := time.Parse(time.RFC3339, tt.after)
		want, _ := time.Parse(time.RFC3339, tt.want)
		got, e := Preview(s, after)
		if e != nil || !got.Equal(want) {
			t.Fatalf("%+v: %s %v", tt, got, e)
		}
		slot := strconv.FormatInt(got.Unix(), 10)
		if !DueSlot(s, slot, got.Add(time.Minute)) || DueSlot(s, slot, got.Add(7*time.Hour)) || DueSlot(s, slot, got.Add(-time.Minute)) {
			t.Fatal("admission time", slot)
		}
	}
	// n/step means n through the field's end, as the existing Python daemon.
	s := Spec{ID: "schedule-step", Revision: 1, Name: "test", Prompt: "test", Cron: "0 1/2 * * *", Timezone: "UTC"}
	if slots, e := Validate(s); e != nil || slots != 12 {
		t.Fatal(slots, e)
	}
}
