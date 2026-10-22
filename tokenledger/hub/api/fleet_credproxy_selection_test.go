package api

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

func codexSelectionQuota(t *testing.T, r *cpRig, label string, now time.Time, five, seven float64, reset5, reset7 time.Duration) {
	t.Helper()
	c, err := r.h.srv.Store.Credential(store.PoolPrincipal, credvault.Codex, label)
	if err != nil || c == nil {
		t.Fatal("credential missing", err)
	}
	r5, r7 := now.Add(reset5), now.Add(reset7)
	q := &model.QuotaSnapshot{Source: "codex", AccountUUID: r.h.srv.Vault.CredentialID(*c), EndpointID: HubQuotaEndpoint,
		ObservedAt: now, Observation: "account_api", Plan: "fixture-plan", Pools: []model.QuotaPool{{LimitID: "codex"}},
		Windows: []model.QuotaWindow{{ID: "codex:primary", LimitID: "codex", Minutes: 300, UsedPercent: five, ResetsAt: &r5},
			{ID: "codex:secondary", LimitID: "codex", Minutes: 10080, UsedPercent: seven, ResetsAt: &r7}}}
	if err := r.h.srv.Store.InsertQuota(*q); err != nil {
		t.Fatal(err)
	}
}

// BREAK-IT codex-quota-sticky: an expiring allowance should not sit unused
// behind account-name order when both real windows have a safety reserve.
func TestCodexQuotaSelection(t *testing.T) {
	r := newCPRig(t)
	if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	codexSelectionQuota(t, r, "poolcx", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", now, 60, 60, 15*time.Minute, 6*24*time.Hour)
	b, err := r.h.srv.sessionBind("fixture-selection", "gh:1005", "", credvault.Codex, now)
	if err != nil || b.Account != "poolcx2" {
		t.Fatalf("expiring safe allowance: %+v, %v", b, err)
	}
}

func selectionFixture(now time.Time) *model.QuotaSnapshot {
	r5, r7 := now.Add(4*time.Hour), now.Add(6*24*time.Hour)
	return &model.QuotaSnapshot{Source: "codex", ObservedAt: now, Observation: "account_api", Windows: []model.QuotaWindow{
		{LimitID: "codex", Minutes: 300, UsedPercent: 20, ResetsAt: &r5},
		{LimitID: "codex", Minutes: 10080, UsedPercent: 20, ResetsAt: &r7},
	}}
}

func TestCodexQuotaInputs(t *testing.T) {
	now := time.Date(2030, 1, 2, 0, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name        string
		change      func(*model.QuotaSnapshot)
		state       string
		opportunity bool
	}{
		{"healthy", func(q *model.QuotaSnapshot) {}, "usable", false},
		{"5h expiring", func(q *model.QuotaSnapshot) { r := now.Add(15 * time.Minute); q.Windows[0].ResetsAt = &r }, "usable", true},
		{"7d expiring", func(q *model.QuotaSnapshot) { r := now.Add(time.Hour); q.Windows[1].ResetsAt = &r }, "usable", true},
		{"weekly bottleneck", func(q *model.QuotaSnapshot) {
			r := now.Add(time.Minute)
			q.Windows[0].ResetsAt = &r
			q.Windows[1].UsedPercent = 95
		}, "tight", false},
		{"5h bottleneck", func(q *model.QuotaSnapshot) {
			r := now.Add(time.Minute)
			q.Windows[1].ResetsAt = &r
			q.Windows[0].UsedPercent = 95
		}, "tight", false},
		{"weekly full", func(q *model.QuotaSnapshot) { q.Windows[1].UsedPercent = 100 }, "limited", false},
		{"5h full", func(q *model.QuotaSnapshot) { q.Windows[0].UsedPercent = 100 }, "limited", false},
		{"missing weekly", func(q *model.QuotaSnapshot) { q.Windows = q.Windows[:1] }, "unknown", false},
		{"stale", func(q *model.QuotaSnapshot) { q.ObservedAt = now.Add(-11 * time.Minute) }, "unknown", false},
		{"window stale", func(q *model.QuotaSnapshot) { r := now.Add(-11 * time.Minute); q.Windows[1].ObservedAt = &r }, "unknown", false},
		{"future", func(q *model.QuotaSnapshot) { q.ObservedAt = now.Add(time.Minute) }, "unknown", false},
		{"window future", func(q *model.QuotaSnapshot) { r := now.Add(time.Minute); q.Windows[1].ObservedAt = &r }, "unknown", false},
		{"reset not observed", func(q *model.QuotaSnapshot) { r := now; q.Windows[0].ResetsAt = &r }, "unknown", false},
		{"missing reset", func(q *model.QuotaSnapshot) { q.Windows[0].ResetsAt = nil }, "unknown", false},
		{"impossible reset", func(q *model.QuotaSnapshot) { r := now.Add(6 * time.Hour); q.Windows[0].ResetsAt = &r }, "unknown", false},
		{"duplicate", func(q *model.QuotaSnapshot) { q.Windows = append(q.Windows, q.Windows[0]) }, "unknown", false},
		{"NaN", func(q *model.QuotaSnapshot) { q.Windows[0].UsedPercent = math.NaN() }, "unknown", false},
		{"infinite", func(q *model.QuotaSnapshot) { q.Windows[0].UsedPercent = math.Inf(1) }, "unknown", false},
		{"out of range", func(q *model.QuotaSnapshot) { q.Windows[0].UsedPercent = -1 }, "unknown", false},
		{"unsupported duration", func(q *model.QuotaSnapshot) { q.Windows[0].Minutes = 60 }, "unknown", false},
		{"full missing reset", func(q *model.QuotaSnapshot) { q.Windows[0].UsedPercent = 100; q.Windows[0].ResetsAt = nil }, "limited", false},
		{"stale full stays negative", func(q *model.QuotaSnapshot) {
			q.ObservedAt = now.Add(-11 * time.Minute)
			q.Windows[1].UsedPercent = 100
		}, "limited", false},
		{"fresh blocked contradictory percentages", func(q *model.QuotaSnapshot) { q.Blocked = true }, "limited", false},
		{"stale blocked no positive evidence", func(q *model.QuotaSnapshot) { q.Blocked = true; q.ObservedAt = now.Add(-11 * time.Minute) }, "unknown", false},
		{"model pool is not general", func(q *model.QuotaSnapshot) { q.Windows[0].LimitID = "model-only" }, "unknown", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			q := selectionFixture(now)
			tc.change(q)
			got := codexQuota(q, nil, now)
			if got.State != tc.state || got.Opportunity != tc.opportunity {
				t.Fatalf("%+v", got)
			}
		})
	}
	q := selectionFixture(now)
	failed := &store.CredentialQuotaRead{At: now, Error: "secret-do-not-log"}
	got := codexQuota(q, failed, now)
	encoded, err := json.Marshal(got)
	if err != nil || strings.Contains(string(encoded), failed.Error) {
		t.Fatal("diagnostic leaked raw error or is not JSON")
	}
	if got.State != "unknown" || got.Reason != "read_failed" {
		t.Fatalf("failed read: %+v", got)
	}
	if got := codexQuota(nil, nil, now); got.State != "unknown" {
		t.Fatal(got)
	}
	// Crossing a reset never creates capacity; a fresh reading does.
	r := now.Add(time.Minute)
	q.Windows[0].ResetsAt = &r
	if got := codexQuota(q, nil, now.Add(2*time.Minute)); got.State != "unknown" {
		t.Fatal(got)
	}
	q = selectionFixture(now.Add(2 * time.Minute))
	if got := codexQuota(q, nil, now.Add(2*time.Minute)); got.State != "usable" {
		t.Fatal(got)
	}
}

func TestCodexQuotaIncomparableCapacity(t *testing.T) {
	now := time.Now()
	choices := []store.Credential{{PrincipalID: store.PoolPrincipal, Account: "larger"}, {PrincipalID: store.PoolPrincipal, Account: "smaller"}}
	large, small := selectionFixture(now), selectionFixture(now)
	large.Plan, small.Plan = "pro", "plus"
	// No trustworthy conversion accompanies either reading. 30% of a larger
	// allowance may exceed 80% of a smaller one; neither implies an ordering.
	large.Windows[0].UsedPercent, large.Windows[1].UsedPercent = 70, 70
	inputs := []codexQuotaInput{codexQuota(large, nil, now), codexQuota(small, nil, now)}
	if got := codexOrder(choices, inputs); got[0] != 0 {
		t.Fatal("invented percentage capacity ordering", got)
	}
	if inputs[0].Comparability != "no_absolute_capacity" || inputs[1].Comparability != "no_absolute_capacity" {
		t.Fatal(inputs)
	}
	// Equal names are still not evidence of equal absolute capacity.
	small.Plan = large.Plan
	inputs[1] = codexQuota(small, nil, now)
	if got := codexOrder(choices, inputs); got[0] != 0 {
		t.Fatal(got)
	}
	// Ownership and refresh health outrank reset preference.
	inputs[1].Opportunity = true
	choices[0].PrincipalID = "person"
	if got := codexOrder(choices, inputs); got[0] != 0 {
		t.Fatal("pool outranked own", got)
	}
	choices[0].PrincipalID = store.PoolPrincipal
	choices[1].RefreshError = "failed"
	if got := codexOrder(choices, inputs); got[0] != 0 {
		t.Fatal("unhealthy outranked healthy", got)
	}
	inputs[0].State = "limited"
	if got := codexOrder(choices, inputs); got[0] != 1 {
		t.Fatal("full was not demoted", got)
	}
	for _, state := range []string{"unknown", "limited"} {
		inputs[0].State, inputs[1].State = state, state
		inputs[0].Opportunity, inputs[1].Opportunity = false, false
		choices[1].RefreshError = ""
		if got := codexOrder(choices, inputs); got[0] != 0 {
			t.Fatal("all unavailable lost deterministic fallback", got)
		}
	}
}

func TestCodexQuotaSticky(t *testing.T) {
	r := newCPRig(t)
	if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	codexSelectionQuota(t, r, "poolcx", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", now, 60, 60, 15*time.Minute, 6*24*time.Hour)
	s := r.h.srv
	seed := func(wid, setBy string, at time.Time) store.SessionBind {
		b, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: wid, Provider: credvault.Codex, Owner: store.PoolPrincipal, Account: "poolcx", SetBy: setBy}, at)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	for _, tc := range []struct {
		name, setBy string
		at          time.Time
		boundary    bool
		want        string
	}{
		{"young", "auto", now, true, "poolcx"},
		{"not boundary", "auto", now.Add(-time.Hour), false, "poolcx"},
		{"manual", "operator", now.Add(-time.Hour), true, "poolcx"},
		{"expired hold", "auto", now.Add(-time.Hour), true, "poolcx2"},
		{"429 bind eligible", "credproxy:429", now.Add(-time.Hour), true, "poolcx2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := seed(tc.name, tc.setBy, tc.at)
			got, err := s.sessionBind(tc.name, "gh:1005", "", credvault.Codex, now, tc.boundary)
			if err != nil || got.Account != tc.want {
				t.Fatalf("%+v %v", got, err)
			}
			if tc.want == "poolcx" && b.Rev != got.Rev {
				t.Fatal("hold bumped revision")
			}
		})
	}
	// Concurrent requests share one actual change, even across different hub
	// handlers. A stale decision cannot overwrite a newer operator decision.
	seed("parallel", "auto", now.Add(-time.Hour))
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b, err := s.sessionBind("parallel", "gh:1005", "", credvault.Codex, now, true)
			if err != nil {
				errs <- err
			} else if b.Account != "poolcx2" || b.Rev != 2 {
				errs <- fmt.Errorf("unexpected binding %+v", b)
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	b := seed("cas", "auto", now.Add(-time.Hour))
	manual, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: b.WorkerID, Provider: b.Provider, Owner: b.Owner, Account: b.Account, SetBy: "operator"}, now)
	if err != nil {
		t.Fatal(err)
	}
	b.Account = "poolcx2"
	actual, err := s.Store.CompareSessionBind(b, b.Rev, now)
	if err != nil || actual != manual {
		t.Fatalf("stale CAS beat operator: %+v %v", actual, err)
	}
	// After a move the new reading can reverse the order, but cannot defeat
	// the hold or cause a switch solely between two similar opportunities.
	later := now.Add(time.Minute)
	codexSelectionQuota(t, r, "poolcx", later, 10, 10, 10*time.Minute, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", later, 10, 10, 4*time.Hour, 6*24*time.Hour)
	held, err := s.sessionBind("parallel", "gh:1005", "", credvault.Codex, later, true)
	if err != nil || held.Account != "poolcx2" || held.Rev != 2 {
		t.Fatalf("thrash: %+v %v", held, err)
	}
	// A lost / unknown current reading isn't proof another account is bigger.
	choices, err := s.sessionBindChoices("gh:1005", "", credvault.Codex)
	if err != nil {
		t.Fatal(err)
	}
	pick, why := s.codexSelect(choices, held, now.Add(time.Hour), true)
	if pick.Account != "poolcx2" || why != "no_known_safe_alternative" && why != "best_current" {
		t.Fatalf("stale move: %s %s", pick.Account, why)
	}
}

func TestCodexQuotaAuthorizationAndHealth(t *testing.T) {
	r := newCPRig(t)
	s := r.h.srv
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	codexSelectionQuota(t, r, "poolcx", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", now, 10, 10, 15*time.Minute, 6*24*time.Hour)
	b, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: "authorized", Provider: credvault.Codex, Owner: store.PoolPrincipal, Account: "poolcx", SetBy: "auto"}, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	first, _ := s.Store.Credential(store.PoolPrincipal, credvault.Codex, "poolcx")
	setPolicy(t, r.h, "user", "gh:1005", []string{s.Vault.CredentialID(*first)})
	got, err := s.sessionBind(b.WorkerID, "gh:1005", "", credvault.Codex, now, true)
	if err != nil || got.Account != "poolcx" {
		t.Fatalf("selection bypassed allowlist: %+v %v", got, err)
	}
	// Allow both, then reauth excludes the otherwise more attractive account.
	second, _ := s.Store.Credential(store.PoolPrincipal, credvault.Codex, "poolcx2")
	setPolicy(t, r.h, "user", "gh:1005", []string{s.Vault.CredentialID(*first), s.Vault.CredentialID(*second)})
	if err := s.Store.MarkReauthRequired(store.PoolPrincipal, credvault.Codex, "poolcx2", "fixture", true, now); err != nil {
		t.Fatal(err)
	}
	got, err = s.sessionBind(b.WorkerID, "gh:1005", "", credvault.Codex, now, true)
	if err != nil || got.Account != "poolcx" {
		t.Fatalf("selection bypassed reauth: %+v %v", got, err)
	}
	// All denied is a refusal, not a choice from the unfiltered vault.
	setPolicy(t, r.h, "user", "gh:1005", []string{})
	if _, err := s.sessionBind(b.WorkerID, "gh:1005", "", credvault.Codex, now, true); err == nil {
		t.Fatal("all denied was allowed")
	}
	// A 429 outranks a fresh positive snapshot and expires only on its own clock.
	s.limits.mark(first.Provider, first.PrincipalID, s.Vault.CredentialID(*first), now.Add(time.Hour))
	if got := s.codexQuotaFor(*first, now); got.State != "limited" || got.Reason != "429_cooldown" {
		t.Fatal(got)
	}
	if got := s.codexQuotaFor(*first, now.Add(time.Hour)); got.State != "unknown" {
		t.Fatal("expired cooldown invented fresh quota", got)
	}
}

func TestCodexQuotaResolveExistingSession(t *testing.T) {
	r := newCPRig(t)
	s := r.h.srv
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	before := time.Now().Add(-time.Minute)
	for _, label := range []string{"poolcx", "poolcx2"} {
		codexSelectionQuota(t, r, label, before, 10, 10, 4*time.Hour, 6*24*time.Hour)
	}
	pass, wid := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Codex, pass); st != 200 {
		t.Fatalf("initial %d %s", st, body)
	}
	b, err := s.Store.SessionBindFor(wid, credvault.Codex)
	if err != nil || b.Account != "poolcx" {
		t.Fatalf("initial %+v %v", b, err)
	}
	if _, err := s.Store.SetSessionBind(b, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	codexSelectionQuota(t, r, "poolcx2", time.Now(), 50, 50, 15*time.Minute, 6*24*time.Hour)
	r.pastCache()
	n := r.upCount()
	if st, body := r.call(t, credvault.Codex, pass); st != 200 {
		t.Fatalf("new request %d %s", st, body)
	}
	b, err = s.Store.SessionBindFor(wid, credvault.Codex)
	if err != nil || b.Account != "poolcx2" || r.upCount() != n+1 {
		t.Fatalf("existing session not moved once: %+v %v requests=%d", b, err, r.upCount()-n)
	}
}
