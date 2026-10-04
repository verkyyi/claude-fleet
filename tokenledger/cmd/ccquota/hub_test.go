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

// CCQUOTA_FLEET_PRINCIPAL_LOGINS decides whose machine a sign-in lands on
// (claude-fleet#1458), so a half-readable value refuses to start the hub
// rather than placing someone silently wrong.
func TestFleetPrincipalLogins(t *testing.T) {
	m, err := fleetPrincipalLogins(" caojian=24haowan , yilianghui = verkyyi ,")
	if err != nil || len(m) != 2 || m["caojian"] != "24haowan" || m["yilianghui"] != "verkyyi" {
		t.Fatalf("parsed %v, %v", m, err)
	}
	if m, err := fleetPrincipalLogins(""); err != nil || len(m) != 0 {
		t.Fatalf("empty → %v, %v", m, err)
	}
	for _, bad := range []string{
		"caojian",                              // no login
		"=verkyyi",                             // no person
		"caojian=Root",                         // not lowercase
		"caojian=root",                         // reserved
		"caojian=24-haowan",                    // not the alphabet
		"a=verkyyi,b=verkyyi",                  // one login, two people
		"yilianghui=verkyyi,yilianghui=other1", // one person, two logins
	} {
		if _, err := fleetPrincipalLogins(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
	// The same pair twice is not a conflict.
	if _, err := fleetPrincipalLogins("a=verkyyi,a=verkyyi"); err != nil {
		t.Errorf("a repeated pair refused: %v", err)
	}
}
