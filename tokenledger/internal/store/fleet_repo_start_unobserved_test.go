package store

import (
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

	blockers, _, err := s.RepoAuthorityBlockers("org/repo", false)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(blockers, "\n")
	if strings.Contains(joined, "local start retained: warm") || !strings.Contains(joined, "local start retained: used") {
		t.Fatal("blockers", blockers)
	}
}
