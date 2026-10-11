package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The entry port's keys, pushed (claude-fleet#3070, EPIC #3067 C3).
//
// A machine that runs the entry port lists CapEntryKeys on its MACHINE hello;
// the hub then sends TypeEntryKeys {version} on that link (Login empty) on the
// first beat and whenever the list for this machine moves. The node program
// answers by running the machine daemon's own
// `fleet-node-supervisor.py entry pull --version N` (root, from the root
// runtime): the GET, the checks, the keys files, AllowUsers, the reload and the
// cut of a revoked key's connections are claude-fleet's, never re-done here. A
// pull that fails is run again on the next beat until one succeeds; while the
// hub is away the machine keeps its last list.

// entryTimeout bounds one pull: the GET plus `sshd -t` and the rewrite.
const entryTimeout = 90 * time.Second

// entryCommand is the injection point for tests.
var entryCommand = func(ctx context.Context, script string, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, script, args...)
}

type entryFollow struct {
	mu      sync.Mutex
	want    int
	done    int
	running bool
	lastLog string
}

// handleEntryKeys takes the hub's TypeEntryKeys on the machine half.
func (ml *machineLink) handleEntryKeys(ctx context.Context, m control.Message) {
	var e control.EntryKeys
	if ml.cfg.EntryCtl == "" || json.Unmarshal(m.Payload, &e) != nil || e.Version <= 0 {
		return
	}
	ml.entry.mu.Lock()
	ml.entry.want = e.Version
	ml.entry.mu.Unlock()
	ml.entryKick(ctx)
}

// entryKick starts a pull when the hub's version has not been applied and none
// is running. The beat calls it every tick: that is the retry.
func (ml *machineLink) entryKick(ctx context.Context) {
	st := &ml.entry
	st.mu.Lock()
	if ml.cfg.EntryCtl == "" || st.running || st.want <= 0 || st.want == st.done {
		st.mu.Unlock()
		return
	}
	st.running = true
	v := st.want
	st.mu.Unlock()
	go func() {
		ok, note := ml.entryPull(ctx, v)
		st.mu.Lock()
		defer st.mu.Unlock()
		st.running = false
		if ok {
			st.done = v
			note = ""
		}
		if note != st.lastLog {
			if note != "" {
				log.Printf("entry keys v%d: pull failed (retried next beat): %s", v, note)
			} else if st.lastLog != "" {
				log.Printf("entry keys v%d: applied", v)
			}
			st.lastLog = note
		}
	}()
}

// entryPull runs `<supervisor> entry pull --version v`. ok = exit 0, or 3 (the
// entry is off on this machine: nothing to retry).
func (ml *machineLink) entryPull(ctx context.Context, v int) (bool, string) {
	// Not the connection's: a link that drops mid-pull must not cut a rewrite.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), entryTimeout)
	defer cancel()
	cmd := entryCommand(ctx, ml.cfg.EntryCtl, "entry", "pull", "--version", strconv.Itoa(v))
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	if err == nil || (cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 3) {
		return true, ""
	}
	last := strings.TrimSpace(out.String())
	if i := strings.LastIndexByte(last, '\n'); i >= 0 {
		last = last[i+1:]
	}
	if last == "" {
		last = err.Error()
	}
	return false, last
}

// How the outside could reach the entry port (claude-fleet#3072, EPIC #3067
// C6): every entryReachEvery the machine runs the daemon's own
// `fleet-node-supervisor.py entry reach` — its global IPv6 addresses, its
// router asked to forward the port (NAT-PMP / UPnP, FLEET_ENTRY_PORTMAP),
// the report POSTed to the hub, which dials each address and answers what
// the doctor's `public` row reads. Off the beat, in its own goroutine: a
// router that never answers or a hub that is away never holds a heartbeat up.

// entryReachEvery is how often the machine reports (MachineConfig's
// EntryReachEvery overrides it).
const entryReachEvery = 5 * time.Minute

// entryReachTimeout bounds one report: the router asked, the hub's dials.
const entryReachTimeout = 2 * time.Minute

type entryReachClock struct {
	mu      sync.Mutex
	running bool
	last    time.Time
	lastLog string
}

// reachKick starts a report when the last one is entryReachEvery old and none
// is running. The beat calls it every tick.
func (ml *machineLink) reachKick(ctx context.Context) {
	st := &ml.reach
	every := ml.cfg.EntryReachEvery
	if every <= 0 {
		every = entryReachEvery
	}
	st.mu.Lock()
	if ml.cfg.EntryCtl == "" || st.running || (!st.last.IsZero() && time.Since(st.last) < every) {
		st.mu.Unlock()
		return
	}
	st.running, st.last = true, time.Now()
	st.mu.Unlock()
	go func() {
		note := ml.entryReach(ctx)
		st.mu.Lock()
		defer st.mu.Unlock()
		st.running = false
		if note != st.lastLog {
			if note != "" {
				log.Printf("entry reach: %s (again in %s)", note, every)
			}
			st.lastLog = note
		}
	}()
}

// entryReach runs `<supervisor> entry reach`: "" when it ran (exit 0, or 3 —
// the entry is off here), else its last line.
func (ml *machineLink) entryReach(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), entryReachTimeout)
	defer cancel()
	cmd := entryCommand(ctx, ml.cfg.EntryCtl, "entry", "reach")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	if err == nil || (cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 3) {
		return ""
	}
	last := strings.TrimSpace(out.String())
	if i := strings.LastIndexByte(last, '\n'); i >= 0 {
		last = last[i+1:]
	}
	if last == "" {
		last = err.Error()
	}
	return last
}
