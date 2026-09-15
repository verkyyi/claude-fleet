package main

// The wire contract of `ccquota budget --json`.
//
// Everything else in budget_test.go asserts Go struct fields — `a.HeadroomPct
// != 4`. That is the decision logic, and it is not what a downstream consumer
// sees. What crosses the boundary is BYTES, and this file is the only thing in
// the repo that looks at them.
//
// Why that matters here and not for every other struct in this binary:
// `budget --json` has a real MACHINE consumer. claude-fleet's pre-emptive
// account rotation shells out to it and parses this payload to decide which
// subscription to move sessions onto. Renaming a `json:` tag, dropping an
// `omitempty`, or switching a timestamp format is a green-CI change in this
// repo and a silent failure — or, since claude-fleet #628, a RED health check
// — on the other side of the boundary:
//
//   - `available` must always be EMITTED, including when true. The downstream
//     uses the presence of this key to tell "ccquota says it cannot read this
//     account" apart from "the payload shape drifted and I am parsing garbage".
//     An `omitempty` here collapses the two into one unreadable case.
//   - `five_hour` / `seven_day` must be ABSENT (not zero-valued) on an account
//     with no reading. `omitempty` on these two is part of the contract, not an
//     implementation detail: the downstream reads key-missing as "no data".
//     A `{"utilization":0}` object reads as a brand-new idle subscription —
//     which is exactly how an unreadable account once became the preferred
//     landing spot for a fan-out (claude-fleet #628).
//   - `resets_at` is RFC3339, a JSON STRING. This same binary emits unix
//     SECONDS for the identically-named field in stamp.go:60, so "which
//     resets_at?" is a live ambiguity; the budget side does not get to move.
//   - `verdict` is one of go / hold / unknown. A new value is a new branch
//     every consumer has to grow.
//
// So: change any of these deliberately, with the downstream, and update this
// file. Do not change them by accident.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The payload claude-fleet's own fixture feeds its parser
// (bin/fleet-doctor-quota-selftest.sh) — the shape this repo is promising:
//
//	{"verdict":"go","accounts":[
//	  {"account_uuid":"u-a","label":"a","available":true,"headroom_pct":70,
//	   "five_hour":{"utilization":30,"resets_at":"2026-09-16T05:00:00Z"},
//	   "seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}}]}
//
// hubLimitsFixture is the hub reading that produces it: one readable account
// and one the hub could not read, because both halves of the contract are
// load-bearing and only the pair exercises `omitempty`.
const hubLimitsFixture = `{"per_account":[
  {"account_uuid":"u-a","label":"a","limits":{"account_uuid":"u-a","available":true,
   "five_hour":{"utilization":30,"resets_at":"2026-09-16T05:00:00Z","burn":{"percent_per_hour":3}},
   "seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z","burn":{"percent_per_hour":1}}}},
  {"account_uuid":"u-b","label":"b","limits":{"account_uuid":"u-b","available":false,
   "reason":"no endpoint on this subscription reported limits"}}]}`

// marshalBudgetFixture runs the real path — hub read, flatten, decideBudget,
// json.Marshal — and hands back the payload decoded as generic maps, so a
// missing key is missing rather than silently defaulted by a typed decode.
func marshalBudgetFixture(t *testing.T) map[string]any {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(hubLimitsFixture))
	}))
	defer srv.Close()

	raw, err := json.Marshal(budget(srv.URL, "tok", "all", "", 90, 2*time.Second))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var top map[string]any
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatalf("unmarshal: %v\npayload: %s", err, raw)
	}
	return top
}

func budgetAccounts(t *testing.T, top map[string]any) []map[string]any {
	t.Helper()
	list, ok := top["accounts"].([]any)
	if !ok {
		t.Fatalf("accounts is %T, want a JSON array", top["accounts"])
	}
	out := make([]map[string]any, 0, len(list))
	for i, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			t.Fatalf("accounts[%d] is %T, want an object", i, e)
		}
		out = append(out, m)
	}
	return out
}

func mustKey(t *testing.T, m map[string]any, where, key string) any {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("%s: key %q is missing — a downstream parser reads it", where, key)
	}
	return v
}

// A readable account carries the four identity/headroom keys plus both window
// objects, and each window carries utilization and resets_at.
func TestBudgetJSON_ReadableAccountShape(t *testing.T) {
	top := marshalBudgetFixture(t)

	for _, k := range []string{"verdict", "reason", "ceiling_pct", "scope", "accounts", "disclaimer"} {
		mustKey(t, top, "report", k)
	}

	a := budgetAccounts(t, top)[0]
	if got := mustKey(t, a, "accounts[0]", "account_uuid"); got != "u-a" {
		t.Errorf("account_uuid = %v, want u-a", got)
	}
	if got := mustKey(t, a, "accounts[0]", "label"); got != "a" {
		t.Errorf("label = %v, want a", got)
	}
	if got := mustKey(t, a, "accounts[0]", "available"); got != true {
		t.Errorf("available = %v, want true (and always emitted, never omitempty)", got)
	}
	// 100 minus the fuller window: 30% five-hour beats 10% weekly.
	if got := mustKey(t, a, "accounts[0]", "headroom_pct"); got != 70.0 {
		t.Errorf("headroom_pct = %v, want 70", got)
	}

	for _, win := range []string{"five_hour", "seven_day"} {
		w, ok := mustKey(t, a, "accounts[0]", win).(map[string]any)
		if !ok {
			t.Fatalf("accounts[0].%s is not an object", win)
		}
		mustKey(t, w, "accounts[0]."+win, "utilization")
		mustKey(t, w, "accounts[0]."+win, "resets_at")
	}
}

// The case that cost the downstream a real bug: an account this repo says it
// cannot read must be UNMISTAKABLY unreadable on the wire. `available:false`
// present, a `reason` to show a human, zero headroom — and NO window objects
// at all, because a window full of zeroes is indistinguishable from a brand-new
// idle subscription to anything parsing this.
func TestBudgetJSON_UnreadableAccountOmitsBothWindows(t *testing.T) {
	a := budgetAccounts(t, marshalBudgetFixture(t))[1]

	if got := mustKey(t, a, "accounts[1]", "available"); got != false {
		t.Errorf("available = %v, want false", got)
	}
	if got, _ := mustKey(t, a, "accounts[1]", "reason").(string); got == "" {
		t.Error("reason is empty — an unreadable account must say why")
	}
	if got := mustKey(t, a, "accounts[1]", "headroom_pct"); got != 0.0 {
		t.Errorf("headroom_pct = %v, want 0", got)
	}
	for _, win := range []string{"five_hour", "seven_day"} {
		if v, ok := a[win]; ok {
			t.Errorf("accounts[1].%s = %v, want the key ABSENT: a downstream reads "+
				"key-missing as 'no data', and an object of zeroes as 'fully idle'", win, v)
		}
	}
}

// resets_at is an RFC3339 string. Not unix seconds — that is what the
// identically-named field in stamp.go carries, and the two shapes already
// coexist in this one binary.
func TestBudgetJSON_ResetsAtIsRFC3339(t *testing.T) {
	a := budgetAccounts(t, marshalBudgetFixture(t))[0]

	for _, win := range []string{"five_hour", "seven_day"} {
		w := a[win].(map[string]any)
		s, ok := w["resets_at"].(string)
		if !ok {
			t.Fatalf("%s.resets_at is %T (%v), want an RFC3339 string",
				win, w["resets_at"], w["resets_at"])
		}
		ts, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatalf("%s.resets_at = %q does not parse as RFC3339: %v", win, s, err)
		}
		if !ts.Equal(time.Date(2026, 9, 16, 5, 0, 0, 0, time.UTC)) {
			t.Errorf("%s.resets_at = %q, want the instant the hub reported", win, s)
		}
	}
}

// verdict has exactly three values. Adding a fourth is a breaking change for
// every consumer branching on it — including claude-fleet, whose own fixture
// currently writes "ok", a value this repo has never emitted.
func TestBudgetJSON_VerdictDomain(t *testing.T) {
	allowed := map[string]bool{"go": true, "hold": true, "unknown": true}

	reports := map[string]BudgetReport{
		"room":       decideBudget(BudgetReport{Accounts: []BudgetAccount{acct("solo", 12, 30)}}, 90),
		"full":       decideBudget(BudgetReport{Accounts: []BudgetAccount{acct("solo", 95, 30)}}, 90),
		"no reading": decideBudget(BudgetReport{Accounts: []BudgetAccount{{AccountUUID: "u-x"}}}, 90),
		"from the hub": func() BudgetReport {
			var r BudgetReport
			raw, _ := json.Marshal(marshalBudgetFixture(t))
			_ = json.Unmarshal(raw, &r)
			return r
		}(),
	}
	seen := map[string]bool{}
	for name, rep := range reports {
		raw, err := json.Marshal(rep)
		if err != nil {
			t.Fatalf("%s: marshal: %v", name, err)
		}
		var got struct {
			Verdict string `json:"verdict"`
		}
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatalf("%s: unmarshal: %v", name, err)
		}
		if !allowed[got.Verdict] {
			t.Errorf("%s: verdict = %q, want one of go/hold/unknown", name, got.Verdict)
		}
		seen[got.Verdict] = true
	}
	// A domain assertion nothing can violate is not an assertion: make sure the
	// cases above actually span it.
	for v := range allowed {
		if !seen[v] {
			t.Errorf("no case produced verdict %q — the table no longer spans the domain", v)
		}
	}
}
