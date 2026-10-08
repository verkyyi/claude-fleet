//go:build unix

package agent

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// m4 (claude-fleet#2336): a login in 28 groups — setgroups(2) on macOS takes 16.
func TestCapGroupsDarwin(t *testing.T) {
	var many []uint32
	for g := uint32(100); g < 128; g++ {
		many = append(many, g)
	}
	many = append(many, 12, 80, 20, 501) // admin and staff late in the list, duplicates below
	many = append(many, 80, 501)
	got := capGroups(many, 501, "darwin")
	if len(got) != darwinMaxGroups {
		t.Fatalf("len %d, want %d: %v", len(got), darwinMaxGroups, got)
	}
	if got[0] != 501 || got[1] != 20 || got[2] != 80 {
		t.Fatalf("own group, staff, admin first: %v", got)
	}
	seen := map[uint32]bool{}
	for _, g := range got {
		if seen[g] {
			t.Fatalf("duplicate %d: %v", g, got)
		}
		seen[g] = true
	}
	if got[3] != 100 {
		t.Fatalf("the rest in order: %v", got)
	}
}

func TestCapGroupsUnchanged(t *testing.T) {
	short := []uint32{20, 80, 501}
	if got := capGroups(short, 501, "darwin"); !reflect.DeepEqual(got, short) {
		t.Fatalf("a short list changed: %v", got)
	}
	var many []uint32
	for g := uint32(0); g < 40; g++ {
		many = append(many, g)
	}
	if got := capGroups(many, 0, "linux"); !reflect.DeepEqual(got, many) {
		t.Fatalf("linux changed: %v", got)
	}
	// a group the login is not in is never added
	if got := capGroups(append([]uint32{}, many[1:18]...), 0, "darwin"); seenAny(got, 0, 80) {
		t.Fatalf("added a group the login is not in: %v", got)
	}
}

func seenAny(gs []uint32, xs ...uint32) bool {
	for _, g := range gs {
		for _, x := range xs {
			if g == x {
				return true
			}
		}
	}
	return false
}

// claude-fleet#2451: a command that never starts as its login says why — the
// login missing, the paths it needed — never a bare «invalid argument».
func TestStartWhyLoginNotFound(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "fleet-control.py")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho '{}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	ra := &RunAs{Login: "ghost-2451", UID: 3999999, GID: uint32(os.Getgid()), Home: filepath.Join(dir, "no-home")}
	_, err := fleetControlCommand(withRunAs(context.Background(), ra), script, nil)
	if err == nil {
		t.Fatal("started as a login that does not exist")
	}
	for _, want := range []string{"login ghost-2451 not found", "home " + ra.Home + " missing", "program " + script} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("missing %q in: %v", want, err)
		}
	}
}

func TestStartWhyLeavesOthersAlone(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "exit 3")
	err := cmd.Run()
	ctx := withRunAs(context.Background(), &RunAs{Login: "x", UID: 1})
	if got := startWhy(ctx, cmd, err); got != err {
		t.Fatalf("an exit status changed: %v", got)
	}
	perr := &fs.PathError{Op: "fork/exec", Path: "/x", Err: syscall.EINVAL}
	if got := startWhy(context.Background(), cmd, perr); got != error(perr) {
		t.Fatalf("a plain agent's error changed: %v", got)
	}
	if got := startWhy(ctx, cmd, perr); !strings.Contains(got.Error(), "EINVAL: ") || !errors.Is(got, syscall.EINVAL) {
		t.Fatalf("errno not named or not wrapped: %v", got)
	}
}
