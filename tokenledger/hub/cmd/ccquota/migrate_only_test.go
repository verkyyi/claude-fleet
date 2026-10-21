package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// `ccquota hub --migrate-only` (claude-fleet#2050): hub-deploy's rehearsal on
// a copy of the live database. It refuses a file that is not there — an empty
// database proves nothing — and on a real one runs the migrations and exits.
func TestMigrateOnly(t *testing.T) {
	dir := t.TempDir()
	if err := migrateOnlyRun(filepath.Join(dir, "missing.db"), &bytes.Buffer{}, false); err == nil {
		t.Fatal("a missing database was accepted")
	}

	db := filepath.Join(dir, "copy.db")
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	st.Close()
	var out bytes.Buffer
	if err := migrateOnlyRun(db, &out, false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "migration 1 remove-company-business") || !strings.Contains(out.String(), "migrate-only: "+db+" ok") {
		t.Errorf("output:\n%s", out.String())
	}
	if err := migrateOnlyRun(db, &bytes.Buffer{}, true); err == nil || !strings.Contains(err.Error(), "simulated") {
		t.Errorf("the drill did not fail: %v", err)
	}
}

// `ccquota hub --check` (claude-fleet#2052): hub-deploy runs the new image this
// way with the live pod's environment on a copy of the live database. It
// passes only when the start would have — the migrations AND every setting the
// hub refuses to start without — and never binds a port.
func TestHubCheck(t *testing.T) {
	for _, k := range []string{"CCQUOTA_FLEET", "CCQUOTA_GITHUB_CLIENT_ID", "CCQUOTA_GITHUB_CLIENT_SECRET", "CCQUOTA_GITHUB_ADMINS", "CCQUOTA_FLEET_PRINCIPAL_LOGINS", "CCQUOTA_DB"} {
		t.Setenv(k, "")
	}
	t.Setenv("CCQUOTA_VIEWER_TOKEN", "viewer")
	dir := t.TempDir()
	db := filepath.Join(dir, "copy.db")
	// A port nobody may hold: --check must not try to bind it.
	args := func(extra ...string) []string {
		return append([]string{"--check", "--db", db, "--addr", "0.0.0.0:1"}, extra...)
	}

	if err := runHub(args()); err == nil || !strings.Contains(err.Error(), "--check") {
		t.Fatalf("a missing database was accepted: %v", err)
	}
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	st.Close()

	if err := runHub(args()); err != nil {
		t.Fatalf("a good start failed the check: %v", err)
	}

	// The release that would have died at start: one GitHub key of the pair.
	t.Setenv("CCQUOTA_GITHUB_CLIENT_ID", "Iv1.abc")
	if err := runHub(args()); err == nil || !strings.Contains(err.Error(), "half configured") {
		t.Errorf("half a GitHub sign-in passed the check: %v", err)
	}
	t.Setenv("CCQUOTA_GITHUB_CLIENT_ID", "")

	pricing := filepath.Join(dir, "pricing.json")
	if err := os.WriteFile(pricing, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := runHub(args("--pricing", pricing)); err == nil {
		t.Error("an unreadable --pricing passed the check")
	}

	// claude-fleet#2087: the old login map is no longer read — a value that
	// once refused the start is ignored.
	t.Setenv("CCQUOTA_FLEET_PRINCIPAL_LOGINS", "gh:1=Not A Login")
	if err := runHub(args()); err != nil {
		t.Errorf("CCQUOTA_FLEET_PRINCIPAL_LOGINS is still read: %v", err)
	}
	t.Setenv("CCQUOTA_FLEET_PRINCIPAL_LOGINS", "")

	if err := runHub(args("--simulate-migration-failure")); err == nil || !strings.Contains(err.Error(), "simulated") {
		t.Errorf("the drill did not fail: %v", err)
	}
	if err := runHub(args("--migrate-only")); err == nil {
		t.Error("--check with --migrate-only was accepted")
	}
}

// claude-fleet T829: a price recorded by hand (`ccquota plan --set`, the
// console) newer than the --pricing file's own date for that plan made every
// new hub exit 1 at start — «codex/prolite already has a price starting
// 2026-10-21» — and three releases rolled back in CrashLoopBackOff. The file's
// older price is now skipped; the newer one stands, and the hub starts.
func TestHubStartsPastANewerRecordedPrice(t *testing.T) {
	for _, k := range []string{"CCQUOTA_FLEET", "CCQUOTA_GITHUB_CLIENT_ID", "CCQUOTA_GITHUB_CLIENT_SECRET", "CCQUOTA_GITHUB_ADMINS", "CCQUOTA_DB", "CCQUOTA_DB_URL"} {
		t.Setenv(k, "")
	}
	t.Setenv("CCQUOTA_VIEWER_TOKEN", "viewer")
	dir := t.TempDir()
	db := filepath.Join(dir, "copy.db")
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	newer := time.Date(2026, 10, 21, 0, 0, 0, 0, time.UTC)
	if err := st.SetPlanPrice(model.SubscriptionPlan{Plan: "prolite", Source: "codex", MonthlyCost: 100, EffectiveFrom: newer}); err != nil {
		t.Fatal(err)
	}
	st.Close()

	pricing := filepath.Join(dir, "pricing.json")
	if err := os.WriteFile(pricing, []byte(`{"plans": [
	  {"plan": "max", "source": "claude", "monthly_cost": 200, "currency": "USD", "effective_from": "2026-07-09T00:00:00Z"},
	  {"plan": "prolite", "source": "codex", "monthly_cost": 200, "currency": "USD", "effective_from": "2026-01-31T00:00:00Z"}
	]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := runHub([]string{"--check", "--db", db, "--addr", "0.0.0.0:1", "--pricing", pricing}); err != nil {
		t.Fatalf("a newer recorded price stopped the start: %v", err)
	}

	st, err = store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	p, err := st.PlanPriceAt("prolite", "codex", newer.Add(time.Hour))
	if err != nil || p == nil || p.MonthlyCost != 100 {
		t.Errorf("the newer recorded price did not stand: %+v err=%v", p, err)
	}
	m, err := st.PlanPriceAt("max", "claude", newer)
	if err != nil || m == nil || m.MonthlyCost != 200 {
		t.Errorf("the file's other price was not recorded: %+v err=%v", m, err)
	}
}
