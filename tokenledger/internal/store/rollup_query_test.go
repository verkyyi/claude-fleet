package store

import (
	"errors"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// seedReview builds two sessions on two projects across three hours.
func seedReview(t *testing.T, s *Store) {
	t.Helper()
	seedAccount(t, s, "acct-a", "ep-a1")
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	mk := func(uuid, session, cwd, model string, min int, out, cacheRead, input int64, side bool, priced bool) model.UsageEvent {
		e := ev("acct-a", "ep-a1", uuid, out)
		e.SessionID, e.CWD, e.Model = session, cwd, model
		e.TS = base.Add(time.Duration(min) * time.Minute)
		e.CacheRead, e.InputTokens, e.IsSidechain = cacheRead, input, side
		e.OSUser, e.Effort, e.Entrypoint = "verkyyi", "xhigh", "cli"
		if !priced {
			e.CostUSD = nil
		}
		return e
	}
	evs := []model.UsageEvent{
		mk("1", "s-big", "/p/alpha", "claude-opus-5", 0, 100, 900, 10, false, true),
		mk("2", "s-big", "/p/alpha", "claude-opus-5", 30, 100, 900, 10, true, true),
		mk("3", "s-big", "/p/alpha", "claude-haiku-4-5", 70, 50, 100, 10, false, false),
		mk("4", "s-small", "/p/beta", "claude-opus-5", 130, 20, 80, 0, false, true),
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
}

func reviewFilter() Filter {
	return Filter{Account: "acct-a",
		Start: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
		End:   time.Date(2026, 8, 31, 15, 0, 0, 0, time.UTC)}
}

func TestUsageByFilteredMatchesEventsAndCarriesComposition(t *testing.T) {
	s := newStore(t)
	seedReview(t, s)
	f := reviewFilter()
	got, err := s.UsageByFiltered(f, ByProject, 10)
	if err != nil {
		t.Fatal(err)
	}
	want, err := s.UsageBy("acct-a", ByProject, f.Start, f.End, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || len(want) != 2 || got[0].Key != "/p/alpha" {
		t.Fatalf("got %+v want %+v", got, want)
	}
	for i := range got {
		if got[i].Tokens != want[i].Tokens || got[i].Events != want[i].Events ||
			got[i].CostUSD != want[i].CostUSD || got[i].Unpriced != want[i].Unpriced || got[i].Sidechain != want[i].Sidechain {
			t.Fatalf("row %d: rollup %+v vs events %+v", i, got[i], want[i])
		}
	}
	if got[0].CacheReadTokens != 1900 || got[0].OutputTokens != 250 || got[0].InputTokens != 30 {
		t.Fatalf("composition: %+v", got[0])
	}
	// A chip narrows it.
	f.Model = "claude-haiku-4-5"
	got, _ = s.UsageByFiltered(f, ByProject, 10)
	if len(got) != 1 || got[0].Events != 1 || got[0].Unpriced != 1 {
		t.Fatalf("model chip: %+v", got)
	}
}

func TestHourlyByModel(t *testing.T) {
	s := newStore(t)
	seedReview(t, s)
	rows, err := s.HourlyByModel(reviewFilter())
	if err != nil {
		t.Fatal(err)
	}
	// 12:00 opus (2 turns), 13:00 haiku, 14:00 opus
	if len(rows) != 3 || rows[0].Hour != "2026-08-31T12:00:00Z" || rows[0].Model != "claude-opus-5" || rows[0].Events != 2 {
		t.Fatalf("%+v", rows)
	}
}

func TestSummary(t *testing.T) {
	s := newStore(t)
	seedReview(t, s)
	sum, err := s.Summary(reviewFilter())
	if err != nil {
		t.Fatal(err)
	}
	if sum.Events != 4 || sum.Sessions != 2 || sum.Unpriced != 1 || sum.OutputTokens != 270 ||
		sum.CacheReadTokens != 1980 || sum.SidechainEvents != 1 || sum.CostUSD != 4.5 {
		t.Fatalf("%+v", sum)
	}
}

func TestSessionsAndTurns(t *testing.T) {
	s := newStore(t)
	seedReview(t, s)
	rows, err := s.Sessions(reviewFilter(), "tokens", 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].SessionID != "s-big" || rows[0].Turns != 3 || rows[0].Model != "claude-opus-5" ||
		len(rows[0].Models) != 2 || rows[0].Ended.Sub(rows[0].Started) != 70*time.Minute || rows[0].CWD != "/p/alpha" {
		t.Fatalf("%+v", rows)
	}
	if rows[0].CacheHit < 0.9 || rows[0].CacheHit > 1 || rows[0].SidechainShare <= 0 {
		t.Fatalf("ratios: %+v", rows[0])
	}
	if rows, _ = s.Sessions(reviewFilter(), "started", 1, 1); len(rows) != 1 || rows[0].SessionID != "s-big" {
		t.Fatalf("started desc, offset 1: %+v", rows)
	}
	turns, err := s.SessionTurns("acct-a", "s-big")
	if err != nil || len(turns) != 3 || !turns[1].IsSidechain || turns[2].CostUSD != nil {
		t.Fatalf("turns=%+v err=%v", turns, err)
	}
	one, err := s.Session("acct-a", "s-small")
	if err != nil || one == nil || one.Turns != 1 {
		t.Fatalf("session=%+v err=%v", one, err)
	}
	if _, err := s.Sessions(reviewFilter(), "drop table", 10, 0); err == nil {
		t.Fatal("unknown sort must be refused")
	} else if !errors.Is(err, ErrUnknownSort) {
		t.Fatalf("want ErrUnknownSort, got %v", err)
	}
}

// TestSessionsDoesNotBlendSameSessionIDAcrossAccounts is the regression for
// the "one session_id, two accounts" seam: the rollup's dedup key is
// (account_uuid, message_uuid), so a session resumed under a different login
// legitimately produces rows under two account_uuids sharing one session_id
// (account_switches records exactly this). Grouping by session_id alone
// blended those into one row labelled with whichever account_uuid sorted
// higher; acct-b is given far more tokens than acct-a specifically so a
// MAX(account_uuid)/blended-sum bug would be obvious rather than
// coincidentally correct.
func TestSessionsDoesNotBlendSameSessionIDAcrossAccounts(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	seedAccount(t, s, "acct-b", "ep-b1")
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	mkFor := func(account, endpoint, uuid string, out int64, min int) model.UsageEvent {
		e := ev(account, endpoint, uuid, out)
		e.SessionID = "shared-session" // same id reused across accounts, deliberately
		e.TS = base.Add(time.Duration(min) * time.Minute)
		return e
	}
	evs := []model.UsageEvent{
		mkFor("acct-a", "ep-a1", "a1", 100, 0),
		mkFor("acct-a", "ep-a1", "a2", 100, 5),
		mkFor("acct-b", "ep-b1", "b1", 5000, 10),
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	f := Filter{Account: AllAccounts, Start: base, End: base.Add(time.Hour)}
	rows, err := s.Sessions(f, "tokens", 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("want 2 separate session rows (one per account), got %d: %+v", len(rows), rows)
	}
	byAccount := map[string]SessionRow{}
	for _, r := range rows {
		if r.SessionID != "shared-session" {
			t.Fatalf("unexpected session id %q", r.SessionID)
		}
		byAccount[r.AccountUUID] = r
	}
	if a := byAccount["acct-a"]; a.Turns != 2 || a.Tokens != 200 {
		t.Fatalf("acct-a row wrong: %+v", a)
	}
	if b := byAccount["acct-b"]; b.Turns != 1 || b.Tokens != 5000 {
		t.Fatalf("acct-b row wrong: %+v", b)
	}

	// The median must not blend the two accounts' populations either: only
	// acct-a's session has >= 2 turns (acct-b's single-turn session is
	// excluded by the HAVING clause both use), so it is the whole population.
	median, err := s.SessionTokenMedian(f)
	if err != nil {
		t.Fatal(err)
	}
	if median != 200 {
		t.Fatalf("median = %d, want 200 (only acct-a's session qualifies with >= 2 turns)", median)
	}
}

// TestSessionsFillModelsRespectsFilter is the regression for
// fillSessionModels ignoring the time range and every drill-down chip: a
// session's model/models used to be computed over ALL of history and every
// model while its tokens were the filtered subset, so a model chip could
// show model: X on a row whose displayed tokens were entirely model Y's.
func TestSessionsFillModelsRespectsFilter(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	mk := func(uuid, model string, out int64, min int) model.UsageEvent {
		e := ev("acct-a", "ep-a1", uuid, out)
		e.SessionID = "s1"
		e.Model = model
		e.TS = base.Add(time.Duration(min) * time.Minute)
		return e
	}
	evs := []model.UsageEvent{
		mk("1", "claude-haiku-4-5", 10, 0),  // minority model overall
		mk("2", "claude-opus-5", 10000, 65), // dominant model overall
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	f := Filter{Account: "acct-a", Start: base, End: base.Add(2 * time.Hour), Model: "claude-haiku-4-5"}
	rows, err := s.Sessions(f, "tokens", 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("want 1 session, got %d: %+v", len(rows), rows)
	}
	r := rows[0]
	if r.Tokens != 10 {
		t.Fatalf("tokens should be the model-chip-filtered subset (10), got %d", r.Tokens)
	}
	if r.Model != "claude-haiku-4-5" {
		t.Fatalf("reported primary model must agree with the counted tokens, got %q", r.Model)
	}
	if len(r.Models) != 1 || r.Models[0] != "claude-haiku-4-5" {
		t.Fatalf("models must not leak a model the filter excluded, got %+v", r.Models)
	}
}

func TestLimitsHistory(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	at := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i, pct := range []float64{10, 95, 50} {
		snap := &model.LimitsSnapshot{AccountUUID: "acct-a", EndpointID: "ep-a1", ObservedAt: at.Add(time.Duration(i) * time.Minute)}
		snap.FiveHour.Utilization = pct
		snap.SevenDay.Utilization = 20
		if err := s.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
	}
	pts, err := s.LimitsHistory(AllAccounts, at, at.Add(time.Hour))
	if err != nil || len(pts) != 3 || pts[1].FiveHour != 95 || pts[1].AccountUUID != "acct-a" {
		t.Fatalf("pts=%+v err=%v", pts, err)
	}
}

// The empty string is what an uninitialised variable looks like; masking a
// caller bug as "no turns found" is the failure every account-scoped query on
// this hub refuses, per Filter.where and LimitsHistory.
func TestSessionTurnsRefusesEmptyAccount(t *testing.T) {
	s := newStore(t)
	seedReview(t, s)
	if _, err := s.SessionTurns("", "s-big"); err == nil {
		t.Fatal("empty account must be refused")
	}
}

// SessionTokenMedian must match findings.runaway()'s own convention exactly:
// sort ascending, take toks[len(toks)/2] -- the upper of the two middle
// values on an even population, not an average. It must also apply the same
// population rule runaway() does (>= 2 turns), so a single-turn session with
// a huge token count cannot skew it.
func TestSessionTokenMedian(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")

	mk := func(session string, turns int, outEach int64) []model.UsageEvent {
		var out []model.UsageEvent
		for i := 0; i < turns; i++ {
			e := ev("acct-a", "ep-a1", session+"-"+string(rune('a'+i)), outEach)
			e.SessionID = session
			out = append(out, e)
		}
		return out
	}
	var evs []model.UsageEvent
	// Five 2-turn sessions totalling 100, 200, 300, 400, 500 -- sorted
	// ascending, toks[5/2] = toks[2] = 300 is the expected median.
	evs = append(evs, mk("s1", 2, 50)...)  // 100
	evs = append(evs, mk("s2", 2, 100)...) // 200
	evs = append(evs, mk("s3", 2, 150)...) // 300
	evs = append(evs, mk("s4", 2, 200)...) // 400
	evs = append(evs, mk("s5", 2, 250)...) // 500
	// A single-turn session with a token count bigger than everything above.
	// If the >= 2 turns rule were not applied, sorting six values would move
	// the median to 400 (toks[6/2] = toks[3]); it must stay 300.
	evs = append(evs, mk("s-single-huge", 1, 100_000)...)
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}

	f := Filter{Account: "acct-a",
		Start: base.Add(-time.Hour), End: base.Add(time.Hour)}
	median, err := s.SessionTokenMedian(f)
	if err != nil {
		t.Fatal(err)
	}
	if median != 300 {
		t.Fatalf("median = %d, want 300 (the single-turn session must be excluded)", median)
	}
}

// No sessions in the window (or none with >= 2 turns) is a legitimate answer
// of 0, not an error -- the same convention LatestLimits and UserSummary use
// for "nothing here yet."
func TestSessionTokenMedian_EmptyPopulationIsZero(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")

	// One single-turn session: present, but excluded by the population rule,
	// so the window is not literally empty -- it just has no >= 2-turn session.
	e := ev("acct-a", "ep-a1", "solo", 999)
	e.SessionID = "solo"
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	f := Filter{Account: "acct-a", Start: base.Add(-time.Hour), End: base.Add(time.Hour)}
	median, err := s.SessionTokenMedian(f)
	if err != nil {
		t.Fatal(err)
	}
	if median != 0 {
		t.Fatalf("median = %d, want 0", median)
	}
}
