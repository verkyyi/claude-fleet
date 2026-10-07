package main

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
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

// The three GitHub settings (claude-fleet#1984): off, on, half refuses.
func TestGitHubAuthFromEnv(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if g, err := githubAuthFromEnv(env(nil)); g != nil || err != nil {
		t.Errorf("unset = %v, %v; want off", g, err)
	}
	g, err := githubAuthFromEnv(env(map[string]string{"CCQUOTA_GITHUB_CLIENT_ID": "Iv1.x",
		"CCQUOTA_GITHUB_CLIENT_SECRET": "s", "CCQUOTA_GITHUB_ADMINS": " verkyyi , alice,"}))
	if err != nil || g == nil || g.ClientID != "Iv1.x" || len(g.Admins) != 2 || g.Admins[0] != "verkyyi" {
		t.Errorf("set = %+v, %v", g, err)
	}
	for _, half := range []map[string]string{{"CCQUOTA_GITHUB_CLIENT_ID": "Iv1.x"}, {"CCQUOTA_GITHUB_CLIENT_SECRET": "s"}} {
		if _, err := githubAuthFromEnv(env(half)); err == nil {
			t.Errorf("%v: half configured started", half)
		}
	}
}

// CCQUOTA_SHUTDOWN_GRACE (claude-fleet#2125): unset is the old 10s, byte for
// byte; a rolling release's 25s is read; nonsense refuses to start.
func TestShutdownGrace(t *testing.T) {
	for _, c := range []struct {
		v    string
		want time.Duration
		ok   bool
	}{{"", 10 * time.Second, true}, {"25s", 25 * time.Second, true}, {"0s", 0, false}, {"6m", 0, false}, {"soon", 0, false}} {
		got, err := shutdownGrace(func(string) string { return c.v })
		if (err == nil) != c.ok || got != c.want {
			t.Errorf("CCQUOTA_SHUTDOWN_GRACE=%q: %v, %v", c.v, got, err)
		}
	}
}
