package store

import (
	"strings"
	"testing"
	"time"
)

func TestFindingMute_RoundTrip(t *testing.T) {
	s := newStore(t)
	now := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)

	got, err := s.MuteFinding(FindingMute{
		FindingID: "abc123", Kind: "stale_agent", Note: "box is in the shop", By: "alice",
	}, 2*time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	if !got.ExpiresAt.Equal(now.Add(2 * time.Hour)) {
		t.Errorf("expires_at = %v, want %v", got.ExpiresAt, now.Add(2*time.Hour))
	}

	active, err := s.ActiveFindingMutes(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(active) != 1 || active[0].FindingID != "abc123" ||
		active[0].Note != "box is in the shop" || active[0].By != "alice" ||
		active[0].Kind != "stale_agent" {
		t.Fatalf("round trip lost something: %+v", active)
	}
}

// The mute EXPIRES, and it expires on the read path. A hub that has taken no
// writes for a week must still stop honouring a lapsed mute the moment it runs
// out -- if only the pruner enforced the expiry, an alert would stay quiet
// until somebody happened to mute something else.
func TestFindingMute_ExpiresOnRead(t *testing.T) {
	s := newStore(t)
	now := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)
	if _, err := s.MuteFinding(FindingMute{FindingID: "x"}, time.Hour, now); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		at   time.Time
		want int
	}{
		{now.Add(59 * time.Minute), 1},
		{now.Add(time.Hour), 0}, // exactly at the expiry: already lapsed
		{now.Add(2 * time.Hour), 0},
	} {
		active, err := s.ActiveFindingMutes(tc.at)
		if err != nil {
			t.Fatal(err)
		}
		if len(active) != tc.want {
			t.Errorf("at +%v: %d active mutes, want %d", tc.at.Sub(now), len(active), tc.want)
		}
	}

	// It is still on the ROSTER, though, for a while: an operator looking
	// right after a mute lapsed should see that it lapsed rather than find
	// the row gone and wonder whether they imagined muting it.
	all, err := s.AllFindingMutes()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 {
		t.Errorf("expired mute vanished from the roster: %+v", all)
	}
}

// There is no permanent mute. A caller asking for a year gets the ceiling --
// clamped rather than refused, because "a long time" is a clear intent and
// honouring it partially beats an error.
func TestFindingMute_DurationIsClampedAndDefaulted(t *testing.T) {
	s := newStore(t)
	now := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)

	for _, tc := range []struct {
		name string
		d    time.Duration
		want time.Duration
	}{
		{"unspecified", 0, DefaultMuteFor},
		{"negative", -time.Hour, DefaultMuteFor},
		{"ordinary", 6 * time.Hour, 6 * time.Hour},
		{"a year", 365 * 24 * time.Hour, MaxMuteFor},
	} {
		got, err := s.MuteFinding(FindingMute{FindingID: "clamp-" + tc.name}, tc.d, now)
		if err != nil {
			t.Fatal(err)
		}
		if d := got.ExpiresAt.Sub(got.MutedAt); d != tc.want {
			t.Errorf("%s: mute lasts %v, want %v", tc.name, d, tc.want)
		}
	}
}

// Re-muting extends rather than erroring: "already muted" has exactly one
// sensible response, so the store gives it without making the caller ask.
func TestFindingMute_ReMuteExtends(t *testing.T) {
	s := newStore(t)
	now := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)
	if _, err := s.MuteFinding(FindingMute{FindingID: "x", Note: "first"}, time.Hour, now); err != nil {
		t.Fatal(err)
	}
	later := now.Add(30 * time.Minute)
	got, err := s.MuteFinding(FindingMute{FindingID: "x", Note: "second"}, 4*time.Hour, later)
	if err != nil {
		t.Fatal(err)
	}
	if !got.ExpiresAt.Equal(later.Add(4 * time.Hour)) {
		t.Errorf("re-mute did not extend: %v", got.ExpiresAt)
	}
	active, err := s.ActiveFindingMutes(later)
	if err != nil {
		t.Fatal(err)
	}
	if len(active) != 1 {
		t.Fatalf("re-muting created a second row: %+v", active)
	}
	if active[0].Note != "second" {
		t.Errorf("note = %q, want the newer one", active[0].Note)
	}
}

// Unmuting something that is not muted satisfies the request either way. The
// common way to hit it is two tabs open on the same card.
func TestFindingMute_UnmuteIsIdempotent(t *testing.T) {
	s := newStore(t)
	now := time.Now().UTC()
	if _, err := s.MuteFinding(FindingMute{FindingID: "x"}, time.Hour, now); err != nil {
		t.Fatal(err)
	}
	existed, err := s.UnmuteFinding("x", now)
	if err != nil || !existed {
		t.Fatalf("first unmute: existed=%v err=%v", existed, err)
	}
	existed, err = s.UnmuteFinding("x", now)
	if err != nil {
		t.Fatal(err)
	}
	if existed {
		t.Error("second unmute reported a row it did not delete")
	}
	active, _ := s.ActiveFindingMutes(now)
	if len(active) != 0 {
		t.Errorf("still muted: %+v", active)
	}
}

func TestFindingMute_RejectsEmptyIDAndBoundsTheNote(t *testing.T) {
	s := newStore(t)
	now := time.Now().UTC()
	if _, err := s.MuteFinding(FindingMute{FindingID: "  "}, time.Hour, now); err == nil {
		t.Error("an empty finding id was accepted; a mute with no subject silences nothing")
	}
	long := strings.Repeat("x", maxMuteNote*3)
	got, err := s.MuteFinding(FindingMute{FindingID: "x", Note: long}, time.Hour, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Note) != maxMuteNote {
		t.Errorf("note is %d bytes; want it bounded at %d", len(got.Note), maxMuteNote)
	}
}

// Long-expired rows are swept on the next write. Not on read: reads filter on
// the clock already, so this is housekeeping rather than correctness -- and it
// must leave the recently-lapsed ones alone (see the roster test above).
func TestFindingMute_PrunesLongExpiredOnWrite(t *testing.T) {
	s := newStore(t)
	now := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)
	if _, err := s.MuteFinding(FindingMute{FindingID: "ancient"}, time.Hour, now); err != nil {
		t.Fatal(err)
	}
	// Much later, mute something else. The write sweeps.
	future := now.Add(mutePruneGrace + 48*time.Hour)
	if _, err := s.MuteFinding(FindingMute{FindingID: "fresh"}, time.Hour, future); err != nil {
		t.Fatal(err)
	}
	all, err := s.AllFindingMutes()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].FindingID != "fresh" {
		t.Errorf("roster = %+v; want only the fresh mute", all)
	}
}
