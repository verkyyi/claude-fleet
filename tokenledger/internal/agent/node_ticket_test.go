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

// A hub ticket's comment (claude-fleet#3597): CapTicket only with the bridge,
// one --event run per comment, nothing for a state change / claim / edit.
func TestTicketPushRunsBridge(t *testing.T) {
	home := t.TempDir()
	a := &Agent{cfg: Config{Home: home}}
	if a.ticketCapable() {
		t.Fatal("no fleet-issue-bridge.sh: the agent must not list CapTicket")
	}
	script := filepath.Join(home, fleetBridgeScript)
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !a.ticketCapable() {
		t.Fatal("with fleet-issue-bridge.sh the agent lists CapTicket")
	}

	var mu sync.Mutex
	var runs []string
	ran := make(chan struct{}, 8)
	old := bridgeCommand
	bridgeCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		mu.Lock()
		runs = append(runs, strings.Join(args[1:], " "))
		mu.Unlock()
		return exec.CommandContext(ctx, "sh", "-c", "echo not now; exit 75")
	}
	t.Cleanup(func() { bridgeCommand = old })

	push := func(ev control.Ticket) {
		m, err := control.New(control.TypeTicket, ev)
		if err != nil {
			t.Fatal(err)
		}
		a.handleTicket(context.Background(), m)
	}
	push(control.Ticket{Repo: "o/n", Number: 7, Kind: "state"})
	push(control.Ticket{Repo: "o/n", Number: 7, Kind: "claim"})
	push(control.Ticket{Repo: "o/n", Number: 7, Kind: "comment"}) // no comment id
	go func() {
		// the one real comment
		push(control.Ticket{Repo: "o/n", Number: 7, Kind: "comment", CommentID: 42})
		ran <- struct{}{}
	}()
	<-ran
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(runs)
		mu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if len(runs) != 1 || runs[0] != "--event o/n 7 42" {
		t.Fatalf("runs %q, want one `--event o/n 7 42`", runs)
	}
}

// No home, no bridge: nothing listed, nothing run (the degenerate case).
func TestTicketOffWithoutHome(t *testing.T) {
	a := &Agent{}
	if a.ticketCapable() {
		t.Fatal("an agent with no home never lists CapTicket")
	}
}
