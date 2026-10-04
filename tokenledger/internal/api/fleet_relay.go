package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Node-to-node relays (claude-fleet#1421, EPIC #1419 C2).
//
// A worker's parent, or the worker a message is for, may live on another
// machine. Neither machine can reach the other; both reach the hub. So the
// sending node hands the relay to the hub over its own control channel, the
// hub STORES it (keyed by the sender's idempotency id, so a resend is a no-op)
// and acks, and only then pushes it down the target node's channel. The
// target's agent applies it through claude-fleet's own script — a child
// report lands in the parent's ledger on the parent's machine and wakes the
// parent; a message lands in the worker's inbox — and answers. A target that
// is not connected gets it when it reconnects; nothing is ever pushed twice
// within relayResendAfter, and an applied relay is never pushed again.
//
// Who may relay to whom: the sender's worker_id must belong to a fleet on the
// SENDING node (the hub checks, a node's claim is not enough), and the target
// fleet must belong to the same owner — the operator's logins with each other,
// a person's logins with each other — never across people. Anything else is
// NOT_FOUND, the same answer as a worker that does not exist.
//
// The same channel carries the other half routing needs: after heartbeats the
// hub pushes the node owner's worker map (TypeWorkers) — every worker on every
// machine of that owner, with its machine and its parent — which the agent
// keeps as claude-fleet's local cache. claude-fleet never asks the network
// where a worker is; it reads that file.

// relayResendAfter is how long a pushed, unanswered relay waits before the
// hub pushes it again (a lost frame, a node that restarted mid-apply).
var relayResendAfter = 60 * time.Second

// relayTTL is how long a relay may wait for its target node; past it the
// relay is expired, never delivered late.
var relayTTL = 7 * 24 * time.Hour

// workersPushEvery bounds the worker-map push to one per node per interval:
// claude-fleet trusts the cache for 30 s, so this keeps it fresh with room.
var workersPushEvery = 10 * time.Second

// relaySuffixRE is the part of a relay id after `<from worker_id>#`.
var relaySuffixRE = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// relayOwner is who a login belongs to, for "only between your own":
// "operator" for the hub's admin logins (and for every login when the hub
// names no admins — a one-operator hub), a person for a login assigned to
// them, else the endpoint alone.
func (s *Server) relayOwner(endpointID, hostname, osUser string, accounts []store.FleetAccount) string {
	if len(s.FleetAdmins) == 0 || s.isFleetAdmin(osUser) {
		return "operator"
	}
	for _, a := range accounts {
		if a.State == store.AccountActive && a.Hostname == hostname && a.Login == osUser {
			return "person:" + a.PrincipalID
		}
	}
	return "endpoint:" + endpointID
}

func (s *Server) activeAccounts() []store.FleetAccount {
	if len(s.FleetAdmins) == 0 {
		return nil
	}
	accts, err := s.Store.FleetAccountsInState(store.AccountActive)
	if err != nil {
		log.Printf("fleet relay: read accounts: %v", err)
		return nil
	}
	return accts
}

// shortNode is the machine as claude-fleet names it: the roster hostname's
// first label ("m4" for "m4.local").
func shortNode(hostname string) string {
	if i := strings.IndexByte(hostname, '.'); i > 0 {
		return hostname[:i]
	}
	return hostname
}

// acceptRelay is a node handing the hub one relay. It answers the sender at
// once — TypeAck when the relay is stored (or was already), TypeError when it
// is refused for good — and then pushes it on.
func (s *Server) acceptRelay(ctx context.Context, conn *websocket.Conn, ep store.Endpoint, m control.Message) {
	r, err := s.checkRelay(ep, m)
	if err != nil {
		e := errorObject(err)
		_ = s.Store.FleetAudit("node:"+ep.ID, "relay", "", "refused:"+e["code"], "", time.Now())
		refuse(ctx, conn, m.OpID, e["code"], e["message"])
		return
	}
	inserted, err := s.Store.InsertFleetRelay(r)
	if err != nil {
		// Not stored: the sender keeps it and sends it again. An error
		// frame would make it drop the relay for good, so say nothing.
		log.Printf("fleet relay %s: store: %v", r.ID, err)
		return
	}
	if inserted {
		_ = s.Store.FleetAudit("node:"+ep.ID, "relay:"+r.Kind, fleetOf(r.ToWID), "stored", r.ID, time.Now())
	}
	ack := control.Message{Type: control.TypeAck, OpID: m.OpID, Proto: control.Proto}
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	_ = wsjson.Write(wctx, conn, ack)
	cancel()
	go s.dispatchRelays(r.TargetEndpoint)
}

func fleetOf(wid string) string {
	fid, _, _ := fleetid.ParseWorkerID(wid)
	return fid
}

// checkRelay validates one node relay and resolves its target.
func (s *Server) checkRelay(ep store.Endpoint, m control.Message) (store.FleetRelay, error) {
	var in control.Relay
	if err := json.Unmarshal(m.Payload, &in); err != nil {
		return store.FleetRelay{}, fault(control.CodeBadMessage, "malformed relay")
	}
	switch in.Kind {
	case control.RelayChildReport, control.RelayMessage:
	default:
		return store.FleetRelay{}, fault("INVALID_ARGUMENT", "unknown relay kind "+in.Kind)
	}
	fromFleet, _, err := fleetid.ParseWorkerID(in.From)
	if err != nil {
		return store.FleetRelay{}, fault("INVALID_ARGUMENT", "from: "+fleetid.ErrBadWorkerID.Error())
	}
	toFleet, _, err := fleetid.ParseWorkerID(in.To)
	if err != nil {
		return store.FleetRelay{}, fault("INVALID_ARGUMENT", "to: "+fleetid.ErrBadWorkerID.Error())
	}
	// The id is the sender's idempotency key, scoped to the sending worker:
	// no node can collide with — or pre-empt — another worker's ids.
	if !strings.HasPrefix(in.ID, in.From+"#") || !relaySuffixRE.MatchString(in.ID[len(in.From)+1:]) {
		return store.FleetRelay{}, fault("INVALID_ARGUMENT", "relay id must be <from worker_id>#<1-64 of A-Za-z0-9._->")
	}
	payload := bytes.TrimSpace(in.Payload)
	var obj map[string]json.RawMessage
	if len(payload) > control.MaxRelayPayload || json.Unmarshal(payload, &obj) != nil || obj == nil {
		return store.FleetRelay{}, fault("INVALID_ARGUMENT", "a relay's payload must be one JSON object of at most 16 KiB")
	}
	from, err := s.Store.Fleet(fromFleet)
	if err != nil || from.EndpointID != ep.ID {
		// A node speaks only for its own workers.
		return store.FleetRelay{}, fault("FORBIDDEN", "from names a fleet this node does not report")
	}
	to, err := s.Store.Fleet(toFleet)
	if err != nil || !to.Present {
		return store.FleetRelay{}, fault("NOT_FOUND", "no such fleet on any machine")
	}
	accts := s.activeAccounts()
	if s.relayOwner(ep.ID, from.Hostname, from.OSUser, accts) != s.relayOwner(to.EndpointID, to.Hostname, to.OSUser, accts) {
		return store.FleetRelay{}, fault("NOT_FOUND", "no such fleet on any machine")
	}
	now := time.Now()
	return store.FleetRelay{ID: in.ID, Kind: in.Kind, FromWID: in.From, ToWID: in.To, FromEndpoint: ep.ID,
		TargetEndpoint: to.EndpointID, Payload: string(payload), Created: now, Updated: now}, nil
}

func (s *Server) relayLock(endpointID string) *sync.Mutex {
	l, _ := s.relayLocks.LoadOrStore(endpointID, &sync.Mutex{})
	return l.(*sync.Mutex)
}

// dispatchRelays pushes every pending relay for endpointID down its channel,
// except one pushed less than relayResendAfter ago. Without an open,
// relay-capable channel it does nothing: the relays wait for the next hello.
func (s *Server) dispatchRelays(endpointID string) {
	l := s.relayLock(endpointID)
	if !l.TryLock() {
		return // another trigger is pushing this node's relays right now
	}
	defer l.Unlock()
	now := time.Now()
	if last := s.relayExpiredAt.Load(); now.UnixNano()-last > int64(time.Minute) &&
		s.relayExpiredAt.CompareAndSwap(last, now.UnixNano()) {
		if n, err := s.Store.ExpireFleetRelays(relayTTL, now); err == nil && n > 0 {
			log.Printf("fleet relay: %d expired undelivered after %s", n, relayTTL)
		}
	}
	c := s.nodes.get(endpointID)
	if c == nil || !c.canRelay {
		return
	}
	rels, err := s.Store.PendingFleetRelays(endpointID)
	if err != nil {
		log.Printf("fleet relay: read pending for %s: %v", endpointID, err)
		return
	}
	nodeOf := map[string]string{}
	for _, r := range rels {
		if !r.SentAt.IsZero() && now.Sub(r.SentAt) < relayResendAfter {
			continue
		}
		fid := fleetOf(r.FromWID)
		if _, ok := nodeOf[fid]; !ok {
			if f, err := s.Store.Fleet(fid); err == nil {
				nodeOf[fid] = shortNode(f.Hostname)
			}
		}
		msg, err := control.New(control.TypeRelay, control.Relay{ID: r.ID, Kind: r.Kind, From: r.FromWID,
			To: r.ToWID, Payload: json.RawMessage(r.Payload), FromNode: nodeOf[fid]})
		if err != nil {
			continue
		}
		msg.OpID = r.ID
		wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err = s.SendNodeWrite(wctx, endpointID, msg)
		cancel()
		if err != nil {
			return // the channel is gone; the next hello resumes
		}
		if err := s.Store.MarkFleetRelaySent(r.ID, now); err != nil {
			log.Printf("fleet relay %s: mark sent: %v", r.ID, err)
		}
	}
}

// relayResult records a target node's answer to a pushed relay.
func (s *Server) relayResult(endpointID string, m control.Message) {
	var res control.RelayResult
	if json.Unmarshal(m.Payload, &res) != nil || res.ID == "" {
		return
	}
	r, err := s.Store.FleetRelay(res.ID)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			log.Printf("fleet relay %s: read: %v", res.ID, err)
		}
		return
	}
	if r.TargetEndpoint != endpointID {
		return // only the node it was sent to may settle it
	}
	status := store.RelayFailed
	switch {
	case res.OK:
		status = store.RelayDelivered
	case res.Retry:
		return // stays pending; pushed again after relayResendAfter
	}
	detail := res.Detail
	if len(detail) > 500 {
		detail = detail[:500]
	}
	if err := s.Store.FinishFleetRelay(r.ID, status, detail, time.Now()); err != nil {
		log.Printf("fleet relay %s: record %s: %v", r.ID, status, err)
		return
	}
	_ = s.Store.FleetAudit("node:"+endpointID, "relay:"+r.Kind, fleetOf(r.ToWID), status, r.ID, time.Now())
}

// workerMap is every worker the owner of endpointID has on any machine.
func (s *Server) workerMap(endpointID, hostname, osUser string, now time.Time) []control.WorkerLoc {
	rows, err := s.Store.Fleets()
	if err != nil {
		return nil
	}
	accts := s.activeAccounts()
	owner := s.relayOwner(endpointID, hostname, osUser, accts)
	avail := s.nodeAvailability(now)
	out := []control.WorkerLoc{}
	for _, r := range rows {
		if !r.Present || s.relayOwner(r.EndpointID, r.Hostname, r.OSUser, accts) != owner {
			continue
		}
		var ws []struct {
			WorkerID  string  `json:"worker_id"`
			OriginWID *string `json:"origin_wid"`
		}
		if json.Unmarshal([]byte(r.WorkersJSON), &ws) != nil {
			continue
		}
		node := shortNode(r.Hostname)
		if avail[r.EndpointID] == "lost" {
			// Last known, marked: claude-fleet routes a report there (it
			// waits on the hub) but never counts it as a live child.
			node += ":lost"
		}
		for _, w := range ws {
			if fid, _, err := fleetid.ParseWorkerID(w.WorkerID); err != nil || fid != r.FleetID {
				continue // an id that does not belong to its fleet is not routable
			}
			loc := control.WorkerLoc{WorkerID: w.WorkerID, Node: node}
			if w.OriginWID != nil {
				if _, _, err := fleetid.ParseWorkerID(*w.OriginWID); err == nil {
					loc.OriginWID = *w.OriginWID
				}
			}
			out = append(out, loc)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].WorkerID < out[j].WorkerID })
	return out
}

// pushWorkers sends the node its owner's worker map, at most once per
// workersPushEvery.
func (s *Server) pushWorkers(ep store.Endpoint, nc *nodeConn) {
	if !nc.canRelay {
		return
	}
	now := time.Now()
	last := nc.workersAt.Load()
	if last != 0 && now.Sub(time.Unix(0, last)) < workersPushEvery {
		return
	}
	if !nc.workersAt.CompareAndSwap(last, now.UnixNano()) {
		return
	}
	msg, err := control.New(control.TypeWorkers, control.Workers{Rows: s.workerMap(ep.ID, nc.hostname(), ep.OSUser, now)})
	if err != nil {
		return
	}
	wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = s.SendNodeWrite(wctx, ep.ID, msg)
}
