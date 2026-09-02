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
