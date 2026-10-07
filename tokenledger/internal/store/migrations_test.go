package store

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// Migration 1 (claude-fleet#1987) on a database as production had it: Claude
// and Codex usage beside gateway, vendor-bill and voice usage, the business
// ledger, repo progress, share links, the notifier's memory, shipper tokens.
// It deletes exactly the three sources' rows, drops exactly those tables,
// retires exactly the shippers — every other row count stays put — and a
// second run changes nothing.
func TestMigration1_RemovesOnlyTheCompanyBusiness(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	var evs []model.UsageEvent
	for i, src := range []string{model.SourceClaude, model.SourceCodex, "gateway", "vendor_bill", "voice"} {
		for j := 0; j < 2; j++ {
			e := ev("acct", "ep1", src+"-"+string(rune('a'+j)), int64(10+i))
			e.Source = src
			e.SessionID = "s-" + src
			evs = append(evs, e)
		}
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	for _, src := range []string{model.SourceClaude, "gateway"} {
		if err := s.SetPlanPrice(model.SubscriptionPlan{Plan: "max", Source: src, MonthlyCost: 100, Currency: "USD",
			EffectiveFrom: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}); err != nil {
			t.Fatal(err)
		}
	}
	db := s.DB()
	for _, q := range []string{
		`CREATE TABLE growth_facts (source TEXT, day TEXT)`,
		`INSERT INTO growth_facts VALUES ('growth-facts', '2026-10-01')`,
		`CREATE TABLE repo_issues (repo TEXT, number INTEGER)`,
		`INSERT INTO repo_issues VALUES ('o/r', 1), ('o/r', 2)`,
		`CREATE TABLE repo_days (repo TEXT, day TEXT)`,
		`CREATE TABLE share_links (id TEXT)`,
		`INSERT INTO share_links VALUES ('board')`,
		`CREATE TABLE finding_notices (problem TEXT)`,
		`DELETE FROM hub_migrations`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for id, kind := range map[string]string{"ep-repo": "repo_shipper", "ep-growth": "growth_shipper", "ep-brief": "growth_reader"} {
		if err := s.EnrollKind(id, id, "hash-"+id, kind); err != nil {
			t.Fatal(err)
		}
	}

	count := func(q string) int {
		t.Helper()
		var n int
		if err := db.QueryRow(q).Scan(&n); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return n
	}
	kept := map[string]string{
		"events":    `SELECT COUNT(*) FROM usage_events WHERE source IN ('claude', 'codex')`,
		"hourly":    `SELECT COUNT(*) FROM usage_hourly WHERE source IN ('claude', 'codex')`,
		"plans":     `SELECT COUNT(*) FROM subscription_plans WHERE source = 'claude'`,
		"accounts":  `SELECT COUNT(*) FROM accounts`,
		"agents":    `SELECT COUNT(*) FROM endpoints WHERE kind = 'agent' AND retired_at IS NULL`,
		"hub_users": `SELECT COUNT(*) FROM hub_users`,
	}
	before := map[string]int{}
	for k, q := range kept {
		before[k] = count(q)
	}
	if before["events"] != 4 || count(`SELECT COUNT(*) FROM usage_events`) != 10 {
		t.Fatalf("fixture: %v, %d events in all", before, count(`SELECT COUNT(*) FROM usage_events`))
	}

	if err := runMigrations(db); err != nil {
		t.Fatal(err)
	}

	for k, q := range kept {
		if got := count(q); got != before[k] {
			t.Errorf("%s: %d rows after the migration, %d before — it touched what it must not", k, got, before[k])
		}
	}
	for _, tbl := range sourceTables {
		if n := count(`SELECT COUNT(*) FROM ` + tbl + ` WHERE source IN ('gateway', 'vendor_bill', 'voice')`); n != 0 {
			t.Errorf("%s still holds %d rows of a removed source", tbl, n)
		}
	}
	for _, tbl := range removedTables {
		if n := count(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '` + tbl + `'`); n != 0 {
			t.Errorf("table %s survived", tbl)
		}
	}
	if n := count(`SELECT COUNT(*) FROM endpoints WHERE kind != 'agent' AND retired_at IS NULL`); n != 0 {
		t.Errorf("%d shipper enrollments still authenticate", n)
	}
	ms, err := s.Migrations()
	if err != nil || len(ms) != 1 || ms[0].ID != 1 {
		t.Fatalf("hub_migrations = %+v, %v", ms, err)
	}
	for _, want := range []string{`"deleted.usage_events":6`, `"dropped.repo_issues":2`, `"retired.shippers":3`} {
		if !strings.Contains(ms[0].Detail, want) {
			t.Errorf("migration detail %s lacks %s", ms[0].Detail, want)
		}
	}

	// Once is once: a second run (the next start) changes nothing.
	again := count(`SELECT COUNT(*) FROM usage_events`)
	if err := runMigrations(db); err != nil {
		t.Fatal(err)
	}
	if count(`SELECT COUNT(*) FROM usage_events`) != again || count(`SELECT COUNT(*) FROM hub_migrations`) != 1 {
		t.Error("the migration ran twice")
	}
}

// A fresh database has nothing to remove: the migration records itself and
// deletes nothing.
func TestMigration1_FreshDatabase(t *testing.T) {
	s := newStore(t)
	ms, err := s.Migrations()
	if err != nil || len(ms) != 1 || ms[0].Detail != "{}" {
		t.Fatalf("hub_migrations on a fresh database = %+v, %v", ms, err)
	}
}
