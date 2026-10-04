package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The read-only half of the Fleet Hub, in the hub (claude-fleet#1409).
//
// bin/fleet_hub.py answers "which fleets exist and what are their windows" by
// SSHing into every registered machine. Here the machines have already told
// us: each heartbeat carries this login's fleets and their window lists, and
// RecordFleetSnapshot keeps them as a registry. A query is answered from that
// registry, and — for fleet_status / config_get / operation_get — asked once
// more of the node itself over the control channel when it is connected and
// says it serves reads (control.CapRead). The node runs the same
// fleet-control.py rpc the SSH path ran, so the answer is the same object.
//
// Identity is the Python scheme, byte for byte (internal/fleetid): a fleet UUID
// or worker_id a caller learned from the SSH hub is the same one here.
//
// Every query is scoped to the caller (EPIC #1407 共同约定 5) through ONE seam,
// fleetScope, which is C4's Server.FleetScope (claude-fleet#1411): the
// operator's doors (viewer token, tailnet identity, --no-auth) see every
// machine; a person signed in through WeCom sees only their own logins.

// FleetFault is a refusal with a Fleet Hub code (the same codes the Python
// hub returns, so a client written against one reads the other).
type FleetFault struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (f *FleetFault) Error() string { return f.Code + ": " + f.Message }

func fault(code, msg string) *FleetFault { return &FleetFault{code, msg} }

// fleetReadTimeout bounds one live read over the control channel. Past it the
// answer comes from the last heartbeat, labelled as such.
const fleetReadTimeout = 8 * time.Second

// fleetPrincipal is who is asking, and what they may see.
type fleetPrincipal struct {
	// Actor names the caller in the journal and the audit log: the viewer,
	// or "operator" for the shared token (which names nobody).
	Actor string
	// Person is the WeCom principal behind the call, "" for the operator's
	// doors. It picks the grant (claude-fleet#1410): the operator holds every
	// scope, a person holds Server.FleetPersonScopes.
	Person string
	// scope is nil for the operator (sees everything), else the (machine,
	// login) pairs this caller may see.
	scope func(hostname, osUser string) bool
}

// All reports whether the caller sees every machine.
func (p fleetPrincipal) All() bool { return p.scope == nil }

func (p fleetPrincipal) sees(hostname, osUser string) bool {
	return p.scope == nil || p.scope(hostname, osUser)
}

// fleetScope is the one place a fleet read asks "what may this caller see":
// C4's Server.FleetScope (claude-fleet#1411) — nil for the operator's doors
// (viewer token, tailnet identity), else exactly the signed-in person's ACTIVE
// (machine, login) accounts.
func (s *Server) fleetScope(r *http.Request) (func(hostname, osUser string) bool, error) {
	if s.fleetScopeHook != nil {
		return s.fleetScopeHook(r)
	}
	return s.FleetScope(r)
}

// FleetPrincipal resolves the caller of r.
func (s *Server) FleetPrincipal(r *http.Request) (fleetPrincipal, error) {
	scope, err := s.fleetScope(r)
	if err != nil {
		return fleetPrincipal{}, err
	}
	// A person is journalled as their WeCom subject, whatever the access
	// log calls them: it is the key their idempotency and operations are
	// scoped by.
	person := principalOf(r.Context())
	actor := person
	if actor == "" {
		actor = viewerOf(r.Context())
	}
	if actor == "" {
		actor = "operator"
	}
	return fleetPrincipal{Actor: actor, Person: person, scope: scope}, nil
}

// --- registry feed (heartbeats) -----------------------------------------

// recordFleets turns one heartbeat into registry rows. verify is true for an
// agent that reports each fleet's checkout (one that said CapRead): then every
// fleet UUID is re-derived from (machine, name, repo, checkout) and a fleet
// whose UUID does not add up is dropped, never registered under a wrong id.
func (s *Server) recordFleets(ep store.Endpoint, hb control.Heartbeat, verify bool, at time.Time) {
	if hb.MachineID == "" || hb.FleetError != "" {
		// No claude-fleet, or this beat could not read it: keep what the
		// registry knew rather than marking every fleet gone.
		return
	}
	if !fleetid.IsUUID(hb.MachineID) {
		log.Printf("node %s: heartbeat machine_id %q is not a canonical UUID; fleets not registered", ep.ID, hb.MachineID)
		return
	}
	reports := make([]store.FleetReport, 0, len(hb.Fleets))
	for _, f := range hb.Fleets {
		if !fleetid.IsUUID(f.FleetID) {
			log.Printf("node %s: fleet %q has no canonical UUID; skipped", ep.ID, f.Name)
			continue
		}
		if verify {
			want, _ := fleetid.FleetID(hb.MachineID, f.Name, f.Repo, f.Checkout)
			if want != f.FleetID {
				log.Printf("node %s: fleet %s (%s) does not derive from machine %s; skipped", ep.ID, f.FleetID, f.Name, hb.MachineID)
				continue
			}
		}
		workers := consistentWorkers(f.FleetID, f.Workers)
		reports = append(reports, store.FleetReport{
			FleetID: f.FleetID, Name: f.Name, Repo: f.Repo, Checkout: f.Checkout, Agent: f.Agent,
			State: f.State, WorkerCount: f.Count, WorkersJSON: string(workers),
		})
	}
	host, user := hb.Hostname, hb.OSUser
	if host == "" {
		host = ep.Hostname
	}
	if user == "" {
		user = ep.OSUser
	}
	rejected, err := s.Store.RecordFleetSnapshot(ep.ID, host, user, hb.MachineID, reports, at)
	if err != nil {
		log.Printf("node %s: record fleets: %v", ep.ID, err)
		return
	}
	for _, id := range rejected {
		log.Printf("node %s: fleet %s is registered to another machine; refused", ep.ID, id)
	}
	// Issue leases ride the same beat (claude-fleet#1422): a session it
	// shows renews its lease, a session it no longer shows releases it.
	s.renewLeases(ep, reports, rejected, s.leaseClock())
}

// consistentWorkers returns a fleet's window list with every worker_id checked
// against the fleet it came with: <fleet UUID>/<key>, key well-formed. A
// window whose id does not add up keeps its row but loses the id — it is
// listed, never routable under a borrowed identity.
func consistentWorkers(fleetID string, raw json.RawMessage) json.RawMessage {
	var ws []map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &ws) != nil {
		return json.RawMessage("[]")
	}
	for _, w := range ws {
		id, _ := w["worker_id"].(string)
		key, _ := w["key"].(string)
		if id == "" {
			continue
		}
		fid, k, err := fleetid.ParseWorkerID(id)
		if err != nil || fid != fleetID || k != key {
			w["worker_id"] = nil
		}
	}
	out, err := json.Marshal(ws)
	if err != nil {
		return json.RawMessage("[]")
	}
	return out
}

// --- live reads over the control channel --------------------------------

// pendingReads routes TypeResult / TypeError replies back to the request that
// is waiting for them, by op_id.
type pendingReads struct {
	mu   sync.Mutex
	wait map[string]chan control.Message
}

func (p *pendingReads) add(op string) chan control.Message {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.wait == nil {
		p.wait = map[string]chan control.Message{}
	}
	ch := make(chan control.Message, 1)
	p.wait[op] = ch
	return ch
}

func (p *pendingReads) remove(op string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.wait, op)
}

// deliver hands a reply to its waiter; false when nobody is waiting (it timed
// out, or the op_id was never ours).
func (p *pendingReads) deliver(m control.Message) bool {
	p.mu.Lock()
	ch := p.wait[m.OpID]
	delete(p.wait, m.OpID)
	p.mu.Unlock()
	if ch == nil {
		return false
	}
	ch <- m
	return true
}

// NodeRead asks endpointID's node for one fleet-control.py read method and
// returns its result. It refuses before sending when the node is offline,
// speaks an incompatible protocol, or never said it serves reads.
func (s *Server) NodeRead(ctx context.Context, endpointID, method string, params any) (json.RawMessage, string, error) {
	if !control.ReadMethods[method] {
		return nil, "", fault("INVALID_ARGUMENT", "not a read method: "+method)
	}
	timeout := fleetReadTimeout
	if fleetGHReads[method] {
		timeout = ghReadTimeout
	}
	c := s.nodes.get(endpointID)
	if c == nil {
		return nil, "", ErrNodeOffline
	}
	if !control.Compatible(int(c.proto.Load())) {
		return nil, "", control.ErrIncompatible
	}
	if !c.canRead {
		return nil, "", fault("UNAVAILABLE", "this node's agent predates live reads; upgrade ccquota there")
	}
	p, err := json.Marshal(params)
	if err != nil {
		return nil, "", err
	}
	msg, err := control.New(control.TypeRequest, control.Request{Method: method, Params: p})
	if err != nil {
		return nil, "", err
	}
	ch := c.pending.add(msg.OpID)
	defer c.pending.remove(msg.OpID)
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := wsjson.Write(ctx, c.conn, msg); err != nil {
		return nil, "", fault("UNAVAILABLE", "control channel write failed: "+err.Error())
	}
	select {
	case <-ctx.Done():
		return nil, "", fault("TIMEOUT", "the node did not answer in time")
	case reply := <-ch:
		if reply.Type == control.TypeError {
			if reply.Error != nil {
				return nil, "", fault(reply.Error.Code, reply.Error.Message)
			}
			return nil, "", fault("REMOTE_ERROR", "the node refused the request")
		}
		var r control.Result
		if err := json.Unmarshal(reply.Payload, &r); err != nil {
			return nil, "", fault("PROTOCOL_ERROR", "malformed result from the node")
		}
		return r.Result, r.MachineID, nil
	}
}

// --- the tools ------------------------------------------------------------

// FleetView is one registered fleet as fleet_list presents it: the Python
// hub's snapshot fields, plus where it lives and how fresh it is.
type FleetView struct {
	FleetID      string    `json:"fleet_id"`
	MachineID    string    `json:"machine_id"`
	Name         string    `json:"name"`
	Repo         string    `json:"repo"`
	Checkout     string    `json:"checkout"`
	Agent        string    `json:"agent"`
	MachineName  string    `json:"machine_name"`
	OSUser       string    `json:"os_user"`
	EndpointID   string    `json:"endpoint_id"`
	Registered   bool      `json:"registered"`
	State        string    `json:"state"`
	Count        int       `json:"count"`
	Availability string    `json:"availability"` // online | lost
	ObservedAt   time.Time `json:"observed_at"`
	AgeSec       float64   `json:"age_sec"`
}

// FleetSession is one window of one fleet on one machine — the row of "my
// sessions". The worker fields are fleet-control.py's, verbatim.
type FleetSession struct {
	WorkerID     *string        `json:"worker_id"`
	MachineName  string         `json:"machine_name"`
	OSUser       string         `json:"os_user"`
	FleetID      string         `json:"fleet_id"`
	FleetName    string         `json:"fleet_name"`
	Availability string         `json:"availability"`
	Worker       map[string]any `json:"worker"`
}

// nodeAvailability maps endpoint → online|lost from the roster.
func (s *Server) nodeAvailability(now time.Time) map[string]string {
	out := map[string]string{}
	rows, err := s.Store.Nodes()
	if err != nil {
		return out
	}
	for _, n := range rows {
		out[n.EndpointID] = NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now)
	}
	return out
}

func (s *Server) visibleFleets(p fleetPrincipal, now time.Time) ([]FleetView, []store.FleetRow, error) {
	rows, err := s.Store.Fleets()
	if err != nil {
		return nil, nil, err
	}
	avail := s.nodeAvailability(now)
	views, kept := []FleetView{}, []store.FleetRow{}
	for _, r := range rows {
		if !p.sees(r.Hostname, r.OSUser) {
			continue
		}
		a := avail[r.EndpointID]
		if a == "" {
			a = "lost"
		}
		views = append(views, FleetView{
			FleetID: r.FleetID, MachineID: r.MachineID, Name: r.Name, Repo: r.Repo, Checkout: r.Checkout,
			Agent: r.Agent, MachineName: r.Hostname, OSUser: r.OSUser, EndpointID: r.EndpointID,
			Registered: r.Present, State: r.State, Count: r.WorkerCount, Availability: a,
			ObservedAt: r.ObservedAt, AgeSec: now.Sub(r.ObservedAt).Seconds(),
		})
		kept = append(kept, r)
	}
	return views, kept, nil
}

// FleetList is fleet_list: every fleet the caller may see, on every machine.
// With refresh, each one on a connected node is re-read live first (in
// parallel, bounded); without it the answer is the heartbeat registry, which
// is never older than a few seconds for an online node.
func (s *Server) FleetList(req *http.Request, refresh bool) (map[string]any, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	ctx := req.Context()
	now := time.Now()
	if refresh {
		_, rows, err := s.visibleFleets(p, now)
		if err != nil {
			return nil, err
		}
		var wg sync.WaitGroup
		for _, r := range rows {
			if !r.Present {
				continue
			}
			wg.Add(1)
			go func(r store.FleetRow) {
				defer wg.Done()
				_, _ = s.liveStatus(ctx, r)
			}(r)
		}
		wg.Wait()
		now = time.Now()
	}
	views, _, err := s.visibleFleets(p, now)
	if err != nil {
		return nil, err
	}
	return map[string]any{"fleets": views}, nil
}

// FleetSessions flattens every visible fleet's windows into one list: "my
// sessions", across machines. Ordered by machine, login, fleet, then key.
func (s *Server) FleetSessions(req *http.Request) (map[string]any, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	views, rows, err := s.visibleFleets(p, time.Now())
	if err != nil {
		return nil, err
	}
	out := []FleetSession{}
	machines := map[string]bool{}
	for i, r := range rows {
		if !r.Present {
			continue
		}
		machines[r.Hostname] = true
		var ws []map[string]any
		_ = json.Unmarshal([]byte(r.WorkersJSON), &ws)
		sort.SliceStable(ws, func(a, b int) bool {
			ka, _ := ws[a]["key"].(string)
			kb, _ := ws[b]["key"].(string)
			return ka < kb
		})
		for _, w := range ws {
			var id *string
			if v, ok := w["worker_id"].(string); ok && v != "" {
				id = &v
			}
			out = append(out, FleetSession{WorkerID: id, MachineName: r.Hostname, OSUser: r.OSUser,
				FleetID: r.FleetID, FleetName: r.Name, Availability: views[i].Availability, Worker: w})
		}
	}
	hosts := make([]string, 0, len(machines))
	for h := range machines {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	return map[string]any{"machines": hosts, "count": len(out), "sessions": out}, nil
}

// visibleFleet resolves one fleet id the caller may see, or NOT_FOUND —
// the same answer for "no such fleet" and "not yours", so a fleet's
// existence never leaks across principals.
func (s *Server) visibleFleet(p fleetPrincipal, fleetID string) (store.FleetRow, error) {
	if !fleetid.IsUUID(fleetID) {
		return store.FleetRow{}, fault("INVALID_ARGUMENT", "fleet_id must be a canonical UUID")
	}
	r, err := s.Store.Fleet(fleetID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !p.sees(r.Hostname, r.OSUser)) {
		return store.FleetRow{}, fault("NOT_FOUND", "Fleet is not registered")
	}
	return r, err
}

// liveStatus asks a fleet's node for fleet_status and stores the answer.
func (s *Server) liveStatus(ctx context.Context, r store.FleetRow) (map[string]any, error) {
	res, machine, err := s.NodeRead(ctx, r.EndpointID, "fleet_status", map[string]any{"fleet_id": r.FleetID})
	if err != nil {
		return nil, err
	}
	if machine != "" && machine != r.MachineID {
		return nil, fault("IDENTITY_MISMATCH", "the node now answers as a different machine")
	}
	var st struct {
		State   string            `json:"state"`
		Workers []json.RawMessage `json:"workers"`
	}
	if err := json.Unmarshal(res, &st); err != nil {
		return nil, fault("PROTOCOL_ERROR", "malformed fleet_status from the node")
	}
	if st.Workers == nil {
		st.Workers = []json.RawMessage{}
	}
	raw, _ := json.Marshal(st.Workers)
	workers := consistentWorkers(r.FleetID, raw)
	now := time.Now()
	if err := s.Store.UpdateFleetWorkers(r.FleetID, st.State, len(st.Workers), string(workers), now); err != nil {
		log.Printf("fleet %s: store live status: %v", r.FleetID, err)
	}
	var out map[string]any
	_ = json.Unmarshal(res, &out)
	out["workers"] = json.RawMessage(workers)
	return out, nil
}

// FleetStatus is fleet_status: one fleet's windows. Asked of the node live
// when it can answer; otherwise the last heartbeat's list, with source and
// age saying so — a lost node's windows are reported as last seen, never as
// gone and never as idle.
func (s *Server) FleetStatus(req *http.Request, fleetID string) (map[string]any, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	ctx := req.Context()
	r, err := s.visibleFleet(p, fleetID)
	if err != nil {
		return nil, err
	}
	if !r.Present {
		return nil, fault("NOT_FOUND", "Fleet is no longer configured on its machine")
	}
	now := time.Now()
	avail := s.nodeAvailability(now)[r.EndpointID]
	if avail == "" {
		avail = "lost"
	}
	base := map[string]any{"fleet_id": r.FleetID, "machine_id": r.MachineID, "machine_name": r.Hostname,
		"os_user": r.OSUser, "name": r.Name, "availability": avail}
	if live, err := s.liveStatus(ctx, r); err == nil {
		for k, v := range live {
			base[k] = v
		}
		base["source"] = "live"
		return base, nil
	} else {
		base["live_error"] = errorObject(err)
	}
	base["state"] = r.State
	base["workers"] = json.RawMessage(r.WorkersJSON)
	base["observed_at"] = r.ObservedAt
	base["age_sec"] = now.Sub(r.ObservedAt).Seconds()
	base["source"] = "heartbeat"
	return base, nil
}

// ConfigGet is config_get: the fleet's remotely managed configuration and its
// revision. Live only — a revision is a promise about the file as it is now,
// and the heartbeat does not carry one.
func (s *Server) ConfigGet(req *http.Request, fleetID string) (json.RawMessage, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	ctx := req.Context()
	r, err := s.visibleFleet(p, fleetID)
	if err != nil {
		return nil, err
	}
	res, machine, err := s.NodeRead(ctx, r.EndpointID, "config_get", map[string]any{"fleet_id": r.FleetID})
	if err != nil {
		if errors.Is(err, ErrNodeOffline) {
			return nil, fault("UNAVAILABLE", "the fleet's machine is not connected")
		}
		return nil, err
	}
	if machine != "" && machine != r.MachineID {
		return nil, fault("IDENTITY_MISMATCH", "the node now answers as a different machine")
	}
	return res, nil
}

// OperationGet is operation_get: one journalled operation the caller made (an
// admin may read anyone's). A non-final one is reconciled with the node when
// it can be reached; when it cannot, it reads as unknown — never retried.
func (s *Server) OperationGet(req *http.Request, opID string) (map[string]any, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	ctx := req.Context()
	if !fleetid.IsUUID(opID) {
		return nil, fault("INVALID_ARGUMENT", "operation_id must be a canonical UUID")
	}
	o, err := s.Store.FleetOperation(opID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !p.All() && o.Actor != p.Actor) {
		return nil, fault("NOT_FOUND", "Unknown operation for this caller")
	}
	if err != nil {
		return nil, err
	}
	var reconcileErr error
	if o.Status != "succeeded" && o.Status != "failed" {
		reconcileErr = s.reconcileOperation(ctx, &o)
	}
	out := operationView(o)
	if reconcileErr != nil {
		out["status"] = "unknown"
		out["reconciliation_error"] = errorObject(reconcileErr)
	}
	return out, nil
}

func (s *Server) reconcileOperation(ctx context.Context, o *store.FleetOperation) error {
	r, err := s.Store.Fleet(o.FleetID)
	if err != nil {
		return fault("NOT_FOUND", "the operation's fleet is not registered")
	}
	res, _, err := s.NodeRead(ctx, r.EndpointID, "operation_get", map[string]any{"operation_id": o.ID})
	if err != nil {
		return err
	}
	var remote struct {
		OperationID string          `json:"operation_id"`
		FleetID     string          `json:"fleet_id"`
		Action      string          `json:"action"`
		Status      string          `json:"status"`
		Result      json.RawMessage `json:"result"`
	}
	if json.Unmarshal(res, &remote) != nil || remote.OperationID != o.ID || remote.FleetID != o.FleetID || remote.Action != o.Action {
		return fault("PROTOCOL_ERROR", "remote operation identity does not match")
	}
	switch remote.Status {
	case "accepted", "running", "succeeded", "failed", "unknown":
	default:
		return fault("PROTOCOL_ERROR", "remote operation status is not one this hub knows")
	}
	now := time.Now()
	if err := s.Store.UpdateFleetOperation(o.ID, remote.Status, string(remote.Result), now); err != nil {
		return err
	}
	o.Status, o.Result, o.Updated = remote.Status, string(remote.Result), now
	return nil
}

func operationView(o store.FleetOperation) map[string]any {
	var result any
	if o.Result != "" {
		result = json.RawMessage(o.Result)
	}
	out := map[string]any{"operation_id": o.ID, "fleet_id": o.FleetID, "action": o.Action,
		"status": o.Status, "created_at": o.Created, "updated_at": o.Updated, "result": result}
	if o.Placement != "" {
		// Where a placed worker_start went, and why (claude-fleet#1410).
		out["placement"] = json.RawMessage(o.Placement)
	}
	return out
}

func errorObject(err error) map[string]string {
	var f *FleetFault
	if errors.As(err, &f) {
		return map[string]string{"code": f.Code, "message": f.Message}
	}
	if errors.Is(err, ErrNodeOffline) {
		return map[string]string{"code": "UNAVAILABLE", "message": err.Error()}
	}
	if errors.Is(err, control.ErrIncompatible) {
		return map[string]string{"code": control.CodeProtoMismatch, "message": err.Error()}
	}
	return map[string]string{"code": "INTERNAL", "message": err.Error()}
}

// CallFleetTool runs one fleet tool by name — the one door both MCP and HTTP
// go through, so the audit row is written exactly once per call whichever way
// it came in.
func (s *Server) CallFleetTool(req *http.Request, tool string, args map[string]any) (out any, err error) {
	if args == nil {
		args = map[string]any{}
	}
	fleetID, _ := args["fleet_id"].(string)
	if wid, ok := args["worker_id"].(string); ok && fleetID == "" {
		// A lifecycle tool names a worker; its fleet half is what is audited.
		fleetID, _, _ = fleetid.ParseWorkerID(wid)
	}
	opID := ""
	defer func() {
		if m, ok := out.(map[string]any); ok && opID == "" {
			opID, _ = m["operation_id"].(string)
			if fleetID == "" {
				fleetID, _ = m["fleet_id"].(string)
			}
		}
		outcome := "OK"
		if err != nil {
			outcome = errorObject(err)["code"]
		}
		actor := "operator"
		if p, perr := s.FleetPrincipal(req); perr == nil {
			actor = p.Actor
		}
		if aerr := s.Store.FleetAudit(actor, tool, fleetID, outcome, opID, time.Now()); aerr != nil {
			log.Printf("fleet audit: %v", aerr)
		}
	}()
	// Every caller needs fleet:read, whatever else it does (the Python
	// grant model's first check).
	if p, perr := s.FleetPrincipal(req); perr != nil {
		return nil, perr
	} else if err := s.authorize(p, "fleet:read", ""); err != nil {
		return nil, err
	}
	switch tool {
	case "fleet_list":
		refresh, _ := args["refresh"].(bool)
		return s.FleetList(req, refresh)
	case "fleet_sessions":
		return s.FleetSessions(req)
	case "fleet_status":
		return s.FleetStatus(req, fleetID)
	case "config_get":
		return s.ConfigGet(req, fleetID)
	case "operation_get":
		opID, _ = args["operation_id"].(string)
		return s.OperationGet(req, opID)
	}
	if fleetWriteTools[tool] || fleetGHReads[tool] {
		p, err := s.FleetPrincipal(req)
		if err != nil {
			return nil, err
		}
		if fleetGHReads[tool] {
			return s.GHRead(req.Context(), p, tool, args)
		}
		return s.SubmitWrite(req.Context(), p, tool, args)
	}
	return nil, fault("INVALID_ARGUMENT", "Unknown Fleet tool")
}

// FleetTools lists every tool CallFleetTool serves: the reads of
// claude-fleet#1409, then the GitHub reads and the journalled writes of
// claude-fleet#1410.
var FleetTools = []string{"fleet_list", "fleet_sessions", "fleet_status", "config_get", "operation_get",
	"gh_issue_view", "gh_pr_view", "gh_pr_checks",
	"worker_start", "worker_message", "worker_stop", "worker_resume", "config_set", "gh_comment"}

// handleFleet serves /v1/fleet/<tool>: a read as GET with query arguments
// (?fleet_id=…&operation_id=…&refresh=1&number=…&repo=…&fields=…), or any tool
// as POST with a JSON object body. A write is POST only, and the body must be
// sent as application/json — a type no cross-site form can send without a
// preflight, so a signed-in person's cookie cannot be ridden into a write.
func (s *Server) handleFleet(w http.ResponseWriter, r *http.Request) {
	tool := r.URL.Path[len("/v1/fleet/"):]
	args := map[string]any{}
	switch r.Method {
	case http.MethodPost:
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			httpError(w, http.StatusUnsupportedMediaType, "send the tool's arguments as application/json")
			return
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
		dec.UseNumber()
		if err := dec.Decode(&args); err != nil || args == nil {
			httpError(w, http.StatusBadRequest, "the body must be one JSON object of tool arguments")
			return
		}
	case http.MethodGet:
		if fleetWriteTools[tool] {
			w.Header().Set("Allow", "POST")
			httpError(w, http.StatusMethodNotAllowed, tool+" is a write: POST it")
			return
		}
		q := r.URL.Query()
		for _, k := range []string{"fleet_id", "operation_id", "repo", "fields"} {
			if v := q.Get(k); v != "" {
				args[k] = v
			}
		}
		if v := q.Get("number"); v != "" {
			args["number"] = json.Number(v)
		}
		if b, err := strconv.ParseBool(q.Get("refresh")); err == nil {
			args["refresh"] = b
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	out, err := s.CallFleetTool(r, tool, args)
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		e := errorObject(err)
		status := map[string]int{"INVALID_ARGUMENT": 400, "NOT_FOUND": 404, "FORBIDDEN": 403,
			"UNAVAILABLE": 503, "TIMEOUT": 504, control.CodeProtoMismatch: 409,
			"IDEMPOTENCY_CONFLICT": 409, "AT_CAPACITY": 429, "NO_ELIGIBLE_NODE": 503}[e["code"]]
		if status == 0 {
			status = http.StatusBadGateway
			if e["code"] == "INTERNAL" {
				status = http.StatusInternalServerError
			}
		}
		writeJSON(w, status, map[string]any{"error": e})
		return
	}
	writeJSON(w, http.StatusOK, out)
}
