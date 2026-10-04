package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

// fakeFleet replaces the script run with one that prints stdout and exits
// with code, and counts runs. The script file itself must exist under home
// for the probe to get as far as running anything.
func fakeFleet(t *testing.T, stdout string, code int) (home string, runs *atomic.Int32) {
	t.Helper()
	home = t.TempDir()
	script := filepath.Join(home, fleetVersionScript)
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	runs = new(atomic.Int32)
	prev := fleetCommand
	fleetCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
		runs.Add(1)
		if name != script {
			t.Errorf("ran %q, want the login's own %q", name, script)
		}
		if len(arg) != 3 || arg[0] != "--json" || arg[1] != "--no-fetch" || arg[2] != "--no-logins" {
			t.Errorf("args = %v; the cheap no-network reading is the only one allowed on the scan cadence", arg)
		}
		return exec.CommandContext(ctx, "sh", "-c", "printf '%s' \"$1\"; exit "+strconv.Itoa(code), "sh", stdout)
	}
	t.Cleanup(func() { fleetCommand = prev })
	return home, runs
}

const behindJSON = `{"dir":"/Users/x/.claude/fleet","host":"macmini","head":"0164208","branch":"master",` +
	`"upstream":"origin/master","behind":12,"ahead":0,"dirty":false,"fetched":false,"verdict":"BEHIND",` +
	`"error":"","logins":null,"follow":"on · no-daemon · … [STUCK]","follow_verdict":"STUCK"}`

// Exit 1 mirrors BEHIND. It is the normal case for exactly the installs this
// exists to surface, and stdout is the answer regardless.
func TestFleetProbe_ReadsTheJSONDespiteTheVerdictExitCode(t *testing.T) {
	home, _ := fakeFleet(t, behindJSON, 1)
	var p fleetProbe
	fv := p.reading(context.Background(), home)
	if fv == nil {
		t.Fatal("exit 1 is the verdict, not a failure; the reading was dropped")
	}
	if fv.Head != "0164208" || fv.Verdict != "BEHIND" || fv.FollowVerdict != "STUCK" || fv.Branch != "master" {
		t.Fatalf("reading = %+v", fv)
	}
	if fv.Behind == nil || *fv.Behind != 12 || fv.Ahead == nil || *fv.Ahead != 0 {
		t.Fatalf("behind/ahead = %v/%v, want 12/0", fv.Behind, fv.Ahead)
	}
	if fv.Fetched {
		t.Error("fetched:false was lost; the hub needs it to say '(not fetched)'")
	}
	if fv.Follow != "on · no-daemon · … [STUCK]" {
		t.Errorf("follow = %q; carried verbatim for the tooltip, never parsed", fv.Follow)
	}
	if fv.ObservedAt.IsZero() || time.Since(fv.ObservedAt) > time.Minute {
		t.Errorf("observed_at = %v, want now", fv.ObservedAt)
	}
}

// null is "could not read the count" (exit 2, UNKNOWN). It must stay nil:
// a 0 here is claude-fleet#635 again.
func TestFleetProbe_NullCountStaysNil(t *testing.T) {
	home, _ := fakeFleet(t, `{"head":"0164208","branch":"master","behind":null,"ahead":null,"dirty":true,`+
		`"fetched":false,"verdict":"UNKNOWN","error":"no upstream configured","follow":"","follow_verdict":null}`, 2)
	var p fleetProbe
	fv := p.reading(context.Background(), home)
	if fv == nil {
		t.Fatal("exit 2 is the UNKNOWN verdict, not a failure")
	}
	if fv.Behind != nil || fv.Ahead != nil {
		t.Fatalf("behind/ahead = %v/%v, want nil/nil", fv.Behind, fv.Ahead)
	}
	if fv.Verdict != "UNKNOWN" || fv.Error != "no upstream configured" || !fv.Dirty {
		t.Fatalf("reading = %+v", fv)
	}
	if fv.FollowVerdict != "" {
		t.Errorf("follow_verdict null (install predates install-sync) = %q, want empty", fv.FollowVerdict)
	}
}

// No script: this login has no claude-fleet. That is not an error and there
// is nothing to invent; the batch carries no field and the hub draws a dash.
func TestFleetProbe_NoScriptMeansNoReading(t *testing.T) {
	home := t.TempDir()
	prev := fleetCommand
	fleetCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
		t.Fatalf("ran %q; nothing should run when the script is absent", name)
		return nil
	}
	t.Cleanup(func() { fleetCommand = prev })
	var p fleetProbe
	if fv := p.reading(context.Background(), home); fv != nil {
		t.Fatalf("reading = %+v, want nil", fv)
	}
}

func TestFleetProbe_NonJSONMeansNoReading(t *testing.T) {
	home, _ := fakeFleet(t, "fleet-install-version.sh: git: command not found", 127)
	var p fleetProbe
	if fv := p.reading(context.Background(), home); fv != nil {
		t.Fatalf("reading = %+v, want nil for output that is not JSON", fv)
	}
}

// One process per interval, not one per scan.
func TestFleetProbe_CachesBetweenScans(t *testing.T) {
	home, runs := fakeFleet(t, behindJSON, 1)
	var p fleetProbe
	for i := 0; i < 5; i++ {
		if fv := p.reading(context.Background(), home); fv == nil {
			t.Fatalf("scan %d: reading dropped", i)
		}
	}
	if n := runs.Load(); n != 1 {
		t.Fatalf("script ran %d times across 5 scans, want 1", n)
	}
	// Age the cache out and it runs again.
	p.at = p.at.Add(-fleetVersionInterval - time.Second)
	p.reading(context.Background(), home)
	if n := runs.Load(); n != 2 {
		t.Fatalf("script ran %d times after the interval passed, want 2", n)
	}
}

// A failure is also cached: a wedged or missing script must not be retried
// on every scan either.
func TestFleetProbe_CachesAFailureToo(t *testing.T) {
	home, runs := fakeFleet(t, "not json", 1)
	var p fleetProbe
	for i := 0; i < 3; i++ {
		p.reading(context.Background(), home)
	}
	if n := runs.Load(); n != 1 {
		t.Fatalf("a failing script ran %d times across 3 scans, want 1", n)
	}
}
