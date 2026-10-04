package api

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Moving a session between machines through the hub (claude-fleet#1426,
// EPIC #1419 C7).
//
// fleet-move.sh --via hub moves a live session from the machine it runs on to
// another of the same person's machines without the two ever talking: the
// source pushes the branch to GitHub, stops the agent, and then
//
//  1. POST /v1/node/move/bundle — uploads the transcript (a tar of
//     `<sid>.jsonl` and its sidecar dir) and gets a bundle id back;
//  2. POST /v1/node/move {"action":"move", …} — the hub picks the target fleet
//     (pickNode, restricted to the machine asked for), hands it the issue's
//     lease (claude-fleet#1422) so no third machine can take the issue in
//     between, and sends it a journalled worker_move_in naming the bundle;
//  3. the target's agent downloads the bundle (GET /v1/node/move/bundle/<id>,
//     its own token — only the move's target may) and hands the write to
//     claude-fleet, which lands the branch in a fresh worktree, unpacks the
//     transcript, opens a window resuming it and checks a live agent appears;
//  4. POST /v1/node/move {"action":"status", "operation_id": …} — the source
//     waits for the outcome, and only on succeeded closes its own window.
//
// A failed move gives the lease back to the source's worker, so the session
// can be resumed where it was. Everything authenticates with the node's own
// enrollment token, like /v1/node/lease and /v1/node/place, and a node can
// only move a worker of a fleet its own heartbeats registered.

// moveBundleMax bounds one uploaded transcript bundle. A long session's
// transcript is tens of MiB; the variable lets tests shrink it.
var moveBundleMax int64 = 256 << 20

// moveWriteWait is how long the hub waits for the target to take a
// worker_move_in: its agent downloads the bundle first.
var moveWriteWait = 120 * time.Second

var (
	moveIDRE     = regexp.MustCompile(`^[0-9a-f]{32}$`)
	moveKeyRE    = regexp.MustCompile(`^(?:[A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?(issue|scratch)-([1-9][0-9]{0,9})$`)
	moveBranchRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$`)
	moveSIDRE    = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	moveStateRE  = regexp.MustCompile(`^[a-z]{1,16}$`)
	moveOriginRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:#/-]{0,255}$`)
	moveHandleRE = regexp.MustCompile(`^[a-z][1-9]$`)
)

// moveBusyStates are the window states a move refuses: an agent mid-turn
// would lose the turn (EPIC #1419 C7 — only an idle session moves).
var moveBusyStates = map[string]bool{"working": true}

// parseMoveIn validates worker_move_in's arguments — exactly
// fleet_hub_common.validate_write's rule — and returns the target fleet and
// the params the node is sent.
func parseMoveIn(args map[string]any) (string, map[string]any, error) {
	if err := checkFields(args, []string{"fleet_id", "move_id", "worker_key", "repo", "branch", "sid", "name", "idempotency_key"},
		"pushed", "raw", "state", "issue", "origin", "origin_wid", "handle", "from_node"); err != nil {
		return "", nil, err
	}
	p := map[string]any{}
	str := func(k string, re *regexp.Regexp, what string, required bool) error {
		v, err := argString(args, k)
		if err != nil || (v == "" && required) || (v != "" && re != nil && !re.MatchString(v)) {
			return fault("INVALID_ARGUMENT", k+" must be "+what)
		}
		if v != "" {
			p[k] = v
		}
		return nil
	}
	fid, _ := args["fleet_id"].(string)
	for _, c := range []struct {
		k, what string
		re      *regexp.Regexp
		req     bool
	}{
		{"move_id", "32 lowercase hex digits", moveIDRE, true},
		{"worker_key", "issue-<N> or scratch-<N> (optionally <slug>:-qualified)", moveKeyRE, true},
		{"branch", "a branch name", moveBranchRE, true},
		{"sid", "a session UUID", moveSIDRE, true},
		{"state", "a window state", moveStateRE, false},
		{"origin", "a worker key", moveOriginRE, false},
		{"handle", "a window handle", moveHandleRE, false},
		{"from_node", "a machine name", nodeNameRE, false},
	} {
		if err := str(c.k, c.re, c.what, c.req); err != nil {
			return "", nil, err
		}
	}
	if b, _ := p["branch"].(string); strings.Contains(b, "..") || strings.HasSuffix(b, ".lock") || strings.HasSuffix(b, "/") {
		return "", nil, fault("INVALID_ARGUMENT", "branch must be a branch name")
	}
	if s, _ := p["state"].(string); moveBusyStates[s] {
		return "", nil, fault("INVALID_STATE", "a working session is never moved; wait until it is idle")
	}
	repo, err := checkRepo(args)
	if err != nil || repo == "" {
		return "", nil, fault("INVALID_ARGUMENT", "repo must be owner/name")
	}
	p["repo"] = repo
	name, _ := args["name"].(string)
	if !moveName(name) {
		return "", nil, fault("INVALID_ARGUMENT", "name must be 1-80 printable characters")
	}
	p["name"] = name
	if v, ok := args["pushed"]; ok {
		b, isBool := v.(bool)
		if !isBool {
			return "", nil, fault("INVALID_ARGUMENT", "pushed must be true or false")
		}
		p["pushed"] = b
	}
	if v, ok := args["raw"]; ok {
		n, err := argInt(v, "raw", 0, 1)
		if err != nil {
			return "", nil, err
		}
		p["raw"] = n
	}
	if v, ok := args["issue"]; ok {
		n, err := argInt(v, "issue", 1, 2147483647)
		if err != nil {
			return "", nil, err
		}
		p["issue"] = n
	}
	if err := str("origin_wid", nil, "", false); err != nil {
		return "", nil, err
	}
	if o, _ := p["origin_wid"].(string); o != "" {
		if _, _, perr := fleetid.ParseWorkerID(o); perr != nil {
			return "", nil, fault("INVALID_ARGUMENT", "origin_wid must be a worker_id (<fleet UUID>/<key>)")
		}
	}
	return fid, p, nil
}

// moveName is a window name a tmux argv may carry: 1-80 characters, none a
// control character.
func moveName(s string) bool {
	n := 0
	for _, c := range s {
		if unicode.IsControl(c) {
			return false
		}
		n++
	}
	return n >= 1 && n <= 80
}

// nodeEndpoint authenticates a node request by its enrollment token.
func (s *Server) nodeEndpoint(w http.ResponseWriter, r *http.Request) (*store.Endpoint, bool) {
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return nil, false
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return nil, false
	}
	return ep, true
}

// handleNodeMoveBundle serves POST /v1/node/move/bundle (the source uploads)
// and GET /v1/node/move/bundle/<id> (the move's target downloads).
func (s *Server) handleNodeMoveBundle(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodPost:
		if r.URL.Path != "/v1/node/move/bundle" {
			httpError(w, http.StatusNotFound, "not found")
			return
		}
		now := time.Now()
		_, _ = s.Store.ExpireFleetMoves(store.FleetMoveTTL, now)
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, moveBundleMax))
		if err != nil {
			httpError(w, http.StatusRequestEntityTooLarge, "a bundle is at most "+strconv.FormatInt(moveBundleMax>>20, 10)+" MiB")
			return
		}
		if len(body) == 0 {
			httpError(w, http.StatusBadRequest, "empty bundle")
			return
		}
		sum := sha256.Sum256(body)
		m := store.FleetMove{ID: control.NewOpID(), FromEndpoint: ep.ID, SHA256: hex.EncodeToString(sum[:]),
			Size: int64(len(body)), Created: now}
		if err := s.Store.InsertFleetMoveBundle(m, body); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"bundle_id": m.ID, "sha256": m.SHA256, "size": m.Size})
	case http.MethodGet:
		id := strings.TrimPrefix(r.URL.Path, "/v1/node/move/bundle/")
		if !moveIDRE.MatchString(id) {
			httpError(w, http.StatusNotFound, "no such bundle")
			return
		}
		b, m, err := s.Store.FleetMoveBundle(id, time.Now())
		// Only the endpoint the move was sent to may read it — and to
		// anyone else it does not exist.
		if errors.Is(err, sql.ErrNoRows) || (err == nil && m.TargetEndpoint != ep.ID) {
			httpError(w, http.StatusNotFound, "no such bundle")
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/x-tar")
		w.Header().Set("X-Bundle-Sha256", m.SHA256)
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		_, _ = io.Copy(w, bytes.NewReader(b))
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// moveRequest is POST /v1/node/move's body.
type moveRequest struct {
	Action string `json:"action"` // plan | move | status
	// WorkerID is the moving session's worker_id on the SOURCE fleet.
	WorkerID string `json:"worker_id"`
	Repo     string `json:"repo"`
	// Node is the machine to move to, or auto (plan, --rebalance).
	Node        string `json:"node"`
	Branch      string `json:"branch"`
	Pushed      bool   `json:"pushed"`
	SID         string `json:"sid"`
	Name        string `json:"name"`
	Raw         int    `json:"raw"`
	State       string `json:"state"`
	Origin      string `json:"origin"`
	OriginWID   string `json:"origin_wid"`
	Handle      string `json:"handle"`
	BundleID    string `json:"bundle_id"`
	OperationID string `json:"operation_id"`
	Idem        string `json:"idempotency_key"`
}

// handleNodeMove serves POST /v1/node/move:
//
//	plan   → 200 {"local": bool, "placement": …, "movable": bool}
//	move   → 200 {"placement": …, "operation": …, "to_wid": …}
//	status → 200 {"operation": …}
//
// Faults answer {"error": {code, message}} with placeStatus's mapping, plus
// 409 SAME_MACHINE (the pick is the asking fleet) and 409 ALREADY_CLAIMED.
func (s *Server) handleNodeMove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	var req moveRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	fleetID, key, err := fleetid.ParseWorkerID(req.WorkerID)
	km := moveKeyRE.FindStringSubmatch(key)
	if err != nil || km == nil {
		httpError(w, http.StatusBadRequest, "worker_id must be <fleet UUID>/issue-<N> or /scratch-<N>")
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
	if req.Action == "status" {
		s.moveStatus(w, r, p, req)
		return
	}
	if req.Node == "" {
		req.Node = "auto"
	}
	if !leaseRepoRE.MatchString(req.Repo) {
		httpError(w, http.StatusBadRequest, "repo must be owner/name")
		return
	}
	if req.Node != "auto" && !nodeNameRE.MatchString(req.Node) {
		httpError(w, http.StatusBadRequest, "node must be auto or a machine name from the roster")
		return
	}
	now := time.Now()
	pl, err := s.pickNode(p, req.Repo, req.Node, now)
	if err != nil {
		s.leaseAudit(p.Actor, "move_"+req.Action, fleetID, errorObject(err)["code"], now)
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	local := pl.FleetID == fleetID
	movable := false
	if c := s.nodes.get(endpointOf(pl)); c != nil {
		movable = c.canMove
	}
	switch req.Action {
	case "plan":
		writeJSON(w, http.StatusOK, map[string]any{"local": local, "placement": pl, "movable": movable})
		return
	case "move":
	default:
		httpError(w, http.StatusBadRequest, "action must be plan, move or status")
		return
	}
	if local {
		writeJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "SAME_MACHINE",
			"message": "the session already runs on " + nodeLabel(pl.Machine)}, "placement": pl})
		return
	}
	if !movable {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]string{"code": "UNAVAILABLE",
			"message": nodeLabel(pl.Machine) + "'s agent cannot take a moved session; upgrade ccquota there"}, "placement": pl})
		return
	}
	if !moveIDRE.MatchString(req.BundleID) {
		httpError(w, http.StatusBadRequest, "bundle_id must come from /v1/node/move/bundle")
		return
	}
	mv, err := s.Store.FleetMove(req.BundleID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && mv.FromEndpoint != ep.ID) {
		httpError(w, http.StatusNotFound, "no such bundle")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// The target's row comes first: the key it will know the session by
	// depends on how many repos it hosts (claude-fleet#1512).
	target, err := s.Store.Fleet(pl.FleetID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	key = targetKey(key, target, req.Repo)
	toWID := pl.FleetID + "/" + key
	issue := 0
	if km[1] == "issue" {
		issue, _ = strconv.Atoi(km[2])
	}
	idem := req.Idem
	if idem == "" {
		idem = "move-" + req.BundleID
	}
	args := map[string]any{"fleet_id": pl.FleetID, "move_id": req.BundleID, "worker_key": key, "repo": req.Repo,
		"branch": req.Branch, "pushed": req.Pushed, "sid": req.SID, "name": req.Name, "raw": float64(req.Raw),
		"idempotency_key": idem, "from_node": nodeLabel(fl.Hostname)}
	if issue > 0 {
		args["issue"] = float64(issue)
	}
	for k, v := range map[string]string{"state": req.State, "origin": req.Origin, "origin_wid": req.OriginWID, "handle": req.Handle} {
		if v != "" {
			args[k] = v
		}
	}
	// Refuse a bad request before anything changes hands.
	if _, _, err := parseWrite("worker_move_in", args); err != nil {
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	if err := s.Store.BindFleetMove(req.BundleID, req.WorkerID, toWID, endpointOf(pl), req.Repo, issue); err != nil {
		code := http.StatusInternalServerError
		if errors.Is(err, store.ErrMoveClaimed) {
			code = http.StatusConflict
		}
		httpError(w, code, err.Error())
		return
	}

	// The lease goes first, so no third machine can open the issue between
	// the source letting go and the target's first heartbeat.
	giveBack := func() {}
	if issue > 0 {
		tclaim := store.LeaseClaim{Repo: req.Repo, Issue: issue, WorkerID: toWID, FleetID: pl.FleetID,
			EndpointID: target.EndpointID, Hostname: target.Hostname, OSUser: target.OSUser}
		moved, err := s.Store.HandOverLease(req.Repo, issue, req.WorkerID, tclaim, leaseStartGrace, now)
		if err == nil && !moved {
			var held store.Lease
			var granted bool
			if granted, held, _, err = s.Store.AcquireLease(tclaim, leaseStartGrace, now); err == nil && !granted {
				s.leaseAudit(p.Actor, "move", fleetID, "HELD by "+held.WorkerID+" on "+nodeLabel(held.Hostname), now)
				writeJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "ALREADY_CLAIMED",
					"message": "#" + strconv.Itoa(issue) + " is leased to " + nodeLabel(held.Hostname)},
					"holder": leaseView(held), "placement": pl})
				return
			}
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		giveBack = func() { s.moveGiveBack(p.Actor, mv.ID) }
	}

	op, err := s.submitWrite(r.Context(), p, "worker_move_in", args, &pl)
	if err != nil {
		giveBack()
		_, _ = s.Store.SettleFleetMove(mv.ID, "refused")
		s.leaseAudit(p.Actor, "move", fleetID, "to "+nodeLabel(pl.Machine)+" refused: "+errorObject(err)["code"], now)
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	opID := asString(op["operation_id"])
	_ = s.Store.SetFleetMoveOperation(mv.ID, opID)
	s.settleMove(p.Actor, mv.ID, asString(op["status"]))
	s.leaseAudit(p.Actor, "move", fleetID, "to "+nodeLabel(pl.Machine)+" "+asString(op["status"]), now)
	writeJSON(w, http.StatusOK, map[string]any{"placement": pl, "operation": op, "to_wid": toWID})
}

func endpointOf(pl Placement) string {
	for _, c := range pl.Candidates {
		if c.FleetID == pl.FleetID {
			return c.EndpointID
		}
	}
	return ""
}

// moveStatus is the source waiting on its move's outcome: the operation,
// reconciled with the target while it is not final.
func (s *Server) moveStatus(w http.ResponseWriter, r *http.Request, p fleetPrincipal, req moveRequest) {
	if !fleetid.IsUUID(req.OperationID) {
		httpError(w, http.StatusBadRequest, "operation_id must be a canonical UUID")
		return
	}
	o, err := s.Store.FleetOperation(req.OperationID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && (o.Actor != p.Actor || o.Action != "worker_move_in")) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "NOT_FOUND", "message": "Unknown move for this node"}})
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	view := operationView(o)
	if o.Status != "succeeded" && o.Status != "failed" {
		if rerr := s.reconcileOperation(r.Context(), &o); rerr != nil {
			view = operationView(o)
			view["reconciliation_error"] = errorObject(rerr)
		} else {
			view = operationView(o)
		}
	}
	if mv, err := s.Store.FleetMoveByOperation(o.ID); err == nil {
		s.settleMove(p.Actor, mv.ID, o.Status)
	}
	writeJSON(w, http.StatusOK, map[string]any{"operation": view})
}

// settleMove acts once on a move's final status: a failure gives the lease
// back to the source; either way the bundle is dropped.
func (s *Server) settleMove(actor, moveID, status string) {
	switch status {
	case "succeeded", "failed":
	default:
		return
	}
	settled, err := s.Store.SettleFleetMove(moveID, status)
	if err != nil || !settled {
		return
	}
	if status == "failed" {
		s.moveGiveBack(actor, moveID)
	}
}

// moveGiveBack hands a move's lease back from the target to the source.
func (s *Server) moveGiveBack(actor, moveID string) {
	mv, err := s.Store.FleetMove(moveID)
	if err != nil || mv.Issue == 0 {
		return
	}
	fromFleet, _, _ := fleetid.ParseWorkerID(mv.FromWID)
	src, err := s.Store.Fleet(fromFleet)
	if err != nil {
		return
	}
	mine := store.LeaseClaim{Repo: mv.Repo, Issue: mv.Issue, WorkerID: mv.FromWID, FleetID: fromFleet,
		EndpointID: src.EndpointID, Hostname: src.Hostname, OSUser: src.OSUser}
	if _, err := s.Store.HandOverLease(mv.Repo, mv.Issue, mv.ToWID, mine, leaseStartGrace, time.Now()); err != nil {
		s.leaseAudit(actor, "move", fromFleet, "lease give-back failed: "+err.Error(), time.Now())
	}
}
