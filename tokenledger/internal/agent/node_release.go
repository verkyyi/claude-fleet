package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// A new stable, pushed (claude-fleet#3146, EPIC #3139 C7).
//
// The hub sends TypeRelease {sha, seq} the moment its stable pointer moves
// and on the first beat of each connection. It is a wake-up, nothing more:
//
//   - the MACHINE link (`ccquota agent --machine`, root) writes the node
//     daemon's <state>/update-now (content: the sha), and the daemon, which
//     looks every second, runs its `update` task at once — the same task its
//     5-minute clock runs, with the same lock, doctor and rollback;
//   - a login of its own (a plain agent whose login follows stable with
//     ~/.claude/fleet/bin/fleet-install-sync.sh) runs one `--now` tick — the
//     same tick its 30-minute clock runs.
//
// Both still read the target from the hub themselves and only move forward,
// so a push can never take anything back; on top of that, a release this
// machine or login is already at (its sha) or past (its seq) is ignored here.
// A push that never arrives changes nothing: the clocks stay as they were. A
// machine tenant (a managed login) lists nothing — its install moves with the
// machine.

// fleetInstallSync is the login's own follower.
var fleetInstallSync = filepath.Join(".claude", "fleet", "bin", "fleet-install-sync.sh")

// releaseSyncTimeout bounds one install-sync tick: a fetch, an apply and two
// doctor runs.
const releaseSyncTimeout = 20 * time.Minute

// releaseCommand is the injection point for tests, like fleetCommand.
var releaseCommand = fleetCommand

type releaseFollow struct {
	mu      sync.Mutex
	want    control.Release // the newest release the hub said
	done    int64           // the seq a tick last ran for
	running bool
}

// releasePush reads a TypeRelease; ok = a well-formed one.
func releasePush(m control.Message) (control.Release, bool) {
	var r control.Release
	if json.Unmarshal(m.Payload, &r) != nil || !release.ValidSHA(r.SHA) || r.Seq < 1 {
		return r, false
	}
	return r, true
}

// linkedSHA is the sha a version link names — <root>/current → <root>/<sha>,
// ~/.claude/fleet → ~/.claude/fleet.versions/<sha> — else "".
func linkedSHA(link string) string {
	t, err := os.Readlink(link)
	if err != nil {
		return ""
	}
	t = filepath.Base(filepath.Clean(t))
	if release.ValidSHA(t) {
		return t
	}
	return ""
}

// releaseAhead: is r past the release `current` names? A release with the
// same sha, or a seq the current release's signed manifest is at or past, is
// not. Unknown (no link, no manifest) counts as behind: the updater decides.
func releaseAhead(current string, r control.Release) bool {
	if current == "" {
		return true
	}
	if linkedSHA(current) == r.SHA {
		return false
	}
	b, err := os.ReadFile(filepath.Join(current, ".release", "manifest.json"))
	if err != nil {
		return true
	}
	var m struct {
		Seq int64 `json:"seq"`
	}
	if json.Unmarshal(b, &m) == nil && m.Seq >= r.Seq {
		return false
	}
	return true
}

// handleRelease takes the hub's TypeRelease on the machine half: the node
// daemon's update-now, written by one rename (root's, 0644).
func (ml *machineLink) handleRelease(m control.Message) {
	r, ok := releasePush(m)
	if !ok || ml.cfg.UpdateNow == "" || !releaseAhead(ml.cfg.CurrentRelease, r) {
		return
	}
	if err := writeUpdateNow(ml.cfg.UpdateNow, r.SHA); err != nil {
		log.Printf("release %.7s #%d: update-now: %v (the update's own clock follows)", r.SHA, r.Seq, err)
		return
	}
	log.Printf("release %.7s #%d: update-now written", r.SHA, r.Seq)
}

func writeUpdateNow(path, sha string) error {
	dir := filepath.Dir(path)
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return fmt.Errorf("no state directory %s", dir)
	}
	f, err := os.CreateTemp(dir, ".update-now-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, err = f.WriteString(sha + "\n")
	if err == nil {
		err = f.Chmod(0o644)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// releaseCapable reports whether this login follows a pushed release: a login
// of its own (no machine link) whose install has install-sync.
func (a *Agent) releaseCapable() bool {
	if a.machine != nil || a.cfg.Home == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(a.cfg.Home, fleetInstallSync))
	return err == nil
}

// handleRelease takes the hub's TypeRelease on a login of its own.
func (a *Agent) handleRelease(ctx context.Context, m control.Message) {
	r, ok := releasePush(m)
	if !ok || !a.releaseCapable() {
		return
	}
	st := &a.rel
	st.mu.Lock()
	if r.Seq > st.want.Seq {
		st.want = r
	}
	st.mu.Unlock()
	a.releaseKick(ctx)
}

// releaseKick runs one install-sync tick for the newest release not yet run
// for, unless one is running (the one running starts the next when it ends).
// A tick that did not move the install is not retried here: its own clock is
// the retry.
func (a *Agent) releaseKick(ctx context.Context) {
	st := &a.rel
	st.mu.Lock()
	r := st.want
	if st.running || r.Seq <= st.done {
		st.mu.Unlock()
		return
	}
	if linkedSHA(filepath.Join(a.cfg.Home, ".claude", "fleet")) == r.SHA {
		st.done = r.Seq // already there: nothing to wake
		st.mu.Unlock()
		return
	}
	st.running = true
	st.mu.Unlock()
	go func() {
		note := a.releaseSync(ctx)
		st.mu.Lock()
		st.running = false
		st.done = r.Seq
		st.mu.Unlock()
		if note != "" {
			log.Printf("release %.7s #%d: install-sync --now: %s (its own clock follows)", r.SHA, r.Seq, note)
		}
		a.releaseKick(ctx)
	}()
}

// releaseSync runs fleet-install-sync.sh --now; "" = it ran.
func (a *Agent) releaseSync(ctx context.Context) string {
	script := filepath.Join(a.cfg.Home, fleetInstallSync)
	// Not the connection's: a link that drops mid-tick must not cut a switch.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), releaseSyncTimeout)
	defer cancel()
	cmd := releaseCommand(ctx, script, "--now")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	if err == nil {
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
