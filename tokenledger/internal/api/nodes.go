package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The hub half of the fleet control channel (claude-fleet#1408).
//
// Every agent with CCQUOTA_FLEET=1 dials /v1/node/connect, says hello, and then
// sends a heartbeat every few seconds for as long as the connection lives. The
// hub keeps two things: the newest heartbeat per node in SQLite (the roster
// survives a hub restart, so a node that never comes back reads as lost rather
// than vanishing), and the open connections in memory (the only thing a write
// can be sent down, and only to a node whose protocol version is compatible).
//
// None of this is mounted unless Server.Fleet is set: a hub without the fleet
// module answers these paths exactly as it did before they existed.

// lostAfterBeats is how many missed heartbeats make a node lost.
const lostAfterBeats = 3

// defaultHeartbeatMS stands in when a node did not state its cadence.
const defaultHeartbeatMS = 5000

// helloTimeout bounds how long a fresh connection may stay silent.
const helloTimeout = 10 * time.Second

// nodeConns is the set of open control channels, by endpoint.
type nodeConns struct {
	mu    sync.Mutex
	conns map[string]*nodeConn
}

type nodeConn struct {
	conn *websocket.Conn
	// proto is re-read on every heartbeat by the reader and checked by
	// SendNodeWrite from other goroutines.
	proto atomic.Int64
	// admin is set once, at hello: this connection may be sent account ops
	// (claude-fleet#1411).
	admin bool
	// canRead is the hello's CapRead: this node answers TypeRequest
	// (claude-fleet#1409). Set once, before the conn is published.
	canRead bool
	// canWrite is the hello's CapWrite: this node takes TypeWrite
	// (claude-fleet#1410). Set once, before the conn is published.
	canWrite bool
	// canRelay is the hello's CapRelay: this node sends and takes TypeRelay
	// and keeps a worker map (claude-fleet#1421). Set once, before publish.
	canRelay bool
	// canMove is the hello's CapMove: this node downloads a moved session's
	// transcript and takes worker_move_in (claude-fleet#1426).
	canMove bool
	// workersAt is when the worker map was last pushed (UnixNano).
	workersAt atomic.Int64
	// canSSHRelay is the hello's CapSSHRelay: this node splices relays onto its
	// sshd (claude-fleet#1413). Set once, before the conn is published.
	canSSHRelay bool
	// canOAuthRefresh is the hello's CapOAuthRefresh: this admin node posts
	// one token refresh to the provider from its own network and hands the
	// answer back (claude-fleet#1490). Set once, before the conn is published.
	canOAuthRefresh bool
	// osUser is the login this agent runs as, refreshed by heartbeats.
	osUser atomic.Value // string
	// pending routes read and write replies to their waiter.
	pending pendingReads
	// host is the machine as the roster names it, refreshed by heartbeats.
	host atomic.Value // string
}

func (c *nodeConn) user() string {
	u, _ := c.osUser.Load().(string)
	return u
}

func (c *nodeConn) hostname() string {
	h, _ := c.host.Load().(string)
	return h
}

func (n *nodeConns) put(id string, c *nodeConn) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.conns == nil {
		n.conns = map[string]*nodeConn{}
	}
	if old := n.conns[id]; old != nil && old != c {
		// The same endpoint reconnected before the hub noticed the old link
		// die. The newer one is the truth; the old one is closed so its
		// reader stops and cannot remove the new entry on its way out.
		old.conn.Close(websocket.StatusPolicyViolation, "superseded by a newer connection")
	}
	n.conns[id] = c
}

func (n *nodeConns) drop(id string, c *nodeConn) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.conns[id] == c {
		delete(n.conns, id)
	}
}

// dropAll closes and forgets an endpoint's connection, whichever it is: a
// released SPOT node's token is retired, so its link must not outlive it
// (claude-fleet#1428).
func (n *nodeConns) dropAll(id string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if c := n.conns[id]; c != nil {
		c.conn.Close(websocket.StatusGoingAway, "node released")
		delete(n.conns, id)
	}
}

func (n *nodeConns) get(id string) *nodeConn {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.conns[id]
}

// each calls fn for every open connection, in endpoint order (deterministic
// when two candidates tie). fn runs under the set's lock: look, never block.
func (n *nodeConns) each(fn func(id string, c *nodeConn)) {
	n.mu.Lock()
	defer n.mu.Unlock()
	ids := make([]string, 0, len(n.conns))
	for id := range n.conns {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		fn(id, n.conns[id])
	}
}

// adminFor returns the open, write-compatible admin connection on hostname.
func (n *nodeConns) adminFor(hostname string) (endpointID string, ok bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	ids := make([]string, 0, len(n.conns))
	for id := range n.conns {
		ids = append(ids, id)
	}
	// Deterministic when a machine has two admin logins on the allowlist.
	sort.Strings(ids)
	for _, id := range ids {
		c := n.conns[id]
		if c.admin && c.hostname() == hostname && control.Compatible(int(c.proto.Load())) {
			return id, true
		}
	}
	return "", false
}

// ErrNodeOffline is returned when a write is addressed to a node with no open
// control channel.
var ErrNodeOffline = errors.New("node has no open control channel")

// SendNodeWrite sends a write op down endpointID's control channel.
//
// It is the one door every hub→node write goes through (C3 and later), and it
// refuses a node whose protocol version this hub does not accept writes from
// BEFORE anything leaves the hub — the node is still listed, with its version,
// so the refusal is visible rather than silent.
func (s *Server) SendNodeWrite(ctx context.Context, endpointID string, msg control.Message) error {
	c := s.nodes.get(endpointID)
	if c == nil {
		return ErrNodeOffline
	}
	if !control.Compatible(int(c.proto.Load())) {
		return control.ErrIncompatible
	}
	if msg.Proto == 0 {
		msg.Proto = control.Proto
	}
	return wsjson.Write(ctx, c.conn, msg)
}

// handleNodeConnect accepts one node's control channel.
func (s *Server) handleNodeConnect(w http.ResponseWriter, r *http.Request) {
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}

	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept has already answered the request.
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1 << 20)

	// Detached from the request: the handler outlives nothing, but a hijacked
	// connection's request context is not a reliable signal of its end.
	ctx := context.Background()

	hctx, cancel := context.WithTimeout(ctx, helloTimeout)
	var hello control.Message
	err = wsjson.Read(hctx, conn, &hello)
	cancel()
	if err != nil {
		return
	}
	if hello.Type != control.TypeHello {
		refuse(ctx, conn, hello.OpID, control.CodeBadMessage, "the first message must be a hello")
		return
	}
	var hp control.Hello
	if len(hello.Payload) > 0 {
		if err := json.Unmarshal(hello.Payload, &hp); err != nil {
			refuse(ctx, conn, hello.OpID, control.CodeBadMessage, "malformed hello")
			return
		}
	}
	if hp.HeartbeatMS <= 0 {
		hp.HeartbeatMS = defaultHeartbeatMS
	}

	if err := s.Store.NodeConnected(ep.ID, ep.Hostname, ep.OSUser, hp.AgentVersion,
		hello.Proto, hp.HeartbeatMS, time.Now()); err != nil {
		log.Printf("node %s: record hello: %v", ep.ID, err)
		conn.Close(websocket.StatusInternalError, "hub could not record the node")
		return
	}
	// A machine joining as a mapped login AFTER its person signed in: adopt
	// it now rather than at their next sign-in (claude-fleet#1458).
	if s.mappedLogin(ep.OSUser) {
		s.adoptMappedLogins(time.Now())
	}

	welcome := control.Welcome{Accepted: control.Compatible(hello.Proto), HubProto: control.Proto, MinProto: control.MinProto}
	if !welcome.Accepted {
		// Listed, never written to. The connection stays open so the roster
		// shows the node and its version — "online, proto 7, writes refused"
		// is something an operator can act on; a node that just disappears
		// is not.
		welcome.Reason = control.CodeProtoMismatch
	}
	reply, _ := control.New(control.TypeWelcome, welcome)
	reply.OpID = hello.OpID
	wctx, cancel := context.WithTimeout(ctx, helloTimeout)
	err = wsjson.Write(wctx, conn, reply)
	cancel()
	if err != nil {
		return
	}

	nc := &nodeConn{conn: conn, admin: hp.Admin && s.isFleetAdmin(ep.OSUser), canRead: hp.HasCap(control.CapRead),
		canWrite: hp.HasCap(control.CapWrite), canRelay: hp.HasCap(control.CapRelay),
		canMove: hp.HasCap(control.CapMove), canSSHRelay: hp.HasCap(control.CapSSHRelay)}
	// The refresh relay is an ADMIN role: a node that offers it without
	// being on the hub's admin list is never handed a refresh token's form.
	nc.canOAuthRefresh = nc.admin && hp.HasCap(control.CapOAuthRefresh)
	nc.osUser.Store(ep.OSUser)
	nc.proto.Store(int64(hello.Proto))
	nc.host.Store(ep.Hostname)
	if hp.Admin && !nc.admin {
		log.Printf("node %s (%s@%s) claims admin but is not on the hub's admin list; no account ops will be sent to it",
			ep.ID, ep.OSUser, ep.Hostname)
	}
	s.nodes.put(ep.ID, nc)
	defer s.nodes.drop(ep.ID, nc)
	if nc.canRelay {
		// Relays that waited for this node while it was away go now
		// (claude-fleet#1421).
		go s.dispatchRelays(ep.ID)
	}
	// Relays this link carried end with it (claude-fleet#1413): the agent
	// has dropped its halves, and the client deserves a clean close, not a
	// stream that silently stops moving.
	defer s.sshRelays.closeNode(nc)
	if nc.admin {
		// Every admin connect re-sends the SSH user CA: the node checks
		// what it already has, so a matching machine changes nothing
		// (claude-fleet#1412).
		go s.sendSSHCA(ep.ID)
		// Anything sent down this link and not yet answered is now unknown:
		// whether the login got made is a question only the node can answer,
		// and it re-sends its answer when it is back.
		defer func() {
			// Superseded by a newer link of the same endpoint: ops sent
			// down that one are still in flight, not lost.
			if cur := s.nodes.get(ep.ID); cur != nil && cur != nc {
				return
			}
			if err := s.Store.LoseAccountOps(ep.ID, time.Now()); err != nil {
				log.Printf("node %s: mark in-flight account ops unknown: %v", ep.ID, err)
			}
		}()
	}

	// A read deadline of a few missed beats: a node whose network vanished
	// sends no FIN, and without this the goroutine would wait on it forever.
	idle := time.Duration(hp.HeartbeatMS*(lostAfterBeats+1)) * time.Millisecond
	if idle < helloTimeout {
		idle = helloTimeout
	}
	for {
		rctx, cancel := context.WithTimeout(ctx, idle)
		var m control.Message
		err := wsjson.Read(rctx, conn, &m)
		cancel()
		if err != nil {
			return
		}
		switch m.Type {
		case control.TypeHeartbeat:
			var hb control.Heartbeat
			if err := json.Unmarshal(m.Payload, &hb); err != nil {
				refuse(ctx, conn, m.OpID, control.CodeBadMessage, "malformed heartbeat")
				continue
			}
			if hb.Hostname == "" {
				hb.Hostname = ep.Hostname
			}
			if hb.OSUser == "" {
				hb.OSUser = ep.OSUser
			}
			nc.host.Store(hb.Hostname)
			nc.osUser.Store(hb.OSUser)
			// The heartbeat carries the version too: a node that upgrades
			// without reconnecting is re-judged on its next beat.
			nc.proto.Store(int64(m.Proto))
			now := time.Now()
			if err := s.Store.NodeHeartbeat(ep.ID, hb.Hostname, hb.OSUser, hb.MachineID,
				m.Proto, string(m.Payload), now); err != nil {
				log.Printf("node %s: record heartbeat: %v", ep.ID, err)
			}
			// The Fleet Hub registry (claude-fleet#1409): this login's
			// fleets, re-derived and checked before they are registered.
			s.recordFleets(*ep, hb, nc.canRead, now)
			if s.Spot != nil {
				// A SPOT node's first beat makes it online; a beat with
				// sessions — or an unknown count, #1465 — restarts its
				// idle clock (claude-fleet#1428).
				s.Spot.Beat(ep.ID, hb.SessionsCount(), now)
			}
			if nc.canRelay {
				// The worker map, and any relay whose push went
				// unanswered (claude-fleet#1421).
				go s.pushWorkers(*ep, nc)
				go s.dispatchRelays(ep.ID)
			}
			if nc.admin {
				// Each admin beat is a chance to send what is queued for
				// this machine: a person assigned while it was offline
				// gets their login within a beat of it coming back.
				go s.dispatchAccounts()
			}
		case control.TypeAccountResult:
			s.applyAccountResult(ctx, conn, ep.ID, nc, m)
		case control.TypeResult:
			// A reply to a hub read (claude-fleet#1409) or write
			// (claude-fleet#1410).
			nc.pending.deliver(m)
		case control.TypeSSHCAResult:
			s.applySSHCAResult(ep.ID, nc, m)
		case control.TypeOAuthRefreshResult:
			// A relayed token refresh's answer (claude-fleet#1490) goes to
			// the lease that is waiting on it; nothing of it is kept here.
			nc.pending.deliver(m)
		case control.TypeError:
			// A refused hub read or write goes to its waiter; any other
			// error is a refused account op.
			if nc.pending.deliver(m) {
				break
			}
			if nc.admin && m.Error != nil {
				s.applyAccountRefusal(ep.ID, m)
			}
		case control.TypeRelay:
			// A node handing over a relay for another machine
			// (claude-fleet#1421).
			if !nc.canRelay {
				refuse(ctx, conn, m.OpID, control.CodeRefused, "relays need the relay capability in the hello")
				break
			}
			s.acceptRelay(ctx, conn, *ep, m)
		case control.TypeRelayResult:
			s.relayResult(ep.ID, m)
		case control.TypeAck:
			// Replies to hub writes. Nothing sends one yet (C3 will).
		default:
			refuse(ctx, conn, m.OpID, control.CodeBadMessage, "unknown message type "+m.Type)
		}
	}
}

func refuse(ctx context.Context, conn *websocket.Conn, opID, code, msg string) {
	m := control.Message{Type: control.TypeError, OpID: opID, Proto: control.Proto,
		Error: &control.Error{Code: code, Message: msg}}
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_ = wsjson.Write(wctx, conn, m)
}

// NodeView is one node as the roster API presents it.
type NodeView struct {
	EndpointID    string     `json:"endpoint_id"`
	Hostname      string     `json:"hostname"`
	OSUser        string     `json:"os_user"`
	MachineID     string     `json:"machine_id,omitempty"`
	Proto         int        `json:"proto"`
	Compatible    bool       `json:"compatible"`
	Status        string     `json:"status"` // online | maintenance | lost
	Connected     bool       `json:"connected"`
	HeartbeatMS   int        `json:"heartbeat_ms"`
	LastHeartbeat *time.Time `json:"last_heartbeat"`
	AgeSec        float64    `json:"age_sec"`
	AgentVersion  string     `json:"agent_version,omitempty"`
	// Admin is a connected node the hub will send account ops to.
	Admin bool `json:"admin,omitempty"`
	// SSHCA is an admin node's last answer to the SSH user CA install
	// (claude-fleet#1412): sent | trusted… | failed….
	SSHCA string `json:"ssh_ca,omitempty"`

	Load1         float64 `json:"load1"`
	NCPU          int     `json:"ncpu"`
	MemFreeBytes  uint64  `json:"mem_free_bytes"`
	MemTotalBytes uint64  `json:"mem_total_bytes"`
	// Sessions is nil when a fleet of this login could not be read
	// (claude-fleet#1465): its count is unknown, never 0. SessionsUnknown
	// then names each unreadable fleet and why.
	Sessions        *int               `json:"sessions"`
	SessionsUnknown []string           `json:"sessions_unknown,omitempty"`
	Fleets          []NodeFleetSummary `json:"fleets"`
	FleetError      string             `json:"fleet_error,omitempty"`
	FleetVersion    string             `json:"fleet_version,omitempty"`

	// Kind is fixed, or ephemeral for a SPOT node the hub started
	// (claude-fleet#1428); Spot is that node's ledger state while it lives.
	Kind string `json:"kind"`
	Spot string `json:"spot,omitempty"`
	// Maintenance is the 维护中 record when the machine is flagged
	// (claude-fleet#1427); Status then reads maintenance while it is heard.
	Maintenance *Maintenance `json:"maintenance,omitempty"`
}

// NodeFleetSummary is one fleet on a node, without its window list (C2 owns
// that view; the roster only counts).
type NodeFleetSummary struct {
	FleetID string   `json:"fleet_id"`
	Name    string   `json:"name"`
	Repo    string   `json:"repo,omitempty"`
	Repos   []string `json:"repos,omitempty"` // claude-fleet#1512; absent from an older agent
	State   string   `json:"state,omitempty"`
	Count   int      `json:"count"`
	Error   string   `json:"error,omitempty"` // why a state "unknown" fleet could not be read
}

// MachineView folds a machine's logins into one row: the operator asks "is m4
// up", not "is each of m4's six agents up".
type MachineView struct {
	Hostname string `json:"hostname"`
	Status   string `json:"status"` // online if any login is; maintenance when flagged
	Online   int    `json:"logins_online"`
	Logins   int    `json:"logins"`
	// Sessions is nil when a heard login's count is unknown
	// (claude-fleet#1465); SessionsUnknown names those fleets as
	// "<login>/<fleet>: <why>".
	Sessions        *int     `json:"sessions"`
	SessionsUnknown []string `json:"sessions_unknown,omitempty"`
	Load1           float64  `json:"load1"`
	NCPU            int      `json:"ncpu"`
	MemFree         uint64   `json:"mem_free_bytes"`
	MemTotal        uint64   `json:"mem_total_bytes"`
	// LastHeartbeat is the newest from any login.
	LastHeartbeat *time.Time `json:"last_heartbeat"`
	// Kind is ephemeral when the machine is a SPOT node (claude-fleet#1428).
	Kind string `json:"kind"`
	// Maintenance is the 维护中 record when the operator flagged the machine
	// (claude-fleet#1427): Status reads maintenance while any login is heard,
	// lost when none is.
	Maintenance *Maintenance `json:"maintenance,omitempty"`
}

// NodesSnapshot is the body of /v1/nodes.
type NodesSnapshot struct {
	At       time.Time     `json:"at"`
	Machines []MachineView `json:"machines"`
	Nodes    []NodeView    `json:"nodes"`
	// Spot is the SPOT nodes block (claude-fleet#1428): absent on a hub
	// that never started one.
	Spot *SpotSummary `json:"spot,omitempty"`
}

// NodeStatus judges a node: lost after lostAfterBeats missed heartbeats. Lost
// is only a label — the row stays, its sessions are not read as idle, and
// nothing on the node is touched.
func NodeStatus(last *time.Time, heartbeatMS int, now time.Time) string {
	if heartbeatMS <= 0 {
		heartbeatMS = defaultHeartbeatMS
	}
	if last == nil || now.Sub(*last) > time.Duration(heartbeatMS*lostAfterBeats)*time.Millisecond {
		return "lost"
	}
	return "online"
}

// Nodes builds the roster as of now.
func (s *Server) Nodes(now time.Time) (NodesSnapshot, error) {
	return s.nodesWhere(now, nil)
}

// nodesWhere builds the roster from the nodes visible passes (nil: all).
func (s *Server) nodesWhere(now time.Time, visible func(hostname, osUser string) bool) (NodesSnapshot, error) {
	rows, err := s.Store.Nodes()
	if err != nil {
		return NodesSnapshot{}, err
	}
	out := NodesSnapshot{At: now.UTC(), Machines: []MachineView{}, Nodes: []NodeView{}}
	// Node kinds and SPOT states (claude-fleet#1428): both tables are empty
	// on a hub that never started a SPOT node, and the reads are one query
	// each.
	kinds, _ := s.Store.EphemeralEndpoints()
	spotState := map[string]string{}
	if spots, err := s.Store.SpotNodes(false, 0); err == nil {
		for _, sp := range spots {
			if sp.EndpointID != "" {
				spotState[sp.EndpointID] = sp.State
			}
		}
	}
	// 维护中 (claude-fleet#1427): the flag is a setting, read once per roster;
	// an empty settings table leaves every status as the heartbeat said.
	settings, _ := s.Store.FleetSettings()
	machines := map[string]*MachineView{}
	order := []string{}
	for _, n := range rows {
		if visible != nil && !visible(n.Hostname, n.OSUser) {
			continue
		}
		v := nodeView(n, now)
		v.Kind = store.NodeKindFixed
		if k := kinds[n.EndpointID]; k != "" {
			v.Kind = k
		}
		v.Spot = spotState[n.EndpointID]
		if m, flagged := maintenanceOf(n.Hostname, settings); flagged {
			v.Maintenance = &m
			if v.Status == "online" {
				v.Status = "maintenance"
			}
		}
		if c := s.nodes.get(n.EndpointID); c != nil {
			v.Connected, v.Admin = true, c.admin
			if c.admin {
				v.SSHCA = s.sshCAStatusOf(n.EndpointID)
			}
		}
		out.Nodes = append(out.Nodes, v)

		m := machines[v.Hostname]
		if m == nil {
			zero := 0
			m = &MachineView{Hostname: v.Hostname, Status: "lost", Kind: v.Kind, Sessions: &zero}
			machines[v.Hostname] = m
			order = append(order, v.Hostname)
		}
		m.Logins++
		if m.Maintenance == nil {
			m.Maintenance = v.Maintenance // a lost machine still shows why it was flagged
		}
		if v.Status == "lost" {
			continue
		}
		// Heard: online, or maintenance when flagged — the machine's word is
		// its logins' word, since the flag is per machine.
		m.Status, m.Maintenance = v.Status, v.Maintenance
		m.Online++
		// One unreadable login makes the machine's count unknown: a sum
		// that silently drops it would read a busy machine as idle.
		for _, u := range v.SessionsUnknown {
			m.SessionsUnknown = append(m.SessionsUnknown, v.OSUser+"/"+u)
		}
		switch {
		case v.Sessions == nil:
			m.Sessions = nil
		case m.Sessions != nil:
			*m.Sessions += *v.Sessions
		}
		// One machine, one load: every login reads the same kernel, so the
		// newest reading stands for all of them.
		if m.LastHeartbeat == nil || (v.LastHeartbeat != nil && v.LastHeartbeat.After(*m.LastHeartbeat)) {
			m.LastHeartbeat = v.LastHeartbeat
			m.Load1, m.NCPU, m.MemFree, m.MemTotal = v.Load1, v.NCPU, v.MemFreeBytes, v.MemTotalBytes
		}
	}
	sort.Strings(order)
	for _, h := range order {
		out.Machines = append(out.Machines, *machines[h])
	}
	out.Spot = s.spotSummary(now, out.Nodes)
	return out, nil
}

func nodeView(n store.Node, now time.Time) NodeView {
	v := NodeView{
		EndpointID: n.EndpointID, Hostname: n.Hostname, OSUser: n.OSUser,
		MachineID: n.MachineID, Proto: n.Proto, Compatible: control.Compatible(n.Proto),
		HeartbeatMS: n.HeartbeatMS, LastHeartbeat: n.LastHeartbeat,
		AgentVersion: n.AgentVersion, Fleets: []NodeFleetSummary{},
		Status: NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now),
	}
	if n.LastHeartbeat != nil {
		v.AgeSec = now.Sub(*n.LastHeartbeat).Seconds()
	}
	var hb control.Heartbeat
	if json.Unmarshal([]byte(n.StatusJSON), &hb) == nil {
		v.Load1, v.NCPU = hb.Load1, hb.NCPU
		v.MemFreeBytes, v.MemTotalBytes = hb.MemFreeBytes, hb.MemTotalBytes
		v.Sessions, v.SessionsUnknown = hb.SessionsCount(), hb.UnreadableFleets()
		v.FleetError, v.FleetVersion = hb.FleetError, hb.FleetVersion
		for _, f := range hb.Fleets {
			v.Fleets = append(v.Fleets, NodeFleetSummary{FleetID: f.FleetID, Name: f.Name, Repo: f.Repo, Repos: reportedRepos(f.Repos), State: f.State, Count: f.Count, Error: f.Error})
		}
	}
	return v
}

// handleNodes serves the roster — narrowed, for a signed-in person, to the
// logins that are theirs (claude-fleet#1411).
func (s *Server) handleNodes(w http.ResponseWriter, r *http.Request) {
	visible, err := s.FleetScope(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	snap, err := s.nodesWhere(time.Now(), visible)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, snap)
}

// serveConnectPage serves the 连接 page (claude-fleet#1412).
func (s *Server) serveConnectPage(w http.ResponseWriter, r *http.Request) {
	// A signed-in person opening 连接 is placed first (claude-fleet#1472), so
	// the page's /v1/fleet/connect finds their login rather than "ask the
	// operator"; the operator's doors name no person and nothing happens.
	s.ensurePerson(r)
	s.serveStandalonePage(w, r, "connect.html")
}

// serveNodesPage serves the standalone roster page.
func (s *Server) serveNodesPage(w http.ResponseWriter, r *http.Request) {
	s.serveStandalonePage(w, r, "nodes.html")
}

// serveSessionsPage serves 我的会话 (claude-fleet#1429): every session the
// viewer may see, on every machine, laid out for a phone.
func (s *Server) serveSessionsPage(w http.ResponseWriter, r *http.Request) {
	s.serveStandalonePage(w, r, "sessions.html")
}
