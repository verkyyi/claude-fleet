package store

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func intp(n int) *int { return &n }

func endpointByID(t *testing.T, s *Store, id string) Endpoint {
	t.Helper()
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range eps {
		if e.ID == id {
			return e
		}
	}
	t.Fatalf("endpoint %s not listed", id)
	return Endpoint{}
}

func TestTouchEndpoint_RecordsTheFleetVersion(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	seen := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	fv := &model.FleetVersion{
		Head: "0164208", Branch: "master", Behind: intp(12), Ahead: intp(0),
		Fetched: false, Verdict: "BEHIND", FollowVerdict: "STUCK",
		Follow: "on · no-daemon · … [STUCK]", ObservedAt: seen,
	}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v1", true, fv); err != nil {
		t.Fatal(err)
	}

	e := endpointByID(t, s, "ep-1")
	if e.FleetHead != "0164208" || e.FleetVerdict != "BEHIND" || e.FleetFollow != "STUCK" {
		t.Fatalf("fleet reading not stored: %+v", e)
	}
	if e.FleetBehind == nil || *e.FleetBehind != 12 {
		t.Fatalf("fleet_behind = %v, want 12", e.FleetBehind)
	}
	if e.FleetFetched {
		t.Error("fetched:false must survive the round trip; the roster says '(not fetched)' from it")
	}
	if e.FleetFollowText != "on · no-daemon · … [STUCK]" {
		t.Errorf("follow sentence = %q; it is the tooltip for the STUCK marker", e.FleetFollowText)
	}
	if e.FleetSeenAt == nil || !e.FleetSeenAt.Equal(seen) {
		t.Errorf("fleet_seen_at = %v, want the agent's observed_at %v", e.FleetSeenAt, seen)
	}
}

// The guest, limits and Codex batches of the same endpoint carry no reading.
// They must leave the last one in place, or the column would blank several
// times a minute -- the same rule cc_version follows.
func TestTouchEndpoint_BatchWithoutFleetVersionKeepsTheLastReading(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	fv := &model.FleetVersion{Head: "0164208", Behind: intp(3), Verdict: "BEHIND", Fetched: true,
		ObservedAt: time.Now().UTC()}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v1", true, fv); err != nil {
		t.Fatal(err)
	}
	// A guest batch (login=false) and a login batch from an agent too old to
	// report, both without the field.
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-b"), "v1", false, nil); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v0", true, nil); err != nil {
		t.Fatal(err)
	}

	e := endpointByID(t, s, "ep-1")
	if e.FleetHead != "0164208" || e.FleetBehind == nil || *e.FleetBehind != 3 || !e.FleetFetched {
		t.Fatalf("a batch without fleet_version cleared the reading: %+v", e)
	}
	if e.FleetSeenAt == nil {
		t.Fatal("fleet_seen_at was cleared by a batch that did not carry a reading")
	}
}

// behind:null is "could not read the count", and it MUST come back as nil --
// storing it as 0 says "current" about an install nobody measured
// (claude-fleet#635).
func TestTouchEndpoint_FleetBehindNullStaysNull(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	// First a real count, so the test proves null OVERWRITES rather than
	// merely "starts out nil".
	known := &model.FleetVersion{Head: "aaaaaaa", Behind: intp(5), Verdict: "BEHIND", ObservedAt: time.Now().UTC()}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v1", true, known); err != nil {
		t.Fatal(err)
	}
	unknown := &model.FleetVersion{Head: "bbbbbbb", Behind: nil, Verdict: "UNKNOWN",
		Error: "no upstream configured", ObservedAt: time.Now().UTC()}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v1", true, unknown); err != nil {
		t.Fatal(err)
	}

	e := endpointByID(t, s, "ep-1")
	if e.FleetHead != "bbbbbbb" || e.FleetVerdict != "UNKNOWN" {
		t.Fatalf("the unknown reading did not replace the known one: %+v", e)
	}
	if e.FleetBehind != nil {
		t.Fatalf("fleet_behind = %d, want nil: null is 'unknown', never 0", *e.FleetBehind)
	}
	if e.FleetError != "no upstream configured" {
		t.Errorf("error text = %q; it is the tooltip that explains the unknown", e.FleetError)
	}
	var raw sql.NullInt64
	if err := s.read.QueryRow(`SELECT fleet_behind FROM endpoints WHERE endpoint_id = 'ep-1'`).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if raw.Valid {
		t.Fatalf("fleet_behind stored as %d, want SQL NULL", raw.Int64)
	}
}

// An endpoint that never reported reads as "no reading", which is different
// from "a reading whose count is unknown": the roster draws a dash for the
// first and "unknown" for the second.
func TestEndpoint_NeverReportedFleetVersionIsEmpty(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	e := endpointByID(t, s, "ep-1")
	if e.FleetHead != "" || e.FleetBehind != nil || e.FleetVerdict != "" || e.FleetSeenAt != nil {
		t.Fatalf("never-reported endpoint carries a fleet reading: %+v", e)
	}
}

func TestMigrate_AddsFleetColumnsToAnOlderDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")

	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// The pre-#157 shape: every endpoints column the previous release had.
	if _, err := old.Exec(`CREATE TABLE endpoints (
		endpoint_id TEXT PRIMARY KEY, account_uuid TEXT, hostname TEXT NOT NULL DEFAULT '',
		os TEXT NOT NULL DEFAULT '', arch TEXT NOT NULL DEFAULT '',
		machine_id TEXT NOT NULL DEFAULT '', cc_version TEXT NOT NULL DEFAULT '',
		agent_version TEXT NOT NULL DEFAULT '', token_hash TEXT NOT NULL,
		label TEXT NOT NULL DEFAULT '', os_user TEXT NOT NULL DEFAULT '',
		kind TEXT NOT NULL DEFAULT 'agent', team TEXT NOT NULL DEFAULT '',
		enrolled_at TEXT NOT NULL, last_seen TEXT,
		limits_unavailable TEXT NOT NULL DEFAULT '', limits_checked_at TEXT,
		dropped_pre_account INTEGER NOT NULL DEFAULT 0, earliest_dropped TEXT,
		dropped_beyond_backfill INTEGER NOT NULL DEFAULT 0,
		backfill_limit TEXT NOT NULL DEFAULT '', retired_at TEXT)`); err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec(
		`INSERT INTO endpoints (endpoint_id, token_hash, label, enrolled_at)
		 VALUES ('ep-old', 'hash-old', 'macmini', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("opening a pre-#157 database must migrate it, not fail: %v", err)
	}
	defer s.Close()

	e := endpointByID(t, s, "ep-old")
	if e.FleetHead != "" || e.FleetBehind != nil || e.FleetSeenAt != nil {
		t.Fatalf("a row written before the columns existed must read as never reported: %+v", e)
	}
	// And the migrated table accepts a reading.
	if err := s.UpsertAccount(ident("acct-a"), "max", ""); err != nil {
		t.Fatal(err)
	}
	fv := &model.FleetVersion{Head: "0164208", Behind: intp(28), Verdict: "BEHIND", ObservedAt: time.Now().UTC()}
	if _, _, err := s.TouchEndpoint("ep-old", ident("acct-a"), "v1", true, fv); err != nil {
		t.Fatal(err)
	}
	if e := endpointByID(t, s, "ep-old"); e.FleetBehind == nil || *e.FleetBehind != 28 {
		t.Fatalf("reading after migration = %+v, want behind 28", e)
	}
}
