package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Back to the last home session (claude-fleet#2564, EPIC #2563 C1).
//
// A `home` place (bin/fleet-client-place.sh `- home`: a no-repo scratch with
// home=true) first asks whether this person already has a CURRENT home session
// for that agent — one they never /exit-ed. If its fleet's last inventory still
// lists it and not as exited, the answer is
//
//	RESUME <machine> <worker_id>\t<reason>
//
// (exit 0, state "resume") and nothing is placed: the client opens that one
// (fleet-shell.sh solo), from any computer of theirs. Otherwise — no current,
// its machine lost, its window gone, its agent /exit-ed (the wrapper's recovery
// page, @claude_state=exited) — the start is placed as before and becomes the
// current one. `new` (fleet claude --new) skips the question and replaces the
// current one. A detach (⌃D), a closed terminal or a dropped network leaves the
// session running and current.
//
// The check is the hub's own heartbeat registry, never the stored row: a row
// whose session the inventory cannot vouch for is no current at all, so a dead
// one is never handed back. One lock per (person, agent) holds two computers'
// first `fleet claude` at once to ONE start: the later one waits and resumes the
// earlier's. A start still on its way (pending) is answered for the later ask
// too — both clients end on the same session.

// homeInventoryLag is how long a just-started home session is taken on trust
// while its fleet's inventory has not been read since it started.
const homeInventoryLag = 2 * time.Minute

var homeLocks sync.Map // actor + "\x00" + agent → *sync.Mutex

func homeLock(actor, agent string) func() {
	v, _ := homeLocks.LoadOrStore(actor+"\x00"+agent, &sync.Mutex{})
	mu := v.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// homeActor is whose current home session a client's ask reads: the person,
// and a test identity's lease (#1931) its own — a test never resumes the
// person's session, nor leaves one for them.
func homeActor(p fleetPrincipal, leaseKey string) string {
	if strings.HasSuffix(leaseKey, clientTestSlot) {
		return p.Actor + clientTestSlot
	}
	return p.Actor
}

// homeLive says whether c's session is still there and not /exit-ed, by its
// fleet's last inventory; f is that fleet.
func (s *Server) homeLive(p fleetPrincipal, c store.HomeCurrent, now time.Time) (store.FleetRow, bool) {
	f, err := s.Store.Fleet(c.FleetID)
	if err != nil || !f.Present || !p.sees(f.Hostname, f.OSUser) {
		return f, false
	}
	if a := s.nodeAvailability(now)[f.EndpointID]; a == "" || a == "lost" {
		return f, false
	}
	var ws []struct {
		WorkerID string  `json:"worker_id"`
		Identity *string `json:"identity"`
		State    string  `json:"state"`
	}
	if json.Unmarshal([]byte(f.WorkersJSON), &ws) != nil {
		return f, false
	}
	for _, w := range ws {
		if w.WorkerID == c.WorkerID || (w.Identity != nil && fleetid.IsUUID(*w.Identity) && f.FleetID+"/"+*w.Identity == c.WorkerID) {
			return f, w.State != "exited"
		}
	}
	// Not listed: an inventory read before the start is no verdict yet.
	return f, f.ObservedAt.Before(c.StartedAt) && now.Sub(c.StartedAt) < homeInventoryLag
}

// alsoOpen is the other devices of this person that have c's session open:
// a live lease other than this one looking at it, or the lease that opened it
// still held and looking at nothing else.
func (t *clientLeaseTable) alsoOpen(key, lease string, c store.HomeCurrent, now time.Time) []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	out := []string{}
	for _, l := range t.liveLocked(key, now) {
		if l.ID == lease {
			continue
		}
		if l.Viewing == c.WorkerID || (l.ID == c.Lease && l.Viewing == "") {
			d := l.Device
			if d == "" {
				d = "另一台电脑"
			}
			out = append(out, d)
		}
	}
	return out
}

// deviceOf is the device a lease says it is, "" when it is not held.
func (t *clientLeaseTable) deviceOf(key, lease string) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	if l := t.holdsLocked(key, lease); l != nil {
		return l.Device
	}
	return ""
}

// homeResume answers a home ask from the current session when there is one —
// true when it wrote the answer. It runs under homeLock.
func (s *Server) homeResume(w http.ResponseWriter, r *http.Request, p fleetPrincipal, leaseKey, lease, actor, agent string,
	wait time.Duration, now time.Time) bool {
	c, err := s.Store.FleetHomeCurrent(actor, agent)
	if err != nil {
		return false
	}
	if c.WorkerID == "" && c.OperationID != "" {
		o, err := s.Store.FleetOperation(c.OperationID)
		if err != nil || o.Actor != p.Actor {
			_ = s.Store.ClearFleetHomeCurrent(c)
			return false
		}
		var pl Placement
		if o.Placement != "" {
			_ = json.Unmarshal([]byte(o.Placement), &pl)
		}
		if pl.Machine == "" {
			pl.Machine = c.Machine
		}
		if pl.FleetID == "" {
			pl.FleetID = o.FleetID
		}
		if !operationFinal(o.Status) {
			// The earlier ask's start is still on its way: this ask waits on
			// the same one.
			out, _ := s.clientPlaceAnswer(r, operationView(o), &pl, wait)
			s.homeRecord(actor, agent, c.Lease, c.Device, out, pl, now)
			s.leaseAudit(p.Actor, "client_place", "home", "SAME "+out.Machine+" "+out.State+" "+c.OperationID, now)
			writeJSON(w, http.StatusOK, out)
			return true
		}
		oc := outcomeOf(operationView(o), s.nodeMachineLabel(pl.Machine))
		if oc.State != "done" || oc.WorkerID == "" {
			_ = s.Store.ClearFleetHomeCurrent(c)
			return false
		}
		c.WorkerID, c.OperationID = oc.WorkerID, ""
		_ = s.Store.PutFleetHomeCurrent(c)
	}
	f, live := s.homeLive(p, c, now)
	if !live {
		_ = s.Store.ClearFleetHomeCurrent(c)
		return false
	}
	m := s.nodeMachineLabel(f.Hostname)
	out := ClientPlaceResponse{Line: "RESUME " + m + " " + c.WorkerID + "\t回到你上一次的会话（" + m + "）",
		Exit: 0, State: "resume", Machine: m, WorkerID: c.WorkerID, Login: f.OSUser,
		AlsoOpen: s.clientLeases.alsoOpen(leaseKey, lease, c, now)}
	s.leaseAudit(p.Actor, "client_place", "home", "RESUME "+m+" "+c.WorkerID, now)
	writeJSON(w, http.StatusOK, out)
	return true
}

// homeRecord makes a home start's answer the current session: done with its
// worker_id, or still pending on its operation. Anything else leaves it be.
func (s *Server) homeRecord(actor, agent, lease, device string, out ClientPlaceResponse, pl Placement, now time.Time) {
	c := store.HomeCurrent{Actor: actor, Agent: agent, FleetID: pl.FleetID, Machine: pl.Machine,
		Lease: lease, Device: device, StartedAt: now}
	switch {
	case out.State == "done" && out.WorkerID != "":
		c.WorkerID = out.WorkerID
	case out.State == "pending" && out.OperationID != "":
		c.OperationID = out.OperationID
	default:
		return
	}
	if c.FleetID == "" {
		c.FleetID = fleetOf(c.WorkerID)
	}
	_ = s.Store.PutFleetHomeCurrent(c)
}
