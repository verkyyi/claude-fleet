package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func exitRetryFixture(t *testing.T, home, flag, body string) relayPaths {
	t.Helper()
	script := filepath.Join(home, fleetHubNodeScript)
	if err := os.MkdirAll(filepath.Dir(script), 0755); err != nil {
		t.Fatal(err)
	}
	content := fmt.Sprintf("#!/bin/sh\ncase \"$1\" in\npaths) printf 'outbox\\t%s/out\\nworkers\\t%s/workers\\n%s' ;;\nexecution-exit-retry) %s ;;\nesac\n", home, home, flag, body)
	if err := os.WriteFile(script, []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
	p, ok := relaySetup(context.Background(), home)
	if !ok {
		t.Fatal("relay setup failed")
	}
	return p
}

func exitRetryIdle(s *executionExitRetry) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.running
}

func TestExecutionExitRetryHeartbeatReconnectAndLogin(t *testing.T) {
	for _, login := range []string{"alpha", "beta"} {
		t.Run(login, func(t *testing.T) {
			home := t.TempDir()
			p := exitRetryFixture(t, home, "execution_exit_retry\\t1\\n", `printf '%s|%s|%s\n' "$HOME" "$USER" "$FLEET_CONF_DIR" >> "$HOME/runs"; test ! -f "$HOME/fail"`)
			if !p.executionExitRetry {
				t.Fatal("local retry probe not recognized")
			}
			ctx := withRunAs(context.Background(), selfRunAs(t, login, home))
			s := &executionExitRetry{}
			if err := os.WriteFile(filepath.Join(home, "fail"), nil, 0600); err != nil {
				t.Fatal(err)
			}
			s.kick(ctx, p)
			executionSyncWait(t, func() bool { return exitRetryIdle(s) })
			if err := os.Remove(filepath.Join(home, "fail")); err != nil {
				t.Fatal(err)
			}
			s.kick(ctx, p) // within throttle: no second process
			for i := 0; i < 2; i++ {
				s.mu.Lock()
				s.next = time.Time{}
				s.mu.Unlock() // later heartbeat
				s.kick(ctx, p)
				executionSyncWait(t, func() bool { return exitRetryIdle(s) })
			}
			next := &executionExitRetry{}
			next.kick(ctx, p) // reconnect does not inherit the throttle
			executionSyncWait(t, func() bool { return exitRetryIdle(next) })
			got, err := os.ReadFile(filepath.Join(home, "runs"))
			want := strings.Repeat(home+"|"+login+"|"+filepath.Join(home, ".config", "claude-fleet")+"\n", 4)
			if err != nil || string(got) != want {
				t.Fatalf("wrong retry identity/count: %q %v", got, err)
			}
		})
	}
}

func TestExecutionExitRetryCancellationAndDedup(t *testing.T) {
	home := t.TempDir()
	p := exitRetryFixture(t, home, "execution_exit_retry\\t1\\n", `echo started >> "$HOME/runs"; exec sleep 30`)
	ctx, cancel := context.WithCancel(withRunAs(context.Background(), selfRunAs(t, "alpha", home)))
	defer cancel()
	s := &executionExitRetry{}
	s.kick(ctx, p)
	executionSyncWait(t, func() bool { _, err := os.Stat(filepath.Join(home, "runs")); return err == nil })
	s.mu.Lock()
	s.next = time.Time{}
	s.mu.Unlock()
	s.kick(ctx, p) // even outside throttle, an in-flight helper is not duplicated
	cancel()
	executionSyncWait(t, func() bool { return exitRetryIdle(s) })
	s.kick(ctx, p)
	got, err := os.ReadFile(filepath.Join(home, "runs"))
	if err != nil || string(got) != "started\n" {
		t.Fatalf("duplicate or late retry: %q %v", got, err)
	}
}

func TestExecutionExitRetryOldPathsDoNothing(t *testing.T) {
	for _, flag := range []string{"", "execution_exit_retry\\t0\\n", "execution_exit_retry\\ttrue\\n", "task_execution_v1\\t1\\n"} {
		home := t.TempDir()
		p := exitRetryFixture(t, home, flag, `touch "$HOME/unexpected"`)
		s := &executionExitRetry{}
		s.kick(context.Background(), p)
		if p.executionExitRetry || !exitRetryIdle(s) || !s.next.IsZero() {
			t.Fatal("old paths enabled exit retry")
		}
		if _, err := os.Stat(filepath.Join(home, "unexpected")); !os.IsNotExist(err) {
			t.Fatal("unexpected helper")
		}
	}
}
