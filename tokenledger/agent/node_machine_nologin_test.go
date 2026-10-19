package agent

import (
	"context"
	"strings"
	"testing"
	"time"
)

// A machine that opens its own logins runs its link with none yet: the hub's
// first create comes down it (claude-fleet#3554, a person's own pod). One that
// cannot open any still refuses to run empty.
func TestRunMachineNoLoginWaitsOnlyWithOpener(t *testing.T) {
	err := RunMachine(context.Background(), MachineConfig{HubURL: "http://127.0.0.1:1", Token: "t"})
	if err == nil || !strings.Contains(err.Error(), "no logins to serve") {
		t.Fatalf("no opener, no login: %v, want a refusal", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan error, 1)
	go func() {
		done <- RunMachine(ctx, MachineConfig{HubURL: "http://127.0.0.1:1", Token: "t",
			AccountOpener: "/nonexistent/fleet-node-linux.py", AccountState: t.TempDir()})
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("opener, no login: %v, want the link to run (and end with ctx)", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("opener, no login: RunMachine did not end with its context")
	}
}
