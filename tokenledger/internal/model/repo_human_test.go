package model

import (
	"strings"
	"testing"
	"time"
)

func at(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// The day row's subset relations ARE its meaning. A ratio above 100% would
// make a reader distrust the axis rather than the shipper, so the hub refuses
// the row instead of drawing it.
func TestRepoHumanDay_RefusesImpossibleRatios(t *testing.T) {
	now := at("2026-09-15T00:00:00Z")
	base := RepoSnapshot{Repo: "o/r", ObservedAt: now}
	for _, tc := range []struct {
		name string
		day  RepoHumanDay
		want string
	}{
		{"more manual fragments than fragments",
			RepoHumanDay{Day: "2026-09-14", Fragments: 3, WithHuman: 4, Steps: 4}, "exceeds fragments"},
		{"more done than there are",
			RepoHumanDay{Day: "2026-09-14", Fragments: 3, WithHuman: 1, Steps: 2, StepsDone: 3}, "exceeds steps"},
		{"steps from nowhere",
			RepoHumanDay{Day: "2026-09-14", Fragments: 3, WithHuman: 0, Steps: 2}, "no fragment carrying them"},
		{"not a day", RepoHumanDay{Day: "14/09/2026", Fragments: 1}, "is not 2006-01-02"},
		{"negative", RepoHumanDay{Day: "2026-09-14", Fragments: -1}, "cannot be negative"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := base
			s.HumanDays = []RepoHumanDay{tc.day}
			err := s.Validate(now)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want an error mentioning %q, got %v", tc.want, err)
			}
		})
	}
	// A day with no manual work at all is the normal case and must pass: it is
	// the denominator that lets the ratio fall instead of the series stopping.
	s := base
	s.HumanDays = []RepoHumanDay{{Day: "2026-09-14", Fragments: 51}}
	if err := s.Validate(now); err != nil {
		t.Fatalf("a zero-manual day must be storable: %v", err)
	}
}

func TestRepoHumanStep_RefusesRowsNoSurfaceCouldRender(t *testing.T) {
	now := at("2026-09-15T00:00:00Z")
	ok := RepoHumanStep{
		Fragment: 6995, Ord: 1, Owner: "发起人", OwnerKind: RepoOwnerPerson,
		OwnerID: "wose1234", Title: "建 Secret", FragmentAt: at("2026-09-10T00:00:00Z"),
	}
	mut := func(f func(*RepoHumanStep)) RepoSnapshot {
		s := ok
		f(&s)
		return RepoSnapshot{Repo: "o/r", ObservedAt: now, HumanSteps: []RepoHumanStep{s}}
	}
	for _, tc := range []struct {
		name string
		snap RepoSnapshot
		want string
	}{
		{"unknown resolution", mut(func(s *RepoHumanStep) { s.OwnerKind = "user" }), "owner_kind must be"},
		// A resolved person nothing can address is the shape that renders as
		// "somebody is on it" while nobody has been told.
		{"person with no id", mut(func(s *RepoHumanStep) { s.OwnerID = "" }), "needs owner_id"},
		{"no title", mut(func(s *RepoHumanStep) { s.Title = "" }), "title is required"},
		{"no fragment time", mut(func(s *RepoHumanStep) { s.FragmentAt = time.Time{} }), "fragment_at is required"},
		{"done before it existed", mut(func(s *RepoHumanStep) {
			d := at("2026-09-01T00:00:00Z")
			s.Done, s.DoneAt = true, &d
		}), "done_at precedes fragment_at"},
		// One field filled and the other forgotten: the row would sit in the
		// owed list with a completion time printed beside it.
		{"a time without the fact", mut(func(s *RepoHumanStep) {
			d := at("2026-09-12T00:00:00Z")
			s.DoneAt = &d
		}), "done_at without done"},
		{"an attribution without the fact", mut(func(s *RepoHumanStep) { s.DoneBy = "易良慧" }), "done_by without done"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.snap.Validate(now)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want an error mentioning %q, got %v", tc.want, err)
			}
		})
	}
	// Done with no timestamp is legal: somebody struck it out by hand.
	if err := mut(func(s *RepoHumanStep) { s.Done = true }).Validate(now); err != nil {
		t.Errorf("a hand-struck step must be storable: %v", err)
	}
	// The two kinds nobody can be reminded about carry no id, and that is not
	// an error: dropping them is what would be.
	for _, kind := range []string{RepoOwnerNotAPerson, RepoOwnerUnresolved} {
		s := mut(func(s *RepoHumanStep) { s.OwnerKind, s.OwnerID = kind, "" })
		if err := s.Validate(now); err != nil {
			t.Errorf("%s step must be storable: %v", kind, err)
		}
	}
}

// An empty snapshot is still refused — the check just had to learn about two
// more kinds of row, or a shipper that ships only manual steps would be told
// its payload was empty.
func TestRepoSnapshot_EmptyIsStillRefused(t *testing.T) {
	now := at("2026-09-15T00:00:00Z")
	if err := (RepoSnapshot{Repo: "o/r", ObservedAt: now}).Validate(now); err == nil {
		t.Fatal("an empty snapshot must be refused")
	}
}
