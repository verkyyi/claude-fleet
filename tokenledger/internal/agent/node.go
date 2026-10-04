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
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

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
// by a reconnect after an exponentially growing, jittered delay capped at a
// minute, and nothing on this machine changes while it is down: the sessions
// keep running, only the hub's view of them goes stale.

// Reconnect backoff bounds. Variables so tests can shrink them.
var (
	nodeBackoffMin = 1 * time.Second
	nodeBackoffMax = 60 * time.Second
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

// nodeBackoff is the reconnect delay: doubling from min to max, with equal
// jitter (half fixed, half random) so a hub restart is not met by every node
// at the same instant.
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
	half := b.cur / 2
	return half + time.Duration(rand.Int63n(int64(half)+1))
}

func (b *nodeBackoff) reset() { b.cur = 0 }

// runNode keeps the control channel up until ctx ends.
func (a *Agent) runNode(ctx context.Context) {
	var bo nodeBackoff
	var lastErr string
	for {
		established, err := a.nodeSession(ctx)
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
func (a *Agent) nodeSession(ctx context.Context) (established bool, err error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	dctx, dcancel := context.WithTimeout(ctx, nodeDialTimeout)
	defer dcancel()
	conn, _, err := websocket.Dial(dctx, nodeURL(a.cfg.HubURL), &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + a.cfg.Token}},
	})
	if err != nil {
		return false, err
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1 << 20)

	hello, err := control.New(control.TypeHello, control.Hello{
		HeartbeatMS:  int(a.cfg.LiveInterval / time.Millisecond),
		AgentVersion: a.cfg.Version,
	})
	if err != nil {
		return false, err
	}
	if err := wsjson.Write(dctx, conn, hello); err != nil {
		return false, err
	}
	var reply control.Message
	if err := wsjson.Read(dctx, conn, &reply); err != nil {
		return false, err
	}
	switch reply.Type {
	case control.TypeWelcome:
	case control.TypeError:
		if reply.Error != nil {
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

	// The reader: the hub's messages (none it must act on yet — C3 adds
	// writes), and the pongs the heartbeat's ping waits for. When it ends,
	// the connection is gone.
	readErr := make(chan error, 1)
	go func() {
		for {
			var m control.Message
			if err := wsjson.Read(ctx, conn, &m); err != nil {
				readErr <- err
				return
			}
			if m.Type == control.TypeError && m.Error != nil {
				log.Printf("control channel: hub reported %s: %s", m.Error.Code, m.Error.Message)
			}
		}
	}()

	probe := &fleetProbe{}
	beat := func() error {
		hb := a.nodeHeartbeat(ctx, probe)
		m, err := control.New(control.TypeHeartbeat, hb)
		if err != nil {
			return err
		}
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		if err := wsjson.Write(wctx, conn, m); err != nil {
			return err
		}
		return conn.Ping(wctx)
	}

	// The first beat goes out at once: the roster should show a node the
	// moment it connects, not one interval later.
	if err := beat(); err != nil {
		return true, err
	}
	t := time.NewTicker(a.cfg.LiveInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			conn.Close(websocket.StatusGoingAway, "agent stopping")
			return true, nil
		case err := <-readErr:
			return true, err
		case <-t.C:
			if err := beat(); err != nil {
				return true, err
			}
		}
	}
}

// nodeHeartbeat assembles one heartbeat. Every part is best effort: a missing
// claude-fleet, a wedged tmux or an unreadable sysctl leaves its fields empty
// and says why, and the beat still goes out — liveness is the one thing it
// must always carry.
func (a *Agent) nodeHeartbeat(ctx context.Context, probe *fleetProbe) control.Heartbeat {
	hb := control.Heartbeat{
		OS: runtime.GOOS, Arch: runtime.GOARCH, NCPU: runtime.NumCPU(),
		AgentVersion: a.cfg.Version, ObservedAt: time.Now().UTC(),
	}
	hb.Hostname, _ = os.Hostname()
	if u, err := user.Current(); err == nil {
		hb.OSUser = u.Username
	}
	si := readSysInfo()
	hb.Load1, hb.MemFreeBytes, hb.MemTotalBytes = si.Load1, si.MemFree, si.MemTotal

	snap, err := readFleets(ctx, a.cfg.Home)
	switch {
	case errors.Is(err, errNoFleet):
	case err != nil:
		hb.FleetError = err.Error()
	default:
		hb.MachineID, hb.Fleets = snap.machineID, snap.fleets
		for _, f := range snap.fleets {
			hb.Sessions += f.Count
		}
	}
	if fv := probe.reading(ctx, a.cfg.Home); fv != nil {
		hb.FleetVersion = fv.Head
	}
	return hb
}

// sysInfo is the machine-wide reading in a heartbeat.
type sysInfo struct {
	Load1    float64
	MemFree  uint64
	MemTotal uint64
}

// errNoFleet means this login has no claude-fleet install: not an error, the
// heartbeat simply carries no fleets.
var errNoFleet = errors.New("no claude-fleet install on this login")

type fleetSnapshot struct {
	machineID string
	fleets    []control.Fleet
}

// fleetControlCommand is the injection point for tests, like fleetCommand.
var fleetControlCommand = func(ctx context.Context, script string, stdin []byte) ([]byte, error) {
	cmd := fleetCommand(ctx, script, "rpc")
	cmd.Stdin = bytes.NewReader(stdin)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	err := cmd.Run()
	// fleet-control.py prints a JSON error object and exits 1 on a refusal;
	// the caller reads stdout either way.
	if stdout.Len() > 0 {
		return stdout.Bytes(), nil
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
			FleetID string `json:"fleet_id"`
			Name    string `json:"name"`
			Repo    string `json:"repo"`
		} `json:"fleets"`
	}
	if err := fleetRPC(ctx, script, map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}}, &disc); err != nil {
		return fleetSnapshot{}, fmt.Errorf("fleet discover: %w", err)
	}
	snap := fleetSnapshot{machineID: disc.MachineID, fleets: []control.Fleet{}}
	for _, f := range disc.Fleets {
		var st struct {
			State   string            `json:"state"`
			Workers []json.RawMessage `json:"workers"`
		}
		fl := control.Fleet{FleetID: f.FleetID, Name: f.Name, Repo: f.Repo}
		err := fleetRPC(ctx, script, map[string]any{"protocol": 1, "method": "fleet_status",
			"machine_id": disc.MachineID, "params": map[string]any{"fleet_id": f.FleetID}}, &st)
		if err != nil {
			fl.State = "unknown"
		} else {
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
	in, err := json.Marshal(req)
	if err != nil {
		return err
	}
	raw, err := fleetControlCommand(ctx, script, in)
	if err != nil {
		return err
	}
	var resp struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &resp); err != nil {
		return errors.New("fleet-control.py printed something that is not JSON")
	}
	if resp.Error != nil {
		return fmt.Errorf("%s: %s", resp.Error.Code, resp.Error.Message)
	}
	return json.Unmarshal(resp.Result, out)
}
