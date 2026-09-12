package store

import (
	"database/sql"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestSourcesMigrationPreservesPrunedHistoryAndDedup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	oldSchema := regexp.MustCompile(`(?m)^\s+source\s+TEXT NOT NULL DEFAULT 'claude',\n`).ReplaceAllString(schemaSQL, "")
	oldSchema = strings.ReplaceAll(oldSchema, "is_sidechain, source)", "is_sidechain)")
	if _, err := db.Exec(oldSchema + `
		CREATE UNIQUE INDEX idx_events_dedup ON usage_events(account_uuid, message_uuid);
		INSERT INTO rollup_meta VALUES ('usage_hourly_version', '1');
		INSERT INTO accounts(account_uuid, first_seen, last_seen) VALUES ('a', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');
		INSERT INTO usage_events(account_uuid, endpoint_id, message_uuid, ts, output_tokens)
		VALUES ('a', 'e', 'same-request', '2026-09-01T12:00:00Z', 10);
		INSERT INTO usage_hourly(hour, account_uuid, endpoint_id, events, output_tokens, unpriced_events, min_ts, max_ts)
		VALUES ('2026-09-01T12:00:00Z', 'a', 'e', 1, 10, 1, '2026-09-01T12:00:00Z', '2026-09-01T12:00:00Z'),
		('2025-01-01T12:00:00Z', 'a', 'e', 9, 900, 9, '2025-01-01T12:00:00Z', '2025-01-01T12:00:00Z');`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	e := model.UsageEvent{AccountUUID: "a", EndpointID: "e", MessageUUID: "same-request", Source: model.SourceCodex, TS: base, OutputTokens: 20}
	if n, d, err := s.InsertEvents([]model.UsageEvent{e, e}); err != nil || n != 1 || d != 1 {
		t.Fatalf("source-aware dedup: inserted=%d deduped=%d err=%v", n, d, err)
	}
	s.Close()
	// Reopening after both sources reuse an id must not recreate the old index.
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	f := Filter{Account: "a", Start: base.AddDate(-2, 0, 0), End: base.Add(time.Hour)}
	for source, want := range map[string]int64{"claude": 910, "codex": 20} {
		f.Source = source
		summary, err := s.Summary(f)
		if err != nil || summary.Tokens != want {
			t.Fatalf("%s summary=%+v err=%v", source, summary, err)
		}
	}
	f.Source = ""
	rows, err := s.UsageByFiltered(f, BySource, 10)
	if err != nil || len(rows) != 2 {
		t.Fatalf("source breakdown=%+v err=%v", rows, err)
	}
	if s.BackfilledRollup != 0 {
		t.Fatal("source upgrade unnecessarily rebuilt history")
	}
	accounts, err := s.ListAccounts()
	if err != nil || len(accounts) != 1 || accounts[0].Source != "claude" {
		t.Fatalf("legacy account: %+v %v", accounts, err)
	}
}

func TestSourceRollupRebuildEqualsRaw(t *testing.T) {
	s := newStore(t)
	claude := ev("acct", "ep", "request", 10)
	codex := claude
	codex.Source, codex.OutputTokens = model.SourceCodex, 20
	if _, _, err := s.InsertEvents([]model.UsageEvent{claude, codex}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RebuildRollup(false); err != nil {
		t.Fatal(err)
	}
	start, end := claude.TS.Add(-time.Hour), claude.TS.Add(time.Hour)
	rows, err := s.EventsInRange("acct", start, end)
	if err != nil || len(rows) != 2 || rows[0].Source == rows[1].Source {
		t.Fatalf("raw sources=%+v err=%v", rows, err)
	}
	rollup, err := s.UsageByFiltered(Filter{Account: "acct", Start: start, End: end}, BySource, 10)
	if err != nil || len(rollup) != 2 {
		t.Fatalf("rebuilt sources=%+v err=%v", rollup, err)
	}
}
