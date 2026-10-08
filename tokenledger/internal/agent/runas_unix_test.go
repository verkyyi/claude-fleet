//go:build unix

package agent

import (
	"reflect"
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
