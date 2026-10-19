package main

import (
	"reflect"
	"testing"
)

// claude-fleet#4070: an admin copied from the docs' placeholder can never get
// the sign-in code — the hub names it and refuses to start.
func TestPlaceholderAdmins(t *testing.T) {
	got := placeholderAdmins([]string{"alice@example.com", "bob@corp.cn", "carol", "dan@Mail.Example.ORG", "eve@example.community"})
	want := []string{"alice@example.com", "dan@Mail.Example.ORG"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("placeholderAdmins = %v, want %v", got, want)
	}
	if got := placeholderAdmins(nil); got != nil {
		t.Fatalf("no admins: %v", got)
	}
}
