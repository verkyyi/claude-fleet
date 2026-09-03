package store

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestRollupFollowsInsertsAndIgnoresDedup(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	e1 := ev("acct-a", "ep-a1", "u-1", 100) // 12:00
	e2 := ev("acct-a", "ep-a1", "u-2", 50)  // same hour, same key
	e3 := ev("acct-a", "ep-a1", "u-3", 7)
	e3.TS = e3.TS.Add(90 * time.Minute)                                              // 13:30 -> a second hour row
	e3.CostUSD = nil                                                                 // unpriced
	if _, _, err := s.InsertEvents([]model.UsageEvent{e1, e2, e3, e1}); err != nil { // e1 twice = dedup
		t.Fatal(err)
	}
	var rows int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 2 {
		t.Fatalf("want 2 hourly rows, got %d", rows)
	}
	var events, out, unpriced int64
	var cost float64
	var minTS, maxTS string
	err := s.db.QueryRow(`SELECT events, output_tokens, unpriced_events, cost_usd, min_ts, max_ts
		FROM usage_hourly WHERE hour = '2026-08-31T12:00:00Z'`).Scan(&events, &out, &unpriced, &cost, &minTS, &maxTS)
	if err != nil {
		t.Fatal(err)
	}
	if events != 2 || out != 150 || unpriced != 0 || cost != 3.0 {
		t.Fatalf("12:00 row = events %d out %d unpriced %d cost %v", events, out, unpriced, cost)
	}
	err = s.db.QueryRow(`SELECT events, unpriced_events, cost_usd FROM usage_hourly
		WHERE hour = '2026-08-31T13:00:00Z'`).Scan(&events, &unpriced, &cost)
	if err != nil {
		t.Fatal(err)
	}
	if events != 1 || unpriced != 1 || cost != 0 {
		t.Fatalf("13:00 row = events %d unpriced %d cost %v", events, unpriced, cost)
	}
}

func TestRollupBackfillMatchesIncremental(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	var evs []model.UsageEvent
	for i := 0; i < 40; i++ {
		e := ev("acct-a", "ep-a1", "u-"+string(rune('a'+i%26))+string(rune('a'+i/26)), int64(i))
		e.TS = e.TS.Add(time.Duration(i*37) * time.Minute)
		if i%5 == 0 {
			e.Model = "claude-opus-5"
		}
		if i%7 == 0 {
			e.IsSidechain = true
		}
		if i%11 == 0 {
			e.CostUSD = nil
		}
		evs = append(evs, e)
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	incremental := dumpRollup(t, s)
	if n, err := s.RebuildRollup(false); err != nil || n == 0 {
		t.Fatalf("rebuild: n=%d err=%v", n, err)
	}
	rebuilt := dumpRollup(t, s)
	if incremental != rebuilt {
		t.Fatalf("rebuild differs from incremental upserts:\n%s\n---\n%s", incremental, rebuilt)
	}
}

// TestRebuildRollupRefusesToDestroyPrunedHistory is the prune-then-rebuild
// regression: PruneEvents and RebuildRollup used to be exercised only in
// separate, unrelated tests, which is exactly how a rebuild that silently
// truncates pruned history survived unnoticed.
func TestRebuildRollupRefusesToDestroyPrunedHistory(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")

	oldTS := time.Date(2026, 6, 1, 3, 0, 0, 0, time.UTC)   // pruned away below
	newTS := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC) // survives

	oldEvent := ev("acct-a", "ep-a1", "u-old", 10)
	oldEvent.TS = oldTS
	newEvent := ev("acct-a", "ep-a1", "u-new", 20)
	newEvent.TS = newTS

	if _, _, err := s.InsertEvents([]model.UsageEvent{oldEvent, newEvent}); err != nil {
		t.Fatal(err)
	}
	if n, err := s.RollupRows(); err != nil || n != 2 {
		t.Fatalf("want 2 rollup rows before prune, got %d err=%v", n, err)
	}

	// PruneEvents deletes the old raw event but must leave its rollup row
	// alone -- that is the entire point of the rollup surviving retention.
	if _, err := s.PruneEvents(oldTS.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	var events int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&events); err != nil {
		t.Fatal(err)
	}
	if events != 1 {
		t.Fatalf("want 1 surviving raw event after prune, got %d", events)
	}
	if n, err := s.RollupRows(); err != nil || n != 2 {
		t.Fatalf("prune must not touch the rollup: rows=%d err=%v", n, err)
	}

	// A rebuild (as a rollupVersion bump, or --rebuild-rollup, would trigger)
	// must refuse: it can no longer reconstruct the pruned hour from
	// usage_events, and deleting-then-rebuilding would erase it for good.
	if _, err := s.RebuildRollup(false); err == nil {
		t.Fatal("RebuildRollup(false) must refuse when usage_hourly holds hours usage_events can no longer reconstruct")
	}
	if n, err := s.RollupRows(); err != nil || n != 2 {
		t.Fatalf("a refused rebuild must not touch the rollup: rows=%d err=%v", n, err)
	}

	// With force, only the reconstructable hour is rebuilt; the
	// unreconstructable one is left exactly as it was -- never deleted.
	n, err := s.RebuildRollup(true)
	if err != nil {
		t.Fatalf("RebuildRollup(true): %v", err)
	}
	if n != 1 {
		t.Fatalf("want 1 rebuilt row (only the reconstructable hour), got %d", n)
	}
	if rows, err := s.RollupRows(); err != nil || rows != 2 {
		t.Fatalf("the pruned hour's rollup row must survive a forced rebuild: rows=%d err=%v", rows, err)
	}
	var oldEvents int64
	if err := s.db.QueryRow(`SELECT events FROM usage_hourly WHERE hour = ?`, hourKey(oldTS)).Scan(&oldEvents); err != nil {
		t.Fatalf("the pruned hour's rollup row must still exist: %v", err)
	}
	if oldEvents != 1 {
		t.Fatalf("the pruned hour's rollup row must be untouched (still 1 event), got %d", oldEvents)
	}
}

func TestOpenBackfillsEmptyRollupAndHonoursVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "r.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acct-a", "ep-a1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-a1", "u-1", 5)}); err != nil {
		t.Fatal(err)
	}
	// Simulate a database written by a hub that predates the rollup.
	if _, err := s.db.Exec(`DELETE FROM usage_hourly; DELETE FROM rollup_meta`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if n, _ := s.RollupRows(); n != 1 {
		t.Fatalf("Open must backfill an empty rollup, rows=%d", n)
	}
	var v string
	if err := s.db.QueryRow(`SELECT value FROM rollup_meta WHERE key='usage_hourly_version'`).Scan(&v); err != nil || v != rollupVersion {
		t.Fatalf("version stamp = %q err=%v", v, err)
	}
}

func dumpRollup(t *testing.T, s *Store) string {
	t.Helper()
	rows, err := s.db.Query(`SELECT hour, model, is_sidechain, events, output_tokens, cost_usd, unpriced_events, min_ts, max_ts
		FROM usage_hourly ORDER BY hour, model, is_sidechain`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out string
	for rows.Next() {
		var hour, model, minTS, maxTS string
		var side, events, outTok, unpriced int64
		var cost float64
		if err := rows.Scan(&hour, &model, &side, &events, &outTok, &cost, &unpriced, &minTS, &maxTS); err != nil {
			t.Fatal(err)
		}
		out += fmt.Sprintf("%s %s %d %d %d %.4f %d %s %s\n", hour, model, side, events, outTok, cost, unpriced, minTS, maxTS)
	}
	return out
}
