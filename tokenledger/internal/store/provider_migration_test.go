package store

import (
	"database/sql"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// Rollup history outlives the raw events it was built from, so the migration
// must carry every existing row across rather than rebuilding from
// usage_events — a rebuild silently drops every hour whose raw rows were
// pruned.
func TestMigrateProvider_PreservesRollupHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// A database from before the dimension: usage_hourly has no provider, in
	// the column list or in the primary key.
	oldSchema := regexp.MustCompile(`(?m)^\s+provider\s+TEXT NOT NULL DEFAULT '',\n`).ReplaceAllString(schemaSQL, "")
	oldSchema = strings.ReplaceAll(oldSchema, "model, provider, git_branch", "model, git_branch")
	if strings.Contains(oldSchema, "provider") {
		t.Fatalf("fixture still mentions provider; the schema shape changed:\n%s", oldSchema)
	}
	// Two rollup rows whose raw events have been pruned — the case a rebuild
	// would erase and a copy must preserve.
	if _, err := db.Exec(oldSchema + `
		INSERT INTO accounts(account_uuid, first_seen, last_seen) VALUES ('a', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');
		INSERT INTO usage_hourly(hour, account_uuid, endpoint_id, events, output_tokens, unpriced_events, min_ts, max_ts)
		VALUES ('2026-09-01T12:00:00Z', 'a', 'e', 1, 100, 0, '2026-09-01T12:00:00Z', '2026-09-01T12:00:00Z'),
		('2025-01-01T12:00:00Z', 'a', 'e', 9, 900, 9, '2025-01-01T12:00:00Z', '2025-01-01T12:00:00Z');`); err != nil {
		t.Fatal(err)
	}
	db.Close()

	s, err := Open(path) // runs migrate()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	var gotRows int
	var gotOut int64
	if err := s.DB().QueryRow(`SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM usage_hourly`).Scan(&gotRows, &gotOut); err != nil {
		t.Fatal(err)
	}
	if gotRows != 2 || gotOut != 1000 {
		t.Errorf("after migration: %d rows / %d output tokens; want 2 / 1000", gotRows, gotOut)
	}

	// Pre-migration rows genuinely predate the dimension and say so by being
	// empty. Inventing a provider for them would be a fabricated breakdown.
	var blank int
	if err := s.DB().QueryRow(`SELECT COUNT(*) FROM usage_hourly WHERE provider = ''`).Scan(&blank); err != nil {
		t.Fatal(err)
	}
	if blank != 2 {
		t.Errorf("%d pre-migration rows acquired a provider; want all 2 blank", 2-blank)
	}

	// And the new primary key is in force: the same hour under two providers
	// is two rows.
	if _, err := s.DB().Exec(`INSERT INTO usage_hourly(hour, account_uuid, endpoint_id, provider, events, output_tokens, unpriced_events, min_ts, max_ts)
		VALUES ('2026-09-01T12:00:00Z', 'a', 'e', 'p1', 1, 5, 0, '2026-09-01T12:00:00Z', '2026-09-01T12:00:00Z')`); err != nil {
		t.Fatalf("provider is not part of the primary key: %v", err)
	}
}

// Two providers serving the same model in the same hour are two rollup rows,
// not one. If provider is missing from the PRIMARY KEY they collapse and the
// per-contract figures are lost forever.
func TestRollup_ProviderSplitsRows(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	mk := func(uuid, provider string, out int64) model.UsageEvent {
		e := ev("acct", "ep1", uuid, out)
		e.Source = model.SourceGateway
		e.Model = "deepseek-v4-flash"
		e.Details = &model.UsageDetails{Provider: provider}
		return e
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		mk("g1", "dashscope.aliyuncs.com", 10),
		mk("g2", "ark.cn-beijing.volces.com", 20),
	}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.DB().Query(`SELECT provider, output_tokens FROM usage_hourly
		WHERE source = 'gateway' ORDER BY provider`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[string]int64{}
	for rows.Next() {
		var p string
		var out int64
		if err := rows.Scan(&p, &out); err != nil {
			t.Fatal(err)
		}
		got[p] = out
	}
	if len(got) != 2 {
		t.Fatalf("got %d rollup rows (%v); want one per provider", len(got), got)
	}
	if got["dashscope.aliyuncs.com"] != 10 || got["ark.cn-beijing.volces.com"] != 20 {
		t.Errorf("rollup rows = %v", got)
	}
}
