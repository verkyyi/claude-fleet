package store

import (
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// step builds a manual step owned by a resolvable person.
func step(fragment, ord int, fragmentAt string) model.RepoHumanStep {
	return model.RepoHumanStep{
		Fragment: fragment, Ord: ord,
		Owner: "发起人", OwnerKind: model.RepoOwnerPerson, OwnerID: "wose1234",
		Title: "建 Secret", FragmentAt: tsAt(fragmentAt),
	}
}

func TestRepoHumanSteps_RoundTripAndWait(t *testing.T) {
	s := newStore(t)
	// ★ The fragment numbers are deliberately the REVERSE of the wait order:
	//   the longest-waiting step is the higher number. Ordering by fragment
	//   (the obvious wrong implementation) would pass with numbers that happen
	//   to agree — it did, until this fixture was flipped.
	told := step(1000, 1, "2026-09-10T00:00:00Z")
	told.TodoAt = ptrT(tsAt("2026-09-12T00:00:00Z"))
	told.How, told.Pass, told.Exit = "kubectl create secret …", "pod 起得来", "找发布者"
	told.FragmentTitle, told.FragmentURL = "repo-progress-ship", "https://example.invalid/1000"

	untold := step(9999, 1, "2026-09-11T00:00:00Z") // nobody was told at all

	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{untold, told},
	}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", OpenOnly: true, Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("want 2 steps, got %d", len(rows))
	}
	// Longest wait first, and the wait of a step nobody was told about runs
	// from the fragment — so #9999 (4 days untold) outranks #1000 (3 days
	// since the card), even though #1000's fragment is older AND its number
	// is lower.
	if rows[0].Fragment != 9999 || rows[1].Fragment != 1000 {
		t.Fatalf("want 9999 before 1000, got %d then %d", rows[0].Fragment, rows[1].Fragment)
	}
	if got := rows[0].WaitingSeconds; got != 4*24*3600 {
		t.Errorf("untold step waiting = %.0fs, want 4d", got)
	}
	if rows[0].ToldSeconds != nil {
		t.Errorf("nobody was told about %d, so told_seconds must be absent, got %v", rows[0].Fragment, *rows[0].ToldSeconds)
	}
	if got := rows[1].WaitingSeconds; got != 3*24*3600 {
		t.Errorf("told step waiting = %.0fs, want 3d (from the card, not the fragment)", got)
	}
	// The two days between writing the step and telling anybody are the
	// system's own delay, and they are invisible in the total above.
	if rows[1].ToldSeconds == nil || *rows[1].ToldSeconds != 2*24*3600 {
		t.Errorf("told_seconds = %v, want 2d", rows[1].ToldSeconds)
	}
	if rows[1].How == "" || rows[1].Pass == "" || rows[1].Exit == "" {
		t.Errorf("the three things the doer needs must survive the round trip: %+v", rows[1])
	}
}

// A done step keeps arriving, with a time. "Done" must never be expressed as
// the shipper going quiet, or a broken shipper and a productive afternoon
// become the same observation.
func TestRepoHumanSteps_DoneIsAFactNotAnAbsence(t *testing.T) {
	s := newStore(t)
	done := step(6995, 1, "2026-09-10T00:00:00Z")
	done.TodoAt = ptrT(tsAt("2026-09-11T00:00:00Z"))
	done.Done, done.DoneAt, done.DoneBy = true, ptrT(tsAt("2026-09-14T00:00:00Z")), "易良慧"
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{done},
	}); err != nil {
		t.Fatal(err)
	}
	open, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", OpenOnly: true, Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(open) != 0 {
		t.Fatalf("a done step must not sit in the owed list, got %d", len(open))
	}
	all, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].DoneBy != "易良慧" {
		t.Fatalf("want the done step readable with its attribution, got %+v", all)
	}
	// Once done, the wait is what it WAS: 3 days from the card to the tick,
	// not "still waiting" measured to now.
	if got := all[0].WaitingSeconds; got != 3*24*3600 {
		t.Errorf("finished step waiting = %.0fs, want the wait it actually took (3d)", got)
	}
}

// A retry that lands out of order must not resurrect a step somebody has
// already ticked off.
func TestRepoHumanSteps_StaleSnapshotDoesNotUnfinish(t *testing.T) {
	s := newStore(t)
	done := step(6995, 1, "2026-09-10T00:00:00Z")
	done.Done, done.DoneAt = true, ptrT(tsAt("2026-09-14T00:00:00Z"))
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{done},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-13T00:00:00Z"), // an older read, arriving late
		HumanSteps: []model.RepoHumanStep{step(6995, 1, "2026-09-10T00:00:00Z")},
	}); err != nil {
		t.Fatal(err)
	}
	open, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", OpenOnly: true, Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(open) != 0 {
		t.Fatalf("a late snapshot reopened a finished step: %+v", open)
	}
}

// Pruning is by last sighting, never by done-ness: a step ticked this morning
// must still be answerable ("how long did that take?") tonight.
func TestPruneRepoHumanSteps_KeepsRecentlySeenDoneSteps(t *testing.T) {
	s := newStore(t)
	fresh := step(6995, 1, "2026-09-10T00:00:00Z")
	fresh.Done, fresh.DoneAt = true, ptrT(tsAt("2026-09-15T08:00:00Z"))
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T09:00:00Z"),
		HumanSteps: []model.RepoHumanStep{fresh},
	}); err != nil {
		t.Fatal(err)
	}
	stale := step(1234, 1, "2026-06-01T00:00:00Z") // last seen in June, never finished
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-06-02T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{stale},
	}); err != nil {
		t.Fatal(err)
	}
	n, err := s.PruneRepoHumanSteps(tsAt("2026-09-01T00:00:00Z"))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 pruned (the one nobody has shipped since June), got %d", n)
	}
	all, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", Now: tsAt("2026-09-15T12:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].Fragment != 6995 {
		t.Fatalf("pruning by done-ness would have taken the finished step; got %+v", all)
	}
}

func TestRepoHumanDays_WindowAndEmptiness(t *testing.T) {
	s := newStore(t)
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		HumanDays: []model.RepoHumanDay{
			{Day: "2026-09-12", Fragments: 55, WithHuman: 1, Steps: 2},
			{Day: "2026-09-13", Fragments: 77, WithHuman: 0, Steps: 0},
			{Day: "2026-09-14", Fragments: 51, WithHuman: 2, Steps: 3, StepsDone: 1},
		},
	}); err != nil {
		t.Fatal(err)
	}
	days, err := s.RepoHumanDays("o/r", dayAt("2026-09-13"), dayAt("2026-09-14"))
	if err != nil {
		t.Fatal(err)
	}
	if len(days) != 2 || days[0].Day != "2026-09-13" || days[1].StepsDone != 1 {
		t.Fatalf("window or ordering wrong: %+v", days)
	}
	// A day with no manual work is a MEASURED zero and must be stored as a
	// row: it is the denominator that makes the ratio fall rather than the
	// series simply stopping.
	if days[0].Fragments != 77 || days[0].WithHuman != 0 {
		t.Errorf("a zero-manual day must keep its denominator, got %+v", days[0])
	}
	none, err := s.RepoHumanDays("o/other", dayAt("2026-09-01"), dayAt("2026-09-15"))
	if err != nil {
		t.Fatal(err)
	}
	if len(none) != 0 {
		t.Errorf("a repo nobody ships fragments for must read as no rows, got %+v", none)
	}
}

// Whatever a viewer is, the store must hand back every owner's rows: the
// filtering this hub cannot honestly do is the filtering by person, and the
// place that must not sneak it in is here, where "just add a WHERE" is easy.
func TestRepoHumanSteps_KeepsEveryOwner(t *testing.T) {
	s := newStore(t)
	a := step(1, 1, "2026-09-10T00:00:00Z")
	b := step(2, 1, "2026-09-10T00:00:00Z")
	b.Owner, b.OwnerID = "另一个人", "wose9999"
	c := step(3, 1, "2026-09-10T00:00:00Z")
	c.Owner, c.OwnerKind, c.OwnerID = "agent", model.RepoOwnerNotAPerson, ""
	d := step(4, 1, "2026-09-10T00:00:00Z")
	d.Owner, d.OwnerKind, d.OwnerID = "某位同事", model.RepoOwnerUnresolved, ""
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{a, b, c, d},
	}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", OpenOnly: true, Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 4 {
		t.Fatalf("want all four owners' steps, got %d", len(rows))
	}
	kinds := map[string]bool{}
	for _, r := range rows {
		kinds[r.OwnerKind] = true
	}
	for _, want := range []string{model.RepoOwnerPerson, model.RepoOwnerNotAPerson, model.RepoOwnerUnresolved} {
		if !kinds[want] {
			t.Errorf("%q was dropped — the steps nobody can be reminded about are the most stuck, not the least", want)
		}
	}
}

// Somebody struck the step out by hand in the issue body: it is finished, and
// no clock anywhere recorded when. Reporting it as still owed would keep a
// done step at the top of a list forever — the exact failure this flag exists
// to prevent.
func TestRepoHumanSteps_DoneByHandHasNoTimestamp(t *testing.T) {
	s := newStore(t)
	byHand := step(6995, 1, "2026-09-10T00:00:00Z")
	byHand.Done = true // and DoneAt stays nil
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-14T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{byHand},
	}); err != nil {
		t.Fatal(err)
	}
	open, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", OpenOnly: true, Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(open) != 0 {
		t.Fatalf("a hand-struck step is done; it must leave the owed list: %+v", open)
	}
	all, err := s.RepoHumanSteps(RepoHumanFilter{Repo: "o/r", Now: tsAt("2026-09-15T00:00:00Z")})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || !all[0].Done || all[0].DoneAt != nil {
		t.Fatalf("want done with no time, got %+v", all)
	}
	// The wait is bounded by the last sighting (4d), not left running to now
	// (5d) as though nobody had done it.
	if got := all[0].WaitingSeconds; got != 4*24*3600 {
		t.Errorf("waiting = %.0fs, want the bound from the last sighting (4d)", got)
	}
}

// A hub that holds only manual-step rows still knows the repository exists.
// The two kinds of row come from two different shippers, so "issues have not
// arrived yet" must not answer "no repositories" — the surface renders
// nothing at all when this list is empty.
func TestRepos_IncludesHumanOnlyRepositories(t *testing.T) {
	s := newStore(t)
	if _, err := s.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: tsAt("2026-09-15T00:00:00Z"),
		HumanSteps: []model.RepoHumanStep{step(6995, 1, "2026-09-10T00:00:00Z")},
		HumanDays:  []model.RepoHumanDay{{Day: "2026-09-14", Fragments: 51, WithHuman: 1, Steps: 1}},
	}); err != nil {
		t.Fatal(err)
	}
	repos, err := s.Repos()
	if err != nil {
		t.Fatal(err)
	}
	if len(repos) != 1 || repos[0].Repo != "o/r" {
		t.Fatalf("want the repo listed from its manual rows alone, got %+v", repos)
	}
	// It has no issues and no day rows, and says so rather than inventing any.
	if repos[0].Issues != 0 || repos[0].Days != 0 {
		t.Errorf("counts must stay honest about what is absent: %+v", repos[0])
	}
}
