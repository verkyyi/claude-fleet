package store

import (
	"fmt"
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
		if ok, err := s.d.tableExists(db, tbl); err != nil || ok {
			t.Errorf("table %s survived (%v)", tbl, err)
		}
	}
	if n := count(`SELECT COUNT(*) FROM endpoints WHERE kind != 'agent' AND retired_at IS NULL`); n != 0 {
		t.Errorf("%d shipper enrollments still authenticate", n)
	}
	ms, err := s.Migrations()
	if err != nil || len(ms) != len(migrations) || ms[0].ID != 1 {
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
	if count(`SELECT COUNT(*) FROM usage_events`) != again || count(`SELECT COUNT(*) FROM hub_migrations`) != len(migrations) {
		t.Error("the migration ran twice")
	}
}

// A fresh database has nothing to remove: the migration records itself and
// deletes nothing.
func TestMigration1_FreshDatabase(t *testing.T) {
	s := newStore(t)
	ms, err := s.Migrations()
	if err != nil || len(ms) != len(migrations) || ms[0].Detail != "{}" {
		t.Fatalf("hub_migrations on a fresh database = %+v, %v", ms, err)
	}
}

// Migration 1 on a database with its foreign keys enforced and a child row
// under every removed-source account (claude-fleet#2050): production's
// endpoints still pointed at the gateway / voice accounts, and the bare
// DELETE FROM accounts died on FOREIGN KEY constraint failed (787). The
// migration walks PRAGMA foreign_key_list itself — a nullable reference lets
// go of the removed account, a NOT NULL one goes with it, its own children
// first — and every row that belongs to Claude or Codex stays.
func TestMigration1_ForeignKeysHold(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep-claude")
	db := s.DB()
	now := fmtTime(time.Now())
	for _, q := range []string{
		`INSERT INTO accounts (account_uuid, source, first_seen, last_seen) VALUES
			('gw', 'gateway', '` + now + `', '` + now + `'),
			('bill', 'vendor_bill', '` + now + `', '` + now + `'),
			('vox', 'voice', '` + now + `', '` + now + `')`,
		// Every table that references accounts gets a child of a removed one:
		// endpoints (nullable, in schema.sql) and one with a NOT NULL reference
		// that has a grandchild of its own.
		`CREATE TABLE acct_children (id TEXT PRIMARY KEY, account_uuid TEXT NOT NULL REFERENCES accounts(account_uuid))`,
		`CREATE TABLE acct_grandchildren (id TEXT PRIMARY KEY, child_id TEXT NOT NULL REFERENCES acct_children(id))`,
		`INSERT INTO acct_children VALUES ('c-claude', 'acct'), ('c-gw', 'gw'), ('c-vox', 'vox')`,
		`INSERT INTO acct_grandchildren VALUES ('g-claude', 'c-claude'), ('g-gw', 'c-gw')`,
		`DELETE FROM hub_migrations`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for ep, acct := range map[string]string{"ep-gw": "gw", "ep-bill": "bill", "ep-vox": "vox"} {
		if err := s.Enroll(ep, ep, "hash-"+ep); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`UPDATE endpoints SET account_uuid = ? WHERE endpoint_id = ?`, acct, ep); err != nil {
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
	before := map[string]int{
		"endpoints": count(`SELECT COUNT(*) FROM endpoints`),
		"claude":    count(`SELECT COUNT(*) FROM accounts WHERE source = 'claude'`),
	}

	if err := runMigrations(db); err != nil {
		t.Fatal(err)
	}

	if n := count(`SELECT COUNT(*) FROM accounts WHERE source IN ('gateway', 'vendor_bill', 'voice')`); n != 0 {
		t.Errorf("%d removed-source accounts survived", n)
	}
	if got := count(`SELECT COUNT(*) FROM accounts WHERE source = 'claude'`); got != before["claude"] {
		t.Errorf("claude accounts: %d after, %d before", got, before["claude"])
	}
	if got := count(`SELECT COUNT(*) FROM endpoints`); got != before["endpoints"] {
		t.Errorf("endpoints: %d after, %d before — a nullable reference must let go, not delete", got, before["endpoints"])
	}
	if n := count(`SELECT COUNT(*) FROM endpoints WHERE endpoint_id IN ('ep-gw', 'ep-bill', 'ep-vox') AND account_uuid IS NOT NULL`); n != 0 {
		t.Errorf("%d endpoints still point at a removed account", n)
	}
	if n := count(`SELECT COUNT(*) FROM endpoints WHERE endpoint_id = 'ep-claude' AND account_uuid = 'acct'`); n != 1 {
		t.Error("the claude endpoint lost its account")
	}
	if got := count(`SELECT COUNT(*) FROM acct_children`); got != 1 {
		t.Errorf("acct_children: %d rows, want only c-claude", got)
	}
	if got := count(`SELECT COUNT(*) FROM acct_grandchildren`); got != 1 {
		t.Errorf("acct_grandchildren: %d rows, want only g-claude", got)
	}
	// Postgres checks every foreign key on every write, so only SQLite (which
	// checks them only while foreign_keys is on) has anything to ask.
	if s.d.pg() {
		return
	}
	if n := count(`SELECT COUNT(*) FROM pragma_foreign_key_check`); n != 0 {
		t.Errorf("%d foreign key violations after the migration", n)
	}
}

// Migration 2 (claude-fleet#3603): a people list keyed on github_id becomes
// one keyed on the principal, every person the same gh:<id> they were — row
// for row, field for field — with a github identity each, and nothing else
// on the list moves. Twice is once.
func TestMigration2_HubUsersKeepEveryone(t *testing.T) {
	s := newStore(t)
	db := s.DB()
	last := "2026-10-01T08:00:00Z"
	for _, q := range []string{
		`DROP TABLE hub_users`,
		s.d.ddl(`CREATE TABLE hub_users (
  github_id     INTEGER PRIMARY KEY,
  login         TEXT NOT NULL,
  role          TEXT NOT NULL,
  machine_login TEXT NOT NULL DEFAULT '',
  added_by      TEXT NOT NULL DEFAULT '',
  added_at      TEXT NOT NULL,
  last_seen     TEXT
)`),
		`INSERT INTO hub_users VALUES (100, 'verkyyi', 'admin', 'verky', 'deploy', '2026-01-02T03:04:05Z', '` + last + `')`,
		`INSERT INTO hub_users VALUES (3002, 'vincentgh', 'user', '', 'verkyyi (gh:100)', '2026-02-03T04:05:06Z', NULL)`,
		`DELETE FROM hub_migrations WHERE id = 2`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	type snap struct {
		Login, Role, Machine, AddedBy, Added string
		Last                                 bool
	}
	want := map[int64]snap{
		100:  {"verkyyi", "admin", "verky", "deploy", "2026-01-02T03:04:05Z", true},
		3002: {"vincentgh", "user", "", "verkyyi (gh:100)", "2026-02-03T04:05:06Z", false},
	}
	for i := 0; i < 2; i++ {
		if err := runMigrations(db); err != nil {
			t.Fatal(err)
		}
	}
	for id, w := range want {
		u, err := s.HubUserByID(id)
		if err != nil || u == nil {
			t.Fatalf("GitHub ID %d after the migration: %+v, %v", id, u, err)
		}
		pid := fmt.Sprintf("gh:%d", id)
		got := snap{u.Login, u.Role, u.MachineLogin, u.AddedBy, u.AddedAt.UTC().Format(time.RFC3339), u.LastSeen != nil}
		if u.PrincipalID != pid || got != w {
			t.Errorf("GitHub ID %d: %s %+v, want %s %+v", id, u.PrincipalID, got, pid, w)
		}
		if by, _ := s.HubUserByPrincipal(pid); by == nil || by.GitHubID != id {
			t.Errorf("%s by principal: %+v", pid, by)
		}
		if owner, err := s.IdentityPrincipal(IdentityGitHub, fmt.Sprint(id)); err != nil || owner != pid {
			t.Errorf("github identity %d lets in %q (%v), want %s", id, owner, err, pid)
		}
	}
	if users, _ := s.HubUsers(); len(users) != 2 {
		t.Errorf("the list has %d people after the migration, want 2", len(users))
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM hub_identities`).Scan(&n); err != nil || n != 2 {
		t.Errorf("%d identities (%v), want one per person", n, err)
	}
	// The new shape takes a person with no GitHub.
	if err := s.UpsertHubUser(HubUser{PrincipalID: "p:0f0f0f0f-0000-4000-8000-000000000001", Login: "Alice", Role: RoleUser}); err != nil {
		t.Fatalf("a person with no GitHub: %v", err)
	}
}

// Identities: one way lets in one person; a person keeps at least one.
func TestHubIdentities(t *testing.T) {
	s := newStore(t)
	a, b := "p:0f0f0f0f-0000-4000-8000-00000000000a", "p:0f0f0f0f-0000-4000-8000-00000000000b"
	if err := s.AddHubIdentity(HubIdentity{Kind: IdentityEmail, Subject: "Alice@Example.com ", PrincipalID: a}); err != nil {
		t.Fatal(err)
	}
	if pid, _ := s.IdentityPrincipal(IdentityEmail, "alice@example.COM"); pid != a {
		t.Fatalf("the address lets in %q, want %s (case folds)", pid, a)
	}
	if err := s.AddHubIdentity(HubIdentity{Kind: IdentityEmail, Subject: "alice@example.com", PrincipalID: b}); err != ErrIdentityTaken {
		t.Fatalf("another person took the same address: %v", err)
	}
	if _, err := s.RemoveHubIdentity(a, IdentityEmail, "alice@example.com"); err != ErrLastIdentity {
		t.Fatalf("removed the only way in: %v", err)
	}
	if err := s.AddHubIdentity(HubIdentity{Kind: IdentityGitHub, Subject: "777", PrincipalID: a}); err != nil {
		t.Fatal(err)
	}
	if ids, _ := s.HubIdentities(a); len(ids) != 2 || ids[0].Kind != IdentityEmail || ids[1].Kind != IdentityGitHub {
		t.Fatalf("identities = %+v", ids)
	}
	if ok, err := s.RemoveHubIdentity(a, IdentityEmail, "ALICE@example.com"); !ok || err != nil {
		t.Fatalf("remove one of two: %v %v", ok, err)
	}
	if ok, err := s.RemoveHubIdentity(b, IdentityGitHub, "777"); ok || err != nil {
		t.Fatalf("someone else removed a's GitHub: %v %v", ok, err)
	}
	if err := s.AddHubIdentity(HubIdentity{Kind: "myspace", Subject: "x", PrincipalID: a}); err == nil {
		t.Fatal("an unknown kind was taken")
	}
}
