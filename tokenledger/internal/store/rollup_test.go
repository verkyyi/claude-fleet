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
	if n, err := s.RebuildRollup(); err != nil || n == 0 {
		t.Fatalf("rebuild: n=%d err=%v", n, err)
	}
	rebuilt := dumpRollup(t, s)
	if incremental != rebuilt {
		t.Fatalf("rebuild differs from incremental upserts:\n%s\n---\n%s", incremental, rebuilt)
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
