package main

import (
	"bytes"
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
