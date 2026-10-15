//go:build unix

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A person's pod runs as its login with fsGroup = its group, and the kubelet's
// fsGroup pass adds g+w to the whole runtime: the opener must still be taken
// there — never for root, never for a group the program is not
// (claude-fleet#4301).
func TestScriptBesideGroupWrite(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "fleet-node-linux.py")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	gid, ok := fileGID(fi)
	if !ok {
		t.Skip("no gid here")
	}
	me, own := os.Geteuid(), int(gid)
	if me == 0 {
		me = 1000
	}
	for _, c := range []struct {
		mode      os.FileMode
		euid, gid int
		want      bool
	}{
		{0o755, me, own, true},
		{0o775, me, own, true},      // the pod: its own group may write
		{0o775, me, own + 1, false}, // someone else's group
		{0o775, 0, own, false},      // root never takes a group-writable script
		{0o757, me, own, false},     // anyone may write
		{0o777, me, own, false},
	} {
		if err := os.Chmod(p, c.mode); err != nil {
			t.Fatal(err)
		}
		got, why := scriptBeside(dir, "fleet-node-linux.py", c.euid, c.gid)
		if (got != "") != c.want {
			t.Fatalf("mode %o euid %d gid %d: got %q (%s), want taken=%v", c.mode, c.euid, c.gid, got, why, c.want)
		}
		if got == "" && why == "" {
			t.Fatalf("mode %o: refused without a reason", c.mode)
		}
	}
	if got, why := scriptBeside(dir, "missing.py", me, own); got != "" || why == "" {
		t.Fatalf("missing script: %q %q", got, why)
	}
}
