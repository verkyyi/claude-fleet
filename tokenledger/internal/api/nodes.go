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

func (n *nodeConns) get(id string) *nodeConn {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.conns[id]
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

	nc := &nodeConn{conn: conn}
	nc.proto.Store(int64(hello.Proto))
	s.nodes.put(ep.ID, nc)
	defer s.nodes.drop(ep.ID, nc)

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
			// The heartbeat carries the version too: a node that upgrades
			// without reconnecting is re-judged on its next beat.
			nc.proto.Store(int64(m.Proto))
			if err := s.Store.NodeHeartbeat(ep.ID, hb.Hostname, hb.OSUser, hb.MachineID,
				m.Proto, string(m.Payload), time.Now()); err != nil {
				log.Printf("node %s: record heartbeat: %v", ep.ID, err)
			}
		case control.TypeAck, control.TypeError:
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
	Status        string     `json:"status"` // online | lost
	Connected     bool       `json:"connected"`
	HeartbeatMS   int        `json:"heartbeat_ms"`
	LastHeartbeat *time.Time `json:"last_heartbeat"`
	AgeSec        float64    `json:"age_sec"`
	AgentVersion  string     `json:"agent_version,omitempty"`

	Load1         float64            `json:"load1"`
	NCPU          int                `json:"ncpu"`
	MemFreeBytes  uint64             `json:"mem_free_bytes"`
	MemTotalBytes uint64             `json:"mem_total_bytes"`
	Sessions      int                `json:"sessions"`
	Fleets        []NodeFleetSummary `json:"fleets"`
	FleetError    string             `json:"fleet_error,omitempty"`
	FleetVersion  string             `json:"fleet_version,omitempty"`
}

// NodeFleetSummary is one fleet on a node, without its window list (C2 owns
// that view; the roster only counts).
type NodeFleetSummary struct {
	FleetID string `json:"fleet_id"`
	Name    string `json:"name"`
	Repo    string `json:"repo,omitempty"`
	State   string `json:"state,omitempty"`
	Count   int    `json:"count"`
}

// MachineView folds a machine's logins into one row: the operator asks "is m4
// up", not "is each of m4's six agents up".
type MachineView struct {
	Hostname string  `json:"hostname"`
	Status   string  `json:"status"` // online if any login is
	Online   int     `json:"logins_online"`
	Logins   int     `json:"logins"`
	Sessions int     `json:"sessions"`
	Load1    float64 `json:"load1"`
	NCPU     int     `json:"ncpu"`
	MemFree  uint64  `json:"mem_free_bytes"`
	MemTotal uint64  `json:"mem_total_bytes"`
	// LastHeartbeat is the newest from any login.
	LastHeartbeat *time.Time `json:"last_heartbeat"`
}

// NodesSnapshot is the body of /v1/nodes.
type NodesSnapshot struct {
	At       time.Time     `json:"at"`
	Machines []MachineView `json:"machines"`
	Nodes    []NodeView    `json:"nodes"`
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
	rows, err := s.Store.Nodes()
	if err != nil {
		return NodesSnapshot{}, err
	}
	out := NodesSnapshot{At: now.UTC(), Machines: []MachineView{}, Nodes: []NodeView{}}
	machines := map[string]*MachineView{}
	order := []string{}
	for _, n := range rows {
		v := nodeView(n, now)
		v.Connected = s.nodes.get(n.EndpointID) != nil
		out.Nodes = append(out.Nodes, v)

		m := machines[v.Hostname]
		if m == nil {
			m = &MachineView{Hostname: v.Hostname, Status: "lost"}
			machines[v.Hostname] = m
			order = append(order, v.Hostname)
		}
		m.Logins++
		if v.Status != "online" {
			continue
		}
		m.Status = "online"
		m.Online++
		m.Sessions += v.Sessions
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
		v.Sessions, v.FleetError, v.FleetVersion = hb.Sessions, hb.FleetError, hb.FleetVersion
		for _, f := range hb.Fleets {
			v.Fleets = append(v.Fleets, NodeFleetSummary{FleetID: f.FleetID, Name: f.Name, Repo: f.Repo, State: f.State, Count: f.Count})
		}
	}
	return v
}

// handleNodes serves the roster.
func (s *Server) handleNodes(w http.ResponseWriter, r *http.Request) {
	snap, err := s.Nodes(time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, snap)
}

// serveNodesPage serves the standalone roster page.
func (s *Server) serveNodesPage(w http.ResponseWriter, r *http.Request) {
	s.serveStandalonePage(w, r, "nodes.html")
}
