package store

import (
	"strings"
	"testing"
	"time"
)

func TestFilterWhereRefusesEmptyAccount(t *testing.T) {
	_, _, err := (Filter{}).where("ts")
	if err == nil {
		t.Fatal("empty account must be refused")
	}
}

func TestFilterWhereAllAccountsHasNoAccountClause(t *testing.T) {
	f := Filter{Account: AllAccounts, Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC()}
	clause, args, err := f.where("ts")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(clause, "account_uuid") {
		t.Fatalf("spanning filter must not scope by account: %s", clause)
	}
	if len(args) != 2 {
		t.Fatalf("want 2 time args, got %v", args)
	}
}

func TestFilterWhereIncludesEveryChip(t *testing.T) {
	f := Filter{Account: "acct", Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC(),
		Endpoint: "ep", OSUser: "u", CWD: "/p", Model: "m", Branch: "b", Team: "t", Session: "s"}
	clause, args, err := f.where("hour")
	if err != nil {
		t.Fatal(err)
	}
	for _, col := range []string{"account_uuid = ?", "endpoint_id = ?", "os_user = ?", "cwd = ?",
		"model = ?", "git_branch = ?", "session_id = ?", "SELECT endpoint_id FROM endpoints WHERE team = ?",
		"hour >= ?", "hour < ?"} {
		if !strings.Contains(clause, col) {
			t.Errorf("clause lacks %q: %s", col, clause)
		}
	}
	// account, ep, u, /p, m, b, t, s, start, end
	if len(args) != 10 {
		t.Fatalf("want 10 args, got %d: %v", len(args), args)
	}
	if args[len(args)-2] != "1970-01-01T00:00:00Z" {
		t.Fatalf("start must be RFC3339 UTC, got %v", args[len(args)-2])
	}
}

func TestFilterPrevAndAlign(t *testing.T) {
	start := time.Date(2026, 9, 2, 10, 20, 0, 0, time.UTC)
	end := time.Date(2026, 9, 2, 12, 5, 0, 0, time.UTC)
	f := Filter{Account: AllAccounts, Start: start, End: end}
	p := f.Prev()
	if !p.End.Equal(start) || !p.Start.Equal(start.Add(-(end.Sub(start)))) {
		t.Fatalf("prev = %v..%v", p.Start, p.End)
	}
	a := f.AlignHours()
	if !a.Start.Equal(time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)) ||
		!a.End.Equal(time.Date(2026, 9, 2, 13, 0, 0, 0, time.UTC)) {
		t.Fatalf("aligned = %v..%v", a.Start, a.End)
	}
	if !a.AlignHours().Start.Equal(a.Start) || !a.AlignHours().End.Equal(a.End) {
		t.Fatal("aligning twice must be idempotent")
	}
}

// The bug this constant exists for: `where` skipped an empty dimension, so the
// drill-down into a blank bucket produced no predicate at all and the answer
// was every row in the scope. Undeclared is the other question, and it has to
// reach SQL as a predicate.
func TestFilterWhereUndeclaredConstrainsToTheBlankSide(t *testing.T) {
	f := Filter{Account: AllAccounts, Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC(),
		Provider: Undeclared}
	clause, args, err := f.where("ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(clause, "provider = ''") {
		t.Fatalf("clause lacks the blank-provider predicate: %s", clause)
	}
	// The sentinel is this package's own literal, never a bind argument: it is
	// written into the SQL, so only the two time bounds are bound.
	if len(args) != 2 {
		t.Fatalf("want 2 time args, got %d: %v", len(args), args)
	}
	for _, a := range args {
		if a == Undeclared {
			t.Errorf("the sentinel must not be bound as a value: %v", args)
		}
	}
}

// The distinction the whole constant rests on. Left unset, a dimension places
// no constraint; set to Undeclared it places one. Conflating them is the bug.
func TestFilterWhereEmptyStringIsStillNoConstraint(t *testing.T) {
	f := Filter{Account: AllAccounts, Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC(),
		Provider: ""}
	clause, _, err := f.where("ts")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(clause, "provider") {
		t.Fatalf("an unset dimension must not be constrained: %s", clause)
	}
}

// Every dimension, not just the one the bug was reported on. A sentinel that
// worked on some columns and silently meant a literal value on the rest would
// be worse than none: the caller cannot see which kind they got.
func TestFilterWhereUndeclaredWorksOnEveryDimension(t *testing.T) {
	base := Filter{Account: AllAccounts, Start: time.Unix(0, 0).UTC(), End: time.Unix(3600, 0).UTC()}
	for _, c := range []struct {
		name string
		set  func(*Filter)
		want string
	}{
		{"endpoint", func(f *Filter) { f.Endpoint = Undeclared }, "endpoint_id = ''"},
		{"user", func(f *Filter) { f.OSUser = Undeclared }, "os_user = ''"},
		{"project", func(f *Filter) { f.CWD = Undeclared }, "cwd = ''"},
		{"model", func(f *Filter) { f.Model = Undeclared }, "model = ''"},
		{"provider", func(f *Filter) { f.Provider = Undeclared }, "provider = ''"},
		{"source", func(f *Filter) { f.Source = Undeclared }, "source = ''"},
		{"branch", func(f *Filter) { f.Branch = Undeclared }, "git_branch = ''"},
		{"repo", func(f *Filter) { f.Repo = Undeclared }, "git_repo = ''"},
		{"session", func(f *Filter) { f.Session = Undeclared }, "session_id = ''"},
		// Team is not a column on these tables, so it takes its own branch --
		// which is exactly why it is asserted here rather than assumed.
		{"team", func(f *Filter) { f.Team = Undeclared }, "WHERE team = ''"},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := base
			c.set(&f)
			clause, args, err := f.where("ts")
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(clause, c.want) {
				t.Errorf("clause lacks %q: %s", c.want, clause)
			}
			for _, a := range args {
				if a == Undeclared {
					t.Errorf("the sentinel leaked into the bind args: %v", args)
				}
			}
		})
	}
}
