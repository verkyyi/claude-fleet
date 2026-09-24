package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func userEv(account, endpoint, uuid, osUser, cwd string, out int64) model.UsageEvent {
	c := 2.0
	return model.UsageEvent{
		AccountUUID: account, EndpointID: endpoint, MessageUUID: uuid,
		SessionID: "s-" + uuid, TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
		Model: "claude-opus-5", OutputTokens: out, CostUSD: &c,
		CWD: cwd, OSUser: osUser, GitBranch: "main",
	}
}

func seedUsers(t *testing.T, s *Store) (start, end time.Time) {
	t.Helper()
	seedAccount(t, s, "acct-1", "ep-1")
	seedAccount(t, s, "acct-1", "ep-2")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep-1", "m1", "alice", "/repo/a", 100),
		userEv("acct-1", "ep-2", "m2", "alice", "/repo/b", 50),
		userEv("acct-1", "ep-1", "m3", "bob", "/repo/a", 7),
	}); err != nil {
		t.Fatal(err)
	}
	return time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
}

func TestUserSummary(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	got, err := s.UserSummary("alice", start, end)
	if err != nil {
		t.Fatal(err)
	}
	if got.Turns != 2 {
		t.Errorf("turns = %d, want 2", got.Turns)
	}
	if got.Tokens != 150 {
		t.Errorf("tokens = %d, want 150", got.Tokens)
	}
	if got.Projects != 2 {
		t.Errorf("projects = %d, want 2", got.Projects)
	}
	if got.Machines != 2 {
		t.Errorf("machines = %d, want 2", got.Machines)
	}
	// alice works on one assigned machine and one unassigned one. Reporting a
	// single team would attribute half her spend to a team that never got it.
	if len(got.Teams) != 1 || got.Teams[0] != "platform" {
		t.Errorf("teams = %v, want [platform]", got.Teams)
	}
}

// An unknown login is not an error -- it is a page that says "no usage".
func TestUserSummary_UnknownLoginIsEmptyNotAnError(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)
	got, err := s.UserSummary("nobody", start, end)
	if err != nil {
		t.Fatal(err)
	}
	if got.Turns != 0 || got.Tokens != 0 {
		t.Errorf("unknown login reported usage: %+v", got)
	}
}

func TestUsageByUser_ScopesToOneLogin(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	buckets, err := s.UsageByUser("alice", ByProject, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	total := int64(0)
	for _, b := range buckets {
		total += b.Tokens
		if b.Key == "/repo/a" && b.Tokens != 100 {
			t.Errorf("/repo/a = %d tokens, want 100 (bob's 7 must not be included)", b.Tokens)
		}
	}
	if total != 150 {
		t.Errorf("total across alice's projects = %d, want 150", total)
	}
}

// The two totals on the page come from different queries. If their token
// expressions ever diverge by a cache column, the page contradicts itself.
func TestUserSummary_AgreesWithUsageByUser(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	sum, err := s.UserSummary("alice", start, end)
	if err != nil {
		t.Fatal(err)
	}
	buckets, err := s.UsageByUser("alice", ByProject, start, end, 1000)
	if err != nil {
		t.Fatal(err)
	}
	var viaBuckets int64
	for _, b := range buckets {
		viaBuckets += b.Tokens
	}
	if sum.Tokens != viaBuckets {
		t.Errorf("summary says %d tokens, the breakdown sums to %d", sum.Tokens, viaBuckets)
	}
}

// enrollLabelled gives an endpoint a label that is NOT its id, so a test can
// tell the two apart -- seedAccount deliberately uses the id for both.
func enrollLabelled(t *testing.T, s *Store, account, endpoint, label string) {
	t.Helper()
	if err := s.UpsertAccount(ident(account), "max", "default_claude_max_20x"); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll(endpoint, label, "hash-"+endpoint); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.TouchEndpoint(endpoint, ident(account), "test", true, nil); err != nil {
		t.Fatal(err)
	}
}

func loginlessBucket(t *testing.T, bs []Bucket) Bucket {
	t.Helper()
	for _, b := range bs {
		if b.Key == "" {
			return b
		}
	}
	t.Fatalf("the login-less bucket is gone from the breakdown: %+v", bs)
	return Bucket{}
}

// The blank login is a REPORTER, not a person the hub lost track of, and when
// one endpoint is behind it the hub can say which one (issue #132). On this
// deployment every one of those 6,204 turns came from `ai-gateway-shipper`, a
// gateway shipper that has no OS login to send -- and the row carried the only
// real invoice on the card while rendering as "(unknown)".
func TestUsageBy_LoginlessBucketIsNamedAfterItsOneReporter(t *testing.T) {
	s := newStore(t)
	enrollLabelled(t, s, "acct-1", "ep_1789272199291316987", "ai-gateway-shipper")
	seedAccount(t, s, "acct-1", "ep-laptop")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep_1789272199291316987", "g1", "", "/w", 900),
		userEv("acct-1", "ep_1789272199291316987", "g2", "", "/w", 100),
		userEv("acct-1", "ep-laptop", "a1", "alice", "/repo/a", 400),
	}); err != nil {
		t.Fatal(err)
	}
	start := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)

	bs, err := s.UsageBy(AllAccounts, ByUser, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	blank := loginlessBucket(t, bs)
	if want := "non-login source: ai-gateway-shipper"; blank.Label != want {
		t.Errorf("login-less bucket label = %q, want %q", blank.Label, want)
	}
	// Named, not hidden: it is the row with the real money on it.
	if blank.Tokens != 1000 {
		t.Errorf("login-less bucket tokens = %d, want 1000 -- naming it must not drop any of it", blank.Tokens)
	}
	// A real login is already its own name; labelling it again would put the
	// same string twice in every row to say nothing new.
	for _, b := range bs {
		if b.Key == "alice" && b.Label != "" {
			t.Errorf("alice got a redundant label %q", b.Label)
		}
	}
}

// Two reporters and the hub says only what it can stand behind: picking one of
// them would put the other's spend under its name.
func TestUsageBy_LoginlessBucketStaysGenericWhenSeveralReported(t *testing.T) {
	s := newStore(t)
	enrollLabelled(t, s, "acct-1", "ep-gw", "ai-gateway-shipper")
	enrollLabelled(t, s, "acct-1", "ep-voice", "voice-shipper")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep-gw", "g1", "", "/w", 900),
		userEv("acct-1", "ep-voice", "v1", "", "/w", 100),
	}); err != nil {
		t.Fatal(err)
	}
	bs, err := s.UsageBy(AllAccounts, ByUser,
		time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC), 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := loginlessBucket(t, bs).Label; got != "non-login source" {
		t.Errorf("label = %q, want %q -- two reporters cannot be named as one", got, "non-login source")
	}
}

// The name is proven against the window being labelled, not against the hub's
// whole history: the same hub answers "one shipper" for a narrow range and
// "two" for a wide one, and the label has to follow the rows it is on.
func TestUsageBy_LoginlessLabelFollowsTheWindow(t *testing.T) {
	s := newStore(t)
	enrollLabelled(t, s, "acct-1", "ep-gw", "ai-gateway-shipper")
	enrollLabelled(t, s, "acct-1", "ep-voice", "voice-shipper")
	gw := userEv("acct-1", "ep-gw", "g1", "", "/w", 900)
	old := userEv("acct-1", "ep-voice", "v1", "", "/w", 100)
	old.TS = time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
	if _, _, err := s.InsertEvents([]model.UsageEvent{gw, old}); err != nil {
		t.Fatal(err)
	}
	narrow, err := s.UsageBy(AllAccounts, ByUser,
		time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC), 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := loginlessBucket(t, narrow).Label; got != "non-login source: ai-gateway-shipper" {
		t.Errorf("narrow window label = %q, want the one reporter inside it", got)
	}
	wide, err := s.UsageBy(AllAccounts, ByUser,
		time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC), 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := loginlessBucket(t, wide).Label; got != "non-login source" {
		t.Errorf("wide window label = %q, want the unqualified name -- two reporters are inside it", got)
	}
}

// The dashboard's by-login card is served from the ROLLUP (UsageByFiltered),
// not from usage_events -- which is why the blank login reached the page
// unnamed even after UsageBy learned to name it. Two paths, two switches; a
// labeler wired into one of them is not wired in.
func TestUsageByFiltered_LoginlessBucketIsNamedOnTheDashboardPath(t *testing.T) {
	s := newStore(t)
	enrollLabelled(t, s, "acct-1", "ep_1789272199291316987", "ai-gateway-shipper")
	seedAccount(t, s, "acct-1", "ep-laptop")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep_1789272199291316987", "g1", "", "/w", 900),
		userEv("acct-1", "ep-laptop", "a1", "alice", "/repo/a", 400),
	}); err != nil {
		t.Fatal(err)
	}
	f := Filter{
		Account: AllAccounts,
		Start:   time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		End:     time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC),
	}
	bs, err := s.UsageByFiltered(f, ByUser, 50)
	if err != nil {
		t.Fatal(err)
	}
	if want := "non-login source: ai-gateway-shipper"; loginlessBucket(t, bs).Label != want {
		t.Errorf("rollup login-less label = %q, want %q -- the page reads THIS query",
			loginlessBucket(t, bs).Label, want)
	}
}

// A drill-down chip narrows the question, so the name is re-proven under it:
// two reporters on the hub, one inside the filter, and the row says which.
func TestUsageByFiltered_LoginlessLabelFollowsTheDrilldown(t *testing.T) {
	s := newStore(t)
	enrollLabelled(t, s, "acct-1", "ep-gw", "ai-gateway-shipper")
	enrollLabelled(t, s, "acct-1", "ep-voice", "voice-shipper")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep-gw", "g1", "", "/w", 900),
		userEv("acct-1", "ep-voice", "v1", "", "/w", 100),
	}); err != nil {
		t.Fatal(err)
	}
	f := Filter{
		Account: AllAccounts,
		Start:   time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		End:     time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC),
	}
	unfiltered, err := s.UsageByFiltered(f, ByUser, 50)
	if err != nil {
		t.Fatal(err)
	}
	if got := loginlessBucket(t, unfiltered).Label; got != "non-login source" {
		t.Errorf("unfiltered label = %q, want the unqualified name", got)
	}
	f.Endpoint = "ep-voice"
	narrowed, err := s.UsageByFiltered(f, ByUser, 50)
	if err != nil {
		t.Fatal(err)
	}
	if want := "non-login source: voice-shipper"; loginlessBucket(t, narrowed).Label != want {
		t.Errorf("drilled-down label = %q, want %q -- the chip narrowed the rows, so it narrows the name",
			loginlessBucket(t, narrowed).Label, want)
	}
}
