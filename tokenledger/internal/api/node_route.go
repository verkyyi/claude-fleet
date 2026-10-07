package api

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A write for a node whose control channel ends in the OTHER hub replica
// (claude-fleet#2124, EPIC #2119 C5).
//
// A node dials one address and the load balancer hands its websocket to one
// replica; only that replica can write down it (nodeConns is per process). So
// with two replicas about half of every hub→node write — a session start, a
// read, a relay, the SSH CA, a token refresh — would answer "not connected".
// Each replica records the links it holds in fleet_node_conns; a replica that
// does not hold the target's link looks the holder up there and hands the call
// to it over NodeRoutePath, an in-cluster route behind a token the replicas
// share. The holder runs the very same function it would have run for a call
// of its own — same checks, same journal answer — and returns its result.
//
// What is NOT forwarded, and why that is acceptable (the in-process inventory
// the issue asks for — tokenledger/README.md «两份入口» is the full table):
//   - beat-driven pushes (the worker map, the team version, queued account
//     ops, waiting relays) run on the holder at the node's next beat, because
//     the beat handler is where they are triggered; at most one beat late.
//   - an SSH relay is a byte stream spliced onto the link: it cannot be handed
//     across per call; ssh_relay_replica.go (#2151) proxies the websocket.
//   - a revoked token closes its link on the holder at the node's next message
//     (the read loop checks it), not at once.
//
// Off — Server.Replica nil, the single hub — nothing here runs: no table, no
// route, no lookup, and Server.forwarded stays 0 (TestNodeRouteSingleNeverForwards).

// NodeRoutePath is the in-cluster route a replica hands a node call to.
const NodeRoutePath = "/internal/v1/node-write"

// replicaTokenHeader carries the replicas' shared token. Its own header, so
// the viewer-token middleware never reads it as a person's credential.
const replicaTokenHeader = "X-Ccquota-Replica-Token"

// nodeRouteMargin is how much longer a forwarded call may take than the same
// call made on the holder: the hop between the two pods.
const nodeRouteMargin = 5 * time.Second

// Replica is this hub process as one of several behind one address
// (CCQUOTA_REPLICA, CCQUOTA_REPLICA_URL, CCQUOTA_REPLICA_TOKEN[_FILE]).
type Replica struct {
	// Name is this replica's own name — the pod name.
	Name string
	// URL is where the other replicas reach this one's NodeRoutePath (the
	// pod's own address, never the public one).
	URL string
	// Token is the secret every replica shares; it never enters the database.
	Token string
	// Client makes the forwarded calls; nil = http.DefaultClient.
	Client *http.Client
}

func (r *Replica) client() *http.Client {
	if r.Client != nil {
		return r.Client
	}
	return http.DefaultClient
}

// ParseReplica reads the replica settings. None set: nil (a single hub). A
// name without its URL or token is refused: a replica that cannot be reached,
// or cannot prove itself, would silently drop half the writes.
func ParseReplica(getenv func(string) string, token string) (*Replica, error) {
	name := strings.TrimSpace(getenv("CCQUOTA_REPLICA"))
	url := strings.TrimRight(strings.TrimSpace(getenv("CCQUOTA_REPLICA_URL")), "/")
	if name == "" && url == "" && token == "" {
		return nil, nil
	}
	switch {
	case name == "":
		return nil, errors.New("CCQUOTA_REPLICA_URL / CCQUOTA_REPLICA_TOKEN are set but CCQUOTA_REPLICA (this replica's name) is not")
	case url == "":
		return nil, errors.New("CCQUOTA_REPLICA is set but CCQUOTA_REPLICA_URL (where the other replicas reach this one) is not")
	case token == "":
		return nil, errors.New("CCQUOTA_REPLICA is set but CCQUOTA_REPLICA_TOKEN[_FILE] (the replicas' shared token) is not")
	}
	return &Replica{Name: name, URL: url, Token: token}, nil
}

// StartReplica prepares the store for this replica: the table, and no row
// left over from a previous life of the same name.
func (s *Server) StartReplica() error {
	if s.Replica == nil {
		return nil
	}
	if err := s.Store.EnsureFleetNodeConns(); err != nil {
		return err
	}
	n, err := s.Store.ReleaseReplicaConns(s.Replica.Name)
	if err != nil {
		return err
	}
	log.Printf("fleet: replica %s (%s) — writes for a node held by another replica go there over %s; %d stale link row(s) cleared",
		s.Replica.Name, s.Replica.URL, NodeRoutePath, n)
	return nil
}

// claimLink records nc as endpointID's link and returns the release to defer.
func (s *Server) claimLink(endpointID string, nc *nodeConn, caps []string) func() {
	if s.Replica == nil {
		return func() {}
	}
	epoch := control.NewOpID()
	row := store.NodeConn{EndpointID: endpointID, Replica: s.Replica.Name, URL: s.Replica.URL,
		Epoch: epoch, Admin: nc.admin, Caps: caps, ConnectedAt: time.Now()}
	if err := s.Store.ClaimNodeConn(row); err != nil {
		// The link still works from here; only the other replicas cannot
		// find it, and they say "not connected" rather than guess.
		log.Printf("node %s: record its link in fleet_node_conns: %v", endpointID, err)
	}
	return func() {
		if err := s.Store.ReleaseNodeConn(endpointID, s.Replica.Name, epoch); err != nil {
			log.Printf("node %s: release its link row: %v", endpointID, err)
		}
	}
}

// localOnlyKey marks a call the holder runs for another replica: it must never
// be forwarded again (a stale row would otherwise bounce it back).
type localOnlyKey struct{}

func localOnly(ctx context.Context) bool {
	v, _ := ctx.Value(localOnlyKey{}).(bool)
	return v
}

// peerOf is the row of the OTHER replica holding endpointID's link — only when
// this one holds none. ok is false on a single hub, for a call already
// forwarded, and when no other replica holds it.
func (s *Server) peerOf(ctx context.Context, endpointID string) (store.NodeConn, bool) {
	if s.Replica == nil || localOnly(ctx) || s.nodes.get(endpointID) != nil {
		return store.NodeConn{}, false
	}
	row, ok, err := s.Store.NodeConnOf(endpointID)
	if err != nil {
		log.Printf("node %s: look up its link: %v", endpointID, err)
		return store.NodeConn{}, false
	}
	if !ok || row.Replica == s.Replica.Name {
		// Our own name on a row with no link here: a drop that lost its
		// delete. Nobody holds the link.
		return store.NodeConn{}, false
	}
	return row, true
}

// peerConns is every link the other replicas hold, by endpoint (nil on a
// single hub).
func (s *Server) peerConns() map[string]store.NodeConn {
	if s.Replica == nil {
		return nil
	}
	rows, err := s.Store.NodeConns()
	if err != nil {
		log.Printf("fleet: read fleet_node_conns: %v", err)
		return nil
	}
	out := map[string]store.NodeConn{}
	for _, r := range rows {
		if r.Replica != s.Replica.Name {
			out[r.EndpointID] = r
		}
	}
	return out
}

// nodeForward is one call handed to the holder.
type nodeForward struct {
	// Kind: write (sendWrite) · read (NodeRead) · send (SendNodeWrite) ·
	// relays (dispatchRelays) · oauth (a relayed token refresh).
	Kind     string `json:"kind"`
	Endpoint string `json:"endpoint_id"`

	Target   *store.FleetRow       `json:"target,omitempty"`
	Op       *store.FleetOperation `json:"op,omitempty"`
	Envelope map[string]any        `json:"envelope,omitempty"`

	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`

	Message *control.Message `json:"message,omitempty"`

	Provider string            `json:"provider,omitempty"`
	Form     map[string]string `json:"form,omitempty"`
}

// nodeForwardReply is the holder's answer.
type nodeForwardReply struct {
	Status    string          `json:"status,omitempty"`
	Result    string          `json:"result,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	MachineID string          `json:"machine_id,omitempty"`
	Via       string          `json:"via,omitempty"`
	HTTP      int             `json:"http_status,omitempty"`
	Body      []byte          `json:"body,omitempty"`
	Error     *FleetFault     `json:"error,omitempty"`
}

// codeNotHere is the holder's answer for a link it no longer has.
const codeNotHere = "NOT_HERE"

// errForwardNotSent is a forward that never reached the holder: nothing left.
var errForwardNotSent = errors.New("the replica holding the link could not be reached")

// forward hands f to peer and decodes its answer. A transport failure before
// the request left is errForwardNotSent; after, it is some other error (the
// call may have run). A NOT_HERE answer releases the stale row.
func (s *Server) forward(ctx context.Context, peer store.NodeConn, f nodeForward, wait time.Duration) (nodeForwardReply, error) {
	s.forwarded.Add(1)
	body, err := json.Marshal(f)
	if err != nil {
		return nodeForwardReply{}, err
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), wait+nodeRouteMargin)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, peer.URL+NodeRoutePath, bytes.NewReader(body))
	if err != nil {
		return nodeForwardReply{}, fmt.Errorf("%w: %v", errForwardNotSent, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(replicaTokenHeader, s.Replica.Token)
	resp, err := s.Replica.client().Do(req)
	if err != nil {
		var op *net.OpError
		if errors.As(err, &op) && op.Op == "dial" {
			return nodeForwardReply{}, fmt.Errorf("%w (%s): %v", errForwardNotSent, peer.Replica, err)
		}
		return nodeForwardReply{}, fmt.Errorf("replica %s: %v", peer.Replica, err)
	}
	defer resp.Body.Close()
	var r nodeForwardReply
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nodeForwardReply{}, fmt.Errorf("replica %s: HTTP %d, unreadable answer: %v", peer.Replica, resp.StatusCode, err)
	}
	if r.Error != nil && r.Error.Code == codeNotHere {
		_ = s.Store.ReleaseNodeConn(peer.EndpointID, peer.Replica, peer.Epoch)
		return r, fmt.Errorf("%w (%s no longer holds it)", errForwardNotSent, peer.Replica)
	}
	if resp.StatusCode/100 != 2 && r.Error == nil {
		return r, fmt.Errorf("replica %s: HTTP %d", peer.Replica, resp.StatusCode)
	}
	return r, nil
}

// handleNodeRoute runs a call another replica handed over, on the link this
// one holds.
func (s *Server) handleNodeRoute(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	got := r.Header.Get(replicaTokenHeader)
	if got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(s.Replica.Token)) != 1 {
		httpError(w, http.StatusUnauthorized, "not a replica of this hub")
		return
	}
	var f nodeForward
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&f); err != nil {
		httpError(w, http.StatusBadRequest, "malformed forward: "+err.Error())
		return
	}
	answer := func(status int, rep nodeForwardReply) { writeJSON(w, status, rep) }
	refuse := func(err error) {
		e := errorObject(err)
		answer(http.StatusOK, nodeForwardReply{Error: fault(e["code"], e["message"])})
	}
	if s.nodes.get(f.Endpoint) == nil {
		answer(http.StatusConflict, nodeForwardReply{Error: fault(codeNotHere, "replica "+s.Replica.Name+" holds no link to "+f.Endpoint)})
		return
	}
	ctx := context.WithValue(r.Context(), localOnlyKey{}, true)
	switch f.Kind {
	case "write":
		if f.Target == nil || f.Op == nil {
			httpError(w, http.StatusBadRequest, "a write needs its target and operation")
			return
		}
		status, result := s.sendWrite(ctx, *f.Target, *f.Op, f.Envelope)
		answer(http.StatusOK, nodeForwardReply{Status: status, Result: result})
	case "read":
		var params any
		if len(f.Params) > 0 {
			params = f.Params
		}
		data, machine, err := s.NodeRead(ctx, f.Endpoint, f.Method, params)
		if err != nil {
			refuse(err)
			return
		}
		answer(http.StatusOK, nodeForwardReply{Data: data, MachineID: machine})
	case "send":
		if f.Message == nil {
			httpError(w, http.StatusBadRequest, "a send needs its message")
			return
		}
		if err := s.SendNodeWrite(ctx, f.Endpoint, *f.Message); err != nil {
			refuse(err)
			return
		}
		answer(http.StatusOK, nodeForwardReply{Status: "sent"})
	case "relays":
		go s.dispatchRelays(f.Endpoint)
		answer(http.StatusOK, nodeForwardReply{Status: "dispatching"})
	case "oauth":
		ans, err := s.oauthRefreshOn(ctx, f.Endpoint, f.Provider, f.Form)
		rep := nodeForwardReply{Via: ans.Via, HTTP: ans.Status, Body: ans.Body}
		if err != nil {
			rep.Error = fault("UNAVAILABLE", err.Error())
		}
		answer(http.StatusOK, rep)
	default:
		httpError(w, http.StatusBadRequest, "unknown forward kind "+f.Kind)
	}
}

// forwardWrite is sendWrite for a link another replica holds: the same
// (status, result) pair, from the holder's own sendWrite.
func (s *Server) forwardWrite(ctx context.Context, peer store.NodeConn, target store.FleetRow, op store.FleetOperation, envelope map[string]any) (string, string) {
	errResult := func(code, msg string) string {
		b, _ := json.Marshal(map[string]any{"error": map[string]string{"code": code, "message": msg}})
		return string(b)
	}
	wait := fleetWriteWait
	if op.Action == "worker_move_in" {
		wait = moveWriteWait
	}
	rep, err := s.forward(ctx, peer, nodeForward{Kind: "write", Endpoint: target.EndpointID,
		Target: &target, Op: &op, Envelope: envelope}, wait)
	switch {
	case errors.Is(err, errForwardNotSent):
		return "failed", errResult("UNAVAILABLE", "before the write was sent: "+err.Error())
	case err != nil:
		// The holder may have sent it: unknown, never failed.
		return "unknown", errResult(control.CodeUnknownOutcome, "forwarding the write: "+err.Error())
	case rep.Error != nil:
		return "unknown", errResult(rep.Error.Code, rep.Error.Message)
	}
	return rep.Status, rep.Result
}

// forwardRead is NodeRead for a link another replica holds.
func (s *Server) forwardRead(ctx context.Context, peer store.NodeConn, method string, params any) (json.RawMessage, string, error) {
	p, err := json.Marshal(params)
	if err != nil {
		return nil, "", err
	}
	timeout := fleetReadTimeout
	if fleetGHReads[method] {
		timeout = ghReadTimeout
	}
	rep, err := s.forward(ctx, peer, nodeForward{Kind: "read", Endpoint: peer.EndpointID, Method: method, Params: p}, timeout)
	if errors.Is(err, errForwardNotSent) {
		return nil, "", ErrNodeOffline
	}
	if err != nil {
		return nil, "", fault("UNAVAILABLE", err.Error())
	}
	if rep.Error != nil {
		return nil, "", rep.Error
	}
	return rep.Data, rep.MachineID, nil
}

// forwardSend is SendNodeWrite for a link another replica holds.
func (s *Server) forwardSend(ctx context.Context, peer store.NodeConn, msg control.Message) error {
	rep, err := s.forward(ctx, peer, nodeForward{Kind: "send", Endpoint: peer.EndpointID, Message: &msg}, 5*time.Second)
	if errors.Is(err, errForwardNotSent) {
		return ErrNodeOffline
	}
	if err != nil {
		return err
	}
	if rep.Error != nil {
		return rep.Error
	}
	return nil
}

// forwardOAuth is a relayed refresh through a node another replica holds.
func (s *Server) forwardOAuth(ctx context.Context, peer store.NodeConn, name, provider string, form map[string]string) (credvault.ProxyAnswer, error) {
	ans := credvault.ProxyAnswer{Via: name}
	rep, err := s.forward(ctx, peer, nodeForward{Kind: "oauth", Endpoint: peer.EndpointID, Provider: provider, Form: form}, oauthRefreshTimeout)
	if err != nil {
		return ans, fmt.Errorf("%w: %s refresh via %s: %v", credvault.ErrRefreshUnavailable, provider, name, err)
	}
	if rep.Via != "" {
		ans.Via = rep.Via
	}
	if rep.Error != nil {
		// The holder's own words already carry ErrRefreshUnavailable's text.
		return ans, fmt.Errorf("%w: %s", credvault.ErrRefreshUnavailable, rep.Error.Message)
	}
	ans.Status, ans.Body = rep.HTTP, rep.Body
	return ans, nil
}
