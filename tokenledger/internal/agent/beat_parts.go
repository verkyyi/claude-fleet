package agent

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A heartbeat is several readings, each on its own clock (claude-fleet#2798):
// the machine's load and memory (a sysctl, every sysEvery), the login's fleets
// (fleet-control.py, slow and sometimes stuck — #1797), a managed machine's
// versions (the updater, every versionsEvery). Each carries the time it was
// read, and none waits on another: before this, m5's beat ran the fleet probe
// first and the hub read its load as empty all day.

// asyncReading keeps the last completed reading of something slow. get starts
// one read when none is running and the last is older than maxAge, waits up to
// wait for it, and answers the last completed reading either way — a read past
// its budget keeps going and lands on a later beat, never an empty one now.
type asyncReading[T any] struct {
	mu       sync.Mutex
	val      T
	at       time.Time
	have     bool
	inflight chan struct{}
}

// get answers the last reading, its time and whether there is one. read's ok
// false (its ctx ended) keeps the previous reading. waitFirst waits for the
// read to finish (or ctx) when there is no reading yet at all.
func (r *asyncReading[T]) get(ctx context.Context, maxAge, wait time.Duration, waitFirst bool, read func(context.Context) (T, bool)) (T, time.Time, bool) {
	r.mu.Lock()
	ch := r.inflight
	if ch == nil && (!r.have || time.Since(r.at) >= maxAge) {
		ch = make(chan struct{})
		r.inflight = ch
		go func() {
			v, ok := read(ctx)
			r.mu.Lock()
			if ok {
				r.val, r.at, r.have = v, time.Now().UTC(), true
			}
			r.inflight = nil
			r.mu.Unlock()
			close(ch)
		}()
	}
	have := r.have
	r.mu.Unlock()
	if ch != nil {
		if !have && waitFirst {
			select {
			case <-ch:
			case <-ctx.Done():
			}
		} else if wait > 0 {
			t := time.NewTimer(wait)
			select {
			case <-ch:
			case <-t.C:
			case <-ctx.Done():
			}
			t.Stop()
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.val, r.at, r.have
}

// ---- the machine's load and memory -----------------------------------------

// sysEvery is how often the sampler reads the kernel; a beat carries the last
// reading with its time.
const sysEvery = 10 * time.Second

// sysSampler reads load and memory on its own goroutine, once per process —
// every login of a machine agent reads the same kernel.
type sysSampler struct {
	once   sync.Once
	every  time.Duration
	read   func() sysInfo
	mu     sync.Mutex
	si     sysInfo
	at     time.Time
	logged string
	done   chan struct{}
}

func newSysSampler(read func() sysInfo, every time.Duration) *sysSampler {
	return &sysSampler{read: read, every: every, done: make(chan struct{})}
}

// stop ends the sampling goroutine (tests; the process's runs for its life).
func (s *sysSampler) stop() { close(s.done) }

// processSys is the process's one sampler; tests swap it.
var processSys = newSysSampler(readSysInfo, sysEvery)

// last is the newest reading and when it was taken. The first call reads
// synchronously (a sysctl, never slow) and starts the sampling goroutine.
func (s *sysSampler) last() (sysInfo, time.Time) {
	s.once.Do(func() {
		s.sample()
		go func() {
			t := time.NewTicker(s.every)
			defer t.Stop()
			for {
				select {
				case <-t.C:
					s.sample()
				case <-s.done:
					return
				}
			}
		}()
	})
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.si, s.at
}

func (s *sysSampler) sample() {
	si := s.read()
	at := time.Now().UTC()
	s.mu.Lock()
	s.si, s.at = si, at
	// What the platform would not say is logged once per distinct reason,
	// and once more when it reads again — a 「读不到」 on the page has its
	// why in the agent's log.
	why := strings.Join(si.Unread, ",")
	if si.Why != "" {
		why += ": " + si.Why
	}
	changed := why != s.logged
	prev := s.logged
	s.logged = why
	s.mu.Unlock()
	switch {
	case changed && why != "":
		log.Printf("sysinfo: cannot read %s", why)
	case changed && prev != "":
		log.Printf("sysinfo: reads again (was: %s)", prev)
	}
}

// fillSys puts the sampler's last reading into a beat.
func fillSys(hb *control.Heartbeat, s *sysSampler) {
	si, at := s.last()
	hb.Load1, hb.MemFreeBytes, hb.MemTotalBytes, hb.MemPressure = si.Load1, si.MemFree, si.MemTotal, si.MemPressure
	if !at.IsZero() {
		hb.SysAt = &at
	}
	if len(si.Unread) > 0 {
		hb.SysUnread = append([]string(nil), si.Unread...)
	}
}

// ---- the login's fleets ----------------------------------------------------

// fleetBeatBudget is how long a beat waits for the fleet half before it goes
// out with the last completed one (claude-fleet#2798). A var for tests.
var fleetBeatBudget = 5 * time.Second

// fleetPart is the fleet half of a beat, read together by one fleet-control.py
// round: the fleets, the capacity, the claude-fleet version, ready, credsep.
type fleetPart struct {
	snap     fleetSnapshot
	err      error
	version  string
	ready    *bool
	notReady string
	credsep  string
}

// readFleetPart is one fleet-half read. ok false when ctx ended under it — a
// dropped connection's half-read is never kept.
func (a *Agent) readFleetPart(ctx context.Context, probe *fleetProbe) (fleetPart, bool) {
	var fp fleetPart
	fp.snap, fp.err = readFleets(ctx, a.cfg.Home)
	if fv := probe.reading(ctx, a.cfg.Home); fv != nil {
		fp.version = fv.Head
	}
	fp.ready, fp.notReady = probe.ready.reading(ctx, a.cfg.Home, time.Now())
	fp.credsep = probe.credsep.reading(ctx, a.cfg.Home, time.Now())
	return fp, ctx.Err() == nil
}

// fill puts a fleet half read at `at` into a beat.
func (fp fleetPart) fill(hb *control.Heartbeat, at time.Time) {
	switch {
	case errors.Is(fp.err, errNoFleet):
	case fp.err != nil:
		hb.FleetError = fp.err.Error()
	default:
		hb.MachineID, hb.Fleets = fp.snap.machineID, fp.snap.fleets
		for _, f := range fp.snap.fleets {
			hb.Sessions += f.Count
		}
		if c := fp.snap.capacity; c != nil {
			if c.MaxSessions > 0 {
				n := c.Sessions
				hb.MaxSessions, hb.CapSessions = c.MaxSessions, &n
			}
			// The gate's own verdict (claude-fleet#1836), as discover said it:
			// absent from a claude-fleet older than that, and then unsaid here.
			hb.Admit, hb.AdmitWhy, hb.Room = c.Admit, c.AdmitWhy, c.Room
		}
	}
	hb.FleetVersion = fp.version
	hb.Ready, hb.NotReady = fp.ready, fp.notReady
	hb.Credsep = fp.credsep
	if !at.IsZero() {
		hb.FleetAt = &at
	}
}

// ---- a managed machine's versions ------------------------------------------

// versionsEvery is how often the machine link asks the updater; each read
// runs the parts' --version, so not every beat.
const versionsEvery = 5 * time.Minute

// versionsTimeout bounds one `fleet-node-update.py versions --json`.
var versionsTimeout = 90 * time.Second

// versionsCommand is the injection point for tests.
var versionsCommand = func(ctx context.Context, updater string) ([]byte, error) {
	return exec.CommandContext(ctx, updater, "versions", "--json").Output()
}

// readVersions asks the updater for the machine's 版本与更新. A failed read is
// a reading too: its Error says why, so the page says 读不到 with the reason.
func readVersions(ctx context.Context, updater string) (control.Versions, bool) {
	ctx, cancel := context.WithTimeout(ctx, versionsTimeout)
	defer cancel()
	out, err := versionsCommand(ctx, updater)
	var v control.Versions
	if err == nil {
		err = json.Unmarshal(out, &v)
	}
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) {
			return v, false
		}
		log.Printf("machine link: versions: %v", err)
		return control.Versions{Error: err.Error()}, true
	}
	return v, true
}
