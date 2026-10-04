package agent

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/sessions"
)

func pct(v float64) *float64 { return &v }

func stampAt(account string, when time.Time, five, seven float64) sessions.Stamp {
	f := when.Add(2 * time.Hour)
	s := when.Add(72 * time.Hour)
	return sessions.Stamp{
		AccountKey: account, StampedAt: when,
		FiveHourPct: pct(five), SevenDayPct: pct(seven),
		FiveHourAt: &f, SevenDayAt: &s,
	}
}

// The gap this closes: utilization used to be a side effect of attributing
// events, so a subscription with no NEW turns was never observed — even though
// its sessions report account-wide rate limits every few seconds. On the fleet
// this was written for, the account carrying 88% of all usage had seven
// utilization samples, all from one sixteen-minute window.
func TestLimitsFromStamps_ObservesASubscriptionWithNoNewTurns(t *testing.T) {
	now := time.Now().UTC()
	a := &Agent{stamps: &sessions.Index{ByTranscript: map[string]sessions.Stamp{
		"/p/idle.jsonl": stampAt("acct-idle", now.Add(-10*time.Second), 41, 9),
	}}}

	got := a.limitsFromStamps(now)
	if len(got) != 1 {
		t.Fatalf("got %d readings, want 1 — an idle session's account is unobserved", len(got))
	}
	if got[0].AccountUUID != "acct-idle" {
		t.Errorf("account = %q", got[0].AccountUUID)
	}
	if got[0].FiveHour.Utilization != 41 || got[0].SevenDay.Utilization != 9 {
		t.Errorf("utilization = %v / %v, want 41 / 9",
			got[0].FiveHour.Utilization, got[0].SevenDay.Utilization)
	}
}

// One reading per subscription: several sessions on one account all report the
// same account-wide numbers, so the rest are copies.
func TestLimitsFromStamps_OneReadingPerSubscriptionFromTheFreshestStamp(t *testing.T) {
	now := time.Now().UTC()
	a := &Agent{stamps: &sessions.Index{ByTranscript: map[string]sessions.Stamp{
		"/p/a.jsonl": stampAt("acct-1", now.Add(-90*time.Second), 10, 1),
		"/p/b.jsonl": stampAt("acct-1", now.Add(-5*time.Second), 44, 4),
		"/p/c.jsonl": stampAt("acct-2", now.Add(-8*time.Second), 70, 7),
	}}}

	got := a.limitsFromStamps(now)
	if len(got) != 2 {
		t.Fatalf("got %d readings for 2 subscriptions", len(got))
	}
	for _, s := range got {
		if s.AccountUUID == "acct-1" && s.FiveHour.Utilization != 44 {
			t.Errorf("acct-1 reported %v, want the freshest stamp's 44",
				s.FiveHour.Utilization)
		}
	}
}

// Re-sending the same reading every scan would fill limit_snapshots with
// duplicates and make the row count look like observation.
func TestLimitsFromStamps_DoesNotResendAnUnchangedReading(t *testing.T) {
	now := time.Now().UTC()
	st := stampAt("acct-1", now.Add(-5*time.Second), 41, 9)
	a := &Agent{stamps: &sessions.Index{ByTranscript: map[string]sessions.Stamp{"/p/a.jsonl": st}}}

	if got := a.limitsFromStamps(now); len(got) != 1 {
		t.Fatalf("first pass returned %d", len(got))
	}
	if got := a.limitsFromStamps(now); len(got) != 0 {
		t.Fatalf("second pass re-sent %d unchanged readings", len(got))
	}

	// ...but a genuinely newer stamp must go.
	a.stamps.ByTranscript["/p/a.jsonl"] = stampAt("acct-1", now.Add(-1*time.Second), 42, 9)
	if got := a.limitsFromStamps(now); len(got) != 1 {
		t.Fatalf("a newer reading was suppressed: %d", len(got))
	}
}

// A stale stamp is from a session that has stopped. Reporting it as current
// utilization would keep a finished session's numbers alive indefinitely.
func TestLimitsFromStamps_IgnoresStaleStamps(t *testing.T) {
	now := time.Now().UTC()
	a := &Agent{stamps: &sessions.Index{ByTranscript: map[string]sessions.Stamp{
		"/p/old.jsonl": stampAt("acct-1", now.Add(-stampLimitsMaxAge-time.Minute), 41, 9),
	}}}
	if got := a.limitsFromStamps(now); len(got) != 0 {
		t.Errorf("a stale stamp produced %d readings", len(got))
	}
}

// An API-key session has invoices, not windows. Reporting it as 0% utilization
// would claim a plan was idle when no plan is involved at all.
func TestLimitsFromStamps_SkipsSessionsWithNoRateLimits(t *testing.T) {
	now := time.Now().UTC()
	st := sessions.Stamp{AccountKey: "acct-api", StampedAt: now.Add(-5 * time.Second)}
	a := &Agent{stamps: &sessions.Index{ByTranscript: map[string]sessions.Stamp{"/p/a.jsonl": st}}}
	if got := a.limitsFromStamps(now); len(got) != 0 {
		t.Errorf("an API-key session produced %d utilization readings", len(got))
	}
}
