package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A pushed team version (claude-fleet#1899): one sync per version, a failed
// one retried on the next kick (the beat), a repeat after a reconnect not run.
func TestTeamPushSyncRetryDedup(t *testing.T) {
	home := t.TempDir()
	a := &Agent{cfg: Config{Home: home}}
	if a.teamCapable() {
		t.Fatal("no fleet-agent-team.py: the agent must not list CapTeam")
	}
	script := filepath.Join(home, fleetTeamScript)
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !a.teamCapable() {
		t.Fatal("with fleet-agent-team.py the agent lists CapTeam")
	}

	var mu sync.Mutex
	var runs []string
	exit := "1"
	old := teamCommand
	teamCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		mu.Lock()
		runs = append(runs, strings.Join(args, " "))
		code := exit
		mu.Unlock()
		return exec.CommandContext(ctx, "sh", "-c", "echo team: the hub answered nothing; exit "+code)
	}
	t.Cleanup(func() { teamCommand = old })
	count := func() int { mu.Lock(); defer mu.Unlock(); return len(runs) }
	idle := func() {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			st := a.team()
			st.mu.Lock()
			r := st.running
			st.mu.Unlock()
			if !r {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("sync never finished")
	}
	push := func(v int) {
		m, _ := control.New(control.TypeTeam, control.Team{TeamVersion: v})
		a.handleTeam(context.Background(), m)
		idle()
	}
	ctx := context.Background()

	push(3)
	if count() != 1 || runs[0] != "sync --hub-version 3" {
		t.Fatalf("push v3: runs %q, want one `sync --hub-version 3`", runs)
	}
	// failed → the next beat runs it again
	a.teamKick(ctx)
	idle()
	if count() != 2 {
		t.Fatalf("beat after a failed sync: %d runs, want 2", count())
	}
	mu.Lock()
	exit = "0"
	mu.Unlock()
	a.teamKick(ctx)
	idle()
	if count() != 3 {
		t.Fatalf("retry: %d runs, want 3", count())
	}
	// synced → beats and a reconnect's repeat of v3 run nothing
	a.teamKick(ctx)
	idle()
	push(3)
	if count() != 3 {
		t.Fatalf("v3 already synced: %d runs, want still 3", count())
	}
	// a new version runs once
	push(4)
	if count() != 4 || runs[3] != "sync --hub-version 4" {
		t.Fatalf("push v4: runs %q", runs)
	}
	// version 0 (no team layer) is never a sync
	push(0)
	if count() != 4 {
		t.Fatalf("v0: %d runs, want 4", count())
	}
	// exit 3 (no hub configured on this login) is done, not a retry loop
	mu.Lock()
	exit = "3"
	mu.Unlock()
	push(5)
	a.teamKick(ctx)
	idle()
	if count() != 5 {
		t.Fatalf("exit 3: %d runs, want 5 (no retry)", count())
	}
}
