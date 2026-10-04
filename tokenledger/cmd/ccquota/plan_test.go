package main

import (
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func TestRunPlan_RecordsAPriceAndItsChange(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db)

	if err := runPlan([]string{"--db", db, "--set", "max", "--monthly", "200",
		"--from", "2026-01-01T00:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	if err := runPlan([]string{"--db", db, "--set", "max", "--monthly", "250",
		"--from", "2026-07-01T00:00:00Z"}); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	plans, err := st.ListPlanPrices()
	if err != nil || len(plans) != 2 {
		t.Fatalf("plans=%+v err=%v", plans, err)
	}
	// The change appended; it did not overwrite what last period cost.
	if plans[0].MonthlyCost != 250 || plans[1].MonthlyCost != 200 {
		t.Errorf("history=%+v, want 250 current over 200 superseded", plans)
	}
	if plans[0].Currency != store.DefaultCurrency || plans[0].Source != model.SourceClaude {
		t.Errorf("defaults not applied: %+v", plans[0])
	}

	if err := runPlan([]string{"--db", db, "--list"}); err != nil {
		t.Fatal(err)
	}
	if err := runPlan([]string{"--db", db, "--spend", "--days", "30"}); err != nil {
		t.Fatal(err)
	}
}

// A plan priced at nothing by accident is worse than one left unpriced: it
// reads as free everywhere it is shown. --monthly is therefore required rather
// than defaulted to 0.
func TestRunPlan_RefusesAnAmountlessOrMalformedPrice(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db)

	if err := runPlan([]string{"--db", db, "--set", "max"}); err == nil {
		t.Error("--set with no --monthly was accepted")
	}
	if err := runPlan([]string{"--db", db, "--set", "max", "--monthly", "200",
		"--from", "January 2026"}); err == nil {
		t.Error("a non-RFC3339 --from was accepted")
	}
	if err := runPlan([]string{"--db", db}); err == nil {
		t.Error("runPlan with no flags did nothing and reported success")
	}
	if err := runPlan([]string{"--db", db, "--spend", "--days", "0"}); err == nil {
		t.Error("--days 0 was accepted")
	}
}
