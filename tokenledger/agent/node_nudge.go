package agent

import (
	"context"
	"os"
	"path/filepath"
	"time"
)

// The state nudge (claude-fleet#1481).
//
// The heartbeat reports every window's state every LiveInterval (5 s), and the
// other machines' sidebars poll the hub on their own clock — so a window that
// just went 「在问你」 took up to 15 s to show up elsewhere. The fleet now
// touches ONE file whenever it writes a window's @claude_state / @claude_needs
// (fleet_hub_nudge in bin/fleet-lib.sh, the hook's and the daemons' inline
// copies): $FLEET_CONF_DIR/global/hub-nudge, one per login — the same scope as
// this agent. The agent polls that file's mtime (no fsnotify dependency) and
// sends an extra heartbeat at once, debounced so a burst of writes costs one
// beat and capped at two nudge beats a second, so a runaway writer can never
// turn the control channel into a firehose. The 5 s cadence stays as it is:
// it is the liveness signal, and the only thing a node without claude-fleet
// has.

// Nudge timing. Variables so tests can read them; the defaults are the
// contract (issue #1481: 250 ms poll, ≤ 2 nudge beats/s; the debounce was
// 300 ms there and is 100 ms since #1526 — the other machine's sidebar now
// long-polls the hub, so the beat's own delay is most of what is left of the
// 1 s budget, and a burst of writes still folds into one beat).
var (
	nodeNudgePoll     = 250 * time.Millisecond
	nodeNudgeDebounce = 100 * time.Millisecond
	nodeNudgeMinGap   = 500 * time.Millisecond
)

// fleetNudgeRel is the nudge file's path under claude-fleet's conf dir.
const fleetNudgeRel = "global/hub-nudge"

// defaultNudgePath is the nudge file for a login whose conf dir is the
// default (~/.config/claude-fleet). The CLI passes $FLEET_CONF_DIR's when set.
func defaultNudgePath(home string) string {
	return filepath.Join(home, ".config", "claude-fleet", filepath.FromSlash(fleetNudgeRel))
}

// watchNudge polls path's mtime every nodeNudgePoll and sends one (coalesced)
// signal each time it changes — a file that appears counts as a change, a
// missing one as nothing. It stops with ctx.
func watchNudge(ctx context.Context, path string) <-chan struct{} {
	ch := make(chan struct{}, 1)
	if path == "" {
		return ch
	}
	go func() {
		var last time.Time
		if st, err := os.Stat(path); err == nil {
			last = st.ModTime()
		}
		t := time.NewTicker(nodeNudgePoll)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				st, err := os.Stat(path)
				if err != nil {
					continue
				}
				if m := st.ModTime(); !m.Equal(last) {
					last = m
					select {
					case ch <- struct{}{}:
					default:
					}
				}
			}
		}
	}()
	return ch
}

// nudgeBeats turns raw nudge signals into beat moments: the first signal arms
// a nodeNudgeDebounce timer (later signals inside it are folded in), and a
// beat that would come sooner than nodeNudgeMinGap after the previous nudge
// beat is held until the gap has passed — never dropped, so the last change
// of a burst always goes out. The returned pending channel is what the
// session loop selects on; it is nil while nothing is armed.
type nudgeBeats struct {
	pending <-chan time.Time
	last    time.Time
}

// arm notes a nudge signal.
func (n *nudgeBeats) arm() {
	if n.pending == nil {
		n.pending = time.After(nodeNudgeDebounce)
	}
}

// due is called when pending fires: it reports whether to beat now, and
// re-arms when the rate limit says not yet.
func (n *nudgeBeats) due() bool {
	n.pending = nil
	if wait := nodeNudgeMinGap - time.Since(n.last); wait > 0 {
		n.pending = time.After(wait)
		return false
	}
	n.last = time.Now()
	return true
}

// fleetReuseMax is how long a beat may answer with the last fleet read while
// hub-nudge has not moved (claude-fleet#3544). Every 5 s beat ran two Python
// starts per login (discover, fleet_status) only for fleet-control.py to answer
// from its own heartbeat cache (READ_CACHE_TTL: workers 15 s, capacity 20 s,
// inventory 60 s — invalidated by the same nudge), so a reuse under the
// shortest of those changes nothing the hub sees and skips the starts. A var
// for tests.
var fleetReuseMax = 14 * time.Second

// fleetQuietReuseMax is the same reuse on a login whose kept read counted no
// session at all: a tenant login with nothing open re-read every 14 s for days
// (two Python starts, a bash that sources fleet-lib.sh, ps and tmux each time),
// ~40 reads a minute on a nine-login machine, while its answer — no rows, the
// same capacity — never moved. What such a read carries besides rows is the
// capacity (the hub's gate re-checks a start on arrival, fleet_control.py
// READ_CACHE_FLOOR) and ready (itself re-asked at most every readyInterval, 60
// s), so a minute old changes nothing a placement relies on; a spawn, close or
// restore touches hub-nudge and the next beat reads at once. A var for tests.
var fleetQuietReuseMax = 60 * time.Second

// fleetNudgeMtime is hub-nudge's mtime as UnixNano, 0 when there is no file.
func (a *Agent) fleetNudgeMtime() int64 {
	if a.cfg.FleetNudgePath == "" {
		return 0
	}
	st, err := os.Stat(a.cfg.FleetNudgePath)
	if err != nil {
		return 0
	}
	return st.ModTime().UnixNano()
}

// fleetReuse is the max age of a fleet read this beat may answer with:
// fleetReuseMax while hub-nudge exists and has not moved since the kept read
// started — fleetQuietReuseMax when that read counted no session in any fleet
// and every fleet read (fleetPart.quiet) — else 0 (read now). No nudge file (no hub
// nudges on this login) or FLEET_CONTROL_READ_CACHE=0 reads every beat, as before.
func (a *Agent) fleetReuse() time.Duration {
	if os.Getenv("FLEET_CONTROL_READ_CACHE") == "0" {
		return 0
	}
	m := a.fleetNudgeMtime()
	if m == 0 || m != a.fleetRdNudge.Load() {
		return 0
	}
	if a.fleetRdQuiet.Load() {
		return fleetQuietReuseMax
	}
	return fleetReuseMax
}
