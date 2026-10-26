package agent

// Moving the hub (task PNWW): a hub with fleet.node_url names its one
// machine-facing address in every welcome (control.Welcome.HubURL). A node that
// dialed another address follows it — never on the announcement alone:
//
//  1. the address is an https origin and not the one dialed (hubMoveTarget);
//  2. bin/fleet-hub-move.py verify asks BOTH addresses' /v1/node/self with this
//     node's own credential (its Authorization values on the script's stdin,
//     never an argv) and they must name one endpoint — a new address that
//     refuses the token, answers another endpoint, redirects or cannot be
//     reached is not followed and nothing is written (BREAK-IT
//     hub-moved-unverified);
//  3. the same script — the ONE writer — rewrites every file the machine's
//     tools read the address from, each by its owner: a plain agent its own
//     login's (`follow --scope login`), the machine agent each tenant's through
//     prepCmd (`rewrite --scope login`) and then root's (`rewrite --scope
//     machine`, machine.env last);
//  4. the agent reconnects there: a plain agent ends Run (its service — launchd
//     KeepAlive, systemd Restart=always, the credsep launcher — starts it on the
//     rewritten node.env), the machine agent is restarted by the node daemon on
//     machine.env's change.
//
// No announcement, the same address, a pod (HubDial), a one-shot run or a seat
// (Core) ⇒ nothing runs, byte for byte as before.

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// hubMoveScriptName is the one writer of a machine's hub address.
const hubMoveScriptName = "fleet-hub-move.py"

// hubMovePython runs it (a seam for the tests).
var hubMovePython = "/usr/bin/python3"

// hubMoveTimeout bounds one call: two /v1/node/self reads (15 s each) and a
// handful of small files — the machine half also re-renders the admin seat's
// unit.
const hubMoveTimeout = 3 * time.Minute

// hubMoveMarker (in a plain agent's StateDir) remembers a follow, so an agent
// whose own setting the writer could not reach (its hub on a --hub flag, a
// unit's environment) does not exit again and again on the same announcement.
const hubMoveMarker = "hub-move.json"

// hubMoveTarget is the announced address to follow from dialed, or "".
func hubMoveTarget(announced, dialed string) string {
	to := strings.TrimRight(strings.TrimSpace(announced), "/")
	if to == "" || strings.EqualFold(to, strings.TrimRight(dialed, "/")) {
		return ""
	}
	u, err := url.Parse(to)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" ||
		u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" || strings.ContainsAny(to, " \t\r\n\"'\\") {
		return ""
	}
	return to
}

// hubFollowOnce is each target tried at most once per process.
type hubFollowOnce struct {
	mu    sync.Mutex
	tried map[string]bool
}

func (o *hubFollowOnce) first(to string) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.tried[to] {
		return false
	}
	if o.tried == nil {
		o.tried = map[string]bool{}
	}
	o.tried[to] = true
	return true
}

// runHubMove runs the writer: as ra when set (prepCmd), else as this process.
func runHubMove(ctx context.Context, ra *RunAs, script, stdin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, hubMoveTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, hubMovePython, append([]string{"-I", script}, args...)...)
	cmd.Stdin = strings.NewReader(stdin)
	if ra != nil {
		if err := prepCmd(withRunAs(ctx, ra), cmd); err != nil {
			return "", err
		}
	}
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// selfAuth is the two Authorization values verify reads on its stdin.
func selfAuth(auth func(method, rawURL string) string, from, to string) string {
	return auth(http.MethodGet, from+"/v1/node/self") + "\n" + auth(http.MethodGet, to+"/v1/node/self") + "\n"
}

// followHub is a plain agent's answer to a welcome's address.
func (a *Agent) followHub(ctx context.Context, announced string) {
	if a.machine != nil || a.cfg.HubDial != "" || a.cfg.Once {
		return
	}
	from := strings.TrimRight(a.cfg.HubURL, "/")
	to := hubMoveTarget(announced, from)
	if to == "" || !a.hubOnce.first(to) {
		return
	}
	if a.followedBefore(from, to) {
		log.Printf("hub moved to %s, but this agent still dials %s after following it once: its own setting is not one the writer reaches — set it to %s by hand", to, from, to)
		return
	}
	script := a.cfg.HubMoveScript
	if script == "" {
		script = filepath.Join(a.cfg.Home, ".claude", "fleet", "bin", hubMoveScriptName)
	}
	if _, err := os.Stat(script); err != nil {
		log.Printf("hub moved to %s; not followed: no %s here", to, script)
		return
	}
	if a.runCtx != nil {
		ctx = a.runCtx // the session's own ends with its connection
	}
	go func() {
		out, err := runHubMove(ctx, nil, script, selfAuth(a.authValue, from, to),
			"follow", "--scope", "login", "--from", from, "--to", to)
		if err != nil {
			log.Printf("hub moved to %s; not followed (%v): %s", to, err, oneLine(out))
			return
		}
		log.Printf("hub moved: %s → %s, this login's configuration rewritten; reconnecting there: %s", from, to, oneLine(out))
		a.markFollowed(from, to)
		a.hubMoved.Store(&to)
		if a.quit != nil {
			a.quit()
		}
	}()
}

// HubMoved is the address Run ended to reconnect to ("" = it did not).
func (a *Agent) HubMoved() string {
	if p := a.hubMoved.Load(); p != nil {
		return *p
	}
	return ""
}

type hubMoveRecord struct {
	From string    `json:"from"`
	To   string    `json:"to"`
	At   time.Time `json:"at"`
}

func (a *Agent) followedBefore(from, to string) bool {
	if a.cfg.StateDir == "" {
		return false
	}
	b, err := os.ReadFile(filepath.Join(a.cfg.StateDir, hubMoveMarker))
	if err != nil {
		return false
	}
	var r hubMoveRecord
	return json.Unmarshal(b, &r) == nil && r.From == from && r.To == to && time.Since(r.At) < 24*time.Hour
}

func (a *Agent) markFollowed(from, to string) {
	if a.cfg.StateDir == "" {
		return
	}
	b, _ := json.Marshal(hubMoveRecord{From: from, To: to, At: time.Now().UTC()})
	p := filepath.Join(a.cfg.StateDir, hubMoveMarker)
	if os.WriteFile(p+".tmp", b, 0o600) == nil {
		_ = os.Rename(p+".tmp", p)
	}
}

// followHub is the machine link's answer to a welcome's address: verified with
// the machine's own credential, every tenant's files rewritten as that login,
// then root's — machine.env last, whose change restarts this program.
func (ml *machineLink) followHub(ctx context.Context, announced string) {
	if ml.cfg.HubDial != "" || ml.cfg.Core != "" || ml.cfg.HubMove == "" {
		return
	}
	from := strings.TrimRight(ml.cfg.HubURL, "/")
	to := hubMoveTarget(announced, from)
	if to == "" || !ml.hubOnce.first(to) {
		return
	}
	if ml.runCtx != nil {
		ctx = ml.runCtx // the session's own ends with its connection
	}
	go func() {
		auth := func(method, rawURL string) string {
			return authValueFor(ml.signer.Load(), ml.cfg.Token, method, rawURL)
		}
		if out, err := runHubMove(ctx, nil, ml.cfg.HubMove, selfAuth(auth, from, to), "verify", "--from", from, "--to", to); err != nil {
			log.Printf("machine link: hub moved to %s; not followed (%v): %s", to, err, oneLine(out))
			return
		}
		for _, ra := range ml.tenants {
			out, err := runHubMove(ctx, ra, ml.cfg.HubMove, "", "rewrite", "--scope", "login", "--from", from, "--to", to)
			if err != nil {
				// a separated login's node.env is the store's: the machine half below
				log.Printf("machine link: hub move: %s's files (%v): %s", ra.Login, err, oneLine(out))
			}
		}
		args := []string{"rewrite", "--scope", "machine", "--from", from, "--to", to}
		if ml.cfg.MachineEnvFile != "" {
			args = append(args, "--state", filepath.Dir(ml.cfg.MachineEnvFile))
		}
		out, err := runHubMove(ctx, nil, ml.cfg.HubMove, "", args...)
		if err != nil {
			log.Printf("machine link: hub moved to %s; the machine's files not all rewritten (%v): %s", to, err, oneLine(out))
			return
		}
		log.Printf("machine link: hub moved: %s → %s, rewritten; the node daemon restarts this program on machine.env: %s", from, to, oneLine(out))
	}()
}

func oneLine(s string) string {
	s = strings.Join(strings.Fields(strings.ReplaceAll(s, "\n", " · ")), " ")
	if len(s) > 400 {
		s = s[:400] + "…"
	}
	return s
}
