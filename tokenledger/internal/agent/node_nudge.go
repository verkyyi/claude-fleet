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
