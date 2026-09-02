package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func seedBadgeDB(t *testing.T, path string) {
	t.Helper()
	st, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	id := model.Identity{AccountUUID: "acct-1", Email: "a@example.com", Hostname: "h1"}
	if err := st.UpsertAccount(id, "max", "tier"); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("ep-1", "ep-1", "hash-1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.TouchEndpoint("ep-1", id, "test", true); err != nil {
		t.Fatal(err)
	}
	cost := 1.5
	if _, _, err := st.InsertEvents([]model.UsageEvent{{
		AccountUUID: "acct-1", EndpointID: "ep-1", MessageUUID: "m1",
		TS: time.Now().UTC().Add(-time.Hour), Model: "claude-opus-5",
		InputTokens: 1000, OutputTokens: 2000, CostUSD: &cost,
		CWD: "/w", OSUser: "alice",
	}}); err != nil {
		t.Fatal(err)
	}
}

func TestPeriodRange(t *testing.T) {
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)

	if _, all, err := periodRange("all", now); err != nil || !all {
		t.Errorf(`periodRange("all") = all:%v err:%v, want all:true nil`, all, err)
	}
	if _, all, err := periodRange("", now); err != nil || !all {
		t.Errorf(`periodRange("") should default to all-time, got all:%v err:%v`, all, err)
	}
	start, all, err := periodRange("30d", now)
	if err != nil || all {
		t.Fatalf(`periodRange("30d") = all:%v err:%v`, all, err)
	}
	if want := now.AddDate(0, 0, -30); !start.Equal(want) {
		t.Errorf("start = %v, want %v", start, want)
	}
	// A period Go's ParseDuration would accept but that means nothing here
	// must be refused rather than silently treated as all-time -- a badge
	// showing a lifetime total under a "7d" label is a lie.
	for _, bad := range []string{"7", "1w", "24h", "-3d", "abc"} {
		if _, _, err := periodRange(bad, now); err == nil {
			t.Errorf("periodRange(%q) was accepted; it must be refused", bad)
		}
	}
}

func TestRunBadge_WritesSVGWithoutNetwork(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db)

	out := filepath.Join(dir, "ccquota.svg")
	if err := runBadge([]string{"--db", db, "--out", out, "--theme", "dark", "--period", "all"}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	svg := string(b)
	if !strings.HasPrefix(svg, "<svg") {
		t.Fatalf("output is not an SVG: %.40q", svg)
	}
	if !strings.Contains(svg, "tokens") {
		t.Error("badge does not carry a token figure")
	}
	// The xmlns identifier is the one permitted URI; see the badge package's
	// own test for why.
	svg = strings.ReplaceAll(svg, `xmlns="http://www.w3.org/2000/svg"`, "")
	for _, forbidden := range []string{"http://", "https://"} {
		if strings.Contains(svg, forbidden) {
			t.Errorf("locally rendered badge contains %q", forbidden)
		}
	}
}

func TestRunBadge_WritesShieldsJSON(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ccquota.db")
	seedBadgeDB(t, db)

	out := filepath.Join(dir, "ccquota.json")
	if err := runBadge([]string{"--db", db, "--json", "--out", out}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("output is not JSON: %v", err)
	}
	if got["schemaVersion"] != float64(1) {
		t.Errorf("schemaVersion = %v, want 1", got["schemaVersion"])
	}
}

// The command reads and never writes, so it must refuse to bring a database
// into being -- a badge rendered from an empty accidental database reports
// zero and looks like a working badge.
func TestRunBadge_RefusesMissingDatabase(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope.db")
	err := runBadge([]string{"--db", missing, "--out", filepath.Join(t.TempDir(), "x.svg")})
	if err == nil {
		t.Fatal("runBadge created or accepted a missing database; it must refuse")
	}
	if _, statErr := os.Stat(missing); statErr == nil {
		t.Error("runBadge created the database file")
	}
}
