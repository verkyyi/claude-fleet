package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/store"
)

// captureStdout runs fn with os.Stdout redirected and returns what it printed.
// These commands report to a human through stdout, so what they print is part
// of the behaviour worth pinning.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stdout
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		io.Copy(&buf, r)
		done <- buf.String()
	}()
	fn()
	w.Close()
	os.Stdout = saved
	return <-done
}

// TestRunEndpoint_RetireKillsTheTokenAndKeepsTheRow is the whole feature from
// the CLI's side: the endpoint stops being on the roster and stops being able
// to push, and its spend is still there.
func TestRunEndpoint_RetireKillsTheTokenAndKeepsTheRow(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db) // enrolls ep-1 (token hash "hash-1") and gives it an event

	if err := runEndpoint([]string{"--db", db, "retire", "ep-1"}); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	active, err := st.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if len(active) != 0 {
		t.Fatalf("retired endpoint still on the roster: %+v", active)
	}
	all, err := st.ListEndpointsWithRetired("")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].RetiredAt == nil {
		t.Fatalf("the row must survive with retired_at set, got %+v", all)
	}
	if _, err := st.EndpointByTokenHash("hash-1"); err == nil {
		t.Fatal("the enrollment token must stop resolving")
	}

	// Retiring it again is reported as a no-op rather than a second success.
	err = runEndpoint([]string{"--db", db, "retire", "ep-1"})
	if err == nil || !strings.Contains(err.Error(), "already retired") {
		t.Fatalf("second retire should say it was already retired, got %v", err)
	}
}

// TestRunEndpoint_DeleteRefusesAnEndpointWithHistory is the guard that keeps
// historical totals honest.
func TestRunEndpoint_DeleteRefusesAnEndpointWithHistory(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db)

	err := runEndpoint([]string{"--db", db, "delete", "ep-1"})
	if err == nil {
		t.Fatal("deleting an endpoint whose spend is in the ledger must refuse")
	}
	if !strings.Contains(err.Error(), "refusing to delete") {
		t.Fatalf("unexpected error: %v", err)
	}

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.EndpointByID("ep-1"); err != nil {
		t.Fatalf("a refused delete must change nothing: %v", err)
	}
}

// TestRunEndpoint_DeleteRemovesAnUnusedEnrollment is the mint-then-abandon
// case from issue #42 — the only one delete is for.
func TestRunEndpoint_DeleteRemovesAnUnusedEnrollment(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db)

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("ep-verify", "verify-health-shipper", "hash-v"); err != nil {
		t.Fatal(err)
	}
	st.Close()

	if err := runEndpoint([]string{"--db", db, "delete", "ep-verify"}); err != nil {
		t.Fatal(err)
	}

	st2, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st2.Close()
	if _, err := st2.EndpointByID("ep-verify"); err == nil {
		t.Fatal("delete left the row behind")
	}
	if _, err := st2.EndpointByID("ep-1"); err != nil {
		t.Fatalf("delete touched the wrong endpoint: %v", err)
	}
}

// TestRunEndpoint_AllFlagWorksAfterTheVerb pins the shape everyone types.
//
// Go's flag package stops parsing at the first non-flag argument, so a single
// FlagSet over ["list", "--all"] leaves --all as a positional and reports the
// ACTIVE endpoints — a wrong answer delivered as a success, which is the worst
// way for this to fail.
func TestRunEndpoint_AllFlagWorksAfterTheVerb(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db)

	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.RetireEndpoint("ep-1"); err != nil {
		t.Fatal(err)
	}
	st.Close()

	for _, args := range [][]string{
		{"--db", db, "list", "--all"},
		{"--db", db, "--all", "list"},
		{"list", "--all", "--db", db},
	} {
		out := captureStdout(t, func() {
			if err := runEndpoint(args); err != nil {
				t.Fatalf("runEndpoint(%v): %v", args, err)
			}
		})
		if !strings.Contains(out, "ep-1") || !strings.Contains(out, "retired") {
			t.Errorf("runEndpoint(%v) did not list the retired endpoint:\n%s", args, out)
		}
	}

	// ...and without --all it stays hidden.
	out := captureStdout(t, func() {
		if err := runEndpoint([]string{"--db", db, "list"}); err != nil {
			t.Fatal(err)
		}
	})
	if strings.Contains(out, "ep-1") {
		t.Errorf("a retired endpoint must not show without --all:\n%s", out)
	}
}

func TestRunEndpoint_RejectsBadInvocations(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ccquota.db")
	seedBadgeDB(t, db)

	for _, args := range [][]string{
		{"--db", db},                         // no verb
		{"--db", db, "retire"},               // no id
		{"--db", db, "delete"},               // no id
		{"--db", db, "retyre", "ep-1"},       // typo'd verb
		{"--db", db, "retire", "ep-nothere"}, // unknown id
	} {
		if err := runEndpoint(args); err == nil {
			t.Errorf("runEndpoint(%v) was accepted", args)
		}
	}
}

// `endpoint list` must not create a database, for the same reason `enroll`
// must not: a command that quietly invents one answers about a hub that has
// never existed.
func TestRunEndpoint_RefusesToInventADatabase(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope.db")
	if err := runEndpoint([]string{"--db", missing, "list"}); err == nil {
		t.Fatal("endpoint list created a database instead of refusing")
	}
}
