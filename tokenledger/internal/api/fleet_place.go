package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
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
	// Kind is what opens: "" / "issue" (a worker on an issue — the lease's
	// holder asks) or "scratch" (claude-fleet#1541: a raw scratch session, which
	// has no issue and takes no lease; its scratch-<N> is minted by the machine
	// that opens it, so the asker names its FLEET, not a worker_id).
	Kind string `json:"kind"`
	// Issue and WorkerID are the asking fleet's worker (the lease's holder).
	Issue    int    `json:"issue"`
	WorkerID string `json:"worker_id"`
	// FleetID is the asking fleet, for a scratch.
	FleetID string `json:"fleet_id"`
	// Name is a scratch's name (optional): the window's label and its unsent
	// first draft, sanitized again by dash-raw-session.sh where it opens.
	Name string `json:"name"`
	// Node is "auto" (default) or one roster machine.
	Node string `json:"node"`
	// OriginWID is the worker that asked for this one, if any.
	OriginWID string `json:"origin_wid"`
	Agent     string `json:"agent"`
	// Reap is when the session may be closed on its own (claude-fleet#1902).
	Reap string `json:"reap"`
	// AccountClass is the kind of subscription the session must run on
	// (claude-fleet#1540): "local" (the opening login's own), "pool" (the
	// hub's leased accounts) or "any" / absent (that fleet's ordinary pick).
	// It travels with a REMOTE start so the choice made on one machine holds
	// on the one that opens it.
	AccountClass string `json:"account_class"`
	Idem         string `json:"idempotency_key"`
	// Wait is how many seconds a REMOTE start is waited on for its outcome
	// (claude-fleet#1586): absent = placeWait, 0 = answer on acceptance.
	Wait *int `json:"wait"`
}

// placeWait is how long a REMOTE start is waited on by default (60 s, the
// EPIC #1645 ruling — claude-fleet#1606), and placeWaitMax the most a node
// may ask for; placePoll is how often the target is asked in between.
// Variables so tests can move them.
var (
	placeWait    = 60 * time.Second
	placeWaitMax = 60 * time.Second
	placePoll    = time.Second
)

// placeOutcome is what became of a REMOTE start (claude-fleet#1586):
// done (a window opened), refused (the target's fleet said no, with the
// spawn's own exit code and refusal line), failed (it never ran — including
// a start that never reached the target, or one it journalled and never
// started within the wait, claude-fleet#1606), or unknown (still running
// when the wait ran out — never read as success). Every outcome but done
// hands the lease back to the asker, whose exit releases it. Exit
// is dash-issue-session.sh's: 0 opened · 1 infrastructure · 2 at capacity ·
// 3 claimed elsewhere.
type placeOutcome struct {
	State  string `json:"state"`
	Exit   *int   `json:"exit,omitempty"`
	Stderr string `json:"stderr1,omitempty"`
	Window string `json:"window,omitempty"`
	// WorkerID is the opened session's worker_id, when the node said it
	// (claude-fleet#1777: the client switches to it).
	WorkerID string `json:"worker_id,omitempty"`
	Node     string `json:"node"`
	// Timing is the node's half of the send's clock (claude-fleet#2238): its
	// operation result's `timing`, passed on as the node wrote it (epoch ms
	// t_accepted / t_window / …). Absent from an older node.
	Timing json.RawMessage `json:"timing,omitempty"`
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
	scratch := false
	switch req.Kind {
	case "", "issue":
	case "scratch":
		scratch = true
	default:
		httpError(w, http.StatusBadRequest, "kind must be issue or scratch")
		return
	}
	if !leaseRepoRE.MatchString(req.Repo) {
		httpError(w, http.StatusBadRequest, "repo must be owner/name")
		return
	}
	var fleetID, key string
	if scratch {
		// A scratch has no issue and no worker_id yet (claude-fleet#1541).
		if req.Issue != 0 || req.WorkerID != "" || !fleetid.IsUUID(req.FleetID) {
			httpError(w, http.StatusBadRequest, "a scratch start names fleet_id (the asking fleet's UUID) and no issue or worker_id")
			return
		}
		if _, err := checkScratchName(req.Name); err != nil {
			httpError(w, http.StatusBadRequest, errorObject(err)["message"])
			return
		}
		fleetID = req.FleetID
	} else {
		if req.Issue <= 0 {
			httpError(w, http.StatusBadRequest, "repo must be owner/name and issue a positive number")
			return
		}
		if req.FleetID != "" || req.Name != "" {
			httpError(w, http.StatusBadRequest, "fleet_id and name belong to a scratch start (kind=scratch)")
			return
		}
		var err error
		fleetID, key, err = fleetid.ParseWorkerID(req.WorkerID)
		m := leaseKeyRE.FindStringSubmatch(key)
		if err != nil || m == nil || m[1] != strconv.Itoa(req.Issue) {
			httpError(w, http.StatusBadRequest, "worker_id must be <fleet UUID>/issue-<issue> (or <slug>:issue-<issue>)")
			return
		}
	}
	if req.Node != "auto" && !nodeNameRE.MatchString(req.Node) {
		httpError(w, http.StatusBadRequest, "node must be auto or a machine name from the roster")
		return
	}
	if !accountClassOK(req.AccountClass) {
		httpError(w, http.StatusBadRequest, "account_class must be local, pool or any")
		return
	}
	if !reapPolicyOK(req.Reap) {
		httpError(w, http.StatusBadRequest, "reap must be merged[:<dur>], done[:<dur>], loop-end, at:<time> or keep")
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

	// A session's own call (claude-fleet#1810): the node vouches for which of
	// its sessions asked. A statement that does not verify is refused (401),
	// never read as the node's own call; one naming a session of another
	// fleet, or a start whose parent is not that session, is NOT_FOUND — a
	// session opens work as itself the parent, nothing else.
	if a := r.Header.Get(workerAssertHeader); a != "" {
		c, err := verifyWorkerAssertion(a, HashToken(tok), now)
		if err != nil {
			s.placeAudit(p, fleetID, "refused:UNAUTHENTICATED", now)
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": errorObject(err)})
			return
		}
		if c.FleetUUID != fleetID || (req.OriginWID != "" && !c.speaksAs(req.OriginWID)) {
			p.Worker = c
			s.placeAudit(p, fleetID, "refused:NOT_FOUND", now)
			writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "NOT_FOUND",
				"message": "no such session on this node"}})
			return
		}
		if req.OriginWID == "" {
			req.OriginWID = c.WorkerID
		}
		p.Worker = c
	}

	pl, err := s.pickNode(p, req.Repo, req.Node, now)
	if err != nil {
		s.placeAudit(p, fleetID, errorObject(err)["code"], now)
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	if pl.FleetID == fleetID {
		s.placeAudit(p, fleetID, "LOCAL "+nodeLabel(pl.Machine), now)
		writeJSON(w, http.StatusOK, map[string]any{"local": true, "placement": pl})
		return
	}

	// Another machine. Its fleet takes the lease first, so the spawn that
	// arrives there finds it already its own (AcquireLease's same-fleet
	// rule) and nobody else can take the issue in between. A scratch has no
	// lease to hand over (claude-fleet#1541): nothing is reserved, nothing is
	// given back — its start is sent as it is.
	target, err := s.Store.Fleet(pl.FleetID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	giveBack := func() {}
	if !scratch {
		tclaim := store.LeaseClaim{Repo: req.Repo, Issue: req.Issue, WorkerID: pl.FleetID + "/" + targetKey(key, target, req.Repo),
			FleetID: pl.FleetID, EndpointID: target.EndpointID, Hostname: target.Hostname, OSUser: target.OSUser}
		moved, err := s.Store.HandOverLease(req.Repo, req.Issue, req.WorkerID, tclaim, leaseStartGrace, now)
		if err == nil && !moved {
			// The asker held no live lease (its own acquire could not reach
			// the hub): take it for the target the ordinary way.
			var held store.Lease
			if moved, held, _, err = s.Store.AcquireLease(tclaim, leaseStartGrace, now); err == nil && !moved {
				s.placeAudit(p, fleetID, "HELD by "+held.WorkerID+" on "+nodeLabel(held.Hostname), now)
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
		giveBack = func() {
			mine := store.LeaseClaim{Repo: req.Repo, Issue: req.Issue, WorkerID: req.WorkerID, FleetID: fleetID,
				EndpointID: ep.ID, Hostname: fl.Hostname, OSUser: fl.OSUser}
			if _, err := s.Store.HandOverLease(req.Repo, req.Issue, tclaim.WorkerID, mine, leaseStartGrace, time.Now()); err != nil {
				s.placeAudit(p, fleetID, "lease give-back failed: "+err.Error(), time.Now())
			}
		}
	}

	idem := req.Idem
	what := strconv.Itoa(req.Issue)
	if scratch {
		what = "scratch"
	}
	if idem == "" {
		idem = "place-" + fleetID[:8] + "-" + what + "-" + strconv.FormatInt(now.UnixNano(), 36)
	}
	args := map[string]any{"fleet_id": pl.FleetID, "repo": req.Repo, "node": req.Node, "idempotency_key": idem}
	if scratch {
		args["kind"] = "scratch"
		if req.Name != "" {
			args["name"] = req.Name
		}
	} else {
		args["issue"] = float64(req.Issue)
	}
	if req.Agent != "" {
		args["agent"] = req.Agent
	}
	if req.OriginWID != "" {
		args["origin_wid"] = req.OriginWID
	}
	if accountClassBinds(req.AccountClass) {
		args["account_class"] = req.AccountClass
	}
	if req.Reap != "" {
		args["reap"] = req.Reap
	}
	op, err := s.submitWrite(r.Context(), p, "worker_start", args, &pl)
	if err != nil {
		giveBack()
		s.placeAudit(p, fleetID, "REMOTE "+nodeLabel(pl.Machine)+" refused: "+errorObject(err)["code"], now)
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err), "placement": pl})
		return
	}
	wait := placeWait
	if req.Wait != nil {
		wait = min(max(time.Duration(*req.Wait)*time.Second, 0), placeWaitMax)
	}
	resp := map[string]any{"local": false, "placement": pl}
	if wait > 0 {
		var heard error
		op, heard = s.awaitOperation(r.Context(), op, time.Now().Add(wait))
		oc := outcomeOf(op, nodeLabel(pl.Machine))
		if oc.State == "unknown" {
			oc = neverStarted(op, heard, oc, wait)
		}
		resp["outcome"] = oc
		if oc.State != "done" {
			// Nothing seen open there (claude-fleet#1606): the issue is the
			// asker's again, which gives it back to the pool when it exits —
			// no lease outlives a start nobody saw open, so the next send
			// needs no --force. A start still running that opens after all
			// is held off by the GitHub claim, the second guard.
			giveBack()
		}
		s.placeAudit(p, fleetID, "REMOTE "+nodeLabel(pl.Machine)+" "+oc.State, now)
	} else {
		if op["status"] == "failed" {
			// The node refused before running anything: the issue is the
			// asker's again, so its fallback can still open it.
			giveBack()
		}
		s.placeAudit(p, fleetID, "REMOTE "+nodeLabel(pl.Machine)+" "+asString(op["status"]), now)
	}
	resp["operation"] = op
	writeJSON(w, http.StatusOK, resp)
}

// awaitOperation asks the target for a REMOTE start's state until it is
// final or the deadline passes, and returns the latest view with the last
// error asking the target gave (nil once it answered). A target that cannot
// be asked is asked again; the view stays what was last known. An unknown
// the hub wrote itself — the write was not acknowledged — is not the
// target's word: it is asked too (claude-fleet#1606), so a start that never
// arrived is told from one that did.
func (s *Server) awaitOperation(ctx context.Context, op map[string]any, deadline time.Time) (map[string]any, error) {
	id := asString(op["operation_id"])
	heard := false
	var last error
	for !(operationFinal(asString(op["status"])) && (heard || asString(op["status"]) != "unknown")) && time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return op, last
		case <-time.After(min(placePoll, time.Until(deadline))):
		}
		o, err := s.Store.FleetOperation(id)
		if err != nil {
			return op, last
		}
		if !heard || !operationFinal(o.Status) {
			if last = s.reconcileOperation(ctx, &o); last != nil {
				continue
			}
			heard = true
		}
		op = operationView(o)
	}
	return op, last
}

// neverStarted turns an unknown REMOTE start into a failed one when the
// target says it never ran it (claude-fleet#1606): it has no record of the
// operation (the start never reached it), or it journalled it and never
// started it within the wait — its executor refuses one that old, so it
// never will. Anything else (still running) stays unknown.
func neverStarted(op map[string]any, heard error, oc placeOutcome, wait time.Duration) placeOutcome {
	id := asString(op["operation_id"])
	var f *FleetFault
	why := ""
	switch {
	case asString(op["status"]) == "accepted":
		why = oc.Node + " accepted operation " + id + " but never started it within " + strconv.FormatFloat(wait.Seconds(), 'f', -1, 64) + " s"
	case heard != nil && errors.As(heard, &f) && f.Code == "NOT_FOUND":
		why = "operation " + id + " never reached " + oc.Node + " (it has no record of it)"
	default:
		return oc
	}
	one := 1
	return placeOutcome{State: "failed", Exit: &one, Stderr: why + " — nothing opened; re-send it", Node: oc.Node}
}

func operationFinal(status string) bool {
	return status == "succeeded" || status == "failed" || status == "unknown"
}

// outcomeOf reads a REMOTE start's operation as a placeOutcome.
func outcomeOf(op map[string]any, node string) placeOutcome {
	var res struct {
		Window  string          `json:"window"`
		Timing  json.RawMessage `json:"timing"`
		Workers []struct {
			WindowID string `json:"window_id"`
			WorkerID string `json:"worker_id"`
		} `json:"workers"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
			Exit    *int   `json:"exit"`
			Stderr  string `json:"stderr1"`
		} `json:"error"`
	}
	if raw, ok := op["result"].(json.RawMessage); ok {
		_ = json.Unmarshal(raw, &res)
	}
	exit := func(n int) *int { return &n }
	switch asString(op["status"]) {
	case "succeeded":
		win, wid := res.Window, ""
		if len(res.Workers) > 0 {
			wid = res.Workers[0].WorkerID
			if win == "" {
				win = res.Workers[0].WindowID
			}
		}
		oc := placeOutcome{State: "done", Exit: exit(0), Window: win, WorkerID: wid, Node: node}
		if len(res.Timing) > 0 && res.Timing[0] == '{' {
			oc.Timing = res.Timing
		}
		return oc
	case "failed":
		why := res.Error.Stderr
		if why == "" {
			why = res.Error.Message
		}
		// The spawn's own code when the node sent it (fleet-control-read.sh
		// start: 2 at capacity, 3 claimed, 4 a disk/quota gate), else the
		// node's reason for it; a gate is "cannot take it now", as a cap is.
		code := -1
		if res.Error.Exit != nil {
			code = *res.Error.Exit
		}
		switch {
		case code == 2 || code == 4 || res.Error.Code == "AT_CAPACITY" || res.Error.Code == "RESOURCE_GATE":
			return placeOutcome{State: "refused", Exit: exit(2), Stderr: why, Node: node}
		case code == 3 || res.Error.Code == "ALREADY_CLAIMED":
			return placeOutcome{State: "refused", Exit: exit(3), Stderr: why, Node: node}
		case code > 0:
			return placeOutcome{State: "refused", Exit: exit(1), Stderr: why, Node: node}
		}
		return placeOutcome{State: "failed", Exit: exit(1), Stderr: why, Node: node}
	}
	why := res.Error.Message
	if why == "" {
		why = "no final state from " + node + " (operation " + asString(op["status"]) + "); its node may predate outcome reports — check that machine before re-dispatching"
	}
	return placeOutcome{State: "unknown", Stderr: why, Node: node}
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
		return fleetPrincipal{Actor: actor, Person: person, scope: scope, From: host}, nil
	case err != nil && !errors.Is(err, store.ErrNoPrincipal):
		return fleetPrincipal{}, err
	}
	return fleetPrincipal{Actor: actor, scope: func(_, u string) bool { return u == user }, From: host}, nil
}

// placeAudit is one placement's audit row, naming the session it was made
// for when a worker assertion said so (claude-fleet#1810).
func (s *Server) placeAudit(p fleetPrincipal, fleetID, outcome string, at time.Time) {
	if err := s.Store.FleetAuditWorker(p.Actor, p.Worker.id(), p.Worker.label(), "place", fleetID, outcome, "", at); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}

// placeStatus is the HTTP status of a placement fault, as /v1/fleet/ maps it.
func placeStatus(err error) int {
	code := errorObject(err)["code"]
	if st := map[string]int{"INVALID_ARGUMENT": 400, "NOT_FOUND": 404, "FORBIDDEN": 403, "UNAUTHENTICATED": 401,
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

// accountClassOK is the account_class rule (claude-fleet#1540): one of three
// words or absent — it becomes an argv word and a window option on the node.
func accountClassOK(c string) bool {
	return c == "" || c == "any" || c == "local" || c == "pool"
}

// accountClassBinds says whether an account_class constrains the start: "any"
// and absent add nothing to what the node is sent.
func accountClassBinds(c string) bool {
	return c == "local" || c == "pool"
}
