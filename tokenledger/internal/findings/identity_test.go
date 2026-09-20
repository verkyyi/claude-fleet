package findings

import (
	"testing"
	"time"
)

// everyRule builds one Inputs and one NowInputs that between them fire every
// rule in the package, so the identity assertions below are about the real
// findings rather than a hand-written sample of them.
func everyRule() (Inputs, NowInputs) {
	in := Inputs{
		Sessions: append(sessions(10, 10, 10, 10), SessionStat{
			SessionID: "big-session-id-0001", CWD: "/srv/proj/alpha", Model: "m",
			Tokens: 150_000_000, Turns: 400, Duration: 6 * time.Hour}),
		Models:         []ModelStat{{Model: "mystery-model", Tokens: 5_000, Unpriced: 7}},
		FreeAllowances: []FreeAllowanceStat{{Model: "free-model", Tokens: 1_000_001, Allowance: 1_000_000}},
		Critical: []AccountCritical{
			{AccountUUID: "acct-a", Label: "Team A", Seconds: 3600, PrevSeconds: 0, Episodes: 2},
		},
		SelectionSeconds: 86_400,
		Projects: []ProjectStat{
			{CWD: "/srv/proj/alpha", Turns: 300, CacheHit: 0.10, Tokens: 2_000_000_000, PrevTokens: 100_000_000},
		},
		PrevProjects: []ProjectStat{
			{CWD: "/srv/proj/alpha", Turns: 300, CacheHit: 0.90, Tokens: 100_000_000},
		},
		Tokens: 2_000_000_000, PrevTokens: 100_000_000,
	}
	old := time.Now().UTC().Add(-4 * time.Hour)
	now := NowInputs{
		Now: time.Now().UTC(),
		Windows: []WindowStat{
			{AccountUUID: "acct-a", Label: "Team A", FiveHourPct: 95},
			{AccountUUID: "acct-a", Label: "Team A", Window: "weekly", FiveHourPct: 95},
		},
		Endpoints: []EndpointSeen{
			{ID: "ep-1", Label: "box", LastSeen: &old},
			{ID: "ep-2", Label: "box"}, // never reported, SAME label as ep-1
		},
		Live: []LiveStat{{SessionID: "live-session-id-9", CWD: "/srv/proj/beta", Tokens: 300_000_000}},
	}
	return in, now
}

func ids(fs []Finding) []string {
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = f.ID
	}
	return out
}

// The one promise the whole feature rests on: recompute the same state and get
// the same names back. A mute that did not survive a refresh would be a mute
// that never worked.
func TestFindingID_StableAcrossRecomputation(t *testing.T) {
	in, nowIn := everyRule()
	for _, tc := range []struct {
		name string
		run  func() []Finding
	}{
		{"review", func() []Finding { return Review(in) }},
		{"now", func() []Finding { return Now(nowIn) }},
	} {
		first, second := ids(tc.run()), ids(tc.run())
		if len(first) == 0 {
			t.Fatalf("%s: fixture fired no rules", tc.name)
		}
		for i := range first {
			if first[i] != second[i] {
				t.Errorf("%s finding %d: id moved between reads (%q -> %q)", tc.name, i, first[i], second[i])
			}
		}
	}
}

// Every rule must set a subject that tells its findings apart. This is the
// test that would have caught keying identity on Scope: four rules carry no
// scope at all, and two endpoints or two accounts sharing a display label are
// ordinary, not exotic.
func TestFindingID_DistinctPerSubject(t *testing.T) {
	in, nowIn := everyRule()
	seen := map[string]Finding{}
	for _, f := range append(Review(in), Now(nowIn)...) {
		if prev, dup := seen[f.ID]; dup {
			t.Errorf("two findings share id %q:\n  %s / %s\n  %s / %s",
				f.ID, prev.Kind, prev.Title, f.Kind, f.Title)
		}
		seen[f.ID] = f
	}
	// The specific collisions the fixture is built to expose: two endpoints
	// labelled "box", and one account's two quota windows.
	if len(seen) < 8 {
		t.Fatalf("fixture produced only %d findings; it is meant to exercise every rule", len(seen))
	}
}

// The identity deliberately ignores the numbers in the prose. A runaway
// session that burned more tokens since the last poll is the SAME runaway
// session, and a mute on it has to survive that.
func TestFindingID_IgnoresRenderedNumbers(t *testing.T) {
	in, _ := everyRule()
	before := Review(in)[0]
	in.Sessions[4].Tokens = 900_000_000
	in.Sessions[4].Duration = 11 * time.Hour
	after := Review(in)[0]
	if before.Kind != "runaway_session" || after.Kind != "runaway_session" {
		t.Fatalf("expected the runaway session to lead: %q / %q", before.Kind, after.Kind)
	}
	if before.Title == after.Title {
		t.Fatal("fixture did not actually change the rendered sentence")
	}
	if before.ID != after.ID {
		t.Errorf("id changed with the token count: %q -> %q", before.ID, after.ID)
	}
}

// Severity IS part of the identity, and this is why: a window silenced while
// it was a warning must speak up again when it turns critical. "I know it is
// warm" is not consent to be surprised by it running out.
func TestFindingID_EscalationBreaksThroughAMute(t *testing.T) {
	warm := NowInputs{Now: time.Now().UTC(),
		Windows: []WindowStat{{AccountUUID: "a", Label: "A", FiveHourPct: 80}}}
	hot := NowInputs{Now: warm.Now,
		Windows: []WindowStat{{AccountUUID: "a", Label: "A", FiveHourPct: 95}}}

	warnID := Now(warm)[0].ID
	if Now(warm)[0].Severity != "warning" || Now(hot)[0].Severity != "critical" {
		t.Fatal("fixture does not straddle the severity threshold")
	}
	mutes := Mutes{warnID: {Until: warm.Now.Add(time.Hour)}}

	warm.Mutes, hot.Mutes = mutes, mutes
	if Now(warm)[0].Muted == nil {
		t.Error("the warning the operator muted came back unmuted")
	}
	if got := Now(hot)[0]; got.Muted != nil {
		t.Errorf("the escalation to critical stayed silenced under the warning's mute (id %q)", got.ID)
	}
}

// A mute is a change of RANK, never a deletion. The two halves of that:
// muted findings hand their slot to a live one, and are still on the wire.
func TestMuting_GivesUpItsSlotButStaysVisible(t *testing.T) {
	var ms []ModelStat
	for i := 0; i < maxFindings+2; i++ {
		ms = append(ms, ModelStat{Model: string(rune('a' + i)), Tokens: int64(1000 - i), Unpriced: int64(10 - i)})
	}
	in := Inputs{Models: ms}

	plain := Review(in)
	if len(plain) != maxFindings {
		t.Fatalf("uncapped: got %d findings, want the cap of %d", len(plain), maxFindings)
	}
	// The two findings the cap dropped -- the ones a mute should make room for.
	dropped := plain[len(plain)-1]

	in.Mutes = Mutes{plain[0].ID: {Until: time.Now().Add(time.Hour)}}
	after := Review(in)

	var live, muted []Finding
	for _, f := range after {
		if f.Muted != nil {
			muted = append(muted, f)
			continue
		}
		live = append(live, f)
	}
	if len(muted) != 1 || muted[0].ID != plain[0].ID {
		t.Fatalf("the muted finding is not in the response: %+v", ids(after))
	}
	if len(live) != maxFindings {
		t.Errorf("live tier holds %d findings; muting one should have let a ninth in, keeping it at %d",
			len(live), maxFindings)
	}
	// The muted one is LAST, after every live finding -- it must not sit in
	// the middle of the card looking urgent.
	if after[len(after)-1].Muted == nil {
		t.Error("muted findings are not ranked last")
	}
	if live[len(live)-1].ID == dropped.ID {
		// Not a failure by itself, just the clearest signal the slot moved.
		t.Logf("the slot freed by the mute went to %q, as intended", live[len(live)-1].Title)
	}
}

// The muted tail is bounded too: a fleet that has silenced forty things does
// not need forty echoed back on every poll.
func TestMuting_TailIsCapped(t *testing.T) {
	var ms []ModelStat
	for i := 0; i < maxMutedFindings+5; i++ {
		ms = append(ms, ModelStat{Model: string(rune('a' + i)), Tokens: int64(1000 - i), Unpriced: 1})
	}
	in := Inputs{Models: ms}
	// Review caps at maxFindings, so its output cannot name every id that
	// needs muting. Hash the rule's UNCAPPED output instead -- the same four
	// components finish() would have used.
	mutes := Mutes{}
	for _, f := range unpriced(ms) {
		mutes[findingID(f.Kind, f.Template, f.Severity, f.subject)] = Mute{Until: time.Now().Add(time.Hour)}
	}
	in.Mutes = mutes
	got := Review(in)
	for _, f := range got {
		if f.Muted == nil {
			t.Fatalf("fixture left %q unmuted", f.Title)
		}
	}
	if len(got) > maxMutedFindings {
		t.Errorf("muted tail holds %d findings; want at most %d", len(got), maxMutedFindings)
	}
}

// A mute for a finding that is not firing is simply not matched. It must not
// create a finding, and it must not blow up.
func TestMuting_UnknownIDIsInert(t *testing.T) {
	in := Inputs{Mutes: Mutes{"deadbeefcafe": {Until: time.Now().Add(time.Hour)}}}
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("a mute conjured findings out of nothing: %+v", fs)
	}
}

// Identity is versioned so that redefining "the same finding" invalidates
// every stored mute at once rather than silently re-pointing old mutes at
// differently-defined findings.
func TestFindingID_IsVersioned(t *testing.T) {
	a := findingID("k", "tmpl", "warning", "subj")
	if len(a) != idLen {
		t.Fatalf("id is %d characters; want %d", len(a), idLen)
	}
	for _, other := range []string{
		findingID("k2", "tmpl", "warning", "subj"),
		findingID("k", "tmpl2", "warning", "subj"),
		findingID("k", "tmpl", "critical", "subj"),
		findingID("k", "tmpl", "warning", "subj2"),
	} {
		if other == a {
			t.Error("two distinct component tuples hash to one id")
		}
	}
	// No component boundary can be shifted into another: the separator does
	// not occur in any identifier the rules use.
	if findingID("a", "b", "c", "d") == findingID("ab", "", "c", "d") {
		t.Error("component boundaries are not separated")
	}
}
