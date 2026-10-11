package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent half of the fleet control channel (claude-fleet#1408).
//
// With Config.Fleet on, the agent keeps one WebSocket open to the hub — dialled
// FROM here, because the hub sits in a cloud region that cannot reach into a
// home network — and sends a heartbeat on it every LiveInterval: this login's
// fleets and their windows, the machine's load and free memory, the install
// version. The hub marks the node lost after three silent intervals.
//
// The link is expected to break (it crosses a border). Every break is followed
// by a reconnect on a 5, 10, 20, 30, 30 … second ladder (claude-fleet#1630:
// network back → node online within 30 s), jittered, and a change in this
// machine's network (netwatch_*.go) skips the wait and clears the ladder.
// Nothing on this machine changes while the link is down: the sessions keep
// running, only the hub's view of them goes stale — and the first beat of the
// next session is the full picture again.

// Reconnect backoff bounds — the ONE place they are set (node_creds.go rides
// the same ladder). Variables so tests can shrink them.
var (
	nodeBackoffMin = 5 * time.Second
	nodeBackoffMax = 30 * time.Second
)

// nodeDialTimeout bounds the dial plus the hello/welcome exchange.
const nodeDialTimeout = 15 * time.Second

// nodeWriteTimeout bounds one heartbeat write and one ping. A link whose
// writes buffer silently (a pulled cable sends no RST) is caught by the ping:
// no pong within this window ends the session and starts a reconnect.
const nodeWriteTimeout = 10 * time.Second

// fleetControlScript is claude-fleet's fixed control entry point, relative to
// the login's home. The agent reads fleets ONLY through it — the same command
// list the hub's SSH path uses — and never parses tmux itself.
var fleetControlScript = filepath.Join(".claude", "fleet", "bin", "fleet-control.py")

// fleetControlTimeout bounds one whole fleet snapshot (discover + one
// fleet_status per fleet).
const fleetControlTimeout = 8 * time.Second

// nodeBackoff is the reconnect delay: doubling from min to max. The jitter
// only ever SHORTENS a rung (down to 80 % of it), so a hub restart is not met
// by every node at the same instant and the cap stays a promise — the wait is
// never longer than nodeBackoffMax.
type nodeBackoff struct {
	cur time.Duration
}

func (b *nodeBackoff) next() time.Duration {
	if b.cur <= 0 {
		b.cur = nodeBackoffMin
	} else {
		b.cur *= 2
	}
	if b.cur > nodeBackoffMax {
		b.cur = nodeBackoffMax
	}
	fifth := b.cur / 5
	return b.cur - fifth + time.Duration(rand.Int63n(int64(fifth)+1))
}

func (b *nodeBackoff) reset() { b.cur = 0 }

// runNode keeps the control channel up until ctx ends.
func (a *Agent) runNode(ctx context.Context) {
	var bo nodeBackoff
	var lastErr string
	netc := watchNetChanges(ctx)
	for {
		established, err := a.nodeSession(ctx, netc)
		if ctx.Err() != nil {
			return
		}
		if established {
			// A session that got as far as the welcome proves the path
			// works; the next failure starts the ladder from the bottom.
			bo.reset()
		}
		msg := "control channel closed"
		if err != nil {
			msg = "control channel: " + err.Error()
		}
		if msg != lastErr {
			// Once per distinct reason, not once per retry: an hour-long
			// outage is one log line, not sixty.
			log.Print(msg + "; reconnecting")
			lastErr = msg
		}
		t := time.NewTimer(bo.next())
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		case <-netc:
			// This machine's network changed: whatever failed the last
			// dial may be gone. Dial now, from the bottom of the ladder.
			t.Stop()
			bo.reset()
			if lastErr != "" {
				log.Print("control channel: network changed; reconnecting now")
			}
		}
	}
}

// nodeURL turns the hub's base URL into the control channel's ws(s) URL.
func nodeURL(hub string) string {
	switch {
	case strings.HasPrefix(hub, "https://"):
		hub = "wss://" + strings.TrimPrefix(hub, "https://")
	case strings.HasPrefix(hub, "http://"):
		hub = "ws://" + strings.TrimPrefix(hub, "http://")
	}
	return strings.TrimRight(hub, "/") + control.Path
}

// nodeSession runs one connection to its end. established reports whether the
// hub welcomed it.
//
// netc wakes on a change in this machine's network: mid-session it beats at
// once (through the nudge limiter), and the ping that beat carries finds a
// link the change has broken without waiting for the next tick.
func (a *Agent) nodeSession(ctx context.Context, netc <-chan struct{}) (established bool, err error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	dctx, dcancel := context.WithTimeout(ctx, nodeDialTimeout)
	defer dcancel()
	var conn nodeLink
	if a.machine != nil {
		// A tenant of the machine's one node program (claude-fleet#2333):
		// this login's lane on the machine link, not a link of its own.
		l, err := a.machine.lane(dctx, a.cfg.RunAs.Login)
		if err != nil {
			return false, err
		}
		conn = l
	} else {
		c, _, err := websocket.Dial(dctx, nodeURL(a.cfg.HubURL), &websocket.DialOptions{
			HTTPHeader: http.Header{"Authorization": []string{"Bearer " + a.cfg.Token}},
		})
		if err != nil {
			return false, err
		}
		c.SetReadLimit(1 << 20)
		conn = wsLink{c}
	}
	defer conn.closeNow()

	caps := []string{control.CapRead, control.CapWrite}
	// Relays (claude-fleet#1421) only when this login's claude-fleet knows
	// where its outbox and worker map live; otherwise the hub sends none.
	rp, relayOK := relaySetup(ctx, a.cfg.Home)
	a.moveIn, a.attachDir = "", ""
	if relayOK {
		caps = append(caps, control.CapRelay)
		if rp.movein != "" {
			// A session moved here through the hub (claude-fleet#1426).
			caps = append(caps, control.CapMove)
			a.moveIn = rp.movein
		}
		if rp.attach != "" {
			// A writing area's files, downloaded before a start (claude-fleet#2393).
			caps = append(caps, control.CapAttach)
			a.attachDir = rp.attach
		}
		if rp.test {
			// The test identity's scratch, marked (claude-fleet#2505).
			caps = append(caps, control.CapTestIdentity)
		}
	}
	if a.cfg.FleetSSHRelay {
		caps = append(caps, control.CapSSHRelay)
	}
	if a.teamCapable() {
		// The team layer follows the hub's push (claude-fleet#1899).
		caps = append(caps, control.CapTeam)
		// … and so does the person's own layer (claude-fleet#2784).
		caps = append(caps, control.CapPerson)
	}
	if a.relaysOAuthRefresh() {
		caps = append(caps, control.CapOAuthRefresh)
	}
	if a.serviceLogCapable() {
		// A service's log, live (claude-fleet#2797).
		caps = append(caps, control.CapServiceLog)
	}
	if a.cfg.FleetAdmin {
		// Its create hands the join code to the script (claude-fleet#3032).
		caps = append(caps, control.CapLoginJoin)
	}
	if a.cfg.FleetAdmin && credsepCapable(a.cfg.Home) {
		// Every login this node's create op opens is separated (claude-fleet#2294).
		caps = append(caps, control.CapCredsep)
	}
	hello, err := control.New(control.TypeHello, control.Hello{
		HeartbeatMS:  int(a.cfg.LiveInterval / time.Millisecond),
		AgentVersion: a.cfg.Version,
		Admin:        a.cfg.FleetAdmin,
		Capabilities: caps,
		Compute:      a.computeClaim(),
		ComputeForce: a.computeForce(),
		Probe:        a.nodeProbe(),
		Personal:     a.personalNow(),
		LoginToken:   a.loginToken(),
	})
	if err != nil {
		return false, err
	}
	if err := conn.write(dctx, hello); err != nil {
		return false, err
	}
	reply, err := conn.read(dctx)
	if err != nil {
		return false, err
	}
	switch reply.Type {
	case control.TypeWelcome:
		a.laneWelcomed()
	case control.TypeError:
		if reply.Error != nil {
			a.laneRefused(reply.Error)
			return false, fmt.Errorf("hub refused the hello: %s: %s", reply.Error.Code, reply.Error.Message)
		}
		return false, errors.New("hub refused the hello")
	default:
		return false, fmt.Errorf("hub answered the hello with %q", reply.Type)
	}
	var w control.Welcome
	_ = json.Unmarshal(reply.Payload, &w)
	if !w.Accepted {
		// Still connected and still reporting: the hub lists this node, it
		// just will not send it writes. Worth one line, since the fix is an
		// upgrade on one side or the other.
		log.Printf("control channel: hub (proto %d, min %d) will not send writes to this node (proto %d): %s",
			w.HubProto, w.MinProto, control.Proto, w.Reason)
	}
	dcancel()

	// The reader: the hub's messages — account ops for an admin agent
	// (claude-fleet#1411), acks of their results, read requests
	// (claude-fleet#1409, answered off the read loop so a slow
	// fleet-control.py never stalls it), writes (claude-fleet#1410, the same
	// way) — and the pongs the heartbeat's ping
	// waits for. When it ends, the connection is gone.
	readErr := make(chan error, 1)
	go func() {
		for {
			m, err := conn.read(ctx)
			if err != nil {
				readErr <- err
				return
			}
			switch m.Type {
			case control.TypeAccountOp:
				a.handleAccountOp(ctx, conn, m)
			case control.TypeSSHCA:
				a.handleSSHCA(ctx, conn, m)
			case control.TypeAck:
				if !a.relayAcked(m.OpID) {
					a.acct.acked(m.OpID)
				}
			case control.TypeRequest:
				go a.answerRequest(ctx, conn, m)
			case control.TypeWrite:
				go a.answerWrite(ctx, conn, m)
			case control.TypeRelay:
				if relayOK {
					go a.relayDeliver(ctx, conn, rp, m)
				}
			case control.TypeWorkers:
				if relayOK {
					if err := relayWorkers(rp, m); err != nil {
						log.Printf("control channel: write the worker map: %v", err)
					}
				}
			case control.TypeTeam:
				a.handleTeam(ctx, m)
			case control.TypePerson:
				a.handlePerson(ctx, m)
			case control.TypeSSHRelayOpen:
				// Bound to this session's ctx: when the control channel
				// drops, every relay it opened is closed with it
				// (claude-fleet#1413).
				if a.cfg.FleetSSHRelay {
					go a.openSSHRelay(ctx, m)
				}
			case control.TypeServiceLog:
				// One entry's log (claude-fleet#2797): a page, or a
				// follow bound to this session — a dropped link ends it.
				a.serviceLog(ctx, conn, m)
			case control.TypeServiceLogStop:
				a.svcLogs.stop(m.OpID)
			case control.TypeOAuthRefresh:
				// One token refresh posted for the hub (claude-fleet#1490),
				// off the read loop so a slow provider never stalls it.
				go a.answerOAuthRefresh(ctx, conn, m)
			case control.TypeError:
				if relayOK && a.relayRefused(rp, m.OpID, m.Error) {
					break
				}
				if m.Error != nil {
					log.Printf("control channel: hub reported %s: %s", m.Error.Code, m.Error.Message)
				}
			}
		}
	}()

	// Results the hub has not acked — from this connection or one that
	// dropped while a script ran — go out now and on completion.
	a.acct.attach(func(m control.Message) error {
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		return conn.write(wctx, m)
	})
	defer a.acct.detach()

	if relayOK {
		go a.relayOutbox(ctx, conn, rp)
	}

	probe := &fleetProbe{}
	beat := func() error {
		hb := a.nodeHeartbeat(ctx, probe)
		m, err := control.New(control.TypeHeartbeat, hb)
		if err != nil {
			return err
		}
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		if err := conn.write(wctx, m); err != nil {
			return err
		}
		return conn.ping(wctx)
	}

	// The first beat goes out at once: the roster should show a node the
	// moment it connects, not one interval later.
	if err := beat(); err != nil {
		return true, err
	}
	a.markNodeReady()
	t := time.NewTicker(a.cfg.LiveInterval)
	defer t.Stop()
	// A state change on this machine beats at once (claude-fleet#1481):
	// node_nudge.go watches the fleet's nudge file and debounces + rate-limits
	// the extra beats it asks for. The ticker above is untouched by it.
	nudge := watchNudge(ctx, a.cfg.FleetNudgePath)
	var nb nudgeBeats
	for {
		select {
		case <-ctx.Done():
			conn.close("agent stopping")
			return true, nil
		case err := <-readErr:
			return true, err
		case <-t.C:
			if err := beat(); err != nil {
				return true, err
			}
			// A team (or person) sync that failed runs again on this beat.
			a.teamKick(ctx)
		case <-nudge:
			nb.arm()
		case <-netc:
			nb.arm()
		case <-nb.pending:
			if !nb.due() {
				continue
			}
			if err := beat(); err != nil {
				return true, err
			}
		}
	}
}

// nodeHeartbeat assembles one heartbeat. Every part is best effort: a missing
// claude-fleet, a wedged tmux or an unreadable sysctl leaves its fields empty
// and says why, and the beat still goes out — liveness is the one thing it
// must always carry. The load is the sampler's last reading and the fleet half
// waits at most fleetBeatBudget (claude-fleet#2798): a slow fleet read never
// holds up the beat or empties its load, and each half says when it was read.
func (a *Agent) nodeHeartbeat(ctx context.Context, probe *fleetProbe) control.Heartbeat {
	hb := control.Heartbeat{
		OS: runtime.GOOS, Arch: runtime.GOARCH, NCPU: runtime.NumCPU(),
		AgentVersion: a.cfg.Version, ObservedAt: time.Now().UTC(),
	}
	hb.Hostname, _ = os.Hostname()
	hb.OSUser = a.osLogin()
	fillSys(&hb, processSys)

	// The first beat of the process has no earlier reading to fall back on,
	// so it waits for the read (as every beat did before #2798): a beat that
	// says no fleets would read a busy login as idle.
	fp, at, _ := a.fleetRd.get(ctx, 0, fleetBeatBudget, true, func(ctx context.Context) (fleetPart, bool) {
		return a.readFleetPart(ctx, probe)
	})
	fp.fill(&hb, at)
	hb.Routes = a.nodeRoutes(ctx)
	hb.HostKeys = nodeHostKeys()
	// Explicit either way in a beat (claude-fleet#1720): a true tells the hub
	// that `fleet node compute on` overrode a hello that said off.
	on := !a.computeOffNow()
	hb.Compute = &on
	hb.ComputeForce, hb.Probe = a.computeForce(), a.nodeProbe()
	hb.Personal = a.personalNow()
	if n := hb.SessionsCount(); n != nil {
		a.lastSessions.Store(int64(*n))
	} else {
		a.lastSessions.Store(-1)
	}
	return hb
}

// readyProbe caches fleet-control.py's `ready` verdict (claude-fleet#1475):
// can this login take a NEW session — gh logged in, a usable Claude or Codex
// credential, every hosted repo's checkout present. The verdict runs `gh auth
// status` and reads credentials, not a 5-second thing, so it is re-asked at
// most every readyInterval and the beats between carry the last answer. A
// controller without `ready` (older than #1475), or no claude-fleet at all,
// leaves the field unsaid — the hub reads nil as ready, as it always did.
type readyProbe struct {
	at    time.Time
	ready *bool
	why   string
}

const readyInterval = 60 * time.Second

func (p *readyProbe) reading(ctx context.Context, home string, now time.Time) (*bool, string) {
	if !p.at.IsZero() && now.Sub(p.at) < readyInterval {
		return p.ready, p.why
	}
	p.at, p.ready, p.why = now, nil, ""
	script := filepath.Join(home, fleetControlScript)
	if _, err := os.Stat(script); err != nil {
		return nil, ""
	}
	ctx, cancel := context.WithTimeout(ctx, fleetControlTimeout)
	defer cancel()
	var out struct {
		Ready   bool     `json:"ready"`
		Missing []string `json:"missing"`
	}
	if err := fleetRPC(ctx, script, map[string]any{"protocol": 1, "method": "ready", "params": map[string]any{}}, &out); err != nil {
		return nil, ""
	}
	r := out.Ready
	p.ready, p.why = &r, strings.Join(out.Missing, ", ")
	return p.ready, p.why
}

// sysInfo is the machine-wide reading in a heartbeat.
type sysInfo struct {
	Load1    float64
	MemFree  uint64
	MemTotal uint64
	// MemPressure is the kernel's memory-pressure level (darwin: 1 normal,
	// 2 warn, 4 critical); 0 where the platform does not say.
	MemPressure int
	// Unread names what could not be read — "load", "mem" — and Why says
	// why (claude-fleet#2798): a zero there is 读不到, never a reading.
	Unread []string
	Why    string
}

// unread records one part the platform would not give, and why.
func (si *sysInfo) unread(part, why string) {
	for _, u := range si.Unread {
		if u == part {
			return
		}
	}
	si.Unread = append(si.Unread, part)
	if si.Why != "" {
		si.Why += "; "
	}
	si.Why += why
}

// errNoFleet means this login has no claude-fleet install: not an error, the
// heartbeat simply carries no fleets.
var errNoFleet = errors.New("no claude-fleet install on this login")

// fleetReadErrs is the last fleet_status refusal per fleet, so an unreadable
// fleet is logged once per distinct reason and once more when it reads again,
// not every beat. claude-fleet#1460: the heartbeat carried 0 sessions for a
// fleet of 22 and the log said nothing; the reason (`tmux: command not found`
// under launchd's PATH) was only ever in the discarded fault.
var fleetReadErrs = &sync.Map{} // fleet name → error string

type fleetSnapshot struct {
	machineID string
	fleets    []control.Fleet
	// capacity is the login's own cap and the count its gate reads
	// (claude-fleet#1587); nil from a claude-fleet older than that.
	capacity *fleetCapacity
}

// fleetCapacity is discover's capacity object (claude-fleet#1587).
type fleetCapacity struct {
	Sessions    int `json:"sessions"`
	MaxSessions int `json:"max_sessions"`
	// Admit / AdmitWhy / Room are the login's own admission verdict
	// (claude-fleet#1836): nil / "" from a claude-fleet older than that.
	Admit    *bool  `json:"admit"`
	AdmitWhy string `json:"admit_why"`
	Room     *int   `json:"room"`
}

// fleetControlCommand is the injection point for tests, like fleetCommand.
var fleetControlCommand = func(ctx context.Context, script string, stdin []byte) ([]byte, error) {
	cmd := fleetCommand(ctx, script, "rpc")
	cmd.Stdin = bytes.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := prepCmd(ctx, cmd); err != nil {
		return nil, err
	}
	err := startWhy(ctx, cmd, cmd.Run())
	// fleet-control.py prints a JSON error object and exits 1 on a refusal;
	// the caller reads stdout either way.
	if stdout.Len() > 0 {
		return stdout.Bytes(), nil
	}
	// It died before it could say why (claude-fleet#2471): its last stderr
	// line is the reason, not a bare «exit status 1».
	if line := lastLine(stderr.String()); err != nil && line != "" {
		err = fmt.Errorf("%w: %s", err, line)
	}
	return nil, err
}

// readFleets asks fleet-control.py for this login's fleets and each one's
// window snapshot: discover, then fleet_status per fleet.
func readFleets(ctx context.Context, home string) (fleetSnapshot, error) {
	script := filepath.Join(home, fleetControlScript)
	if _, err := os.Stat(script); err != nil {
		return fleetSnapshot{}, errNoFleet
	}
	ctx, cancel := context.WithTimeout(ctx, fleetControlTimeout)
	defer cancel()

	var disc struct {
		MachineID string `json:"machine_id"`
		Fleets    []struct {
			FleetID  string   `json:"fleet_id"`
			Name     string   `json:"name"`
			Repo     string   `json:"repo"`
			Checkout string   `json:"checkout"`
			Agent    string   `json:"agent"`
			Repos    []string `json:"repos"`
		} `json:"fleets"`
		Capacity *fleetCapacity `json:"capacity"`
	}
	if err := fleetRPC(ctx, script, map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}}, &disc); err != nil {
		return fleetSnapshot{}, fmt.Errorf("fleet discover: %w", err)
	}
	snap := fleetSnapshot{machineID: disc.MachineID, fleets: []control.Fleet{}, capacity: disc.Capacity}
	for _, f := range disc.Fleets {
		var st struct {
			State   string            `json:"state"`
			Workers []json.RawMessage `json:"workers"`
		}
		fl := control.Fleet{FleetID: f.FleetID, Name: f.Name, Repo: f.Repo, Checkout: f.Checkout, Agent: f.Agent, Repos: f.Repos}
		err := fleetRPC(ctx, script, map[string]any{"protocol": 1, "method": "fleet_status",
			"machine_id": disc.MachineID, "params": map[string]any{"fleet_id": f.FleetID}}, &st)
		if err != nil {
			fl.State, fl.Error = control.FleetStateUnknown, err.Error()
			if prev, _ := fleetReadErrs.Load(f.Name); prev != err.Error() {
				log.Printf("heartbeat: fleet %s is unreadable, reported as state unknown (not 0 sessions): %v", f.Name, err)
				fleetReadErrs.Store(f.Name, err.Error())
			}
		} else {
			if _, had := fleetReadErrs.LoadAndDelete(f.Name); had {
				log.Printf("heartbeat: fleet %s reads again", f.Name)
			}
			fl.State, fl.Count = st.State, len(st.Workers)
			if st.Workers == nil {
				st.Workers = []json.RawMessage{}
			}
			fl.Workers, _ = json.Marshal(st.Workers)
		}
		snap.fleets = append(snap.fleets, fl)
	}
	return snap, nil
}

// fleetRPC runs one fleet-control.py request and decodes its result into out.
func fleetRPC(ctx context.Context, script string, req map[string]any, out any) error {
	res, _, err := fleetRPCRaw(ctx, script, req)
	if err != nil {
		return err
	}
	return json.Unmarshal(res, out)
}

// rpcFault is fleet-control.py's own refusal ({"error": {code, message}}),
// kept apart from a transport failure so a request answer can carry its code.
type rpcFault struct{ Code, Message string }

func (e *rpcFault) Error() string { return e.Code + ": " + e.Message }

// fleetRPCRaw runs one fleet-control.py request and returns its result and the
// machine_id it answered as, undecoded.
func fleetRPCRaw(ctx context.Context, script string, req map[string]any) (json.RawMessage, string, error) {
	in, err := json.Marshal(req)
	if err != nil {
		return nil, "", err
	}
	raw, err := fleetControlCommand(ctx, script, in)
	if err != nil {
		return nil, "", err
	}
	var resp struct {
		MachineID string          `json:"machine_id"`
		Result    json.RawMessage `json:"result"`
		Error     *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &resp); err != nil {
		return nil, "", errors.New("fleet-control.py printed something that is not JSON")
	}
	if resp.Error != nil {
		return nil, "", &rpcFault{resp.Error.Code, resp.Error.Message}
	}
	return resp.Result, resp.MachineID, nil
}

// requestTimeout bounds one hub read request on this node.
const requestTimeout = 20 * time.Second

// ghRequestTimeout bounds a gh_* read: fleet-gh.sh may fall through its local
// copy to gh, then to REST, and fleet-control.py gives it 20s of its own.
const ghRequestTimeout = 30 * time.Second

// writeTimeout bounds one hub write. fleet-control.py's submit only journals
// the operation and starts a detached executor, so it answers in well under a
// second; the executor runs on past this, and past this agent.
const writeTimeout = 20 * time.Second

// answerRequest serves one hub read (claude-fleet#1409). Only ReadMethods are
// run, through the same fixed fleet-control.py entry point the heartbeat uses;
// anything else is refused here, whatever the hub asked. The node fills in
// its OWN machine_id — fleet-control.py checks it, so a request can never
// address another login's controller.
func (a *Agent) answerRequest(ctx context.Context, conn nodeLink, m control.Message) {
	a.answerControl(ctx, conn, m, false)
}

// answerWrite serves one hub write (claude-fleet#1410): fleet-control.py's
// `submit`, and nothing else. It runs as THIS login, so the controller it
// reaches knows only this login's fleets — a write the hub mis-addressed is
// refused there as NOT_FOUND, the node half of "only your own" (EPIC #1407
// 共同约定 5).
//
// The answer must never claim more than the node knows. A refusal before the
// controller ran, or a structured refusal from it, is definite: nothing was
// journalled here. Anything else after it started — a crash, a timeout, output
// that is not JSON — may have come after the controller committed the
// operation, so it goes back as UNKNOWN_OUTCOME and the hub never re-sends it.
func (a *Agent) answerWrite(ctx context.Context, conn nodeLink, m control.Message) {
	if a.serviceControlWrite(ctx, conn, m) {
		return // the register's own write (claude-fleet#2527), never the controller's
	}
	a.answerControl(ctx, conn, m, true)
}

func (a *Agent) answerControl(ctx context.Context, conn nodeLink, m control.Message, write bool) {
	reply := func(msg control.Message) {
		msg.OpID = m.OpID
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = conn.write(wctx, msg)
	}
	// Every write the hub sends leaves one line in this agent's log, taken
	// or refused (claude-fleet#1606): a start the hub says it sent and this
	// machine never opened is told apart — no line (the frame never came),
	// "refused" (it never reached the controller), or "journalled" (the
	// controller's own ops.log carries the rest).
	what := "write"
	logWrite := func(outcome string) {
		if write {
			log.Printf("control: %s %s", what, outcome)
		}
	}
	fail := func(code, msg string) {
		logWrite("refused " + code + ": " + msg)
		reply(control.Message{Type: control.TypeError, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: msg}})
	}
	var req control.Request
	if err := json.Unmarshal(m.Payload, &req); err != nil {
		fail(control.CodeBadMessage, "malformed request")
		return
	}
	allowed, kind := control.ReadMethods, "read"
	if write {
		allowed, kind = control.WriteMethods, "write"
	}
	if !allowed[req.Method] {
		fail(control.CodeRefused, "this node serves no "+kind+" method "+req.Method+" over the control channel")
		return
	}
	script := filepath.Join(a.cfg.Home, fleetControlScript)
	if _, err := os.Stat(script); err != nil {
		fail("UNAVAILABLE", errNoFleet.Error())
		return
	}
	params := json.RawMessage(`{}`)
	if len(req.Params) > 0 {
		params = req.Params
	}
	if write {
		// The envelope is an object or nothing at all: never a string or
		// array the controller would have to second-guess.
		var obj map[string]json.RawMessage
		if json.Unmarshal(params, &obj) != nil || obj == nil {
			fail(control.CodeBadMessage, "a write's params must be one JSON object")
			return
		}
		var env struct {
			OperationID string `json:"operation_id"`
			Action      string `json:"action"`
		}
		_ = json.Unmarshal(params, &env)
		what = fmt.Sprintf("write %s operation %s", env.Action, env.OperationID)
	}
	if write {
		// A moved-in session's transcript comes over HTTP, never the
		// channel (claude-fleet#1426): fetch it before the controller
		// journals the write, so a failed download is a clean refusal.
		if code, msg := a.fetchMoveBundle(ctx, params); code != "" {
			fail(code, msg)
			return
		}
		// …and so do a writing area's attachments (claude-fleet#2393).
		if code, msg := a.fetchAttachments(ctx, params); code != "" {
			fail(code, msg)
			return
		}
	}
	timeout := requestTimeout
	switch {
	case write:
		timeout = writeTimeout
	case strings.HasPrefix(req.Method, "gh_"):
		timeout = ghRequestTimeout
	}
	rctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	call := map[string]any{"protocol": 1, "method": req.Method, "params": params}
	if req.Method != "discover" {
		var disc struct {
			MachineID string `json:"machine_id"`
		}
		if err := fleetRPC(rctx, script, map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}}, &disc); err != nil {
			fail("UNAVAILABLE", "fleet discover: "+err.Error())
			return
		}
		call["machine_id"] = disc.MachineID
	}
	res, machineID, err := fleetRPCRaw(rctx, script, call)
	if err != nil {
		var f *rpcFault
		switch {
		case write && (!errors.As(err, &f) || f.Code == "INTERNAL"):
			// The controller may have committed before it failed.
			fail(control.CodeUnknownOutcome, "the node's controller did not confirm the write: "+err.Error())
		case errors.As(err, &f):
			fail(f.Code, f.Message)
		default:
			fail("UNAVAILABLE", err.Error())
		}
		return
	}
	out, err := control.New(control.TypeResult, control.Result{MachineID: machineID, Result: res})
	if err != nil {
		code := "INTERNAL"
		if write {
			code = control.CodeUnknownOutcome
		}
		fail(code, err.Error())
		return
	}
	var st struct {
		Status string `json:"status"`
	}
	_ = json.Unmarshal(res, &st)
	logWrite("journalled: " + st.Status)
	reply(out)
}
