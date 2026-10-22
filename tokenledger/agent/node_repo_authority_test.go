package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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
	for _, bad := range []string{"-x/y", "org", "a/b/c"} {
		push(bad, 9)
	}
	push("org/b", 0)
	if count() != 4 {
		t.Fatalf("malformed pushes ran the script: %q", runs)
	}
	// A host that hosts no repo yet (claude-fleet T490) is pushed with none:
	// the re-read runs with no repo argument.
	push("", 1)
	if count() != 5 || runs[4] != "/fleet/bin/fleet-hub-node.sh authority-sync" {
		t.Fatalf("no-repo push: runs %q", runs)
	}
}

// A reconnect re-pushes every repo at once (claude-fleet T903): the re-reads
// queue on authoritySlots instead of all asking the credential proxy together,
// and every one still runs.
func TestRepoAuthoritySyncsBounded(t *testing.T) {
	a := &Agent{}
	dir := t.TempDir()
	old := authorityCommand
	authorityCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		// each run marks itself, counts who else is running, then leaves
		return exec.CommandContext(ctx, "sh", "-c",
			`mkdir -p "$1/run"; touch "$1/run/$$"; ls "$1/run" | wc -l >> "$1/seen"; sleep 0.1; rm "$1/run/$$"`, "_", dir)
	}
	t.Cleanup(func() { authorityCommand = old })
	ctx := context.Background()
	for i := 0; i < 8; i++ {
		m, _ := control.New(control.TypeRepoAuthority, control.RepoAuthority{Repo: "org/r" + string(rune('a'+i)), Mode: "hub", Revision: 2})
		a.handleRepoAuthority(ctx, "/fleet/bin/fleet-hub-node.sh", m)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		a.authority.mu.Lock()
		synced := 0
		for _, w := range a.authority.repos {
			if w.done == 2 {
				synced++
			}
		}
		a.authority.mu.Unlock()
		if synced == 8 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("only %d of 8 re-reads synced", synced)
		}
		time.Sleep(20 * time.Millisecond)
	}
	b, err := os.ReadFile(filepath.Join(dir, "seen"))
	if err != nil {
		t.Fatal(err)
	}
	seen := strings.Fields(string(b))
	peak := 0
	for _, f := range seen {
		if n, _ := strconv.Atoi(f); n > peak {
			peak = n
		}
	}
	if len(seen) != 8 || peak > 2 {
		t.Fatalf("runs %d, peak %d at once — want 8 runs, at most 2 at once", len(seen), peak)
	}
}
