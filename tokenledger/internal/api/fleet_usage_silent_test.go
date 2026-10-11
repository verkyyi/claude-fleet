package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3204: a login with a session working and no usage reaching the
// hub is raised as usage_silent, and cleared once a turn lands.

func usageSilentBeat(t *testing.T, st *store.Store, state string, at time.Time) {
	t.Helper()
	workers := `[{"agent":"claude","state":"` + state + `","key":"verkyyi-claude-fleet:issue-1"},` +
		`{"agent":"claude","state":"looping","key":"verkyyi-claude-fleet:scratch-4"}]`
	if _, err := st.RecordFleetSnapshot("ep-verky", "macmini", "verky", "machine-1", []store.FleetReport{{
		FleetID: "fleet-1", Name: "fleet", Agent: "claude", State: "running", WorkerCount: 2, WorkersJSON: workers,
	}}, at); err != nil {
		t.Fatal(err)
	}
}

// usageSilentStore is a store with the fleet tables (they ride the fleet
// switch, EnsureNodes).
func usageSilentStore(t *testing.T) *store.Store {
	t.Helper()
	st := openTestStore(t)
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	return st
}

func usageSilentOpen(t *testing.T, st *store.Store) []string {
	t.Helper()
	subs, err := st.OpenFleetAlertSubjects(store.AlertUsageSilent, "")
	if err != nil {
		t.Fatal(err)
	}
	return subs
}

func TestUsageSilentRaisedWhenWorkingLoginSendsNothing(t *testing.T) {
	st := usageSilentStore(t)
	srv := &Server{Store: st, UsageSilentAfter: 30 * time.Minute}
	t0 := time.Now().UTC().Truncate(time.Second)

	// Working, but not yet for the threshold: nothing.
	usageSilentBeat(t, st, "working", t0)
	srv.UsageSilentTick(t0, true)
	usageSilentBeat(t, st, "working", t0.Add(20*time.Minute))
	srv.UsageSilentTick(t0.Add(20*time.Minute), true)
	if subs := usageSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("raised before the threshold: %v", subs)
	}

	// Working past the threshold with no usage: the attribution is broken.
	now := t0.Add(31 * time.Minute)
	usageSilentBeat(t, st, "working", now)
	srv.UsageSilentTick(now, true)
	subs := usageSilentOpen(t, st)
	if len(subs) != 1 || subs[0] != "ep-verky/claude" {
		t.Fatalf("want one usage_silent on ep-verky/claude, have %v", subs)
	}

	// A turn lands: cleared on the next sweep.
	if _, _, err := st.InsertEvents([]model.UsageEvent{{
		Source: model.SourceClaude, AccountUUID: "claude:local", EndpointID: "ep-verky", OSUser: "verky",
		MessageUUID: "m-1", SessionID: "s", TS: now.Add(time.Minute), Model: "claude-opus-5-5", OutputTokens: 10,
	}}); err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Minute)
	usageSilentBeat(t, st, "working", now)
	srv.UsageSilentTick(now, true)
	if subs := usageSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("still open after usage landed: %v", subs)
	}
}

// Usage that keeps flowing never raises; a looping or waiting session never
// counts as working.
func TestUsageSilentQuietWhenUsageFlowsOrNothingWorks(t *testing.T) {
	st := usageSilentStore(t)
	srv := &Server{Store: st, UsageSilentAfter: 30 * time.Minute}
	t0 := time.Now().UTC().Truncate(time.Second)
	for i := 0; i <= 4; i++ {
		at := t0.Add(time.Duration(i) * 15 * time.Minute)
		if _, _, err := st.InsertEvents([]model.UsageEvent{{
			Source: model.SourceClaude, AccountUUID: "acct", EndpointID: "ep-verky", OSUser: "verky",
			MessageUUID: "m-" + at.Format(time.RFC3339), SessionID: "s", TS: at, Model: "claude-opus-5-5", OutputTokens: 1,
		}}); err != nil {
			t.Fatal(err)
		}
		usageSilentBeat(t, st, "working", at)
		srv.UsageSilentTick(at, true)
	}
	if subs := usageSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("raised while usage was flowing: %v", subs)
	}

	srv2 := &Server{Store: usageSilentStore(t), UsageSilentAfter: 30 * time.Minute}
	for i := 0; i <= 4; i++ {
		at := t0.Add(time.Duration(i) * 15 * time.Minute)
		usageSilentBeat(t, srv2.Store, "done", at)
		srv2.UsageSilentTick(at, true)
	}
	if subs := usageSilentOpen(t, srv2.Store); len(subs) != 0 {
		t.Fatalf("raised with nothing working: %v", subs)
	}
}

func TestUsageSilentAfterFromEnv(t *testing.T) {
	for v, want := range map[string]time.Duration{
		"": defaultUsageSilentAfter, "x": defaultUsageSilentAfter, "-5": defaultUsageSilentAfter,
		"600": 10 * time.Minute, "0": -1,
	} {
		t.Setenv("FLEET_USAGE_SILENT_ALERT_SECS", v)
		if got := UsageSilentAfterFromEnv(); got != want {
			t.Errorf("FLEET_USAGE_SILENT_ALERT_SECS=%q: %v, want %v", v, got, want)
		}
	}
}
