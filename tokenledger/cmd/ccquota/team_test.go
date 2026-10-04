package main

import (
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/store"
)

func TestRunTeam_AssignsAndRefusesUnknown(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db) // enrolls ep-1

	if err := runTeam([]string{"--db", db, "--endpoint", "ep-1", "--set", "platform"}); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	eps, err := st.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if eps[0].Team != "platform" {
		t.Fatalf("team = %q, want platform", eps[0].Team)
	}

	if err := runTeam([]string{"--db", db, "--endpoint", "ghost", "--set", "platform"}); err == nil {
		t.Error("assigning a team to an unknown endpoint was accepted")
	}
}

func TestRunTeam_RequiresSomethingToDo(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db)
	if err := runTeam([]string{"--db", db}); err == nil {
		t.Error("runTeam with no flags did nothing and reported success")
	}
}
