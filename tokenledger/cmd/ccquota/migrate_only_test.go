package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
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

	t.Setenv("CCQUOTA_FLEET_PRINCIPAL_LOGINS", "gh:1=Not A Login")
	if err := runHub(args()); err == nil || !strings.Contains(err.Error(), "PRINCIPAL_LOGINS") {
		t.Errorf("a bad CCQUOTA_FLEET_PRINCIPAL_LOGINS passed the check: %v", err)
	}
	t.Setenv("CCQUOTA_FLEET_PRINCIPAL_LOGINS", "")

	if err := runHub(args("--simulate-migration-failure")); err == nil || !strings.Contains(err.Error(), "simulated") {
		t.Errorf("the drill did not fail: %v", err)
	}
	if err := runHub(args("--migrate-only")); err == nil {
		t.Error("--check with --migrate-only was accepted")
	}
}
