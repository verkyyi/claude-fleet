package store

import (
	"database/sql"
	"errors"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestRetireEndpoint_KillsTheTokenAndKeepsTheHistory(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-1", "u1", 10)}); err != nil {
		t.Fatal(err)
	}

	if _, err := s.EndpointByTokenHash("hash-ep-1"); err != nil {
		t.Fatalf("token should work before retiring: %v", err)
	}

	changed, err := s.RetireEndpoint("ep-1")
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("retiring an active endpoint must report a change")
	}

	// The point of the feature: the token is dead everywhere at once, because
	// every enrollment-token path resolves through this one query.
	if _, err := s.EndpointByTokenHash("hash-ep-1"); err == nil {
		t.Fatal("a retired endpoint's enrollment token must stop resolving")
	}

	// ...and the history it already reported is untouched, so totals do not move.
	var events int64
	if err := s.DB().QueryRow(`SELECT COUNT(*) FROM usage_events WHERE endpoint_id='ep-1'`).
		Scan(&events); err != nil {
		t.Fatal(err)
	}
	if events == 0 {
		t.Fatal("retiring must not remove usage rows")
	}
}

func TestRetireEndpoint_SecondTimeIsANoOp(t *testing.T) {
	s := newStore(t)
	if err := s.Enroll("ep-1", "web-01", "hash-1"); err != nil {
		t.Fatal(err)
	}
	if changed, err := s.RetireEndpoint("ep-1"); err != nil || !changed {
		t.Fatalf("first retire: changed=%v err=%v", changed, err)
	}
	changed, err := s.RetireEndpoint("ep-1")
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("retiring an already-retired endpoint must report no change, " +
			"so the CLI can say so rather than claiming a success it did not cause")
	}
	if changed, err := s.RetireEndpoint("ep-nope"); err != nil || changed {
		t.Fatalf("retiring an unknown id: changed=%v err=%v", changed, err)
	}
}

func TestListEndpoints_HidesRetiredUnlessAsked(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	seedAccount(t, s, "acct-a", "ep-2")
	if _, err := s.RetireEndpoint("ep-2"); err != nil {
		t.Fatal(err)
	}

	active, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if ids := endpointIDs(active); len(ids) != 1 || ids[0] != "ep-1" {
		t.Fatalf("the roster, the stale-agent finding and the scope picker all read "+
			"this: a retired endpoint must not appear. got %v", ids)
	}

	all, err := s.ListEndpointsWithRetired("")
	if err != nil {
		t.Fatal(err)
	}
	ids := endpointIDs(all)
	if len(ids) != 2 {
		t.Fatalf("ListEndpointsWithRetired should show both, got %v", ids)
	}
	for _, e := range all {
		if e.ID == "ep-2" && e.RetiredAt == nil {
			t.Fatal("a retired endpoint must carry retired_at, or a caller cannot tell it apart")
		}
		if e.ID == "ep-1" && e.RetiredAt != nil {
			t.Fatal("an active endpoint must have no retired_at")
		}
	}
}

// TestRetiredEndpoint_KeepsItsNameInHistory is the promise retire makes, and
// it is easy to break: every "hide retired endpoints" filter is one line, and
// the label lookups read the same list the roster does. Drop retired rows
// there too and the spend survives with its name replaced by a raw ep_… id --
// technically still attributable, useless to read.
func TestRetiredEndpoint_KeepsItsNameInHistory(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-1", "u1", 10)}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RetireEndpoint("ep-1"); err != nil {
		t.Fatal(err)
	}

	bs, err := s.UsageBy("acct-a", ByEndpoint,
		time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), 10)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, b := range bs {
		if b.Key == "ep-1" {
			found = true
			if b.Label != "ep-1" {
				t.Fatalf("a retired endpoint's past spend lost its name: label=%q", b.Label)
			}
		}
	}
	if !found {
		t.Fatalf("retiring removed an endpoint's spend from the totals: %+v", bs)
	}

	// Its team must survive too, or retiring a machine silently moves last
	// month's spend off the budget that incurred it.
	all, err := s.ListEndpointsWithRetired("")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].Team != "platform" {
		t.Fatalf("team lost on retire: %+v", all)
	}
}

// TestListEnrollments_ShowsShippersToo is the gap that would have made this
// feature miss its own motivating case: the fleet roster filters to
// kind = 'agent', and a repo shipper retired through this CLI is exactly what
// issue #42 was about. A shipper missing here is a token whose id an operator
// cannot look up — back to editing the database by hand.
func TestListEnrollments_ShowsShippersToo(t *testing.T) {
	s := newStore(t)
	if err := s.Enroll("ep-agent", "web-01", "hash-a"); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep-ship", "verify-health-shipper", "hash-s"); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkRepoShipper("ep-ship"); err != nil {
		t.Fatal(err)
	}

	// The fleet roster excludes it, correctly — it is not a machine.
	roster, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if ids := endpointIDs(roster); len(ids) != 1 || ids[0] != "ep-agent" {
		t.Fatalf("the fleet roster should hold only the agent, got %v", ids)
	}

	// The operator inventory must include it, or it cannot be retired.
	inv, err := s.ListEnrollments(false)
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]Enrollment{}
	for _, e := range inv {
		byID[e.ID] = e
	}
	if len(inv) != 2 {
		t.Fatalf("`endpoint list` must show every kind, got %d: %+v", len(inv), inv)
	}
	if byID["ep-ship"].Kind != "repo_shipper" {
		t.Fatalf("the inventory must say what each token is, got %q", byID["ep-ship"].Kind)
	}
	if byID["ep-ship"].Label != "verify-health-shipper" {
		t.Fatalf("label = %q", byID["ep-ship"].Label)
	}

	// And retiring one works, and hides it from the default listing.
	if changed, err := s.RetireEndpoint("ep-ship"); err != nil || !changed {
		t.Fatalf("retire shipper: changed=%v err=%v", changed, err)
	}
	if _, err := s.EndpointByTokenHash("hash-s"); err == nil {
		t.Fatal("a retired shipper's token must stop resolving")
	}
	active, err := s.ListEnrollments(false)
	if err != nil {
		t.Fatal(err)
	}
	if len(active) != 1 || active[0].ID != "ep-agent" {
		t.Fatalf("retired shipper still in the default listing: %+v", active)
	}
	all, err := s.ListEnrollments(true)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("--all must show the retired shipper, got %+v", all)
	}
}

func TestDeleteEndpoint_RefusesOneThatHasReported(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-1", "u1", 10)}); err != nil {
		t.Fatal(err)
	}

	err := s.DeleteEndpoint("ep-1")
	var inUse *InUseError
	if !errors.As(err, &inUse) {
		t.Fatalf("deleting an endpoint whose spend is in the ledger must refuse, got %v", err)
	}
	if len(inUse.Footprint) == 0 {
		t.Fatal("the refusal must name what would have been orphaned")
	}
	var found bool
	for _, f := range inUse.Footprint {
		if f.Table == "usage_events" && f.Rows > 0 {
			found = true
		}
	}
	if !found {
		t.Fatalf("footprint should account for usage_events, got %v", inUse.Footprint)
	}

	// Still there, and still resolvable: a refusal must change nothing.
	if _, err := s.EndpointByID("ep-1"); err != nil {
		t.Fatalf("refused delete must leave the row: %v", err)
	}
}

func TestDeleteEndpoint_RemovesAMintThenAbandonEnrollment(t *testing.T) {
	s := newStore(t)
	// Exactly the incident in issue #42: a token minted for a shipper that was
	// never run, leaving a row nobody can explain.
	if err := s.Enroll("ep-verify", "verify-health-shipper", "hash-v"); err != nil {
		t.Fatal(err)
	}
	fp, err := s.EndpointFootprint("ep-verify")
	if err != nil {
		t.Fatal(err)
	}
	if len(fp) != 0 {
		t.Fatalf("an endpoint that never reported has no footprint, got %v", fp)
	}
	if err := s.DeleteEndpoint("ep-verify"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.EndpointByID("ep-verify"); !errors.Is(err, ErrNoSuchEndpoint) {
		t.Fatalf("after delete the id must name nothing, got %v", err)
	}
	if err := s.DeleteEndpoint("ep-verify"); !errors.Is(err, ErrNoSuchEndpoint) {
		t.Fatalf("deleting an unknown id must say so, got %v", err)
	}
}

func TestDeleteEndpoint_RefusesOnLastSeenAlone(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1") // TouchEndpoint sets last_seen, no events
	fp, err := s.EndpointFootprint("ep-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(fp) == 0 {
		// endpoint_accounts is written by TouchEndpoint, so this should not be
		// reachable -- but if the two ever disagree, the refusal below is what
		// has to hold.
		t.Log("no table footprint; last_seen is the only signal left")
	}
	if err := s.DeleteEndpoint("ep-1"); err == nil {
		t.Fatal("an endpoint that has reported must not be deletable")
	}
}

// TestMigrate_AddsRetiredAtToAnOlderDatabase covers the upgrade path, which is
// the only path most hubs will actually take.
//
// schema.sql is all CREATE TABLE IF NOT EXISTS, so on an existing database it
// does nothing at all — a new column only arrives through migrate(). Get that
// wrong and an upgraded hub does not fail loudly at startup; it fails on every
// query that mentions the column, which is every endpoint read there is.
//
// The fixture pre-creates `endpoints` WITHOUT retired_at, exactly as a hub
// running the previous release has it, then opens the store normally.
func TestMigrate_AddsRetiredAtToAnOlderDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")

	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// The pre-#42 shape: every column the previous release had, and no more.
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
		backfill_limit TEXT NOT NULL DEFAULT '')`); err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec(
		`INSERT INTO endpoints (endpoint_id, token_hash, label, enrolled_at)
		 VALUES ('ep-old', 'hash-old', 'web-01', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("opening a pre-#42 database must migrate it, not fail: %v", err)
	}
	defer s.Close()

	// The endpoint that predates the column reads as active, which is the only
	// correct answer for a row written before retiring existed.
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatalf("reading endpoints after migration: %v", err)
	}
	if len(eps) != 1 || eps[0].ID != "ep-old" || eps[0].RetiredAt != nil {
		t.Fatalf("migrated endpoint should be active, got %+v", eps)
	}
	if _, err := s.EndpointByTokenHash("hash-old"); err != nil {
		t.Fatalf("an existing token must keep working across the upgrade: %v", err)
	}
	// ...and the new verb works on it.
	if changed, err := s.RetireEndpoint("ep-old"); err != nil || !changed {
		t.Fatalf("retire on a migrated row: changed=%v err=%v", changed, err)
	}
	if _, err := s.EndpointByTokenHash("hash-old"); err == nil {
		t.Fatal("the migrated endpoint's token must stop resolving once retired")
	}
}

// TestEndpointRefTables_CoversSchema fails when a new table grows an
// endpoint_id column and nobody adds it to endpointRefTables.
//
// Without this the list rots silently in the one direction that matters:
// DeleteEndpoint would stop seeing a table, decide an endpoint is unused, and
// orphan its rows -- which is precisely what the refusal exists to prevent.
func TestEndpointRefTables_CoversSchema(t *testing.T) {
	known := map[string]bool{}
	for _, tbl := range endpointRefTables {
		known[tbl] = true
	}
	// endpoints itself owns the column as its primary key, not as a reference.
	known["endpoints"] = true

	var missing []string
	for _, tbl := range tablesWithEndpointID(t) {
		if !known[tbl] {
			missing = append(missing, tbl)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Fatalf("these tables carry endpoint_id but are not in endpointRefTables, "+
			"so DeleteEndpoint would orphan their rows: %v", missing)
	}
}

// tablesWithEndpointID reads the embedded schema rather than a live database:
// the point is to catch a table added to schema.sql, including one a test
// database would only create later.
func tablesWithEndpointID(t *testing.T) []string {
	t.Helper()
	var out []string
	re := regexp.MustCompile(`(?is)CREATE TABLE IF NOT EXISTS\s+(\w+)\s*\((.*?)\n\);`)
	for _, m := range re.FindAllStringSubmatch(schemaSQL, -1) {
		if strings.Contains(m[2], "endpoint_id") {
			out = append(out, m[1])
		}
	}
	if len(out) < 5 {
		t.Fatalf("schema scan found only %v — the regexp has stopped matching, "+
			"which would make this test pass for the wrong reason", out)
	}
	return out
}

func endpointIDs(eps []Endpoint) []string {
	out := make([]string, 0, len(eps))
	for _, e := range eps {
		out = append(out, e.ID)
	}
	sort.Strings(out)
	return out
}
