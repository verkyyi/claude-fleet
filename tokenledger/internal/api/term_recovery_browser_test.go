//go:build browseracceptance && unix

package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
)

// Production console + hub + node adapter + lifecycle helper + native tmux.
// Only the worker command and menu's row producer are fixtures. No live Fleet,
// agent model, account, firewall or host restart is involved.
func TestTerminalRecoveryChromium(t *testing.T) {
	// Playwright's installed browser belongs to the runner, while the native
	// terminal deliberately gets an empty HOME. Resolve its cache before that.
	if os.Getenv("PLAYWRIGHT_BROWSERS_PATH") == "" {
		cache, err := os.UserCacheDir()
		if err != nil {
			t.Fatal(err)
		}
		t.Setenv("PLAYWRIGHT_BROWSERS_PATH", filepath.Join(cache, "ms-playwright"))
	}
	for _, mode := range []string{"direct", "relay"} {
		t.Run(mode, func(t *testing.T) {
			r := newTermRig(t, true)
			root, _ := filepath.Abs("../../..")
			home := t.TempDir()
			sock := fmt.Sprintf("recovery%d", time.Now().UnixNano())
			for _, name := range []string{"TMUX", "TMUX_PANE", "FLEET_SESSION", "FLEET_CLIENT", "FLEET_SHELL", "CCQUOTA_FLEET", "FLEET_WORKER_CRED"} {
				t.Setenv(name, "")
			}
			t.Setenv("HOME", home)
			t.Setenv("SHELL", "/bin/sh")
			t.Setenv("FLEET_UI_LANG", "en")
			t.Setenv("PATH", strings.Join(filterTmuxShim(filepath.SplitList(os.Getenv("PATH"))), string(os.PathListSeparator)))
			if _, err := exec.LookPath("tmux"); err != nil {
				t.Fatal("native recovery acceptance requires tmux")
			}
			conf := os.Getenv("FLEET_CONF_DIR")
			os.MkdirAll(filepath.Join(conf, "fleets", sock), 0700)
			os.WriteFile(filepath.Join(conf, "fleets", sock, "conf"), []byte("FLEET_REPO=acme/test\nFLEET_MAIN="+home+"\n"), 0600)
			tm := func(args ...string) string {
				out, err := exec.Command("tmux", append([]string{"-L", sock}, args...)...).CombinedOutput()
				if err != nil {
					t.Errorf("isolated tmux %v: %v: %s", args, err, out)
				}
				return strings.TrimSpace(string(out))
			}
			tm("-f", "/dev/null", "new-session", "-d", "-s", sock, "-n", "home", "-x", "120", "-y", "32", "exec /bin/sh")
			t.Cleanup(func() { exec.Command("tmux", "-L", sock, "kill-server").Run() })
			hw := tm("display-message", "-p", "-t", "="+sock+":home", "#{window_id}")
			tm("set-option", "-w", "-t", hw, "@fleet_role", "home")
			tm("set-option", "-w", "-t", hw, "remain-on-exit", "on")
			worker := tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "="+sock+":", "-n", "worker", "exec /bin/sh")
			tm("set-option", "-w", "-t", worker, "@fleet_id", r.fid)
			tm("set-option", "-w", "-t", worker, "@fleet_role", "worker")
			tm("set-option", "-w", "-t", worker, "remain-on-exit", "on")
			rows := filepath.Join(home, "rows")
			os.WriteFile(rows, []byte(strings.Join([]string{worker, "working", "x", "wk", " ", "", "0", "", "", "#1", "-", "50%", "ok", "Browser worker", "merged", "", "", "", ""}, "\x1f")+"\n"), 0600)
			t.Setenv("FLEET_VIEW_ROWS_CMD", "cat '"+rows+"'")
			t.Setenv("FLEET_VIEW_FIRST_CMD", "false")
			t.Setenv("FLEET_STATUS_G", filepath.Join(home, "global"))
			for _, key := range []string{"FLEET_VIEW_ROWS_CMD", "FLEET_VIEW_FIRST_CMD", "FLEET_STATUS_G", "FLEET_UI_LANG"} {
				tm("set-environment", "-g", key, os.Getenv(key))
			}
			agent.SetNativeTermHelperForTest(func(view, target string) []string {
				return []string{"/bin/bash", filepath.Join(root, "bin/fleet-term-attach.sh"), "--view", view, "--target", target}
			})
			r.h.srv.ConsoleFS = os.DirFS(filepath.Join(root, "extras/web-console/dist"))
			initialWorkerPID := tm("display-message", "-p", "-t", worker, "#{pane_pid}")
			initialPID := tm("display-message", "-p", "-t", hw, "#{pane_pid}")
			// Failure injection addresses ONLY the disposable test identities/socket.
			fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				switch req.URL.Path {
				case "/relay":
					if nc := r.h.srv.nodes.get("ep_" + r.label); nc != nil {
						nc.wire.close(websocket.StatusGoingAway, "isolated recovery test")
					}
				case "/host":
					exec.Command("tmux", "-L", sock, "kill-server").Run()
				case "/worker-respawn":
					tm("respawn-pane", "-k", "-t", worker, "exec /bin/sh")
				case "/state":
					commands, _ := os.ReadFile(filepath.Join(home, "commands"))
					identity, _ := os.ReadFile(filepath.Join(conf, "webterm/terminal.json"))
					json.NewEncoder(w).Encode(map[string]any{"commands": string(commands), "identity": string(identity), "home_pid": tm("display-message", "-p", "-t", hw, "#{pane_pid}"), "initial_pid": initialPID, "worker_pid": tm("display-message", "-p", "-t", worker, "#{pane_pid}"), "initial_worker_pid": initialWorkerPID, "views": tm("list-sessions", "-F", "#{session_name}|#{window_id}"), "worker_dead": tm("display-message", "-p", "-t", worker, "#{pane_dead}"), "worker_window": worker, "home_window": hw})
				default:
					http.NotFound(w, req)
				}
			}))
			defer fixture.Close()
			// UDP denial exercises the real seven-second ICE fallback on every
			// fresh page. Repeated exit/renew + two-tab races add those bounded
			// negotiations; allow six minutes without relaxing any assertion.
			budget := 240 * time.Second
			if mode == "relay" {
				budget = 360 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), budget)
			defer cancel()
			cmd := exec.CommandContext(ctx, "node", "recovery.mjs", mode)
			cmd.Dir = filepath.Join(root, "extras/browser-transport")
			fresh := personCookie(pAlice, "alice renewed")
			cmd.Env = append(os.Environ(), "FLEET_TEST_ORIGIN="+r.origin, "FLEET_TEST_COOKIE="+r.alice.Name+"="+r.alice.Value, "FLEET_TEST_FRESH_COOKIE="+fresh.Value, "FLEET_TEST_WORKER="+r.wid, "FLEET_TEST_FIXTURE="+fixture.URL)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("native Chromium recovery: %v\n%s", err, out)
			}
			t.Log(string(out))
			waitFor(t, 30*time.Second, "all recovery attachments cleaned", func() bool { return r.h.srv.termRelays.open() == 0 })
			audits, _ := r.h.srv.Store.FleetTermSessions(pAlice, 100)
			payload := int64(0)
			for _, row := range audits {
				if row.Mode == "direct" && (row.BytesUp != 0 || row.BytesDown != 0) {
					t.Fatal("direct payload passed through hub", row)
				}
				payload += row.BytesUp + row.BytesDown
			}
			if mode == "relay" && payload == 0 {
				t.Fatal("forced fallback had no hub payload")
			}
			t.Logf("%s audit: %+v", mode, audits)
		})
	}
}

func filterTmuxShim(paths []string) []string {
	var out []string
	for _, path := range paths {
		if !strings.Contains(path, "tmux-shim") {
			out = append(out, path)
		}
	}
	return out
}
