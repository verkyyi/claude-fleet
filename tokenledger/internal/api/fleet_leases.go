package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Issue leases (claude-fleet#1422, EPIC #1419 C3): "the same issue is never
// opened on two machines at once".
//
// dash-issue-session.sh asks POST /v1/node/lease for (repo, issue) before its
// GitHub claim check; only the node granted the lease opens the session, and
// the loser is told which node holds it. The call authenticates with the
// node's own enrollment token, like the control channel — the same credential
// the agent already holds, and a lease can only be taken for a fleet that this
// endpoint's heartbeats registered.
//
// Renewal needs no call at all: the agent's heartbeat already lists the
// login's sessions, so recordFleets renews every lease a beat shows alive and
// releases the ones whose session it no longer shows (store.RenewLeases). A
// node that goes silent stops renewing, and its leases run out leaseLostTTL
// after the last beat that saw them — released, never re-dispatched.

// leaseLostTTL is how long a lease outlives its holder's last sighting: the
// 2026-10-03 decision (EPIC #1419 发起人拍板 2) — 30 minutes.
const leaseLostTTL = 30 * time.Minute

// leaseStartGrace is how long a fresh lease waits for its first sighting: the
// window is opened after the grant, and the next heartbeat is seconds behind.
// A spawn that dies before its window exists frees the issue after this.
const leaseStartGrace = 5 * time.Minute

// leaseKeyRE is the key half of a lease's worker_id: issue-<N>, optionally
// repo-qualified (<slug>:issue-<N>) in a multi-repo fleet.
var leaseKeyRE = regexp.MustCompile(`^(?:[A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?issue-([1-9][0-9]{0,9})$`)

// leaseRepoRE is owner/name.
var leaseRepoRE = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

func (s *Server) leaseClock() time.Time {
	if s.leaseNow != nil {
		return s.leaseNow()
	}
	return time.Now()
}

// nodeLabel is how a holder is named to the node that lost: the machine's
// first hostname label ("m5" for "m5.local").
func nodeLabel(hostname string) string {
	if i := strings.IndexByte(hostname, '.'); i > 0 {
		return hostname[:i]
	}
	return hostname
}

// LeaseView is a lease as /v1/node/lease reports it.
type LeaseView struct {
	Node      string    `json:"node"`
	Hostname  string    `json:"hostname"`
	OSUser    string    `json:"os_user"`
	WorkerID  string    `json:"worker_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

func leaseView(l store.Lease) *LeaseView {
	return &LeaseView{Node: nodeLabel(l.Hostname), Hostname: l.Hostname, OSUser: l.OSUser,
		WorkerID: l.WorkerID, ExpiresAt: l.ExpiresAt}
}

// handleNodeLease serves POST /v1/node/lease:
//
//	{"action": "acquire", "repo": "o/r", "issue": 12, "worker_id": "<fleet>/issue-12", "force": false}
//	{"action": "release", "repo": "o/r", "issue": 12, "worker_id": "<fleet>/issue-12"}
//
// acquire answers 200 {"granted": true, "lease": …} or 409 {"granted": false,
// "holder": …}; a forced grant that displaced a live holder adds "displaced".
// release answers 200 {"released": bool}.
func (s *Server) handleNodeLease(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
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
	var req struct {
		Action   string `json:"action"`
		Repo     string `json:"repo"`
		Issue    int    `json:"issue"`
		WorkerID string `json:"worker_id"`
		Force    bool   `json:"force"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	if !leaseRepoRE.MatchString(req.Repo) || req.Issue <= 0 {
		httpError(w, http.StatusBadRequest, "repo must be owner/name and issue a positive number")
		return
	}
	fleetID, key, err := fleetid.ParseWorkerID(req.WorkerID)
	m := leaseKeyRE.FindStringSubmatch(key)
	if err != nil || m == nil || m[1] != strconv.Itoa(req.Issue) {
		httpError(w, http.StatusBadRequest, "worker_id must be <fleet UUID>/issue-<issue> (or <slug>:issue-<issue>)")
		return
	}
	// Only a fleet this very endpoint reports may take a lease: one node
	// cannot hold an issue in another node's name.
	fl, err := s.Store.Fleet(fleetID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && fl.EndpointID != ep.ID) {
		httpError(w, http.StatusForbidden, "fleet "+fleetID+" is not registered to this node (has its heartbeat reached the hub?)")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	actor := "node:" + ep.OSUser + "@" + ep.Hostname
	now := s.leaseClock()
	w.Header().Set("Cache-Control", "no-store")

	switch req.Action {
	case "release":
		ok, err := s.Store.ReleaseLease(req.Repo, req.Issue, req.WorkerID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.leaseAudit(actor, "lease_release", fleetID, map[bool]string{true: "OK", false: "NOT_HELD"}[ok], now)
		writeJSON(w, http.StatusOK, map[string]any{"released": ok})
	case "acquire":
		host := fl.Hostname
		if host == "" {
			host = ep.Hostname
		}
		user := fl.OSUser
		if user == "" {
			user = ep.OSUser
		}
		granted, l, displaced, err := s.Store.AcquireLease(store.LeaseClaim{Repo: req.Repo, Issue: req.Issue,
			WorkerID: req.WorkerID, FleetID: fleetID, EndpointID: ep.ID, Hostname: host, OSUser: user,
			Force: req.Force}, leaseStartGrace, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !granted {
			s.leaseAudit(actor, "lease_acquire", fleetID, "HELD by "+l.WorkerID+" on "+nodeLabel(l.Hostname), now)
			writeJSON(w, http.StatusConflict, map[string]any{"granted": false, "holder": leaseView(l)})
			return
		}
		out := map[string]any{"granted": true, "lease": leaseView(l)}
		if displaced != nil {
			// --force is the escape hatch past a stale lease; the takeover
			// is on the record, naming whom it displaced.
			log.Printf("lease %s#%d: %s took it by force from %s on %s", l.Repo, l.Issue, req.WorkerID,
				displaced.WorkerID, displaced.Hostname)
			s.leaseAudit(actor, "lease_force", fleetID, "FORCED from "+displaced.WorkerID+" on "+nodeLabel(displaced.Hostname), now)
			out["displaced"] = leaseView(*displaced)
		} else {
			s.leaseAudit(actor, "lease_acquire", fleetID, "OK", now)
		}
		writeJSON(w, http.StatusOK, out)
	default:
		httpError(w, http.StatusBadRequest, `action must be "acquire" or "release"`)
	}
}

func (s *Server) leaseAudit(actor, action, fleetID, outcome string, at time.Time) {
	if err := s.Store.FleetAudit(actor, action, fleetID, outcome, "", at); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}

// renewLeases feeds one heartbeat's sessions to the lease table. reports are
// the fleets the beat carried that the registry accepted; a fleet whose status
// read failed (state "unknown") is left out of readFleets, so its leases are
// neither renewed nor released on this beat.
//
// reconnect marks a connection's first beat (claude-fleet#1630): its sessions
// are also checked against leases other workers hold, before renewing.
func (s *Server) renewLeases(ep store.Endpoint, host, user string, reports []store.FleetReport, rejected []string, reconnect bool, at time.Time) {
	bad := map[string]bool{}
	for _, id := range rejected {
		bad[id] = true
	}
	read := map[string]bool{}
	var sessions []store.LeaseSession
	for _, f := range reports {
		if bad[f.FleetID] || f.State == "unknown" {
			continue
		}
		ws, ok := parseWorkerSessions(f.FleetID, f.Repo, f.WorkersJSON)
		if !ok {
			continue
		}
		read[f.FleetID] = true
		sessions = append(sessions, ws...)
	}
	if len(read) == 0 {
		return
	}
	if reconnect {
		s.checkLeaseConflicts(ep, host, user, sessions, at)
	}
	if _, released, err := s.Store.RenewLeases(ep.ID, read, sessions, leaseLostTTL, at); err != nil {
		log.Printf("node %s: renew leases: %v", ep.ID, err)
	} else if released > 0 {
		log.Printf("node %s: released %d lease(s) whose session ended", ep.ID, released)
	}
}
