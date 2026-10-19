package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveDB_PrecedenceIsFlagThenEnvThenHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	t.Setenv("CCQUOTA_DB", "/from/env.db")
	if got, err := resolveDB("/from/flag.db"); err != nil || got != "/from/flag.db" {
		t.Errorf("flag: got %q, %v; want /from/flag.db", got, err)
	}
	if got, err := resolveDB(""); err != nil || got != "/from/env.db" {
		t.Errorf("env: got %q, %v; want /from/env.db", got, err)
	}

	t.Setenv("CCQUOTA_DB", "")
	want := filepath.Join(home, ".ccquota", "ccquota.db")
	got, err := resolveDB("")
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("default: got %q, want %q", got, want)
	}
	// The point of the change: the default must not depend on where the
	// command happens to be run from.
	if !filepath.IsAbs(got) {
		t.Errorf("default %q is relative; running enroll from another directory "+
			"would silently target a different database", got)
	}
}

// The bug this guards: `enroll` defaulted to ./ccquota.db, SQLite created it,
// and the minted token was printed as if it had worked. The failure surfaced
// only later and elsewhere, as a 401 in an agent's log on another machine.
func TestResolveExistingDB_RefusesToInventADatabase(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CCQUOTA_DB", "")

	missing := filepath.Join(home, "nowhere", "ccquota.db")
	_, err := resolveExistingDB(missing)
	if err == nil {
		t.Fatal("resolving a missing database succeeded; enroll would mint tokens into a new file")
	}
	if !strings.Contains(err.Error(), missing) {
		t.Errorf("error does not name the path it looked at: %v", err)
	}
	// The message has to connect the refusal to the symptom, or the next
	// person re-derives it from an agent log on a different machine.
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("error does not mention the symptom it prevents: %v", err)
	}

	// ...and it must still be usable. A guard that rejects everything would
	// pass the assertion above while breaking enrolment entirely.
	real := filepath.Join(home, "ccquota.db")
	if err := os.WriteFile(real, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := resolveExistingDB(real)
	if err != nil {
		t.Fatalf("an existing database was refused: %v", err)
	}
	if got != real {
		t.Errorf("got %q, want %q", got, real)
	}
}

// resolveExistingDB must apply the same precedence as resolveDB, or --db and
// $CCQUOTA_DB would mean different things depending on which command you ran.
func TestResolveExistingDB_HonoursEnvAndDefault(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	envDB := filepath.Join(home, "env.db")
	if err := os.WriteFile(envDB, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CCQUOTA_DB", envDB)
	if got, err := resolveExistingDB(""); err != nil || got != envDB {
		t.Errorf("env: got %q, %v; want %q", got, err, envDB)
	}

	t.Setenv("CCQUOTA_DB", "")
	defaultDB := filepath.Join(home, ".ccquota", "ccquota.db")
	if err := os.MkdirAll(filepath.Dir(defaultDB), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(defaultDB, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := resolveExistingDB(""); err != nil || got != defaultDB {
		t.Errorf("default: got %q, %v; want %q", got, err, defaultDB)
	}
}
