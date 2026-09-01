package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func acct(label string, five, seven float64) BudgetAccount {
	a := BudgetAccount{AccountUUID: "u-" + label, Label: label, Available: true,
		FiveHour: &BudgetWindow{Utilization: five}, SevenDay: &BudgetWindow{Utilization: seven}}
	used := five
	if seven > used {
		used = seven
	}
	a.HeadroomPct = 100 - used
	return a
}

func TestDecideBudget(t *testing.T) {
	cases := []struct {
		name    string
		accts   []BudgetAccount
		ceiling float64
		want    string
		inWhy   string
	}{
		{
			name:    "room on the only subscription",
			accts:   []BudgetAccount{acct("solo", 12, 30)},
			ceiling: 90, want: verdictGo, inWhy: "headroom",
		},
		{
			name:    "five-hour window full",
			accts:   []BudgetAccount{acct("solo", 95, 30)},
			ceiling: 90, want: verdictHold, inWhy: "95.0%",
		},
		{
			// The tighter window governs: a calm 5h window says nothing when the
			// weekly one is nearly spent, and the weekly one is the expensive
			// mistake — it locks you out for days, not hours.
			name:    "weekly window full though the five-hour one is calm",
			accts:   []BudgetAccount{acct("solo", 3, 97)},
			ceiling: 90, want: verdictHold, inWhy: "97.0%",
		},
		{
			name:    "exactly at the ceiling holds",
			accts:   []BudgetAccount{acct("solo", 90, 10)},
			ceiling: 90, want: verdictHold,
		},
		{
			name:    "one of two subscriptions still has room",
			accts:   []BudgetAccount{acct("full", 99, 10), acct("fresh", 5, 5)},
			ceiling: 90, want: verdictGo, inWhy: "fresh",
		},
		{
			name:    "every subscription in scope is full",
			accts:   []BudgetAccount{acct("full", 99, 10), acct("alsofull", 10, 93)},
			ceiling: 90, want: verdictHold, inWhy: "all 2 subscriptions",
		},
		{
			// Unknown is never a hold: a monitor that halts the work it is meant
			// to observe, because it cannot see, is worse than one that says so.
			name:    "no readable subscription",
			accts:   []BudgetAccount{{AccountUUID: "u-x", Available: false, Reason: "token expired"}},
			ceiling: 90, want: verdictUnknown,
		},
		{
			name:    "an unreadable subscription does not veto a readable one",
			accts:   []BudgetAccount{{AccountUUID: "u-x", Available: false}, acct("fresh", 5, 5)},
			ceiling: 90, want: verdictGo,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := decideBudget(BudgetReport{Accounts: tc.accts}, tc.ceiling)
			if got.Verdict != tc.want {
				t.Fatalf("verdict = %q (%s), want %q", got.Verdict, got.Reason, tc.want)
			}
			if tc.inWhy != "" && !strings.Contains(got.Reason, tc.inWhy) {
				t.Errorf("reason %q does not mention %q", got.Reason, tc.inWhy)
			}
		})
	}
}

// A gate that never holds is indistinguishable from no gate at all, and a gate
// that always holds silently stops the fleet. Both directions must be reachable
// from the same inputs — this is the control for the table above.
func TestDecideBudget_BothVerdictsAreReachable(t *testing.T) {
	one := []BudgetAccount{acct("solo", 50, 50)}
	if got := decideBudget(BudgetReport{Accounts: one}, 90); got.Verdict != verdictGo {
		t.Errorf("ceiling 90 over 50%% used: %s, want go", got.Verdict)
	}
	if got := decideBudget(BudgetReport{Accounts: one}, 40); got.Verdict != verdictHold {
		t.Errorf("ceiling 40 under 50%% used: %s, want hold", got.Verdict)
	}
}

// No hub configured must not look like "plenty of room".
func TestBudget_NoHubIsUnknownNotGo(t *testing.T) {
	rep := budget("", "", "all", "", 90, time.Second)
	if rep.Verdict != verdictUnknown {
		t.Fatalf("verdict = %q, want unknown", rep.Verdict)
	}
	if !strings.Contains(rep.Reason, "hub") {
		t.Errorf("reason %q should say the hub is unconfigured", rep.Reason)
	}
}

// An unreachable or unhappy hub degrades to unknown, never to a hold. A
// scheduler polling this every minute must not be stopped by the monitor.
func TestBudget_HubErrorsDegradeToUnknown(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"nope"}`, http.StatusInternalServerError)
	}))
	defer srv.Close()

	rep := budget(srv.URL, "tok", "all", "", 90, 2*time.Second)
	if rep.Verdict != verdictUnknown {
		t.Fatalf("verdict = %q (%s), want unknown", rep.Verdict, rep.Reason)
	}
}

// The whole point of the default scope: judge the subscription this machine
// would actually spend on, and pass the viewer token through.
func TestBudget_ReadsTheHubAndFlattensBothWindows(t *testing.T) {
	var gotAuth, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"per_account":[
			{"account_uuid":"u-1","label":"one","limits":{"account_uuid":"u-1","available":true,
			 "five_hour":{"utilization":20,"burn":{"percent_per_hour":3}},
			 "seven_day":{"utilization":96,"burn":{"percent_per_hour":1}}}}]}`))
	}))
	defer srv.Close()

	rep := budget(srv.URL, "secret-token", "all", "", 90, 2*time.Second)

	if gotAuth != "Bearer secret-token" {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if !strings.Contains(gotQuery, "account=all") {
		t.Errorf("query = %q, want account=all", gotQuery)
	}
	if len(rep.Accounts) != 1 {
		t.Fatalf("accounts = %d, want 1", len(rep.Accounts))
	}
	a := rep.Accounts[0]
	if a.HeadroomPct != 4 {
		t.Errorf("headroom = %v, want 4 (governed by the 96%% weekly window, not the 20%% five-hour one)",
			a.HeadroomPct)
	}
	if rep.Verdict != verdictHold {
		t.Errorf("verdict = %q (%s), want hold", rep.Verdict, rep.Reason)
	}
}
