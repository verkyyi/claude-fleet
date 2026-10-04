package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// The login's claude-fleet install, reported alongside the agent's own version
// so the hub roster can answer "which machine's fleet is behind trunk" without
// anyone logging into it (issue #157; claude-fleet#644).
//
// This file is deliberately thin. claude-fleet already knows how far its
// install trails its trunk -- fleet-install-version.sh, whose JSON key set its
// own selftest pins -- so the agent runs that script and relays what it says.
// There is no second git comparison here, and no dependency: the path either
// exists on this login or it does not, and when it does not the batch simply
// carries no reading and the hub draws a dash.

// fleetVersionScript is where claude-fleet installs the reporter, relative to
// the login's home. The agent already runs as that login with --home pointing
// at it, so cfg.Home is the right root.
var fleetVersionScript = filepath.Join(".claude", "fleet", "bin", "fleet-install-version.sh")

// fleetVersionArgs asks for the cheap reading: ~0.2s, no network, no sudo.
// --no-fetch means `behind` is read against the remote-tracking ref the
// install already has, which the install-sync daemon refreshes every 30
// minutes on its own; the script reports fetched:false so the hub can say so.
// A fetching run (~1s, network) does not belong on a seconds-level cadence,
// and the daemon's own fetch makes it unnecessary.
var fleetVersionArgs = []string{"--json", "--no-fetch", "--no-logins"}

// fleetVersionInterval is how long one reading is reused before the script
// runs again. The count only moves when the install fetches (every 30 min
// under install-sync) or someone pulls, so re-running on every 15-second scan
// would be a process per scan for a number that changes twice an hour.
const fleetVersionInterval = 5 * time.Minute

// fleetVersionTimeout bounds one run. The script is ~0.2s without a fetch; a
// run that takes longer than this is a wedged shell, not a slow one, and the
// scan must not wait behind it.
const fleetVersionTimeout = 10 * time.Second

// fleetCommand is the injection point for tests, like gitCommand.
var fleetCommand = exec.CommandContext

// fleetProbe caches the reading between runs, and remembers what it last
// logged so a login without claude-fleet (most of them) says so once, not
// once per scan.
type fleetProbe struct {
	last    *model.FleetVersion
	at      time.Time // when the script last ran (or was last found missing)
	lastLog string
}

// fleetVersionWire is the script's JSON as it arrives. Kept separate from
// model.FleetVersion so a key the script grows later cannot break decoding
// here, and so `logins` / `follow` (sentences for a reader) are carried
// without being parsed.
type fleetVersionWire struct {
	Head          string  `json:"head"`
	Branch        string  `json:"branch"`
	Behind        *int    `json:"behind"`
	Ahead         *int    `json:"ahead"`
	Dirty         bool    `json:"dirty"`
	Fetched       bool    `json:"fetched"`
	Verdict       string  `json:"verdict"`
	FollowVerdict *string `json:"follow_verdict"`
	Follow        string  `json:"follow"`
	Error         string  `json:"error"`
}

// reading returns the current fleet-install-version reading for the login
// under home, running the script when the cached one has aged out. nil means
// "nothing to report": the script is not installed, did not finish, or did
// not produce JSON. Each of those is logged once (the message is deduped),
// and none of them delays the batch that asked.
func (p *fleetProbe) reading(ctx context.Context, home string) *model.FleetVersion {
	if !p.at.IsZero() && time.Since(p.at) < fleetVersionInterval {
		return p.last
	}
	p.at = time.Now()
	p.last = nil

	script := filepath.Join(home, fleetVersionScript)
	if _, err := os.Stat(script); err != nil {
		// Not an error: most logins have no claude-fleet, and the whole
		// contract is "this path exists → report it; otherwise no column".
		p.logOnce("")
		return nil
	}

	ctx, cancel := context.WithTimeout(ctx, fleetVersionTimeout)
	defer cancel()
	cmd := fleetCommand(ctx, script, fleetVersionArgs...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()

	// The exit code MIRRORS the verdict (1 = BEHIND/AHEAD/DIVERGED, 2 =
	// UNKNOWN) and stdout is valid JSON either way, so a non-zero exit is
	// the normal case for exactly the installs this exists to surface.
	// Decide on stdout; the exit code only matters when there is none.
	var w fleetVersionWire
	if derr := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &w); derr != nil {
		switch {
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			p.logOnce("fleet-install-version.sh did not finish within " + fleetVersionTimeout.String() + "; not reporting the fleet version")
		case err != nil:
			p.logOnce("fleet-install-version.sh failed (" + err.Error() + "): " + firstLine(stderr.String()))
		default:
			p.logOnce("fleet-install-version.sh printed something that is not JSON; not reporting the fleet version")
		}
		return nil
	}
	p.logOnce("")

	fv := &model.FleetVersion{
		Head: w.Head, Branch: w.Branch, Behind: w.Behind, Ahead: w.Ahead,
		Dirty: w.Dirty, Fetched: w.Fetched, Verdict: w.Verdict,
		Follow: w.Follow, Error: w.Error,
		ObservedAt: p.at.UTC(),
	}
	if w.FollowVerdict != nil {
		fv.FollowVerdict = *w.FollowVerdict
	}
	p.last = fv
	return fv
}

// logOnce prints msg when it differs from the last thing this probe printed,
// so a persistent condition is one line in the log rather than one per scan.
// An empty msg clears the memory without printing, so the same condition
// recurring after a recovery is reported again.
func (p *fleetProbe) logOnce(msg string) {
	if msg == p.lastLog {
		return
	}
	p.lastLog = msg
	if msg != "" {
		log.Print(msg)
	}
}

func firstLine(s string) string {
	if i := bytes.IndexByte([]byte(s), '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
