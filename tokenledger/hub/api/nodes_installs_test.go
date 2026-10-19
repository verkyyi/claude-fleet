package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func bp(b bool) *bool { return &b }

const (
	instA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	instB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

// A machine's 「安装」 folds every login's reading (claude-fleet#2697): the
// runtime from the newest, each login from its own, every item judged
// against the hub's stable; with no hub
// stable the script's own word stands.
func TestMachineInstallsFoldAndJudge(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	t1 := t0.Add(time.Minute)
	pk := &installsPick{logins: map[string]installsLogin{}}
	pk.add(&control.Installs{At: &t1,
		Runtime: &control.InstallItem{Version: instB},
		Logins: []control.LoginInstall{{Login: "bob",
			Install: &control.InstallItem{Version: instB, Kind: "link"},
			Shell:   &control.InstallItem{Version: instA, Follows: false, AtStable: bp(true)}}}})
	pk.add(&control.Installs{At: &t0,
		Runtime: &control.InstallItem{Version: instA},
		Logins: []control.LoginInstall{{Login: "alice",
			Install: &control.InstallItem{Version: "-"},
			Client:  &control.InstallItem{Version: instA[:7]}}}})

	got := pk.judged(instB)
	if got.Stable != instB || got.Runtime.Version != instB || !*got.Runtime.AtStable {
		t.Fatalf("runtime = %+v stable %s", got.Runtime, got.Stable)
	}
	if len(got.Logins) != 2 || got.Logins[0].Login != "alice" || got.Logins[1].Login != "bob" {
		t.Fatalf("logins = %+v", got.Logins)
	}
	al, bo := got.Logins[0], got.Logins[1]
	if al.Install.AtStable != nil {
		t.Fatalf("a '-' version judged: %+v", al.Install)
	}
	if *al.Client.AtStable || !*bo.Install.AtStable || *bo.Shell.AtStable {
		t.Fatalf("judged wrong: client %v install %v shell %v", *al.Client.AtStable, *bo.Install.AtStable, *bo.Shell.AtStable)
	}
	if got.At == nil || !got.At.Equal(t1) {
		t.Fatalf("at = %v", got.At)
	}

	// 落后: the script's behind_secs, kept only for the stable it counted from
	n := int64(600)
	pk.stable = instB
	pk.runtime = &control.InstallItem{Version: instA, BehindSecs: &n}
	if g := pk.judged(instB); g.Runtime.BehindSecs == nil || *g.Runtime.BehindSecs != 600 {
		t.Fatalf("behind kept: %+v", g.Runtime)
	}
	if g := pk.judged(instA); g.Runtime.BehindSecs != nil || !*g.Runtime.AtStable {
		t.Fatalf("at the hub's stable, no 落后: %+v", g.Runtime)
	}
	pk.stable = instA[:7]
	if g := pk.judged(instB); g.Runtime.BehindSecs != nil || *g.Runtime.AtStable {
		t.Fatalf("another stable's 落后 kept: %+v", g.Runtime)
	}
	pk.stable, pk.runtime = "", &control.InstallItem{Version: instB}

	// one release line (claude-fleet#4671): judged against stable
	if g := pk.judged(instB); g.Stable != instB || !*g.Runtime.AtStable {
		t.Fatalf("one release line: stable %s runtime %+v", g.Stable, g.Runtime)
	}
	// no hub stable: the script's word stands
	if g := pk.judged(""); !*g.Logins[1].Shell.AtStable || g.Runtime.AtStable != nil {
		t.Fatalf("no stable: %+v %+v", g.Logins[1].Shell, g.Runtime)
	}
}

// The roster and the summary carry it per machine; a machine none reported
// for has no key.
func TestNodesCarryMachineInstalls(t *testing.T) {
	h := newFleetHarness(t)
	a := connectNode(t, h, "mac-i-alice", "mac-i", "alice", false)
	connectNode(t, h, "mac-j-bob", "mac-j", "bob", false)
	at := time.Now().UTC()
	beat(t, a.c, control.Proto, control.Heartbeat{Hostname: "mac-i", OSUser: "alice", Installs: &control.Installs{
		At: &at, Runtime: &control.InstallItem{Version: instA, Source: "hub"},
		Logins: []control.LoginInstall{{Login: "alice", Install: &control.InstallItem{Version: instA, Kind: "link", AtStable: bp(true)}}}}})
	waitFor(t, 3*time.Second, "alice's installs", func() bool {
		for _, m := range roster(t, h).Machines {
			if m.Hostname == "mac-i" && m.Installs != nil {
				return true
			}
		}
		return false
	})
	code, out, raw := postSummary(t, h, asOperator, nil)
	if code != http.StatusOK {
		t.Fatalf("HTTP %d %s", code, raw)
	}
	for _, m := range out.Machines {
		switch m.Hostname {
		case "mac-i":
			if m.Installs == nil || m.Installs.Runtime.Version != instA || len(m.Installs.Logins) != 1 ||
				m.Installs.Logins[0].Install.AtStable == nil || !*m.Installs.Logins[0].Install.AtStable {
				t.Fatalf("mac-i installs = %+v (%s)", m.Installs, raw)
			}
		case "mac-j":
			if m.Installs != nil {
				t.Fatalf("mac-j reported none: %+v", m.Installs)
			}
		}
	}
}
