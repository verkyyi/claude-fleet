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
	if err := s.write.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 2 {
		t.Fatalf("want 2 hourly rows, got %d", rows)
	}
	var events, out, unpriced int64
	var cost float64
	var minTS, maxTS string
	err := s.write.QueryRow(`SELECT events, output_tokens, unpriced_events, cost_usd, min_ts, max_ts
		FROM usage_hourly WHERE hour = '2026-08-31T12:00:00Z'`).Scan(&events, &out, &unpriced, &cost, &minTS, &maxTS)
	if err != nil {
		t.Fatal(err)
	}
	if events != 2 || out != 150 || unpriced != 0 || cost != 3.0 {
		t.Fatalf("12:00 row = events %d out %d unpriced %d cost %v", events, out, unpriced, cost)
	}
	err = s.write.QueryRow(`SELECT events, unpriced_events, cost_usd FROM usage_hourly
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
	if err := s.write.QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&events); err != nil {
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
	if err := s.write.QueryRow(`SELECT events FROM usage_hourly WHERE hour = ?`, hourKey(oldTS)).Scan(&oldEvents); err != nil {
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
	if _, err := s.write.Exec(`DELETE FROM usage_hourly; DELETE FROM rollup_meta`); err != nil {
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
	if err := s.write.QueryRow(`SELECT value FROM rollup_meta WHERE key='usage_hourly_version'`).Scan(&v); err != nil || v != rollupVersion {
		t.Fatalf("version stamp = %q err=%v", v, err)
	}
}

// TestForceRebuildWithEmptyEventsPreservesRollup is the pre-deploy review's
// first landmine: RebuildRollup(true) with usage_events completely empty
// used to fall into a stray `else` branch running an unconditional DELETE
// FROM usage_hourly -- destroying exactly what force is documented to
// preserve (rollup.go's own comments, and hub.go's --rebuild-rollup-force
// flag help, both promise pre-retention rows are "left exactly as they are,
// not deleted, not rebuilt"). With no surviving raw events there is no hour
// left to reconstruct from, so the correct delete set is empty, not "all of
// usage_hourly".
func TestForceRebuildWithEmptyEventsPreservesRollup(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")

	e := ev("acct-a", "ep-a1", "u-1", 10)
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	if n, err := s.RollupRows(); err != nil || n != 1 {
		t.Fatalf("want 1 rollup row before prune, got %d err=%v", n, err)
	}

	// Prune away every raw event: usage_events is now empty, but its rollup
	// row is the only surviving record of that history.
	if _, err := s.PruneEvents(e.TS.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	var events int64
	if err := s.write.QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&events); err != nil {
		t.Fatal(err)
	}
	if events != 0 {
		t.Fatalf("want 0 surviving raw events after pruning, got %d", events)
	}

	// The interactive refusal must still fire: nothing here is asking for
	// force yet.
	if _, err := s.RebuildRollup(false); err == nil {
		t.Fatal("RebuildRollup(false) must refuse when usage_events is empty but usage_hourly is not")
	}
	if n, err := s.RollupRows(); err != nil || n != 1 {
		t.Fatalf("a refused rebuild must not touch the rollup: rows=%d err=%v", n, err)
	}

	// With force, there is nothing to backfill (usage_events is empty), so
	// the rollup must come out of this untouched, not wiped.
	n, err := s.RebuildRollup(true)
	if err != nil {
		t.Fatalf("RebuildRollup(true) with empty usage_events must not error: %v", err)
	}
	if n != 0 {
		t.Fatalf("nothing to backfill from an empty usage_events, want 0 rebuilt rows, got %d", n)
	}
	if rows, err := s.RollupRows(); err != nil || rows != 1 {
		t.Fatalf("FORCE rebuild must preserve the rollup when usage_events is empty: rows=%d (want 1) err=%v", rows, err)
	}
}

// TestOpenDegradesRollupOnPrunedDBInsteadOfFailing is the pre-deploy review's
// second landmine: a rollupVersion bump on a hub that has ever pruned used to
// fail store.Open outright (ensureRollup always called RebuildRollup(false),
// whose refusal to destroy pre-retention rows then failed Open) -- with no
// way to reach the documented --rebuild-rollup-force escape hatch, because
// every command that opens the store, including hub itself, dies before it
// gets a chance to honour that flag. Open must instead degrade to the same
// scoped, non-destructive rebuild force already performs: rebuild every
// reconstructable hour, leave the pre-retention rows exactly as they are,
// and succeed.
func TestOpenDegradesRollupOnPrunedDBInsteadOfFailing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "r.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acct-a", "ep-a1")

	oldTS := time.Date(2026, 6, 1, 3, 0, 0, 0, time.UTC)   // pruned away below
	newTS := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC) // survives, reconstructable

	oldEvent := ev("acct-a", "ep-a1", "u-old", 10)
	oldEvent.TS = oldTS
	newEvent := ev("acct-a", "ep-a1", "u-new", 20)
	newEvent.TS = newTS
	if _, _, err := s.InsertEvents([]model.UsageEvent{oldEvent, newEvent}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PruneEvents(oldTS.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	// Simulate the design's own rollup-schema upgrade mechanism: a
	// rollupVersion bump, recorded here by hand since the real constant is
	// fixed at "1" in this build.
	if _, err := s.write.Exec(
		`UPDATE rollup_meta SET value = 'simulated-next-version' WHERE key = 'usage_hourly_version'`,
	); err != nil {
		t.Fatal(err)
	}
	s.Close()

	s2, err := Open(path)
	if err != nil {
		t.Fatalf("Open must degrade to a scoped rebuild rather than fail on a pruned DB whose rollup version differs: %v", err)
	}
	defer s2.Close()

	var v string
	if err := s2.write.QueryRow(`SELECT value FROM rollup_meta WHERE key='usage_hourly_version'`).Scan(&v); err != nil || v != rollupVersion {
		t.Fatalf("version stamp after the degraded rebuild = %q err=%v, want %q", v, err, rollupVersion)
	}

	// The pre-retention hour must survive, untouched.
	var oldEvents int64
	if err := s2.write.QueryRow(`SELECT events FROM usage_hourly WHERE hour = ?`, hourKey(oldTS)).Scan(&oldEvents); err != nil {
		t.Fatalf("the pruned hour's rollup row must survive Open's degraded rebuild: %v", err)
	}
	if oldEvents != 1 {
		t.Fatalf("pre-retention row must be untouched (still 1 event), got %d", oldEvents)
	}

	// The reconstructable hour must have been rebuilt under the new version.
	var newEvents int64
	if err := s2.write.QueryRow(`SELECT events FROM usage_hourly WHERE hour = ?`, hourKey(newTS)).Scan(&newEvents); err != nil {
		t.Fatalf("the reconstructable hour must be rebuilt: %v", err)
	}
	if newEvents != 1 {
		t.Fatalf("reconstructable hour rebuild has the wrong shape: events=%d", newEvents)
	}
}

func dumpRollup(t *testing.T, s *Store) string {
	t.Helper()
	rows, err := s.write.Query(`SELECT hour, model, is_sidechain, events, output_tokens, cost_usd, unpriced_events, min_ts, max_ts
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
