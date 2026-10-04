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

// ---- provider dimension -----------------------------------------------

// The gateway shipper sends the upstream inside details.model_provider. The
// hub lifts it onto the event so it can be grouped, without the shipper having
// to change what it sends.
func TestInsert_ProviderComesFromDetailsWhenUnset(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "u-gw-1", 10)
	e.Source = model.SourceGateway
	e.Model = "qwen-plus"
	e.Details = &model.UsageDetails{Provider: "dashscope.aliyuncs.com"}
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	var got string
	if err := s.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-gw-1").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "dashscope.aliyuncs.com" {
		t.Errorf("provider = %q, want dashscope.aliyuncs.com", got)
	}
}

func TestInsert_ExplicitProviderWins(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "u-gw-2", 10)
	e.Source = model.SourceGateway
	e.Provider = "explicit.example"
	e.Details = &model.UsageDetails{Provider: "details.example"}
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	var got string
	if err := s.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-gw-2").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "explicit.example" {
		t.Errorf("provider = %q, want explicit.example", got)
	}
}

// Absent is absent. A Claude transcript declares no upstream and must not
// acquire an invented one.
func TestInsert_NoProviderStaysEmpty(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct", "ep1", "u-cc-1", 10)}); err != nil {
		t.Fatal(err)
	}

	var got string
	if err := s.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-cc-1").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Errorf("provider = %q, want empty", got)
	}
}

// History is already in the database, inside details_json. The migration lifts
// it out rather than starting the dimension from today.
func TestMigrate_BackfillsProviderFromDetails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backfill.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "u-old", 10)
	e.Source = model.SourceGateway
	e.Details = &model.UsageDetails{Provider: "ark.cn-beijing.volces.com"}
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	// Simulate a row written before the column existed.
	if _, err := s.DB().Exec(`UPDATE usage_events SET provider = '' WHERE message_uuid = ?`, "u-old"); err != nil {
		t.Fatal(err)
	}
	s.Close()

	s2, err := Open(path) // reopening runs migrate()
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	var got string
	if err := s2.DB().QueryRow(
		`SELECT provider FROM usage_events WHERE message_uuid = ?`, "u-old").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "ark.cn-beijing.volces.com" {
		t.Errorf("backfilled provider = %q, want ark.cn-beijing.volces.com", got)
	}
}
