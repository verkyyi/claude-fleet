package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// POST /v1/node/place — a node asks where a new session should run
// (claude-fleet#1425, EPIC #1419 C6).
//
// claude-fleet's dash-issue-session.sh calls it (through `ccquota place`)
// after it took the issue's lease and before it opens anything: the hub runs
// pickNode — the same placement worker_start(node=auto) uses — over the
// machines of the person this login belongs to. When the answer is the
// asking fleet, the node opens the session itself, as it always has; when it
// is another machine, the hub hands that machine's fleet the lease and sends
// it the start as a journalled worker_start, carrying the parent's worker_id
// (origin_wid) so the new window records whom to report to.
//
// Authenticated by the node's own enrollment token, like /v1/node/lease, and
// only for a fleet that endpoint's heartbeats registered: one node cannot
// place work in another node's name. Who the caller is for placement and the
// grant: the person whose ACTIVE fleet account is this (machine, login); a
// login no person owns places among the logins of the same name — the
// operator's own accounts across machines.

// placeRequest is the node's question.
type placeRequest struct {
	Repo string `json:"repo"`
	// Issue and WorkerID are the asking fleet's worker (the lease's holder).
	Issue    int    `json:"issue"`
	WorkerID string `json:"worker_id"`
	// Node is "auto" (default) or one roster machine.
	Node string `json:"node"`
	// OriginWID is the worker that asked for this one, if any.
	OriginWID string `json:"origin_wid"`
	Agent     string `json:"agent"`
	Idem      string `json:"idempotency_key"`
}

func (s *Server) handleNodePlace(w http.ResponseWriter, r *http.Request) {
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
	var req placeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	if req.Node == "" {
		req.Node = "auto"
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
	if req.Node != "auto" && !nodeNameRE.MatchString(req.Node) {
		httpError(w, http.StatusBadRequest, "node must be auto or a machine name from the roster")
		return
	}
	fl, err := s.Store.Fleet(fleetID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && fl.EndpointID != ep.ID) {
		httpError(w, http.StatusForbidden, "fleet "+fleetID+" is not registered to this node (has its heartbeat reached the hub?)")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	p, err := s.nodePrincipal(ep, fl)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	w.Header().Set("Cache-Control", "no-store")

	pl, err := s.pickNode(p, req.Repo, req.Node, now)
	if err != nil {
		s.leaseAudit(p.Actor, "place", fleetID, errorObject(err)["code"], now)
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	if pl.FleetID == fleetID {
		s.leaseAudit(p.Actor, "place", fleetID, "LOCAL "+nodeLabel(pl.Machine), now)
		writeJSON(w, http.StatusOK, map[string]any{"local": true, "placement": pl})
		return
	}

	// Another machine. Its fleet takes the lease first, so the spawn that
	// arrives there finds it already its own (AcquireLease's same-fleet
	// rule) and nobody else can take the issue in between.
	target, err := s.Store.Fleet(pl.FleetID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	tclaim := store.LeaseClaim{Repo: req.Repo, Issue: req.Issue, WorkerID: pl.FleetID + "/" + targetKey(key, target, req.Repo),
		FleetID: pl.FleetID, EndpointID: target.EndpointID, Hostname: target.Hostname, OSUser: target.OSUser}
	moved, err := s.Store.HandOverLease(req.Repo, req.Issue, req.WorkerID, tclaim, leaseStartGrace, now)
	if err == nil && !moved {
		// The asker held no live lease (its own acquire could not reach
		// the hub): take it for the target the ordinary way.
		var held store.Lease
		if moved, held, _, err = s.Store.AcquireLease(tclaim, leaseStartGrace, now); err == nil && !moved {
			s.leaseAudit(p.Actor, "place", fleetID, "HELD by "+held.WorkerID+" on "+nodeLabel(held.Hostname), now)
			writeJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "ALREADY_CLAIMED",
				"message": "#" + strconv.Itoa(req.Issue) + " is leased to " + nodeLabel(held.Hostname)},
				"holder": leaseView(held), "placement": pl})
			return
		}
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	giveBack := func() {
		mine := store.LeaseClaim{Repo: req.Repo, Issue: req.Issue, WorkerID: req.WorkerID, FleetID: fleetID,
			EndpointID: ep.ID, Hostname: fl.Hostname, OSUser: fl.OSUser}
		if _, err := s.Store.HandOverLease(req.Repo, req.Issue, tclaim.WorkerID, mine, leaseStartGrace, time.Now()); err != nil {
			s.leaseAudit(p.Actor, "place", fleetID, "lease give-back failed: "+err.Error(), time.Now())
		}
	}

	idem := req.Idem
	if idem == "" {
		idem = "place-" + fleetID[:8] + "-" + strconv.Itoa(req.Issue) + "-" + strconv.FormatInt(now.UnixNano(), 36)
	}
	args := map[string]any{"fleet_id": pl.FleetID, "issue": float64(req.Issue), "repo": req.Repo,
		"node": req.Node, "idempotency_key": idem}
	if req.Agent != "" {
		args["agent"] = req.Agent
	}
	if req.OriginWID != "" {
		args["origin_wid"] = req.OriginWID
	}
	op, err := s.submitWrite(r.Context(), p, "worker_start", args, &pl)
	if err != nil {
		giveBack()
		s.leaseAudit(p.Actor, "place", fleetID, "REMOTE "+nodeLabel(pl.Machine)+" refused: "+errorObject(err)["code"], now)
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	if op["status"] == "failed" {
		// The node refused before running anything: the issue is the
		// asker's again, so its fallback can still open it.
		giveBack()
	}
	s.leaseAudit(p.Actor, "place", fleetID, "REMOTE "+nodeLabel(pl.Machine)+" "+asString(op["status"]), now)
	writeJSON(w, http.StatusOK, map[string]any{"local": false, "placement": pl, "operation": op})
}

// nodePrincipal is who a node's placement acts for: the person who owns this
// login, else the logins of the same name on every machine.
func (s *Server) nodePrincipal(ep *store.Endpoint, fl store.FleetRow) (fleetPrincipal, error) {
	host, user := fl.Hostname, fl.OSUser
	if host == "" {
		host = ep.Hostname
	}
	if user == "" {
		user = ep.OSUser
	}
	actor := "node:" + user + "@" + host
	person, err := s.Store.PrincipalForLogin(host, user)
	switch {
	case err == nil && person != "":
		scope, err := s.scopeFor(person)
		if err != nil {
			return fleetPrincipal{}, err
		}
		return fleetPrincipal{Actor: actor, Person: person, scope: scope}, nil
	case err != nil && !errors.Is(err, store.ErrNoPrincipal):
		return fleetPrincipal{}, err
	}
	return fleetPrincipal{Actor: actor, scope: func(_, u string) bool { return u == user }}, nil
}

// placeStatus is the HTTP status of a placement fault, as /v1/fleet/ maps it.
func placeStatus(err error) int {
	code := errorObject(err)["code"]
	if st := map[string]int{"INVALID_ARGUMENT": 400, "NOT_FOUND": 404, "FORBIDDEN": 403,
		"UNAVAILABLE": 503, "TIMEOUT": 504, control.CodeProtoMismatch: 409,
		"IDEMPOTENCY_CONFLICT": 409, "AT_CAPACITY": 429, "NO_ELIGIBLE_NODE": 503}[code]; st != 0 {
		return st
	}
	if code == "INTERNAL" {
		return http.StatusInternalServerError
	}
	return http.StatusBadGateway
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}
