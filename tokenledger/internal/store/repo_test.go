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

func dayAt(s string) time.Time {
	t, err := time.Parse(model.RepoDayLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

func tsAt(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

func ptrT(t time.Time) *time.Time { return &t }
func ptrF(f float64) *float64     { return &f }
func ptrI(i int) *int             { return &i }

// issue builds an open issue created at created.
func issue(n int, created string) model.RepoIssue {
	return model.RepoIssue{Number: n, Title: "issue", State: model.RepoStateOpen, CreatedAt: tsAt(created)}
}

// closedIssue builds one that closed at closed.
func closedIssue(n int, created, closed string) model.RepoIssue {
	i := issue(n, created)
	i.State = model.RepoStateClosed
	i.ClosedAt = ptrT(tsAt(closed))
	return i
}

func TestRepoSnapshot_RoundTrips(t *testing.T) {
	s := newStore(t)
	snap := model.RepoSnapshot{
		Repo:       "verkyyi/tokenledger",
		ObservedAt: tsAt("2026-09-14T00:00:00Z"),
		Issues: []model.RepoIssue{{
			Number: 32, Title: "repo progress", State: model.RepoStateOpen,
			CreatedAt: tsAt("2026-09-01T10:00:00Z"),
			UpdatedAt: ptrT(tsAt("2026-09-13T10:00:00Z")),
			Labels:    []string{"enhancement", "a11y"},
			Comments:  3, URL: "https://github.com/verkyyi/tokenledger/issues/32",
		}},
		Days: []model.RepoDay{{
			Day: "2026-09-13", Opened: 4, Closed: 6, OpenAtEnd: 431,
			MergedPRs: ptrI(5), CloseP95Seconds: ptrF(941760), ClosedSample: ptrI(2257),
		}},
	}
	if _, err := s.UpsertRepoSnapshot(snap); err != nil {
		t.Fatal(err)
	}

	rows, err := s.RepoIssues(RepoIssueFilter{Repo: "verkyyi/tokenledger", Now: tsAt("2026-09-14T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("want 1 issue, got %d", len(rows))
	}
	got := rows[0]
	if got.Number != 32 || got.Comments != 3 || got.URL == "" {
		t.Errorf("issue did not round-trip: %+v", got)
	}
	// Labels are stored sorted so an unchanged issue re-ships as a no-op.
	if len(got.Labels) != 2 || got.Labels[0] != "a11y" || got.Labels[1] != "enhancement" {
		t.Errorf("labels = %v, want sorted [a11y enhancement]", got.Labels)
	}
	if want := 13 * 24 * 3600.0; got.AgeSeconds != want-10*3600 {
		t.Errorf("age = %v seconds, want %v", got.AgeSeconds, want-10*3600)
	}

	days, err := s.RepoDays("verkyyi/tokenledger", dayAt("2026-09-01"), dayAt("2026-09-15"))
	if err != nil {
		t.Fatal(err)
	}
	if len(days) != 1 || days[0].OpenAtEnd != 431 || *days[0].MergedPRs != 5 {
		t.Fatalf("day did not round-trip: %+v", days)
	}
}

// The same snapshot arriving twice — a shipper retry, or a backlog paged
// across several POSTs — must not double anything. Nothing here is additive
// for exactly this reason.
func TestRepoSnapshot_ReplayIsANoOp(t *testing.T) {
	s := newStore(t)
	snap := model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-14T00:00:00Z"),
		Issues: []model.RepoIssue{issue(1, "2026-09-01T00:00:00Z")},
		Days:   []model.RepoDay{{Day: "2026-09-13", Opened: 2, Closed: 1, OpenAtEnd: 10}},
	}
	for i := 0; i < 3; i++ {
		if _, err := s.UpsertRepoSnapshot(snap); err != nil {
			t.Fatal(err)
		}
	}
	rows, _ := s.RepoIssues(RepoIssueFilter{Repo: "o/r"})
	if len(rows) != 1 {
		t.Errorf("replay created %d issue rows, want 1", len(rows))
	}
	days, _ := s.RepoDays("o/r", dayAt("2026-09-01"), dayAt("2026-09-20"))
	if len(days) != 1 || days[0].Opened != 2 {
		t.Errorf("replay disturbed the day row: %+v", days)
	}
}

// Snapshots can arrive out of order after a shipper retries. A stale one must
// never overwrite a newer one — it would silently reopen a closed issue, and
// nothing downstream could tell that from a real reopen.
func TestRepoSnapshot_OlderObservationNeverOverwrites(t *testing.T) {
	s := newStore(t)
	repo := "o/r"
	fresh := model.RepoSnapshot{
		Repo: repo, ObservedAt: tsAt("2026-09-14T12:00:00Z"),
		Issues: []model.RepoIssue{closedIssue(7, "2026-09-01T00:00:00Z", "2026-09-14T09:00:00Z")},
	}
	stale := model.RepoSnapshot{
		Repo: repo, ObservedAt: tsAt("2026-09-14T06:00:00Z"),
		Issues: []model.RepoIssue{issue(7, "2026-09-01T00:00:00Z")},
	}
	if _, err := s.UpsertRepoSnapshot(fresh); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertRepoSnapshot(stale); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.RepoIssues(RepoIssueFilter{Repo: repo})
	if len(rows) != 1 || rows[0].State != model.RepoStateClosed {
		t.Fatalf("stale snapshot reopened the issue: %+v", rows)
	}
}

// An open issue's age runs to now; a closed one's stops at closed_at. Storing
// the number instead of deriving it would make every open row wrong by the
// time anybody read it.
func TestRepoIssues_AgeStopsAtClose(t *testing.T) {
	s := newStore(t)
	now := tsAt("2026-09-14T00:00:00Z")
	_, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		Issues: []model.RepoIssue{
			issue(1, "2026-09-04T00:00:00Z"),
			closedIssue(2, "2026-09-04T00:00:00Z", "2026-09-05T00:00:00Z"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	rows, err := s.RepoIssues(RepoIssueFilter{Repo: "o/r", Now: now})
	if err != nil {
		t.Fatal(err)
	}
	byNum := map[int]RepoIssueRow{}
	for _, r := range rows {
		byNum[r.Number] = r
	}
	if got := byNum[1].AgeSeconds; got != 10*24*3600 {
		t.Errorf("open issue age = %v, want 10 days", got)
	}
	if got := byNum[2].AgeSeconds; got != 24*3600 {
		t.Errorf("closed issue age = %v, want 1 day", got)
	}
}

// The stalled list is only useful if the cutoff is applied before the LIMIT.
// Filtering afterwards returns a page and then empties most of it.
func TestRepoIssues_MinAgeIsAppliedBeforeLimit(t *testing.T) {
	s := newStore(t)
	now := tsAt("2026-09-14T00:00:00Z")
	var issues []model.RepoIssue
	// Ten recent issues, then two old ones. Sorted oldest-first, the old pair
	// leads — but only because the cutoff ran in SQL.
	for n := 1; n <= 10; n++ {
		issues = append(issues, issue(n, "2026-09-13T00:00:00Z"))
	}
	issues = append(issues, issue(90, "2026-06-01T00:00:00Z"), issue(91, "2026-06-02T00:00:00Z"))
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{Repo: "o/r", ObservedAt: now, Issues: issues}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.RepoIssues(RepoIssueFilter{
		Repo: "o/r", State: model.RepoStateOpen,
		MinAgeSeconds: 30 * 24 * 3600, Limit: 5, Now: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].Number != 90 || rows[1].Number != 91 {
		t.Fatalf("want the two old issues oldest-first, got %+v", rows)
	}
}

// Percentiles are what every age judgement scales to, so "nobody computed
// them" has to be a distinguishable answer. A hub that substituted a constant
// would print a confident badge derived from a number nobody measured.
func TestRepoCloseScale_AbsentIsNotZero(t *testing.T) {
	s := newStore(t)
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-14T00:00:00Z"),
		Days: []model.RepoDay{{Day: "2026-09-13", Opened: 1, Closed: 1, OpenAtEnd: 5}},
	}); err != nil {
		t.Fatal(err)
	}
	sc, err := s.RepoCloseScale("o/r")
	if err != nil {
		t.Fatal(err)
	}
	if sc != nil {
		t.Fatalf("a day row with no percentiles reported a scale: %+v", sc)
	}

	// A later day that does carry them wins; an earlier one that does not must
	// not shadow it.
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		Days: []model.RepoDay{
			{Day: "2026-09-12", Opened: 1, Closed: 1, OpenAtEnd: 5, CloseP95Seconds: ptrF(100)},
			{Day: "2026-09-14", Opened: 1, Closed: 1, OpenAtEnd: 5,
				CloseP50Seconds: ptrF(11232), CloseP95Seconds: ptrF(941760), ClosedSample: ptrI(2257)},
		},
	}); err != nil {
		t.Fatal(err)
	}
	sc, err = s.RepoCloseScale("o/r")
	if err != nil {
		t.Fatal(err)
	}
	if sc == nil || sc.Day != "2026-09-14" || *sc.P95Seconds != 941760 || *sc.ClosedSample != 2257 {
		t.Fatalf("scale = %+v, want the 09-14 row", sc)
	}
	if sc.P90Seconds != nil {
		t.Errorf("p90 was absent in the source row but came back as %v", *sc.P90Seconds)
	}
}

// Retention bounds the per-issue table and never the day rows. Losing
// per-issue detail is the deal; losing a count is not.
func TestPruneRepoIssues_KeepsOpenAndEveryDayRow(t *testing.T) {
	s := newStore(t)
	now := tsAt("2026-09-14T00:00:00Z")
	_, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		Issues: []model.RepoIssue{
			issue(1, "2026-01-01T00:00:00Z"),                               // open, seen today
			closedIssue(2, "2026-01-01T00:00:00Z", "2026-01-05T00:00:00Z"), // closed long ago
			closedIssue(3, "2026-09-01T00:00:00Z", "2026-09-13T00:00:00Z"), // closed recently
		},
		Days: []model.RepoDay{{Day: "2026-01-05", Opened: 0, Closed: 1, OpenAtEnd: 9}},
	})
	if err != nil {
		t.Fatal(err)
	}
	n, err := s.PruneRepoIssues(now.AddDate(0, 0, -90))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("pruned %d rows, want 1 (the long-closed issue)", n)
	}
	rows, _ := s.RepoIssues(RepoIssueFilter{Repo: "o/r", Now: now})
	if len(rows) != 2 {
		t.Fatalf("want the open and recently-closed issues left, got %+v", rows)
	}
	days, _ := s.RepoDays("o/r", dayAt("2026-01-01"), dayAt("2026-09-20"))
	if len(days) != 1 {
		t.Errorf("pruning deleted a day row; day rows are the long-term record: %+v", days)
	}
}

// An open issue that stops appearing in snapshots was deleted, transferred or
// made private upstream. Keeping it would leave a permanent phantom at the top
// of the stalled list, which is where a wrong row does the most damage.
func TestPruneRepoIssues_DropsOpenIssuesNobodySeesAnyMore(t *testing.T) {
	s := newStore(t)
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-01-02T00:00:00Z"),
		Issues: []model.RepoIssue{issue(1, "2026-01-01T00:00:00Z")},
	}); err != nil {
		t.Fatal(err)
	}
	n, err := s.PruneRepoIssues(tsAt("2026-09-14T00:00:00Z").AddDate(0, 0, -90))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("pruned %d rows, want the unseen open issue", n)
	}
}

func TestRepos_ListsReposWithOnlyDayRows(t *testing.T) {
	s := newStore(t)
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/day-only", ObservedAt: tsAt("2026-09-14T00:00:00Z"),
		Days: []model.RepoDay{{Day: "2026-09-13", Opened: 1, Closed: 1, OpenAtEnd: 3}},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/issues-only", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		Issues: []model.RepoIssue{issue(1, "2026-09-01T00:00:00Z"), closedIssue(2, "2026-09-01T00:00:00Z", "2026-09-02T00:00:00Z")},
	}); err != nil {
		t.Fatal(err)
	}
	repos, err := s.Repos()
	if err != nil {
		t.Fatal(err)
	}
	if len(repos) != 2 {
		t.Fatalf("want both repos, got %+v", repos)
	}
	// Most recently observed first.
	if repos[0].Repo != "o/issues-only" || repos[0].Open != 1 || repos[0].Issues != 2 {
		t.Errorf("issues-only row wrong: %+v", repos[0])
	}
	if repos[1].Repo != "o/day-only" || repos[1].Days != 1 || repos[1].LastDay != "2026-09-13" {
		t.Errorf("day-only row wrong: %+v", repos[1])
	}
}

// The repo string is a primary-key component. Three spellings of one
// repository would become three tenants that never reconcile, and a shipper's
// typo would be invisible rather than loud.
func TestValidateSnapshot_RejectsWhatCannotBeStoredHonestly(t *testing.T) {
	now := tsAt("2026-09-14T00:00:00Z")
	base := func() model.RepoSnapshot {
		return model.RepoSnapshot{
			Repo: "o/r", ObservedAt: now,
			Issues: []model.RepoIssue{issue(1, "2026-09-01T00:00:00Z")},
		}
	}
	cases := map[string]func(*model.RepoSnapshot){
		"no repo":             func(s *model.RepoSnapshot) { s.Repo = "" },
		"not owner/name":      func(s *model.RepoSnapshot) { s.Repo = "tokenledger" },
		"url spelling":        func(s *model.RepoSnapshot) { s.Repo = "https://github.com/o/r" },
		"no observed_at":      func(s *model.RepoSnapshot) { s.ObservedAt = time.Time{} },
		"future observed_at":  func(s *model.RepoSnapshot) { s.ObservedAt = now.Add(time.Hour) },
		"empty snapshot":      func(s *model.RepoSnapshot) { s.Issues = nil },
		"issue number zero":   func(s *model.RepoSnapshot) { s.Issues[0].Number = 0 },
		"unknown state":       func(s *model.RepoSnapshot) { s.Issues[0].State = "merged" },
		"closed without time": func(s *model.RepoSnapshot) { s.Issues[0].State = model.RepoStateClosed },
		"open with closed_at": func(s *model.RepoSnapshot) { s.Issues[0].ClosedAt = ptrT(now) },
		"closed before open": func(s *model.RepoSnapshot) {
			s.Issues[0].State = model.RepoStateClosed
			s.Issues[0].ClosedAt = ptrT(tsAt("2026-08-01T00:00:00Z"))
		},
		"day is not a day": func(s *model.RepoSnapshot) {
			s.Days = []model.RepoDay{{Day: "2026-09-13T00:00:00Z"}}
		},
		"negative count": func(s *model.RepoSnapshot) {
			s.Days = []model.RepoDay{{Day: "2026-09-13", Opened: -1}}
		},
		"negative percentile": func(s *model.RepoSnapshot) {
			s.Days = []model.RepoDay{{Day: "2026-09-13", CloseP95Seconds: ptrF(-1)}}
		},
	}
	for name, mutate := range cases {
		snap := base()
		mutate(&snap)
		if err := snap.Validate(now); err == nil {
			t.Errorf("%s: accepted, want rejected", name)
		}
	}
	if err := base().Validate(now); err != nil {
		t.Errorf("a valid snapshot was rejected: %v", err)
	}
}

// Upgrading a hub must not empty its fleet roster.
//
// ListEndpoints now filters on endpoints.kind, a column that does not exist in
// any database predating repo progress. If the ALTER did not backfill the
// default onto existing rows, every machine an operator already runs would
// vanish from the roster and from every finding on the first restart — a
// silent, total loss of the surface this tool started as.
func TestMigrateEndpointKind_ExistingEndpointsStayInTheFleet(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	oldSchema := regexp.MustCompile(`(?m)^\s+kind\s+TEXT NOT NULL DEFAULT 'agent',\n`).ReplaceAllString(schemaSQL, "")
	if strings.Contains(oldSchema, "kind          TEXT") {
		t.Fatalf("fixture still declares endpoints.kind; the schema shape changed")
	}
	if _, err := db.Exec(oldSchema + `
		INSERT INTO endpoints(endpoint_id, token_hash, label, enrolled_at)
		VALUES ('ep-1', 'h1', 'laptop', '2026-09-01T00:00:00Z');`); err != nil {
		t.Fatal(err)
	}
	db.Close()

	s, err := Open(path) // runs migrate()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if len(eps) != 1 || eps[0].Label != "laptop" {
		t.Fatalf("pre-existing endpoint disappeared after migration: %+v", eps)
	}
}

// A shipper leaves the roster but must stay authenticable: the two lookups are
// separate on purpose, and collapsing them would lock a shipper out of the
// endpoint it just identified itself as.
func TestMarkRepoShipper_LeavesTheRosterButKeepsTheToken(t *testing.T) {
	s := newStore(t)
	if err := s.Enroll("ep-ship", "shipper", "hash-1"); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep-agent", "laptop", "hash-2"); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkRepoShipper("ep-ship"); err != nil {
		t.Fatal(err)
	}
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if len(eps) != 1 || eps[0].ID != "ep-agent" {
		t.Fatalf("roster = %+v, want only the collecting endpoint", eps)
	}
	ep, err := s.EndpointByTokenHash("hash-1")
	if err != nil || ep.ID != "ep-ship" {
		t.Fatalf("the shipper can no longer authenticate: %+v %v", ep, err)
	}
}
