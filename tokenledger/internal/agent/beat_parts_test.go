package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// stubSys swaps the process's sampler for one that reads read, every 10 ms.
func stubSys(t *testing.T, read func() sysInfo) {
	t.Helper()
	old := processSys
	processSys = newSysSampler(read, 10*time.Millisecond)
	t.Cleanup(func() { processSys.stop(); processSys = old })
}

// claude-fleet#2798 完成判据: the fleet probe hangs, and the beat still goes
// out on time with the load read fresh (load1 non-zero, sys_at new) and the
// fleet half the LAST completed one, with its older fleet_at — never empty.
func TestHeartbeatGoesOutWhileTheFleetProbeHangs(t *testing.T) {
	stubSys(t, func() sysInfo { return sysInfo{Load1: 1.5, MemTotal: 16 << 30, MemFree: 4 << 30} })
	oldBudget := fleetBeatBudget
	fleetBeatBudget = 150 * time.Millisecond
	t.Cleanup(func() { fleetBeatBudget = oldBudget })

	home := t.TempDir()
	script := filepath.Join(home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)
	var hang atomic.Bool
	release := make(chan struct{})
	var once sync.Once
	letGo := func() { once.Do(func() { close(release) }) }
	t.Cleanup(letGo)
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		if hang.Load() {
			// m5's probe (#1797): stuck until it is let go or its own deadline.
			select {
			case <-release:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		var req map[string]any
		json.Unmarshal(stdin, &req)
		switch req["method"] {
		case "discover":
			return []byte(`{"result":{"machine_id":"m-1","fleets":[{"fleet_id":"f-a","name":"fleet-a","repo":"o/a"}]}}`), nil
		case "fleet_status":
			return []byte(`{"result":{"state":"running","workers":[{"key":"1"},{"key":"2"}]}}`), nil
		}
		return []byte(`{"result":{}}`), nil
	}
	t.Cleanup(func() { fleetControlCommand = old })

	a, err := New(Config{HubURL: "http://hub.invalid", Token: "x", Home: home, StateDir: t.TempDir(),
		SessionsDir: t.TempDir(), Fleet: true})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	probe := &fleetProbe{}

	hb1 := a.nodeHeartbeat(ctx, probe)
	if hb1.FleetAt == nil || hb1.Sessions != 2 || hb1.SysAt == nil || hb1.Load1 != 1.5 {
		t.Fatalf("first beat: fleet_at %v sessions %d sys_at %v load %v", hb1.FleetAt, hb1.Sessions, hb1.SysAt, hb1.Load1)
	}

	time.Sleep(50 * time.Millisecond)
	hang.Store(true)
	start := time.Now()
	hb2 := a.nodeHeartbeat(ctx, probe)
	if took := time.Since(start); took > fleetBeatBudget+time.Second {
		t.Fatalf("the beat waited %v on a hung fleet probe; budget %v", took, fleetBeatBudget)
	}
	if hb2.Load1 != 1.5 || hb2.SysAt == nil || time.Since(*hb2.SysAt) > time.Second {
		t.Fatalf("hung probe: load %v sys_at %v; want 1.5, fresh", hb2.Load1, hb2.SysAt)
	}
	if hb2.FleetAt == nil || !hb2.FleetAt.Equal(*hb1.FleetAt) || hb2.Sessions != 2 || len(hb2.Fleets) != 1 {
		t.Fatalf("hung probe: fleet_at %v sessions %d; want the last reading (%v, 2), never empty", hb2.FleetAt, hb2.Sessions, hb1.FleetAt)
	}
	if !hb2.SysAt.After(*hb2.FleetAt) {
		t.Fatalf("sys_at %v should be newer than the stuck fleet_at %v", hb2.SysAt, hb2.FleetAt)
	}
	// A third beat while it still hangs starts no second read and waits the
	// budget again at most.
	start = time.Now()
	if hb := a.nodeHeartbeat(ctx, probe); time.Since(start) > fleetBeatBudget+time.Second || !hb.FleetAt.Equal(*hb1.FleetAt) {
		t.Fatalf("third beat: took %v, fleet_at %v", time.Since(start), hb.FleetAt)
	}

	// Let it go: the read that was stuck lands on a later beat, newer.
	hang.Store(false)
	letGo()
	deadline := time.Now().Add(5 * time.Second)
	for {
		hb := a.nodeHeartbeat(ctx, probe)
		if hb.FleetAt != nil && hb.FleetAt.After(*hb1.FleetAt) && hb.Sessions == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the fleet half never came back: fleet_at %v", hb.FleetAt)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// An older hub reads the new beat as it always did: the new fields are only
// added, each optional, and an old beat decodes with them absent.
func TestHeartbeatNewFieldsAreOptional(t *testing.T) {
	var old control.Heartbeat
	if err := json.Unmarshal([]byte(`{"hostname":"m5","load1":0.5,"ncpu":8,"sessions":1,"observed_at":"2026-10-09T00:00:00Z"}`), &old); err != nil {
		t.Fatal(err)
	}
	if old.SysAt != nil || old.FleetAt != nil || old.Versions != nil || old.VersionsAt != nil || old.SysUnread != nil {
		t.Fatalf("an old beat decoded with new fields: %+v", old)
	}
	b, _ := json.Marshal(control.Heartbeat{Hostname: "m5"})
	for _, k := range []string{"sys_at", "fleet_at", "versions", "versions_at", "sys_unread"} {
		if strings.Contains(string(b), `"`+k+`"`) {
			t.Fatalf("an empty %s is on the wire: %s", k, b)
		}
	}
}

// What the platform will not say is 读不到 on the beat, and its why is logged
// once — and once more when it reads again.
func TestUnreadSysIsSaidAndLoggedOnce(t *testing.T) {
	var bad atomic.Bool
	bad.Store(true)
	s := newSysSampler(func() sysInfo {
		var si sysInfo
		if bad.Load() {
			si.unread("load", "vm.loadavg: operation not permitted")
		} else {
			si.Load1 = 0.7
		}
		return si
	}, time.Hour)
	t.Cleanup(s.stop)
	var logged bytes.Buffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	var hb control.Heartbeat
	fillSys(&hb, s)
	if len(hb.SysUnread) != 1 || hb.SysUnread[0] != "load" || hb.SysAt == nil {
		t.Fatalf("beat = unread %v at %v", hb.SysUnread, hb.SysAt)
	}
	s.sample()
	s.sample()
	if n := strings.Count(logged.String(), "operation not permitted"); n != 1 {
		t.Fatalf("logged %d times:\n%s", n, logged.String())
	}
	bad.Store(false)
	s.sample()
	s.sample()
	if n := strings.Count(logged.String(), "reads again"); n != 1 {
		t.Fatalf("reads-again logged %d times:\n%s", n, logged.String())
	}
	hb = control.Heartbeat{}
	fillSys(&hb, s)
	if hb.SysUnread != nil || hb.Load1 != 0.7 {
		t.Fatalf("beat after recovery = %+v", hb)
	}
}

// The machine link's versions come from the updater off the beat: the first
// beats go without (never waiting), a later one carries them with their time;
// a failed read is said, not dropped.
func TestMachineBeatCarriesVersionsOffTheBeat(t *testing.T) {
	stubSys(t, func() sysInfo { return sysInfo{Load1: 2} })
	var calls atomic.Int32
	fail := atomic.Bool{}
	old := versionsCommand
	versionsCommand = func(ctx context.Context, updater string) ([]byte, error) {
		calls.Add(1)
		if updater != "/x/fleet-node-update.py" {
			t.Errorf("updater = %s", updater)
		}
		if fail.Load() {
			return nil, errors.New("exit status 1")
		}
		time.Sleep(50 * time.Millisecond)
		return []byte(`{"runtime":"abc","actual":{"claude":"2.1.295","tmux":"3.7c"},"want":{"claude":"2.1.295"},"update":{"result":"current","phase":"idle","at":"2026-10-10T00:52:07Z"}}`), nil
	}
	t.Cleanup(func() { versionsCommand = old })
	ml := newMachineLink(MachineConfig{Version: "t", Updater: "/x/fleet-node-update.py"})
	ctx := context.Background()

	hb := machineHeartbeat("t", nil, "")
	start := time.Now()
	ml.fillVersions(ctx, &hb)
	if time.Since(start) > 30*time.Millisecond || hb.Versions != nil {
		t.Fatalf("the first beat waited %v or carried %+v", time.Since(start), hb.Versions)
	}
	if hb.Load1 != 2 || hb.SysAt == nil {
		t.Fatalf("machine beat load %v at %v", hb.Load1, hb.SysAt)
	}
	deadline := time.Now().Add(3 * time.Second)
	for hb.Versions == nil {
		if time.Now().After(deadline) {
			t.Fatal("versions never reached a beat")
		}
		time.Sleep(20 * time.Millisecond)
		hb = machineHeartbeat("t", nil, "")
		ml.fillVersions(ctx, &hb)
	}
	if hb.Versions.Runtime != "abc" || hb.Versions.Actual["tmux"] != "3.7c" || hb.VersionsAt == nil ||
		hb.Versions.Update == nil || hb.Versions.Update.Phase != "idle" {
		t.Fatalf("versions = %+v at %v", hb.Versions, hb.VersionsAt)
	}
	// Fresh for versionsEvery: more beats run no more reads.
	n := calls.Load()
	for i := 0; i < 5; i++ {
		ml.fillVersions(ctx, &hb)
	}
	if calls.Load() != n {
		t.Fatalf("versions re-read %d times within versionsEvery", calls.Load()-n)
	}

	// A failed read is a reading: its error rides the beat.
	fail.Store(true)
	var bad control.Versions
	if v, ok := readVersions(ctx, "/x/fleet-node-update.py"); !ok || v.Error == "" {
		t.Fatalf("failed read = %+v ok %v", v, ok)
	} else {
		bad = v
	}
	if bad.Runtime != "" {
		t.Fatalf("a failed read guessed a runtime: %+v", bad)
	}
	// No updater configured: no versions, no read.
	ml2 := newMachineLink(MachineConfig{Version: "t"})
	hb = control.Heartbeat{}
	ml2.fillVersions(ctx, &hb)
	if hb.Versions != nil {
		t.Fatalf("no updater, versions %+v", hb.Versions)
	}
}
