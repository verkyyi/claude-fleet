package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHubMoveTarget(t *testing.T) {
	for _, c := range []struct{ announced, dialed, want string }{
		{"", "https://old.example", ""},                                        // nothing announced
		{"https://old.example", "https://old.example/", ""},                    // the one dialed
		{"https://OLD.example", "https://old.example", ""},                     // the same, other case
		{"https://new.example/", "https://old.example", "https://new.example"}, // a move
		{"https://new.example:8443", "http://192.0.2.5:8080", "https://new.example:8443"},
		{"http://new.example", "https://old.example", ""},        // never in the clear
		{"https://new.example/v1", "https://old.example", ""},    // an origin only
		{"https://u:p@new.example", "https://old.example", ""},   // no user info
		{"https://new.example?x=1", "https://old.example", ""},   // no query
		{"https://new.example\nX: y", "https://old.example", ""}, // no smuggled header
	} {
		if got := hubMoveTarget(c.announced, c.dialed); got != c.want {
			t.Errorf("hubMoveTarget(%q, %q) = %q, want %q", c.announced, c.dialed, got, c.want)
		}
	}
}

// fakeHubMove makes hubMovePython a shell that records its argv and stdin and
// exits rc — the writer as the agent sees it.
func fakeHubMove(t *testing.T, rc int) (script, record string) {
	t.Helper()
	d := t.TempDir()
	record = filepath.Join(d, "record")
	py := filepath.Join(d, "python3")
	body := "#!/bin/sh\nprintf 'ARGV %s\\n' \"$*\" >> '" + record + "'\ncat >> '" + record + "'\nexit " + string(rune('0'+rc)) + "\n"
	if err := os.WriteFile(py, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	script = filepath.Join(d, hubMoveScriptName)
	if err := os.WriteFile(script, []byte("# the writer\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := hubMovePython
	hubMovePython = py
	t.Cleanup(func() { hubMovePython = old })
	return script, record
}

func readRecord(t *testing.T, p string) string {
	t.Helper()
	b, _ := os.ReadFile(p)
	return string(b)
}

// A verified, rewritten move ends Run (the service starts the agent on the new
// configuration); the writer got the old and new addresses on its argv and the
// node's two Authorization values on its stdin — never on the argv.
func TestPlainAgentFollowsMovedHub(t *testing.T) {
	shrinkBackoff(t)
	f := newFakeControlHub(t)
	f.welcome.HubURL = "https://new.example"
	script, record := fakeHubMove(t, 0)
	a := nodeTestAgent(t, f.srv.URL, true)
	a.cfg.HubMoveScript = script
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()
	if err := a.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if ctx.Err() != nil {
		t.Fatalf("Run did not end after the move was followed (%s)", time.Since(start))
	}
	if a.HubMoved() != "https://new.example" {
		t.Fatalf("HubMoved = %q", a.HubMoved())
	}
	rec := readRecord(t, record)
	want := "ARGV -I " + script + " follow --scope login --from " + f.srv.URL + " --to https://new.example"
	if !strings.Contains(rec, want) {
		t.Fatalf("writer argv: %q, want %q", rec, want)
	}
	if strings.Count(rec, "Bearer tok\n") != 2 || strings.Contains(strings.SplitN(rec, "\n", 2)[0], "tok") {
		t.Fatalf("the two Authorization values belong on stdin only: %q", rec)
	}
	if _, err := os.Stat(filepath.Join(a.cfg.StateDir, hubMoveMarker)); err != nil {
		t.Fatalf("no follow marker: %v", err)
	}
}

// A writer that refuses (the new address does not take the token: verify exit
// 3) leaves the agent where it is, connected to the hub it dialed, asked once.
func TestPlainAgentStaysOnUnverifiedMove(t *testing.T) {
	shrinkBackoff(t)
	f := newFakeControlHub(t)
	f.welcome.HubURL = "https://evil.example"
	script, record := fakeHubMove(t, 3)
	a := nodeTestAgent(t, f.srv.URL, true)
	a.cfg.HubMoveScript = script
	runFor(t, a, 1200*time.Millisecond)
	if a.HubMoved() != "" {
		t.Fatalf("followed an unverified move to %q", a.HubMoved())
	}
	if f.dials.Load() < 2 {
		t.Fatalf("the agent stopped reconnecting to its own hub (%d dials)", f.dials.Load())
	}
	if n := strings.Count(readRecord(t, record), "ARGV "); n != 1 {
		t.Fatalf("the writer ran %d times for one announcement, want once per process", n)
	}
}

// No announcement, a pod's in-cluster dial, or a follow already made from this
// very address: nothing runs.
func TestPlainAgentFollowNothing(t *testing.T) {
	_, record := fakeHubMove(t, 0)
	a := nodeTestAgent(t, "https://old.example", true)
	a.followHub(context.Background(), "")
	a.followHub(context.Background(), "https://old.example")
	pod := nodeTestAgent(t, "https://old.example", true)
	pod.cfg.HubDial = "http://hub.fleet.svc.cluster.local:8080"
	pod.followHub(context.Background(), "https://new.example")
	again := nodeTestAgent(t, "https://old.example", true)
	again.markFollowed("https://old.example", "https://new.example")
	again.followHub(context.Background(), "https://new.example")
	time.Sleep(200 * time.Millisecond)
	if rec := readRecord(t, record); rec != "" {
		t.Fatalf("the writer ran: %q", rec)
	}
}

// The machine link verifies with the machine's credential, rewrites each
// tenant's files as that login and then root's with machine.env's directory.
func TestMachineLinkFollowsMovedHub(t *testing.T) {
	script, record := fakeHubMove(t, 0)
	ml := newMachineLink(MachineConfig{HubURL: "https://old.example", Token: "mtok", HubMove: script,
		MachineEnvFile: "/var/db/fleet-node/machine.env"})
	ml.followHub(context.Background(), "https://new.example")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && !strings.Contains(readRecord(t, record), "--scope machine") {
		time.Sleep(20 * time.Millisecond)
	}
	rec := readRecord(t, record)
	v := strings.Index(rec, "verify --from https://old.example --to https://new.example")
	m := strings.Index(rec, "rewrite --scope machine --from https://old.example --to https://new.example --state /var/db/fleet-node")
	if v < 0 || m < 0 || m < v || strings.Count(rec, "Bearer mtok\n") != 2 {
		t.Fatalf("machine follow: %q", rec)
	}
	// on the seat (Core) nothing of root's is written
	_, rec2 := fakeHubMove(t, 0)
	seat := newMachineLink(MachineConfig{HubURL: "https://old.example", Token: "mtok", HubMove: script, Core: "/var/run/x.sock"})
	seat.followHub(context.Background(), "https://new.example")
	time.Sleep(200 * time.Millisecond)
	if r := readRecord(t, rec2); r != "" {
		t.Fatalf("the seat followed: %q", r)
	}
}
