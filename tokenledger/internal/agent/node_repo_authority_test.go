package agent

import (
	"context"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A pushed repo authority move (claude-fleet#4730): one re-read per revision
// per repo, a failed one retried on the next beat, a repeat not run, and a
// malformed repo never handed to the script.
func TestRepoAuthorityPushSyncRetryDedup(t *testing.T) {
	a := &Agent{}
	var mu sync.Mutex
	var runs []string
	exit := "1"
	old := authorityCommand
	authorityCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		mu.Lock()
		runs = append(runs, name+" "+strings.Join(args, " "))
		code := exit
		mu.Unlock()
		return exec.CommandContext(ctx, "sh", "-c", "echo repo authority: hub unavailable; exit "+code)
	}
	t.Cleanup(func() { authorityCommand = old })
	count := func() int { mu.Lock(); defer mu.Unlock(); return len(runs) }
	idle := func() {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			busy := false
			a.authority.mu.Lock()
			for _, w := range a.authority.repos {
				busy = busy || w.running
			}
			a.authority.mu.Unlock()
			if !busy {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("re-read never finished")
	}
	ctx := context.Background()
	push := func(repo string, rev int64) {
		m, _ := control.New(control.TypeRepoAuthority, control.RepoAuthority{Repo: repo, Mode: "hub", Revision: rev})
		a.handleRepoAuthority(ctx, "/fleet/bin/fleet-hub-node.sh", m)
		idle()
	}

	push("org/a", 2)
	if count() != 1 || runs[0] != "/fleet/bin/fleet-hub-node.sh authority-sync org/a" {
		t.Fatalf("push: runs %q", runs)
	}
	a.authorityKick(ctx)
	idle()
	if count() != 2 {
		t.Fatalf("beat after a failed re-read: %d runs, want 2", count())
	}
	mu.Lock()
	exit = "0"
	mu.Unlock()
	a.authorityKick(ctx)
	idle()
	a.authorityKick(ctx)
	idle()
	push("org/a", 2)
	if count() != 3 {
		t.Fatalf("after a synced revision: %d runs, want 3", count())
	}
	push("org/a", 3)
	if count() != 4 {
		t.Fatalf("a new revision: %d runs, want 4", count())
	}
	for _, bad := range []string{"", "-x/y", "org", "a/b/c"} {
		push(bad, 9)
	}
	push("org/b", 0)
	if count() != 4 {
		t.Fatalf("malformed pushes ran the script: %q", runs)
	}
}
