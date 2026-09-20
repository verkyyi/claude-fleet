package store

import (
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// spendWindow is wide enough to hold everything the helpers below insert.
func spendWindow() Filter {
	return Filter{
		Account: AllAccounts,
		Start:   time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		End:     time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC),
	}
}

// evSpend is ev() with a branch, a source and its own hourly row.
func evSpend(account, endpoint, uuid, branch, source string, out int64) model.UsageEvent {
	e := ev(account, endpoint, uuid, out)
	e.GitBranch = branch
	e.Source = source
	e.SessionID = uuid // keep each event in its own hourly row
	return e
}

func seedIssueSpend(t *testing.T, s *Store, evs ...model.UsageEvent) {
	t.Helper()
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
}

// The distribution, the bucket that must never disappear, and the arithmetic a
// reader is entitled to check: attributed + unattributed = total.
func TestSpendByIssue_PartsSumToTheTotal(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	seedIssueSpend(t, s,
		evSpend("acc", "ep", "u1", "issue-57", "claude", 100),
		evSpend("acc", "ep", "u2", "issue-57", "claude", 50),
		evSpend("acc", "ep", "u3", "issue-58", "claude", 30),
		// Every family the rule refuses, so the bucket is not one shape.
		evSpend("acc", "ep", "u4", "scratch-94", "claude", 20),
		evSpend("acc", "ep", "u5", "HEAD", "claude", 7),
		evSpend("acc", "ep", "u6", "main", "claude", 3),
	)

	page, err := s.SpendByIssue(spendWindow(), 0)
	if err != nil {
		t.Fatal(err)
	}

	if len(page.Issues) != 2 {
		t.Fatalf("attributed issues = %d, want 2: %+v", len(page.Issues), page.Issues)
	}
	// Largest first: #57 carries 150 output tokens against #58's 30.
	if page.Issues[0].Number != 57 || page.Issues[1].Number != 58 {
		t.Errorf("order = %d, %d; want 57 then 58 (largest first)",
			page.Issues[0].Number, page.Issues[1].Number)
	}
	if page.Issues[0].Events != 2 {
		t.Errorf("issue 57 events = %d, want 2", page.Issues[0].Events)
	}

	// The invariant the whole package comment is about. Tokens first.
	if got, want := page.Attributed.Tokens+page.Unattributed.Tokens, page.Total.Tokens; got != want {
		t.Errorf("attributed+unattributed = %d tokens, total says %d", got, want)
	}
	if got, want := page.Attributed.Events+page.Unattributed.Events, page.Total.Events; got != want {
		t.Errorf("attributed+unattributed = %d events, total says %d", got, want)
	}
	if page.Unattributed.Events != 3 {
		t.Errorf("unattributed events = %d, want 3 (scratch-94, HEAD, main)", page.Unattributed.Events)
	}
	// And in money, per source, because that is the only way money sums here.
	a, _ := page.Attributed.Cost.Of("claude")
	u, _ := page.Unattributed.Cost.Of("claude")
	total, _ := page.Total.Cost.Of("claude")
	if got := a.CostUSD + u.CostUSD; got != total.CostUSD {
		t.Errorf("claude cost: attributed %v + unattributed %v = %v, total says %v",
			a.CostUSD, u.CostUSD, got, total.CostUSD)
	}
}

// The unattributed bucket is returned even when it is empty. A card that only
// ever sees it populated will not have a place to put it the day it is not.
func TestSpendByIssue_EmptyBucketIsStillPresent(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	seedIssueSpend(t, s, evSpend("acc", "ep", "u1", "issue-57", "claude", 10))

	page, err := s.SpendByIssue(spendWindow(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if page.Unattributed.Events != 0 || page.Unattributed.Tokens != 0 {
		t.Errorf("unattributed = %+v, want empty", page.Unattributed.SpendTotal)
	}
	if page.Unattributed.Branches == nil {
		t.Error("unattributed branches are nil; want an empty list so a renderer can iterate it")
	}
	if page.Total.Tokens != page.Attributed.Tokens {
		t.Errorf("total %d != attributed %d with nothing unattributed",
			page.Total.Tokens, page.Attributed.Tokens)
	}
}

// Why the bucket is 63% is answerable from the branch, which is what makes it
// explicable rather than merely disclosed.
func TestSpendByIssue_UnattributedBreaksDownByBranch(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	seedIssueSpend(t, s,
		evSpend("acc", "ep", "u1", "scratch-94", "claude", 100),
		evSpend("acc", "ep", "u2", "HEAD", "claude", 40),
		evSpend("acc", "ep", "u3", "issue-57", "claude", 999),
	)

	page, err := s.SpendByIssue(spendWindow(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Unattributed.Branches) != 2 {
		t.Fatalf("branches = %+v, want scratch-94 and HEAD", page.Unattributed.Branches)
	}
	if page.Unattributed.Branches[0].Branch != "scratch-94" {
		t.Errorf("largest unattributed branch = %q, want scratch-94",
			page.Unattributed.Branches[0].Branch)
	}
	for _, b := range page.Unattributed.Branches {
		if b.Branch == "issue-57" {
			t.Error("an attributed branch leaked into the unattributed breakdown")
		}
	}
}

// Truncation must not shrink the totals. A top-N that also totals only the
// visible rows is the flattering error this endpoint exists to prevent.
func TestSpendByIssue_LimitTruncatesRowsNotTotals(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	var evs []model.UsageEvent
	for i := 1; i <= 5; i++ {
		evs = append(evs, evSpend("acc", "ep",
			"u"+string(rune('a'+i)), "issue-"+strconv.Itoa(i), "claude", int64(i*10)))
	}
	seedIssueSpend(t, s, evs...)

	all, err := s.SpendByIssue(spendWindow(), 0)
	if err != nil {
		t.Fatal(err)
	}
	top, err := s.SpendByIssue(spendWindow(), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(top.Issues) != 2 {
		t.Fatalf("limit 2 returned %d rows", len(top.Issues))
	}
	if top.Distinct != 5 {
		t.Errorf("distinct_issues = %d, want 5: a truncated list must still say how long the tail is", top.Distinct)
	}
	if top.Attributed.Tokens != all.Attributed.Tokens {
		t.Errorf("truncation changed the attributed total: %d != %d",
			top.Attributed.Tokens, all.Attributed.Tokens)
	}
	if top.Total.Tokens != all.Total.Tokens {
		t.Errorf("truncation changed the grand total: %d != %d", top.Total.Tokens, all.Total.Tokens)
	}
}

// Cost comes back split, and the two kinds of money stay apart even when one
// issue carries both.
func TestSpendByIssue_KeepsSourcesApart(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	seedIssueSpend(t, s,
		evSpend("acc", "ep", "u1", "issue-57", "claude", 10),
		evSpend("acc", "ep", "u2", "issue-57", "gateway", 10),
	)

	page, err := s.SpendByIssue(spendWindow(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Issues) != 1 {
		t.Fatalf("issues = %+v, want one", page.Issues)
	}
	claude, ok := page.Issues[0].Cost.Of("claude")
	if !ok || claude.Events != 1 {
		t.Errorf("claude = %+v, want one event", claude)
	}
	gw, ok := page.Issues[0].Cost.Of("gateway")
	if !ok || gw.Events != 1 {
		t.Errorf("gateway = %+v, want one event", gw)
	}
	if claude.Kind == gw.Kind {
		t.Errorf("claude and gateway both report kind %q; notional and billed money must not read alike", claude.Kind)
	}
}

// The lifetime figure ignores the window on purpose: a branch named issue-57 is
// work on issue 57 whenever it happened.
func TestIssueLifetimeSpend_IgnoresTheWindow(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	old := evSpend("acc", "ep", "u1", "issue-57", "claude", 100)
	old.TS = time.Date(2026, 1, 2, 3, 0, 0, 0, time.UTC)
	recent := evSpend("acc", "ep", "u2", "issue-57", "claude", 5)
	seedIssueSpend(t, s, old, recent)

	// A window that excludes the older turn entirely.
	narrow := spendWindow()
	page, err := s.SpendByIssue(narrow, 0)
	if err != nil {
		t.Fatal(err)
	}
	if page.Issues[0].Tokens != 5 {
		t.Errorf("window tokens = %d, want 5 (the older turn is outside it)", page.Issues[0].Tokens)
	}

	life, err := s.IssueLifetimeSpend(AllAccounts, []int64{57})
	if err != nil {
		t.Fatal(err)
	}
	if life[57].Tokens != 105 {
		t.Errorf("lifetime tokens = %d, want 105: the lifetime figure is not clipped to a window", life[57].Tokens)
	}
}

// An issue nobody spent on is an absence, not a zero: the map simply has no
// entry, and a caller reading it gets a SpendTotal with no events.
func TestIssueLifetimeSpend_UnknownNumberIsAbsent(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	seedIssueSpend(t, s, evSpend("acc", "ep", "u1", "issue-57", "claude", 10))

	life, err := s.IssueLifetimeSpend(AllAccounts, []int64{57, 999})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := life[999]; ok {
		t.Error("issue 999 has an entry; an issue with no spend must be absent, not zero")
	}
	if life[999].Events != 0 || len(life[999].Cost) != 0 {
		t.Errorf("the zero value of a missing entry is %+v, want empty", life[999])
	}
}

// The empty account string is refused here for the same reason Filter refuses
// it: it is what an uninitialised variable looks like, and answering it by
// spanning every subscription would be a blend nobody asked for.
func TestIssueLifetimeSpend_RefusesTheEmptyAccount(t *testing.T) {
	s := newStore(t)
	if _, err := s.IssueLifetimeSpend("", []int64{57}); err == nil {
		t.Error("an empty account was accepted; want a refusal naming store.AllAccounts")
	}
	// No numbers is not an error, it is an empty answer.
	got, err := s.IssueLifetimeSpend("", nil)
	if err != nil || len(got) != 0 {
		t.Errorf("IssueLifetimeSpend(\"\", nil) = %v, %v; want an empty map and no error", got, err)
	}
}

// The join back from the spend side: the numbers come from branch names, and
// the backlog query has to answer for exactly those.
func TestRepoIssues_FilterByNumbers(t *testing.T) {
	s := newStore(t)
	now := time.Date(2026, 9, 19, 0, 0, 0, 0, time.UTC)
	if _, _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		Issues: []model.RepoIssue{
			{Number: 57, Title: "seam", State: model.RepoStateOpen, CreatedAt: now.AddDate(0, 0, -3)},
			{Number: 58, Title: "axis", State: model.RepoStateOpen, CreatedAt: now.AddDate(0, 0, -2)},
			{Number: 59, Title: "other", State: model.RepoStateOpen, CreatedAt: now.AddDate(0, 0, -1)},
		},
	}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.RepoIssues(RepoIssueFilter{Repo: "o/r", Numbers: []int64{57, 59, 4059}, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (#4059 is not in this repo and is simply absent)", len(rows))
	}
	if rows[0].Number != 57 || rows[1].Number != 59 {
		t.Errorf("got #%d, #%d; want #57, #59 oldest first", rows[0].Number, rows[1].Number)
	}
}

// The IN list is built from the caller's set, and the backlog read that feeds
// it accepts limit=1000. Pinning a set well past that is what stops a driver
// with a lower bind-parameter cap from turning a large repository's stalled
// list into a 500 nobody reproduces on a small one.
func TestIssueLifetimeSpend_HandlesALargeNumberSet(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	seedIssueSpend(t, s, evSpend("acc", "ep", "u1", "issue-57", "claude", 10))

	nums := make([]int64, 0, 5000)
	for i := 1; i <= 5000; i++ {
		nums = append(nums, int64(i))
	}
	got, err := s.IssueLifetimeSpend(AllAccounts, nums)
	if err != nil {
		t.Fatalf("5000 issue numbers: %v", err)
	}
	if got[57].Tokens == 0 {
		t.Error("issue 57 lost its spend in a large set")
	}
}
