package main

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestBindHosts(t *testing.T) {
	got := bindHosts("127.0.0.1:8787, 100.85.129.58:8787,[::1]:8787,garbage")
	want := []string{"127.0.0.1", "100.85.129.58", "::1"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("bindHosts = %v, want %v", got, want)
	}
}

// --reprice-since is only meaningful with --reprice, and a mistyped instant must
// be refused BEFORE the hub opens a database or binds a port: the operator is
// usually restarting a live hub to pick up a rate correction, and "your flag was
// wrong" is only useful if it arrives before the downtime.
func TestHubRejectsBadRepriceFlags(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		args       []string
	}{
		{
			name: "since without reprice",
			want: "nothing would be repriced",
			args: []string{"--reprice-since", "2026-09-01T00:00:00Z"},
		},
		{
			name: "unparseable instant",
			want: "RFC3339",
			args: []string{"--reprice", "--reprice-since", "last tuesday"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := runHub(append([]string{"--db", filepath.Join(t.TempDir(), "x.db")}, tc.args...))
			if err == nil {
				t.Fatal("accepted the flags instead of complaining")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}
