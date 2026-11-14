package main

import (
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Task PVG9: a bad CCQUOTA_FLEET_SCHEDULE_LIMITS never stops the hub; every
// owner keeps the defaults.
func TestScheduleLimitsFromEnv(t *testing.T) {
	env := func(v string) func(string) string {
		return func(k string) string {
			if k == "CCQUOTA_FLEET_SCHEDULE_LIMITS" {
				return v
			}
			return ""
		}
	}
	if o := scheduleLimitsFromEnv(env("")); o != nil {
		t.Fatal("unset", o)
	}
	o := scheduleLimitsFromEnv(env(`{"gh:1":{"tasks":20,"daily_slots":72,"daily_starts":60}}`))
	if o.For("gh:1") != (store.ScheduleLimits{Tasks: 20, DailySlots: 72, DailyStarts: 60}) || o.For("gh:2") != store.DefaultScheduleLimits {
		t.Fatal(o)
	}
	for _, bad := range []string{`{"gh:1":`, `{"gh:1":{"tasks":0}}`, `{"gh:1":{"tasks":1000}}`} {
		if o := scheduleLimitsFromEnv(env(bad)); o.For("gh:1") != store.DefaultScheduleLimits {
			t.Fatal(bad, o)
		}
	}
}
