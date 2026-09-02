// internal/api/history_test.go
package api

import (
	"testing"

	"github.com/verkyyi/ccquota/internal/store"
)

func hr(hour, model string, tokens int64) store.HourRow {
	return store.HourRow{Hour: hour, Model: model, Events: 1, Tokens: tokens}
}

func TestFoldHoursIntoSixHourBucketsWithStack(t *testing.T) {
	rows := []store.HourRow{
		hr("2026-09-02T05:00:00Z", "opus", 10),
		hr("2026-09-02T06:00:00Z", "opus", 20),
		hr("2026-09-02T07:00:00Z", "haiku", 5),
		hr("2026-09-02T07:00:00Z", "sonnet", 1),
	}
	top := topModels(rows, 2) // opus, haiku
	if len(top) != 2 || top[0] != "opus" || top[1] != "haiku" {
		t.Fatalf("top=%v", top)
	}
	out, err := foldHours(rows, "6h", true, top)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 || out[0].Key != "2026-09-02T00" || out[1].Key != "2026-09-02T06" {
		t.Fatalf("%+v", out)
	}
	if out[1].Tokens != 26 || out[1].Events != 3 {
		t.Fatalf("%+v", out[1])
	}
	// stack: opus 20, haiku 5, other 1 — every series has all three entries
	st := out[1].Stack
	if len(st) != 3 || st[0].Key != "opus" || st[0].Tokens != 20 || st[1].Tokens != 5 || st[2].Key != "other" || st[2].Tokens != 1 {
		t.Fatalf("stack=%+v", st)
	}
	if len(out[0].Stack) != 3 || out[0].Stack[1].Tokens != 0 {
		t.Fatalf("zero-filled stack expected: %+v", out[0].Stack)
	}
	if _, err := foldHours(rows, "week", false, nil); err == nil {
		t.Fatal("unknown granularity must be refused")
	}
	day, _ := foldHours(rows, "day", false, nil)
	if len(day) != 1 || day[0].Key != "2026-09-02" || day[0].Tokens != 36 {
		t.Fatalf("day=%+v", day)
	}
	hour, _ := foldHours(rows, "hour", false, nil)
	if len(hour) != 3 || hour[0].Key != "2026-09-02T05:00" {
		t.Fatalf("hour=%+v", hour)
	}
}
