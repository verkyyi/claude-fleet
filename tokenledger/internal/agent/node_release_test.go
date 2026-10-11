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

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A new stable, pushed (claude-fleet#3146, EPIC #3139 C7).

const (
	relA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	relB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	relC = "cccccccccccccccccccccccccccccccccccccccc"
)

func releaseMsg(sha string, seq int64) control.Message {
	m, _ := control.New(control.TypeRelease, control.Release{SHA: sha, Seq: seq})
	return m
}

// runtimeAt lays out <root>/<sha>/.release/manifest.json (seq) and
// <root>/current → <sha>, as the machine updater leaves them.
func runtimeAt(t *testing.T, root, sha string, seq int) string {
	t.Helper()
	rel := filepath.Join(root, sha, ".release")
	if err := os.MkdirAll(rel, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rel, "manifest.json"), []byte(`{"sha":"`+sha+`","seq":`+strconv.Itoa(seq)+`}`), 0o644); err != nil {
		t.Fatal(err)
	}
	cur := filepath.Join(root, "current")
	os.Remove(cur)
	if err := os.Symlink(sha, cur); err != nil {
		t.Fatal(err)
	}
	return cur
}

// The machine half: a release past the runtime writes update-now (the sha);
// one the machine is at, or a seq it is past, writes nothing.
func TestReleasePushWritesUpdateNow(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	now := filepath.Join(state, "update-now")
	ml := newMachineLink(MachineConfig{UpdateNow: now, CurrentRelease: runtimeAt(t, root, relA, 2)})
	has := func() string { b, _ := os.ReadFile(now); return strings.TrimSpace(string(b)) }

	ml.handleRelease(releaseMsg(relA, 2))
	ml.handleRelease(releaseMsg(relB, 1)) // older than the runtime: never back
	ml.handleRelease(releaseMsg(relB, 2)) // not past it either
	ml.handleRelease(releaseMsg("nope", 9))
	if s := has(); s != "" {
		t.Fatalf("a release the machine is at or past wrote update-now %q", s)
	}
	ml.handleRelease(releaseMsg(relC, 3))
	if s := has(); s != relC {
		t.Fatalf("update-now = %q, want %s", s, relC)
	}
	if fi, err := os.Stat(now); err != nil || fi.Mode().Perm() != 0o644 {
		t.Fatalf("update-now mode: %v %v", fi, err)
	}
	if left, _ := filepath.Glob(filepath.Join(state, ".update-now-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}

	// No updater (UpdateNow ""): nothing written, and the hello lists nothing.
	os.Remove(now)
	off := newMachineLink(MachineConfig{CurrentRelease: filepath.Join(root, "current")})
	off.handleRelease(releaseMsg(relC, 9))
	if s := has(); s != "" {
		t.Fatalf("no updater, yet update-now %q", s)
	}
}

func TestReleaseMachineHelloCapability(t *testing.T) {
	for _, on := range []bool{false, true} {
		srv, hellos, conns := entryHub(t)
		ctx, cancel := context.WithCancel(context.Background())
		cfg := MachineConfig{HubURL: srv.URL, Token: "m", LiveInterval: time.Hour}
		state := t.TempDir()
		if on {
			cfg.UpdateNow = filepath.Join(state, "update-now")
			cfg.CurrentRelease = runtimeAt(t, t.TempDir(), relA, 1)
		}
		go newMachineLink(cfg).run(ctx)
		h := <-hellos
		listed := false
		for _, c := range h.Capabilities {
			listed = listed || c == control.CapRelease
		}
		if listed != on {
			t.Fatalf("updater %v: the hello lists %v", on, h.Capabilities)
		}
		if on {
			// The hub's push on the machine half (Login empty) lands in update-now.
			c := <-conns
			if err := wsjson.Write(ctx, c, releaseMsg(relB, 2)); err != nil {
				t.Fatal(err)
			}
			deadline := time.Now().Add(5 * time.Second)
			for {
				if b, _ := os.ReadFile(cfg.UpdateNow); strings.TrimSpace(string(b)) == relB {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("the pushed release never reached update-now")
				}
				time.Sleep(20 * time.Millisecond)
			}
		}
		cancel()
		srv.Close()
	}
}

// A login of its own: one install-sync --now per newer release, none for the
// release its install already is, none for an older seq; a machine tenant and
// a login without install-sync list nothing.
func TestReleasePushRunsInstallSync(t *testing.T) {
	home := t.TempDir()
	a := &Agent{cfg: Config{Home: home}}
	if a.releaseCapable() {
		t.Fatal("no fleet-install-sync.sh: the agent must not list CapRelease")
	}
	vers := filepath.Join(home, ".claude", "fleet.versions", relA)
	if err := os.MkdirAll(filepath.Join(vers, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vers, "bin", "fleet-install-sync.sh"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join("fleet.versions", relA), filepath.Join(home, ".claude", "fleet")); err != nil {
		t.Fatal(err)
	}
	if !a.releaseCapable() {
		t.Fatal("with install-sync the agent lists CapRelease")
	}
	if (&Agent{cfg: Config{Home: home}, machine: &machineLink{}}).releaseCapable() {
		t.Fatal("a machine tenant (a managed login) must not list CapRelease")
	}

	var mu sync.Mutex
	var runs []string
	old := releaseCommand
	releaseCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		mu.Lock()
		runs = append(runs, filepath.Base(name)+" "+strings.Join(args, " "))
		mu.Unlock()
		return exec.CommandContext(ctx, "sh", "-c", "exit 0")
	}
	t.Cleanup(func() { releaseCommand = old })
	count := func() int { mu.Lock(); defer mu.Unlock(); return len(runs) }
	idle := func() {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			a.rel.mu.Lock()
			r := a.rel.running
			a.rel.mu.Unlock()
			if !r {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("install-sync never finished")
	}
	push := func(sha string, seq int64) {
		a.handleRelease(context.Background(), releaseMsg(sha, seq))
		idle()
	}

	push(relA, 4) // the install is already there
	if count() != 0 {
		t.Fatalf("the install's own release ran %q", runs)
	}
	push(relB, 5)
	if count() != 1 || runs[0] != "fleet-install-sync.sh --now" {
		t.Fatalf("a newer release: runs %q, want one `fleet-install-sync.sh --now`", runs)
	}
	push(relB, 5) // a reconnect's repeat
	push(relC, 3) // older than the last one
	if count() != 1 {
		t.Fatalf("a repeat or an older release ran again: %q", runs)
	}
	push(relC, 6)
	if count() != 2 {
		t.Fatalf("the next stable: %d runs, want 2", count())
	}
}
