package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A service run on a machine's service login (claude-fleet#4086).
//
// Claude Code runs only where its region allows — the Mac mini — so a service
// run is not a cluster Job (ClusterSvcRunner) but an attempt on a SERVICE
// LOGIN: a login of its own (never a person's, never a spare or a trial's),
// made a service login by root (CCQUOTA_FLEET_SVC=1 in its env, so its agent
// lists CapSvcRun) and named by the hub's fleet.svc.logins. One login runs for
// many workspaces; bin/fleet-svc-local.sh gives each attempt a fresh directory
// and leaves nothing behind (BREAK-IT svc-run-leaks-across-runs).
//
//	fleet.svc.logins     <host>:<login>,… — the service logins (none ⇒ no slot,
//	                     every run waits in the queue and expires)
//	fleet.svc.per_login  attempts one login runs at once (default 1, at most 4)
//
// The queue is the hub's, oldest first: the dispatch claims only as many runs as
// there are free slots (svcSlotted). Start mints the one-time key — kept here as
// its sha256, svc_run_jobs.cluster = node:<host>/<login> — and sends svc_run
// down that login's link; the agent starts the wrapper and answers at once. The
// run reads its spec and hands in its result over /v1/node/svc-runs itself, the
// same road a Job takes, with a pass bound to the run (the model through the
// hub's credential proxy, metered by tenant). Cancel ends the key and the pass
// and sends svc_run_cancel. A Codex-only service could run in the cluster
// instead (ClusterSvcRunner); one hub has one runner.
type NodeSvcRunner struct {
	s *Server
}

// NewNodeSvcRunner is the runner of service logins.
func NewNodeSvcRunner(s *Server) *NodeSvcRunner { return &NodeSvcRunner{s: s} }

// SvcLoginsKey / SvcPerLoginKey are the runner's two fleet settings.
const (
	SvcLoginsKey   = "fleet.svc.logins"
	SvcPerLoginKey = "fleet.svc.per_login"
	svcPerLoginMax = 4
	svcRunAckWait  = 30 * time.Second
)

var errNoSvcLane = errors.New("no service login has a free slot")

// svcLoginsSettingCheck says why a value of fleet.svc.logins / per_login is
// refused; "" = fine ("" clears either).
func svcLoginsSettingCheck(key, value string) string {
	if value == "" {
		return ""
	}
	if key == SvcPerLoginKey {
		if n, err := strconv.Atoi(value); err != nil || n < 1 || n > svcPerLoginMax {
			return SvcPerLoginKey + " is an integer 1–" + strconv.Itoa(svcPerLoginMax) + ", or \"\" for 1"
		}
		return ""
	}
	for _, f := range strings.Split(value, ",") {
		h, l, ok := strings.Cut(strings.TrimSpace(f), ":")
		if !ok || !nodeNameRE.MatchString(h) || !control.ValidCreateLogin(l, true) {
			return SvcLoginsKey + " is <machine>:<login>,… (e.g. mac-a:fleetsvc1), or \"\" for none"
		}
	}
	return ""
}

// svcLoginsAllowed reads fleet.svc.logins into an allow function.
func svcLoginsAllowed(settings map[string]string) func(host, login string) bool {
	type hl struct{ host, login string }
	var list []hl
	for _, f := range strings.Split(settings[SvcLoginsKey], ",") {
		if h, l, ok := strings.Cut(strings.TrimSpace(f), ":"); ok && h != "" && l != "" {
			list = append(list, hl{h, l})
		}
	}
	return func(host, login string) bool {
		for _, x := range list {
			if x.login == login && sameMachine(host, x.host) {
				return true
			}
		}
		return false
	}
}

func svcPerLogin(settings map[string]string) int {
	n, err := strconv.Atoi(strings.TrimSpace(settings[SvcPerLoginKey]))
	if err != nil || n < 1 {
		return 1
	}
	if n > svcPerLoginMax {
		return svcPerLoginMax
	}
	return n
}

// lanes is every connected service login with how many attempts it holds.
func (r *NodeSvcRunner) lanes(settings map[string]string) ([]svcLane, map[string]int) {
	busy, err := r.s.Store.SvcRunJobsOpen()
	if err != nil {
		busy = map[string]int{}
	}
	return r.allLanes(svcLoginsAllowed(settings)), busy
}

// allLanes is every service login's link, wherever it ends: the ones this
// replica holds, then — with several replicas — the ones another holds
// (fleet_node_conns), named off the node roster. The svc-runs loop runs on one
// replica while a login's link lands on either, so a lane held elsewhere is
// a lane all the same (R2 waited in the queue for exactly this).
func (r *NodeSvcRunner) allLanes(allowed func(host, login string) bool) []svcLane {
	s := r.s
	out := s.nodes.svcLanes(allowed)
	peers := s.peerConns()
	if len(peers) == 0 {
		return out
	}
	held := map[string]bool{}
	for _, l := range out {
		held[l.id] = true
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		return out
	}
	byID := make(map[string]store.Node, len(rows))
	for _, n := range rows {
		byID[n.EndpointID] = n
	}
	ids := make([]string, 0, len(peers))
	for id := range peers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		pc := peers[id]
		n, ok := byID[id]
		if held[id] || !ok || !pc.HasCap(control.CapSvcRun) || !control.Compatible(n.Proto) {
			continue
		}
		if n.Hostname != "" && n.OSUser != "" && allowed(n.Hostname, n.OSUser) {
			out = append(out, svcLane{id: id, peer: &pc, host: n.Hostname, login: n.OSUser})
		}
	}
	return out
}

// FreeSlots is how many attempts the service logins can start now.
func (r *NodeSvcRunner) FreeSlots(settings map[string]string) int {
	per := svcPerLogin(settings)
	lanes, busy := r.lanes(settings)
	free := 0
	for _, l := range lanes {
		if n := per - busy[l.place()]; n > 0 {
			free += n
		}
	}
	return free
}

// pick is the least busy service login with a free slot.
func (r *NodeSvcRunner) pick() (svcLane, error) {
	settings, _ := r.s.Store.FleetSettings()
	per := svcPerLogin(settings)
	lanes, busy := r.lanes(settings)
	best, bestN := -1, per
	for i, l := range lanes {
		if n := busy[l.place()]; n < bestN {
			best, bestN = i, n
		}
	}
	if best < 0 {
		return svcLane{}, errNoSvcLane
	}
	return lanes[best], nil
}

// send writes one message down l's link and waits for its TypeResult ack —
// here, or on the replica holding the link (the ack comes back to the one
// that wrote it, so the holder waits for it and returns it).
func (r *NodeSvcRunner) send(ctx context.Context, l svcLane, typ string, v any) (control.SvcRunAck, error) {
	msg, err := control.New(typ, v)
	if err != nil {
		return control.SvcRunAck{}, err
	}
	if l.conn != nil {
		return svcSendConn(ctx, l.conn, l.place(), msg)
	}
	var ack control.SvcRunAck
	rep, err := r.s.forward(ctx, *l.peer, nodeForward{Kind: "svc", Endpoint: l.id, Message: &msg}, svcRunAckWait)
	if err != nil {
		return ack, fmt.Errorf("%s through replica %s: %w", l.place(), l.peer.Replica, err)
	}
	if rep.Error != nil {
		return ack, fmt.Errorf("%s through replica %s: %s", l.place(), l.peer.Replica, rep.Error.Message)
	}
	if err := json.Unmarshal(rep.Data, &ack); err != nil {
		return ack, fmt.Errorf("%s answered %s with a malformed ack", l.place(), typ)
	}
	return ack, nil
}

// svcSendConn writes msg down c and waits for its TypeResult ack.
func svcSendConn(ctx context.Context, c *nodeConn, place string, msg control.Message) (control.SvcRunAck, error) {
	var ack control.SvcRunAck
	if msg.Proto == 0 {
		msg.Proto = control.Proto
	}
	ch := c.pending.add(msg.OpID)
	defer c.pending.remove(msg.OpID)
	ctx, cancel := context.WithTimeout(ctx, svcRunAckWait)
	defer cancel()
	if err := c.wire.write(ctx, msg); err != nil {
		return ack, fmt.Errorf("write to %s: %w", place, err)
	}
	select {
	case <-ctx.Done():
		return ack, fmt.Errorf("%s did not answer %s within %s", place, msg.Type, svcRunAckWait)
	case reply := <-ch:
		if reply.Type == control.TypeError {
			why := "refused"
			if reply.Error != nil {
				why = reply.Error.Code + ": " + reply.Error.Message
			}
			return ack, fmt.Errorf("%s refused %s: %s", place, msg.Type, why)
		}
		if err := json.Unmarshal(reply.Payload, &ack); err != nil {
			return ack, fmt.Errorf("%s answered %s with a malformed ack", place, msg.Type)
		}
		return ack, nil
	}
}

// Start hands the attempt to a service login. A digest the principal never
// registered ends the run template_invalid, and nothing is sent.
func (r *NodeSvcRunner) Start(ctx context.Context, run store.SvcRun) error {
	s := r.s
	if _, err := s.Store.SvcTemplateOf(run.Principal, run.Digest); errors.Is(err, sql.ErrNoRows) {
		_, ferr := s.SvcRunFinish(run.ID, store.SvcRunFailed, SvcErrTemplateInvalid, nil, nil)
		return ferr
	} else if err != nil {
		return err
	}
	if _, err := svcLabel(run.Principal); err != nil {
		return err
	}
	if run.Attempt < 1 || run.Attempt > 9 {
		return fmt.Errorf("attempt %d is not 1-9", run.Attempt)
	}
	lane, err := r.pick()
	if err != nil {
		return err
	}
	key, err := svcMintKey()
	if err != nil {
		return err
	}
	if err := s.Store.AddSvcRunJob(store.SvcRunJob{RunID: run.ID, Attempt: run.Attempt, KeySHA: svcKeySHA(key),
		Cluster: lane.place()}, time.Now()); err != nil {
		return err
	}
	ack, err := r.send(ctx, lane, control.TypeSvcRun, control.SvcRunStart{Run: run.Ref(), Attempt: run.Attempt,
		Deadline: svcJobDeadline(run, time.Now()), Token: key})
	if err == nil && !ack.OK {
		err = fmt.Errorf("%s did not start it: %s", lane.place(), ack.Line)
	}
	if err != nil {
		_, _ = s.Store.EndSvcRunJob(run.ID, run.Attempt, time.Now())
		return err
	}
	s.svcAudit(run.Principal, "svc.run.job", run.Ref(), "ok", "attempt "+strconv.Itoa(run.Attempt)+" on "+lane.place(), time.Now())
	return nil
}

// Cancel ends the attempt's key and pass and stops it on its login.
func (r *NodeSvcRunner) Cancel(ctx context.Context, run store.SvcRun) error {
	s := r.s
	j, jerr := s.Store.SvcRunJobOf(run.ID, run.Attempt)
	s.svcEnvEnd(run.ID, run.Attempt, "run "+run.State, time.Now())
	if jerr != nil {
		return nil
	}
	settings, _ := s.Store.FleetSettings()
	for _, l := range r.allLanes(svcLoginsAllowed(settings)) {
		if l.place() != j.Cluster {
			continue
		}
		ack, err := r.send(ctx, l, control.TypeSvcRunCancel, control.SvcRunCancel{Run: run.Ref(), Attempt: run.Attempt})
		if err == nil && !ack.OK {
			err = fmt.Errorf("%s: %s", l.place(), ack.Line)
		}
		return err
	}
	// its login is gone from the hub: its agent's own deadline stops it
	return nil
}
