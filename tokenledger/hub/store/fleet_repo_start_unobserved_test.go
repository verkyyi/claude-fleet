package store

import (
	"sort"
	"strings"
	"testing"
	"time"
)

// Issue #4792: a begun start whose agent exited with no native ever observed —
// a warm Codex window closed before its first turn — closes as abandoned. Only
// that start, only by its own worker; a late observe is fenced afterwards and
// the repo's authority blockers no longer list it.
func TestRepoStartUnobservedCloses(t *testing.T) {
	s := taskStore(t)
	now := time.Date(2026, 10, 19, 0, 0, 0, 0, time.UTC)
	proof := &RepoNativeIdentity{WorkerID: "fleet/worker", NativeSession: "sid", PID: 123, Birth: "birth", Executable: "/bin/codex"}
	call := func(key, action, worker string, native *RepoNativeIdentity) (RepoLocalStart, error) {
		return s.RepoLocalStart("org/repo", "alice", "node", key, action, worker, native, now)
	}
	must := func(key, action string) RepoLocalStart {
		t.Helper()
		r, err := call(key, action, proof.WorkerID, nil)
		if err != nil {
			t.Fatal(key, action, err)
		}
		return r
	}
	must("warm", "reserve")
	if _, err := call("warm", "unobserved", proof.WorkerID, nil); err == nil {
		t.Fatal("a never-begun reservation is cancelled, not abandoned")
	}
	must("warm", "begin")
	if _, err := call("warm", "unobserved", "fleet/other", nil); err == nil {
		t.Fatal("another worker closed this start")
	}
	if _, err := call("warm", "unobserved", "", nil); err == nil {
		t.Fatal("a start closed with no worker named")
	}
	if r := must("warm", "unobserved"); r.Phase != "abandoned" || r.Native != nil {
		t.Fatal("not abandoned", r)
	}
	if r := must("warm", "unobserved"); r.Phase != "abandoned" {
		t.Fatal("replay changed the phase", r)
	}
	if _, err := call("warm", "observe", proof.WorkerID, proof); err == nil {
		t.Fatal("a late observe took authority after abandon")
	}
	var status string
	if err := s.read.QueryRow(`SELECT status FROM fleet_operations WHERE id = ?`, repoStartID("org/repo", "alice", "node", "warm")).Scan(&status); err != nil || status != "succeeded" {
		t.Fatal("abandoned start still running", status, err)
	}

	// An observed start keeps its native: never abandoned.
	must("used", "reserve")
	must("used", "begin")
	if _, err := call("used", "observe", proof.WorkerID, proof); err != nil {
		t.Fatal(err)
	}
	if _, err := call("used", "unobserved", proof.WorkerID, nil); err == nil {
		t.Fatal("an observed native was closed without a stop proof")
	}

	blockers, _, err := s.OwnerAuthorityBlockers("alice", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(blockers, "\n")
	if strings.Contains(joined, "local start retained: warm") || !strings.Contains(joined, "local start retained: used") {
		t.Fatal("blockers", blockers)
	}
}

// Issue #4832: RepoOpenStarts is the retained set, scoped by owner / endpoint.
func TestRepoOpenStartsScoped(t *testing.T) {
	s := taskStore(t)
	now := time.Date(2026, 10, 19, 0, 0, 0, 0, time.UTC)
	for _, c := range []struct{ owner, ep, key, action, worker string }{
		{"alice", "node", "a", "reserve", ""}, {"alice", "node", "b", "reserve", ""}, {"alice", "node", "b", "cancel", ""},
		{"alice", "other", "c", "reserve", ""}, {"alice", "node", "d", "reserve", ""}, {"alice", "node", "d", "begin", "fleet/w"},
	} {
		if _, err := s.RepoLocalStart("org/repo", c.owner, c.ep, c.key, c.action, c.worker, nil, now); err != nil {
			t.Fatal(c, err)
		}
	}
	got := func(owner, ep string) string {
		rows, err := s.RepoOpenStarts("org/repo", owner, ep)
		if err != nil {
			t.Fatal(err)
		}
		keys := []string{}
		for _, r := range rows {
			keys = append(keys, r.Reservation+":"+r.Phase)
		}
		sort.Strings(keys) // one clock tick here: order is the id's
		return strings.Join(keys, ",")
	}
	if g := got("alice", "node"); g != "a:reserved,d:starting" {
		t.Fatal(g)
	}
	if g := got("", ""); g != "a:reserved,c:reserved,d:starting" {
		t.Fatal(g)
	}
	if g := got("bob", ""); g != "" {
		t.Fatal(g)
	}
	if rows, _ := s.RepoOpenStarts("org/other", "", ""); len(rows) != 0 {
		t.Fatal("another repo", rows)
	}
}
