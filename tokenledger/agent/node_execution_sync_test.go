package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func executionSyncFixture(t *testing.T, home, flag, body string) relayPaths {
	t.Helper()
	script := filepath.Join(home, fleetHubNodeScript)
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	text := fmt.Sprintf("#!/bin/sh\ncase \"$1\" in\npaths) printf 'outbox\\t%s/out\\nworkers\\t%s/workers\\n%s' ;;\nexecution-sync) %s ;;\nesac\n", home, home, flag, body)
	if err := os.WriteFile(script, []byte(text), 0o755); err != nil {
		t.Fatal(err)
	}
	p, ok := relaySetup(context.Background(), home)
	if !ok {
		t.Fatal("fixture relay paths refused")
	}
	return p
}

func executionSyncWait(t *testing.T, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if done() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("execution synchronization did not reach the expected state")
}

func executionSyncIdle(s *executionStopSync) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.running
}

func TestExecutionSyncRetriesAndUsesEachLogin(t *testing.T) {
	for _, login := range []string{"alpha", "beta"} {
		t.Run(login, func(t *testing.T) {
			home := t.TempDir()
			p := executionSyncFixture(t, home, "execution_sync\\t1\\n", `printf '%s|%s|%s\n' "$HOME" "$USER" "$FLEET_CONF_DIR" >> "$HOME/runs"; test ! -f "$HOME/fail"`)
			if !p.executionSync {
				t.Fatal("execution_sync probe not recognized")
			}
			ctx := withRunAs(context.Background(), selfRunAs(t, login, home))
			if err := os.WriteFile(filepath.Join(home, "fail"), nil, 0o600); err != nil {
				t.Fatal(err)
			}
			s := &executionStopSync{}
			s.kick(ctx, p)
			executionSyncWait(t, func() bool { return executionSyncIdle(s) })
			if s.succeeded {
				t.Fatal("failed import was marked successful")
			}
			if err := os.Remove(filepath.Join(home, "fail")); err != nil {
				t.Fatal(err)
			}
			s.kick(ctx, p) // the next heartbeat
			executionSyncWait(t, func() bool { return executionSyncIdle(s) })
			if !s.succeeded {
				t.Fatal("next heartbeat did not retry the failed import")
			}
			s.kick(ctx, p) // successful import is not repeated on this connection
			next := &executionStopSync{}
			next.kick(ctx, p) // a reconnect must import again
			executionSyncWait(t, func() bool { return executionSyncIdle(next) })
			got, err := os.ReadFile(filepath.Join(home, "runs"))
			want := strings.Repeat(home+"|"+login+"|"+filepath.Join(home, ".config", "claude-fleet")+"\n", 3)
			if err != nil || string(got) != want {
				t.Fatalf("imports used the wrong login or count: %q, %v; want %q", got, err, want)
			}
		})
	}
}

func TestExecutionSyncOldPathsHaveNoSideEffects(t *testing.T) {
	for _, flag := range []string{"", "execution_sync\\t0\\n", "execution_sync\\ttrue\\n", "task_execution_v1\\t1\\n"} {
		home := t.TempDir()
		p := executionSyncFixture(t, home, flag, `touch "$HOME/unexpected"`)
		s := &executionStopSync{}
		s.kick(withRunAs(context.Background(), selfRunAs(t, "old", home)), p)
		if p.executionSync || !executionSyncIdle(s) || s.succeeded {
			t.Fatalf("old/unsupported paths enabled synchronization: %q", flag)
		}
		if _, err := os.Stat(filepath.Join(home, "unexpected")); !os.IsNotExist(err) {
			t.Fatal("old script was called")
		}
	}
}

func TestExecutionSyncRunningDedupAndConnectionCancellation(t *testing.T) {
	home := t.TempDir()
	p := executionSyncFixture(t, home, "execution_sync\\t1\\n", `echo started >> "$HOME/runs"; exec sleep 30`)
	ctx, cancel := context.WithCancel(withRunAs(context.Background(), selfRunAs(t, "alpha", home)))
	defer cancel()
	s := &executionStopSync{}
	s.kick(ctx, p)
	executionSyncWait(t, func() bool { _, err := os.Stat(filepath.Join(home, "runs")); return err == nil })
	for i := 0; i < 20; i++ {
		s.kick(ctx, p)
	}
	cancel()
	executionSyncWait(t, func() bool { return executionSyncIdle(s) })
	if s.succeeded {
		t.Fatal("cancelled import was marked successful")
	}
	s.kick(ctx, p)
	got, err := os.ReadFile(filepath.Join(home, "runs"))
	if err != nil || string(got) != "started\n" {
		t.Fatalf("overlapping/cancelled connection started more imports: %q, %v", got, err)
	}
}

// Match execution-sync's exec Python -> shell -> HTTP subprocess shape. The
// direct helper is cancelled; the already-started read may finish under its own
// timeout. Its completion must not mark the old connection synchronized.
func TestExecutionSyncCancellationLetsBoundedReadFinish(t *testing.T) {
	home := t.TempDir()
	helper := `import os, pathlib, subprocess
home = pathlib.Path(os.environ["HOME"])
subprocess.run(["/bin/sh", "-c", 'touch "$1/child-started"; sleep 0.5; touch "$1/child-finished"', "read", str(home)], check=True)
(home / "helper-finished").touch()
`
	if err := os.WriteFile(filepath.Join(home, "bounded-read.py"), []byte(helper), 0o600); err != nil {
		t.Fatal(err)
	}
	p := executionSyncFixture(t, home, "execution_sync\\t1\\n", `exec python3 "$HOME/bounded-read.py"`)
	ctx, cancel := context.WithCancel(withRunAs(context.Background(), selfRunAs(t, "alpha", home)))
	defer cancel()
	s := &executionStopSync{}
	s.kick(ctx, p)
	exists := func(name string) bool { _, err := os.Stat(filepath.Join(home, name)); return err == nil }
	// Always let this test's bounded child finish before removing its HOME.
	defer func() {
		if exists("child-started") {
			executionSyncWait(t, func() bool { return exists("child-finished") })
		}
	}()
	executionSyncWait(t, func() bool { return exists("child-started") })
	cancel()
	executionSyncWait(t, func() bool { return executionSyncIdle(s) })
	executionSyncWait(t, func() bool { return exists("child-finished") })
	if s.succeeded || exists("helper-finished") {
		t.Fatal("cancelled helper finished or its child's read marked the connection synchronized")
	}
}

// Both logical nodeSessions share a real machine websocket. Alpha's snapshot
// import remains blocked while beta succeeds, and both keep answering reads,
// stop delivery and heartbeat pings. No execution capability is advertised.
func TestNodeExecutionSyncMachineLanesKeepServing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	replies := make(chan control.Message, 32)
	serverErrors := make(chan error, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		sent := map[string]bool{}
		for {
			var m control.Message
			if err := wsjson.Read(ctx, c, &m); err != nil {
				return
			}
			switch m.Type {
			case control.TypeHello:
				var hello control.Hello
				if err := json.Unmarshal(m.Payload, &hello); err != nil {
					serverErrors <- err
					return
				}
				for _, cap := range hello.Capabilities {
					if cap == control.CapTaskExecution {
						serverErrors <- fmt.Errorf("unexpected task execution capability on %q", m.Login)
						return
					}
				}
				welcome, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true})
				welcome.Login = m.Login
				if err := wsjson.Write(ctx, c, welcome); err != nil {
					return
				}
			case control.TypeHeartbeat:
				if m.Login == "" || sent[m.Login] {
					continue
				}
				sent[m.Login] = true
				read, _ := control.New(control.TypeRequest, control.Request{Method: "discover"})
				read.Login, read.OpID = m.Login, m.Login+"-read"
				stop, _ := control.New(control.TypeWrite, control.Request{Method: "submit", Params: json.RawMessage(`{"operation_id":"stop","fleet_id":"f","action":"worker_stop","params":{},"actor":"test"}`)})
				stop.Login, stop.OpID = m.Login, m.Login+"-stop"
				if wsjson.Write(ctx, c, read) != nil || wsjson.Write(ctx, c, stop) != nil {
					return
				}
			case control.TypeResult, control.TypeError:
				replies <- m
			}
		}
	}))
	defer srv.Close()
	ml := newMachineLink(MachineConfig{HubURL: srv.URL, Token: "machine", LiveInterval: time.Hour})
	machineDone := make(chan struct{})
	go func() { defer close(machineDone); ml.run(ctx) }()
	nodeDone := make(chan error, 2)
	homes := map[string]string{}
	for _, login := range []string{"alpha", "beta"} {
		a := nodeTestAgent(t, srv.URL, true)
		homes[login] = a.cfg.Home
		body := `printf '%s|%s\n' "$HOME" "$USER" > "$HOME/sync-identity"; `
		if login == "alpha" {
			body += "exec sleep 30"
		} else {
			body += `if [ ! -f "$HOME/retry" ]; then touch "$HOME/retry"; exit 1; fi; touch "$HOME/synced"`
		}
		executionSyncFixture(t, a.cfg.Home, "execution_sync\\t1\\n", body)
		// The real control RPC subprocess: enough to observe that reads and
		// stop submissions reach this login while its sync subprocess waits.
		controller := "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'protocol':1,'machine_id':'m', 'result':{'machine_id':'m','fleets':[],'ready':True,'operation_id':'stop','status':'accepted'}}))\n"
		if err := os.WriteFile(filepath.Join(a.cfg.Home, fleetControlScript), []byte(controller), 0o755); err != nil {
			t.Fatal(err)
		}
		a.cfg.RunAs = selfRunAs(t, login, a.cfg.Home)
		a.machine = ml
		go func() {
			_, err := a.nodeSession(withRunAs(ctx, a.cfg.RunAs), nil)
			nodeDone <- err
		}()
	}
	defer func() {
		cancel()
		for i := 0; i < 2; i++ {
			select {
			case <-nodeDone:
			case <-time.After(5 * time.Second):
				t.Error("node session did not end")
			}
		}
		<-machineDone
	}()
	seen := map[string]bool{}
	for len(seen) < 4 {
		select {
		case err := <-serverErrors:
			t.Fatal(err)
		case m := <-replies:
			if m.Type != control.TypeResult || !strings.HasPrefix(m.OpID, m.Login+"-") {
				t.Fatalf("read/stop failed or crossed login lanes: %+v", m)
			}
			seen[m.OpID] = true
		case <-ctx.Done():
			t.Fatalf("blocked import stalled read/stop delivery: %v", seen)
		}
	}
	for login, home := range homes {
		executionSyncWait(t, func() bool { _, err := os.Stat(filepath.Join(home, "sync-identity")); return err == nil })
		got, err := os.ReadFile(filepath.Join(home, "sync-identity"))
		if err != nil || string(got) != home+"|"+login+"\n" {
			t.Fatalf("machine lane imported as the wrong login: %q, %v", got, err)
		}
	}
	executionSyncWait(t, func() bool { _, err := os.Stat(filepath.Join(homes["beta"], "synced")); return err == nil })
}
