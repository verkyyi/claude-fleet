//go:build browseracceptance

package e2e

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestAttachmentChromium(t *testing.T) {
	for _, scenario := range []string{"direct-and-late-fallback", "udp-denied"} {
		t.Run(scenario, func(t *testing.T) {
			r := newTermRig(t, true)
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			args := []string{"browser.mjs"}
			if scenario == "udp-denied" {
				args = append(args, "--deny-udp")
			}
			cmd := exec.CommandContext(ctx, "node", args...)
			cmd.Dir = filepath.Join("..", "..", "extras", "browser-transport")
			cmd.Env = append(os.Environ(), "FLEET_TEST_ORIGIN="+r.origin, "FLEET_TEST_COOKIE="+r.alice.Name+"="+r.alice.Value, "FLEET_TEST_WORKER="+r.wid)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("Chromium: %v\n%s", err, out)
			}
			t.Log(string(out))
			waitFor(t, 30*time.Second, "browser attachment resources released", func() bool { return r.procs() == 0 && r.h.Srv.TermRelaysOpenForTest() == 0 })
			rows, err := r.h.Srv.Store.FleetTermSessions(pAlice, 10)
			if err != nil {
				t.Fatal(err)
			}
			var direct, relay []store.FleetTermSession
			for _, row := range rows {
				switch row.Mode {
				case "direct":
					direct = append(direct, row)
				case "relay":
					relay = append(relay, row)
				default:
					t.Fatalf("unfinished attachment: %+v", row)
				}
			}
			if len(relay) != 1 || relay[0].BytesUp == 0 || relay[0].BytesDown == 0 {
				t.Fatalf("fallback payload counters %+v", rows)
			}
			if scenario == "direct-and-late-fallback" {
				if len(direct) != 1 || direct[0].BytesUp != 0 || direct[0].BytesDown != 0 {
					t.Fatalf("direct payload traversed hub: %+v", rows)
				}
			} else if len(direct) != 0 {
				t.Fatal("UDP denial produced a direct attachment")
			}
			t.Logf("%s: hub payload counters=%+v; remaining target processes=0, relay entries=0; model launches=0 (isolated shell only)", scenario, rows)
		})
	}
}

// Production React/xterm against the real hub, ordered transport and node PTY.
// The child is an isolated input probe, NOT an agent or a native Fleet menu.
// Actual Fleet/Safari/OS IME acceptance remains a separately recorded batch gate.
func TestTerminalConsoleChromium(t *testing.T) {
	r := newTermRig(t, true)
	// Sessions scopes through active accounts; terminal admission uses EntryHome.
	person, err := r.h.Srv.Store.AdoptPrincipal(pAlice, r.login, "Terminal test", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := r.h.Srv.Store.AdoptAccount(person, r.host, time.Now()); err != nil {
		t.Fatal(err)
	}
	r.h.Srv.ConsoleFS = os.DirFS(filepath.Join("..", "..", "extras", "web-console", "dist"))
	agent.SetTermHelperForTest(func(view, target string) []string {
		return []string{"/bin/sh", "-c", `stty raw -echo; exec python3 -c 'import os
os.write(1, b"\x1b[?2004hIsolated PTY input probe - not native Fleet\r\n")
while True:
 b = os.read(0, 32768)
 if not b: break
 os.write(1, ("\r\nbytes:" + b.hex() + "\r\n").encode())' "$1"`, "probe", r.tok}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "node", "terminal.mjs")
	cmd.Dir = filepath.Join("..", "..", "extras", "browser-transport")
	cmd.Env = append(os.Environ(), "FLEET_TEST_ORIGIN="+r.origin, "FLEET_TEST_COOKIE="+r.alice.Name+"="+r.alice.Value, "FLEET_TEST_WORKER="+r.wid)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("terminal Chromium: %v\n%s", err, out)
	}
	t.Log(string(out))
	waitFor(t, 30*time.Second, "console releases attachment resources", func() bool { return r.procs() == 0 && r.h.Srv.TermRelaysOpenForTest() == 0 })
}
