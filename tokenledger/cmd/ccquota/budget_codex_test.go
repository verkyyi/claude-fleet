package main

import (
	"github.com/verkyyi/ccquota/internal/api"
	"testing"
	"time"
)

func TestCodexBudgetGenericWindowsAndUnknown(t *testing.T) {
	reset := time.Now().Add(time.Hour)
	v := &api.LimitsView{Source: "codex", Available: true, Windows: []api.ProviderWindow{{ID: "codex:primary", Minutes: 10080, WindowView: api.WindowView{Utilization: 95, ResetsAt: &reset}}}}
	a := flatten("x", "Codex", v)
	if a.HeadroomPct != 5 || len(a.Windows) != 1 {
		t.Fatalf("generic window ignored: %+v", a)
	}
	if r := decideBudget(BudgetReport{Accounts: []BudgetAccount{a}}, 90); r.Verdict != verdictHold {
		t.Fatal("full quota not held")
	}
	v.Windows = nil
	a = flatten("x", "Codex", v)
	if a.Available {
		t.Fatal("missing windows treated as 0%")
	}
	v.Blocked = true
	a = flatten("x", "Codex", v)
	if !a.Available || a.HeadroomPct != 0 {
		t.Fatal("spend control not held")
	}
	v.StaleSeconds = 1000
	a = flatten("x", "Codex", v)
	if a.Available {
		t.Fatal("stale block treated as current")
	}
}
