package api

import (
	"crypto/hmac"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Open a session from the client (claude-fleet#1777, EPIC #1776 C1).
//
// A computer that runs only the `fleet` client has no fleet to open anything
// in: the client asks the hub, and the hub has the machine open it — the same
// placement and the same journalled node operations a node's own
// /v1/node/place uses (pickNode → worker_start / worker_resume).
//
//	POST /v1/fleet/client/place   {cert sig ts | a session / viewer door,
//	                               lease, payload, mac}
//
// Who may ask: the person's CURRENT client lease, and nothing else. The
// connection certificate (or door) says who the person is; the lease id must
// be that person's live lease, and mac must be HMAC-SHA256 of payload under
// that lease's action key — the key only the lease's own client is told
// (fleet_client_actions.go). A taken-over or lapsed lease, or a wrong key, is
// 401, so a second device of the same person, or anyone holding a copy of an
// old key, opens nothing.
//
// payload is one JSON object (clientPlaceRequest): action place (default) or
// status. place names repo, kind issue | scratch | restore (issue N /
// key <fleet-history row key> / an optional name), node auto | a machine,
// title, agent, idempotency_key, wait (seconds, at most clientPlaceWaitMax).
// A scratch may carry a body (its seed) and no_repo instead of a repo — a
// session of no repo, opened in $HOME on any of the person's fleets
// (claude-fleet#1956, the writing area's 「不关联仓库」).
// status names the operation_id a place answered and waits on it again — the
// client polls this way, so no one request outlives a proxy's patience.
//
// The answer carries the line `ccquota place` prints for the same outcome
// (`REMOTE <m> <op> done <worker_id>` / `DECLINED <m> <op> <exit>` /
// `UNKNOWN <m> <op>` / `HELD <m>` / `REFUSED <code>`, the reason after a TAB)
// and its exit code, so bin/fleet-client-place.sh prints exactly what
// fleet_hub_place would. Machines are named the way a client names them (the
// route list's alias, else the first label).

const clientPlaceWaitMax = 25 * time.Second

// clientPlaceKeyRE is a /fleet-history row key: issue-<N> or scratch-<N>, with
// a multi-repo fleet's `<slug>:` prefix allowed.
var clientPlaceKeyRE = regexp.MustCompile(`^(?:[A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?((issue|scratch)-[1-9][0-9]{0,9})$`)

// ClientPlaceEnvelope is the body of a POST to control.ClientPath+"/place".
type ClientPlaceEnvelope struct {
	Cert    string `json:"cert,omitempty"`
	Sig     string `json:"sig,omitempty"`
	TS      int64  `json:"ts,omitempty"`
	Lease   string `json:"lease"`
	Payload string `json:"payload"`
	MAC     string `json:"mac"`
}

// clientPlaceRequest is the signed payload.
type clientPlaceRequest struct {
	Action string `json:"action"` // place | status
	TS     int64  `json:"ts"`
	Repo   string `json:"repo"`
	Kind   string `json:"kind"` // issue | scratch | restore | new
	Issue  int    `json:"issue"`
	Key    string `json:"key"`
	Name   string `json:"name"`
	Node   string `json:"node"`
	Title  string `json:"title"`
	Body   string `json:"body"` // kind=new: the issue's body (claude-fleet#1953); kind=scratch: its seed (#1956)
	NoRepo bool   `json:"no_repo"`
	// Home / New: a HOME session (`fleet claude`, claude-fleet#2564) — a
	// no-repo scratch that first goes back to the person's current one
	// (fleet_home.go); New opens another anyway and makes it the current.
	Home        bool   `json:"home"`
	New         bool   `json:"new"`
	Agent       string `json:"agent"`
	Reap        string `json:"reap"`
	Idem        string `json:"idempotency_key"`
	OperationID string `json:"operation_id"`
	Wait        *int   `json:"wait"`
	// Attachments: the files the writing area sends with a new or scratch
	// start (claude-fleet#2393) — see fleet_attachment.go.
	Attachments []clientAttachment `json:"attachments"`
}

// ClientPlaceResponse is the answer: Line and Exit are fleet_hub_place's.
// State is done / refused / failed / unknown (a start's outcome), held, or
// pending — the start was sent and has no final state yet: poll status with
// OperationID.
type ClientPlaceResponse struct {
	Line        string     `json:"line"`
	Exit        int        `json:"exit"`
	State       string     `json:"state"`
	OperationID string     `json:"operation_id,omitempty"`
	Machine     string     `json:"machine,omitempty"`
	WorkerID    string     `json:"worker_id,omitempty"`
	Window      string     `json:"window,omitempty"`
	Placement   *Placement `json:"placement,omitempty"`
	// Timing: the node's timing points for a done start (claude-fleet#2238),
	// as the node wrote them; the client logs them in compose.ndjson.
	Timing json.RawMessage `json:"timing,omitempty"`
	// WindowID / Key / Filed: a warm start's (claude-fleet#2234), passed on
	// as the node said them — the client switches at once (#2236). An older
	// node says none, and the client finds the row as before.
	WindowID string `json:"window_id,omitempty"`
	Key      string `json:"key,omitempty"`
	Filed    string `json:"filed,omitempty"`
	// Login is the login the session's fleet runs under on Machine
	// (claude-fleet#2430): one person may hold two logins on one machine, and
	// the client must ssh in as the one that holds it — the far end finds a
	// worker only in its own login's fleets. "" when unknown.
	Login string `json:"login,omitempty"`
	// Attempts are the machines that declined this start before the one
	// answered (claude-fleet#1610); the line carries them as `after …`.
	Attempts []placeAttempt `json:"attempts,omitempty"`
	// Attached is how many of the request's attachments the start carried
	// (claude-fleet#2393); AttachNote says why none went when some were
	// sent. An older hub says neither, and the client says the files did
	// not go.
	Attached   int    `json:"attached,omitempty"`
	AttachNote string `json:"attach_note,omitempty"`
	// AlsoOpen: a RESUME's other devices that have the session open now
	// (claude-fleet#2564) — the client says so at the top of its view.
	AlsoOpen []string `json:"also_open,omitempty"`
}

// placedLogin is the login of the candidate placement chose (its fleet_id).
func placedLogin(pl *Placement) string {
	if pl == nil {
		return ""
	}
	for _, c := range pl.Candidates {
		if c.FleetID == pl.FleetID {
			return c.OSUser
		}
	}
	return ""
}

// checkActionMAC says whether lease is one of key's live leases and mac is
// payload's HMAC under its action key.
func (t *clientLeaseTable) checkActionMAC(key, lease, payload, mac string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	if c := t.holdsLocked(key, lease); !t.live(c, now) {
		return false
	}
	k := t.keys[lease]
	if k == "" {
		return false
	}
	return hmac.Equal([]byte(signClientAction(k, []byte(payload))), []byte(strings.ToLower(mac)))
}

// clientPrincipal is who a client's request acts for: the person its
// certificate names, or the operator's door.
func (s *Server) clientPrincipal(id sshRelayIdentity) (fleetPrincipal, error) {
	if id.Operator || id.Principal == "" {
		actor := id.Actor
		if actor == "" {
			actor = "operator"
		}
		return fleetPrincipal{Actor: actor}, nil
	}
	scope, err := s.scopeFor(id.Principal)
	if err != nil {
		return fleetPrincipal{}, err
	}
	return fleetPrincipal{Actor: id.Principal, Person: id.Principal, scope: scope}, nil
}

// machineHostname turns a client's machine name (an alias from the route
// list, `m5`) into the roster hostname placement matches on.
func (s *Server) machineHostname(name string) string {
	for _, m := range s.fleetMachines() {
		if m.Alias != "" && strings.EqualFold(m.Alias, name) {
			return m.Hostname
		}
	}
	return name
}

func (s *Server) handleFleetClientPlace(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var env ClientPlaceEnvelope
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, clientPlaceBodyMax))
	if err != nil {
		httpError(w, http.StatusRequestEntityTooLarge, "a place request is at most "+strconv.Itoa(clientPlaceBodyMax>>20)+" MiB")
		return
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	now := time.Now()
	id, ok := s.clientIdentity(w, r, env.Cert, env.Sig, env.TS, now)
	if !ok {
		return
	}
	// a test identity's lease lives in its own slot (#1931), as in actions
	key := s.clientLeases.slotOf(clientLeaseKey(id), env.Lease)
	if !s.clientLeases.checkActionMAC(key, env.Lease, env.Payload, env.MAC, now) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "not your client: the lease is not held (asked to leave, disconnected or lapsed) or the action key does not check")
		return
	}
	var req clientPlaceRequest
	if err := json.Unmarshal([]byte(env.Payload), &req); err != nil {
		httpError(w, http.StatusBadRequest, "the payload must be one JSON object")
		return
	}
	if len(raw) > clientPlaceSmallMax && len(req.Attachments) == 0 {
		// Only attachments make a place request big (claude-fleet#2393).
		httpError(w, http.StatusRequestEntityTooLarge, "a place request without attachments is at most 32 KiB")
		return
	}
	if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
		httpError(w, http.StatusUnauthorized, "the payload's timestamp is too far from the hub's clock — check this computer's time")
		return
	}
	p, err := s.clientPrincipal(id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	wait := clientPlaceWaitMax
	if req.Wait != nil {
		wait = min(max(time.Duration(*req.Wait)*time.Second, 0), clientPlaceWaitMax)
	}
	switch req.Action {
	case "status":
		s.clientPlaceStatus(w, r, p, req.OperationID, wait)
	case "", "place":
		s.clientPlace(w, r, p, key, env.Lease, req, wait, now)
	default:
		httpError(w, http.StatusBadRequest, "action must be place or status")
	}
}

// refusedAnswer is a placement fault as the client's line: HELD for a lease
// held elsewhere, REFUSED <code> for everything else.
func refusedAnswer(err error, pl *Placement) ClientPlaceResponse {
	e := errorObject(err)
	return ClientPlaceResponse{Line: "REFUSED " + e["code"] + "\t" + oneLine(e["message"]), Exit: 4,
		State: "refused", Placement: pl}
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func (s *Server) clientPlace(w http.ResponseWriter, r *http.Request, p fleetPrincipal, leaseKey, lease string, req clientPlaceRequest, wait time.Duration, now time.Time) {
	if (req.Home || req.New) && (!req.Home || !req.NoRepo || req.Kind != "scratch") {
		httpError(w, http.StatusBadRequest, "home is a no_repo scratch; new goes with home")
		return
	}
	if req.NoRepo {
		// The writing area's 「不关联仓库」 (claude-fleet#1956): a scratch only,
		// and it names no repo — any of this person's fleets may open it.
		if req.Kind != "scratch" || req.Repo != "" {
			httpError(w, http.StatusBadRequest, "no_repo is a scratch that names no repo")
			return
		}
	} else if !leaseRepoRE.MatchString(req.Repo) {
		httpError(w, http.StatusBadRequest, "repo must be owner/name")
		return
	}
	node := req.Node
	if node == "" {
		node = "auto"
	}
	if node != "auto" {
		if !nodeNameRE.MatchString(node) {
			httpError(w, http.StatusBadRequest, "node must be auto or a machine name from the roster")
			return
		}
		node = s.machineHostname(node)
	}
	if req.Agent != "" && req.Agent != "claude" && req.Agent != "codex" {
		httpError(w, http.StatusBadRequest, "agent must be claude or codex")
		return
	}
	if req.Idem != "" && !idemRE.MatchString(req.Idem) {
		httpError(w, http.StatusBadRequest, "idempotency_key must be 1–128 letters, digits or ._:-")
		return
	}
	idem := req.Idem
	if idem == "" {
		idem = "client-" + lease[:min(8, len(lease))] + "-" + strconv.FormatInt(now.UnixNano(), 36)
	}
	args := map[string]any{"node": node, "idempotency_key": idem}
	if req.NoRepo {
		args["no_repo"] = true
	} else {
		args["repo"] = req.Repo
	}
	if req.Agent != "" {
		args["agent"] = req.Agent
	}
	if !reapPolicyOK(req.Reap) {
		httpError(w, http.StatusBadRequest, "reap must be merged[:<dur>], done[:<dur>], loop-end, at:<time> or keep")
		return
	}
	if req.Reap != "" {
		args["reap"] = req.Reap
	}
	tool := "worker_start"
	var pl Placement
	var target store.FleetRow
	what := ""

	switch req.Kind {
	case "issue", "":
		if req.Issue <= 0 || req.Key != "" || req.Name != "" {
			httpError(w, http.StatusBadRequest, "kind=issue names a positive issue and no key or name")
			return
		}
		what = "#" + strconv.Itoa(req.Issue)
	case "scratch":
		if req.Issue != 0 || req.Key != "" {
			httpError(w, http.StatusBadRequest, "kind=scratch names no issue or key")
			return
		}
		name := req.Name
		if name == "" {
			name = req.Title // the title is a scratch's label when it has no name
		}
		n, err := checkScratchName(name)
		if err != nil {
			httpError(w, http.StatusBadRequest, errorObject(err)["message"])
			return
		}
		args["kind"] = "scratch"
		if n != "" {
			args["name"] = n
		}
		if req.Body != "" {
			// The writing area's text (claude-fleet#1956): the scratch
			// starts working on it.
			if _, err := checkText(req.Body, "body"); err != nil {
				httpError(w, http.StatusBadRequest, errorObject(err)["message"])
				return
			}
			args["body"] = req.Body
		}
		what = "scratch"
	case "new":
		// The writing area (claude-fleet#1953): the issue does not exist yet —
		// the chosen machine files it (fleet-issue-file.sh) and opens its
		// worker, so there is no number to lease here; the node's own spawn
		// takes the lease as any spawn there does.
		if req.Issue != 0 || req.Key != "" || req.Name != "" {
			httpError(w, http.StatusBadRequest, "kind=new names a title (and a body), no issue, key or name")
			return
		}
		title, err := checkIssueTitle(req.Title)
		if err != nil {
			httpError(w, http.StatusBadRequest, errorObject(err)["message"])
			return
		}
		args["kind"], args["title"] = "new", title
		if req.Body != "" {
			if _, err := checkText(req.Body, "body"); err != nil {
				httpError(w, http.StatusBadRequest, errorObject(err)["message"])
				return
			}
			args["body"] = req.Body
		}
		what = "new"
	case "restore":
		if req.Issue != 0 || req.Name != "" || !clientPlaceKeyRE.MatchString(req.Key) {
			httpError(w, http.StatusBadRequest, "kind=restore names key: a /fleet-history row's issue-<N> or scratch-<N>")
			return
		}
		what = req.Key
	default:
		httpError(w, http.StatusBadRequest, "kind must be issue, scratch, restore or new")
		return
	}

	// A home session (claude-fleet#2564): the current one, when there is one —
	// under the person's lock for this agent, held through the start below so
	// a second computer's ask resumes this one rather than opening a twin.
	homeActorID, homeAgent := "", ""
	if req.Home {
		homeActorID, homeAgent = homeActor(p, leaseKey), req.Agent
		if homeAgent == "" {
			homeAgent = "claude"
		}
		defer homeLock(homeActorID, homeAgent)()
		if !req.New && s.homeResume(w, r, p, leaseKey, lease, homeActorID, homeAgent, wait, now) {
			return
		}
	}

	var held []heldAttachment
	if len(req.Attachments) > 0 {
		if req.Kind != "new" && req.Kind != "scratch" {
			httpError(w, http.StatusBadRequest, "attachments go with a new or scratch start")
			return
		}
		var err error
		if held, err = checkAttachments(p.Actor, idem, req.Attachments, now); err != nil {
			httpError(w, http.StatusBadRequest, errorObject(err)["message"])
			return
		}
		_, _ = s.Store.ExpireFleetAttachments(store.FleetAttachmentTTL, now)
		for _, h := range held {
			if err := s.Store.PutFleetAttachment(h.rec, h.data); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
		}
	}

	if req.Kind == "restore" {
		var err error
		pl, target, err = s.restoreTarget(p, req.Repo, req.Key, node, now)
		if err != nil {
			s.leaseAudit(p.Actor, "client_place", what, errorObject(err)["code"], now)
			writeJSON(w, http.StatusOK, refusedAnswer(err, &pl))
			return
		}
		bare := clientPlaceKeyRE.FindStringSubmatch(req.Key)[1]
		tool = "worker_resume"
		args = map[string]any{"worker_id": target.FleetID + "/" + targetKey(bare, target, req.Repo), "idempotency_key": idem}
		m := s.nodeMachineLabel(pl.Machine)
		op, err := s.submitWrite(r.Context(), p, tool, args, &pl)
		if err != nil {
			s.leaseAudit(p.Actor, "client_place", what, "REMOTE "+m+" refused: "+errorObject(err)["code"], now)
			writeJSON(w, http.StatusOK, refusedAnswer(err, &pl))
			return
		}
		out, _ := s.clientPlaceAnswer(r, op, &pl, wait)
		if target.OSUser != "" {
			out.Login = target.OSUser // the fleet it went to — a restore has no candidates
		}
		s.leaseAudit(p.Actor, "client_place", what, "REMOTE "+m+" "+out.State+" "+asString(op["operation_id"]), now)
		writeJSON(w, http.StatusOK, out)
		return
	}

	// A start (claude-fleet#1610): an auto issue or scratch start whose
	// machine declines it is tried on the next candidate in placement's
	// order, its lease back in the pool in between — within this request's
	// wait, the earlier tries in the answer's `attempts` and the line's
	// `after …` field; every machine declining is REFUSED ALL_DECLINED. A
	// machine named, a restore (one fleet holds its row) and a new issue
	// (the machine may have filed it before it said no) are tried once.
	var err error
	if pl, err = s.pickNode(p, req.Repo, node, now); err != nil {
		s.leaseAudit(p.Actor, "client_place", what, errorObject(err)["code"], now)
		writeJSON(w, http.StatusOK, refusedAnswer(err, &pl))
		return
	}
	retry := node == "auto" && wait > 0 && (req.Kind == "" || req.Kind == "issue" || req.Kind == "scratch")
	deadline := now.Add(wait)
	declined := map[string]string{}
	attempts := []placeAttempt{}
	attached, attachNote := 0, ""
	answer := func(out ClientPlaceResponse) {
		if req.Home {
			s.homeRecord(homeActorID, homeAgent, lease, s.clientLeases.deviceOf(leaseKey, lease), out, pl, time.Now())
		}
		out.Attached, out.AttachNote = attached, attachNote
		if len(attempts) > 0 {
			out.Attempts = attempts
			out.Line += "\t" + attemptsTail(attempts)
		}
		writeJSON(w, http.StatusOK, out)
	}
	// next takes a declined try out of the running: true = try pl now,
	// false = the declined answer stands (or the refusal was written: done).
	next := func(a placeAttempt) (ok, done bool) {
		if !retry || time.Until(deadline) < placeRetryMin(wait) {
			return false, false
		}
		attempts = append(attempts, a)
		declined[pl.FleetID] = a.Why
		npl, err := s.pickNodeAfter(p, req.Repo, "auto", time.Now(), declined, "")
		if err != nil {
			if len(attempts) == 1 {
				attempts = attempts[:0]
				return false, false
			}
			s.leaseAudit(p.Actor, "client_place", what, errorObject(err)["code"], time.Now())
			answer(refusedAnswer(err, &npl))
			return false, true
		}
		pl = npl
		return true, false
	}
	for try := 1; ; try++ {
		if target, err = s.Store.Fleet(pl.FleetID); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		args["fleet_id"] = pl.FleetID
		if try > 1 {
			args["idempotency_key"] = retryIdem(idem, try) // a new start, not the declined one again
		}
		delete(args, "attachments")
		attached, attachNote = 0, ""
		if len(held) > 0 {
			// The chosen machine downloads them, or is sent none and the
			// client says so (claude-fleet#2393).
			if s.canAttach(r.Context(), target.EndpointID) {
				list, err := s.attachArgs(held, target.EndpointID)
				if err != nil {
					httpError(w, http.StatusInternalServerError, err.Error())
					return
				}
				args["attachments"], attached = list, len(list)
			} else {
				attachNote = s.nodeMachineLabel(pl.Machine) + "'s node agent takes no attachments yet (upgrade ccquota / claude-fleet there)"
			}
		}
		giveBack := func() {}
		if req.Kind != "scratch" && req.Kind != "new" {
			args["issue"] = float64(req.Issue)
			// The chosen machine's fleet takes the issue's lease, so the
			// spawn that arrives there finds it its own and nobody else can
			// take it in between (the node place rule).
			claim := store.LeaseClaim{Repo: req.Repo, Issue: req.Issue,
				WorkerID: pl.FleetID + "/" + targetKey("issue-"+strconv.Itoa(req.Issue), target, req.Repo),
				FleetID:  pl.FleetID, EndpointID: target.EndpointID, Hostname: target.Hostname, OSUser: target.OSUser}
			hadOwn := false
			if ls, err := s.Store.Leases(time.Now()); err == nil {
				for _, l := range ls {
					if l.Repo == store.NormRepo(req.Repo) && l.Issue == req.Issue && l.FleetID == pl.FleetID {
						hadOwn = true // a live worker there already holds it: never give that back
					}
				}
			}
			granted, held, _, err := s.Store.AcquireLease(claim, leaseStartGrace, time.Now())
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			if !granted {
				m := s.nodeMachineLabel(held.Hostname)
				s.leaseAudit(p.Actor, "client_place", what, "HELD by "+held.WorkerID+" on "+m, now)
				answer(ClientPlaceResponse{Line: "HELD " + m + "\t" + what + " is leased to " + m,
					Exit: 3, State: "held", Machine: m, Placement: &pl})
				return
			}
			if !hadOwn {
				giveBack = func() { _, _ = s.Store.ReleaseLease(req.Repo, req.Issue, claim.WorkerID) }
			}
		}

		m := s.nodeMachineLabel(pl.Machine)
		op, err := s.submitWrite(r.Context(), p, tool, args, &pl)
		if err != nil {
			giveBack()
			e := errorObject(err)
			s.leaseAudit(p.Actor, "client_place", what, "REMOTE "+m+" refused: "+e["code"], now)
			if declinedBySubmit(e["code"]) {
				one := 1
				if ok, done := next(placeAttempt{Machine: m, State: "refused", Exit: &one, Why: oneLine(e["message"])}); done {
					return
				} else if ok {
					continue
				}
			}
			answer(refusedAnswer(err, &pl))
			return
		}
		out, oc := s.clientPlaceAnswer(r, op, &pl, min(wait, max(time.Until(deadline), time.Second)))
		if target.OSUser != "" {
			out.Login = target.OSUser
		}
		if out.State == "refused" || out.State == "failed" {
			giveBack()
		}
		s.leaseAudit(p.Actor, "client_place", what, "REMOTE "+m+" "+out.State+" "+asString(op["operation_id"]), now)
		if out.Exit == 5 && oc.Exit != nil && *oc.Exit != 3 {
			if ok, done := next(placeAttempt{Machine: m, OperationID: out.OperationID, State: oc.State,
				Exit: oc.Exit, Why: oneLine(oc.Stderr)}); done {
				return
			} else if ok {
				continue
			}
		}
		answer(out)
		return
	}
}

// clientPlaceAnswer waits up to wait on op and words what became of it.
func (s *Server) clientPlaceAnswer(r *http.Request, op map[string]any, pl *Placement, wait time.Duration) (ClientPlaceResponse, placeOutcome) {
	m := s.nodeMachineLabel(pl.Machine)
	var heard error
	if wait > 0 {
		op, heard = s.awaitOperation(r.Context(), op, time.Now().Add(wait))
	}
	opID := asString(op["operation_id"])
	out := ClientPlaceResponse{OperationID: opID, Machine: m, Placement: pl, Login: placedLogin(pl)}
	oc := outcomeOf(op, m)
	if oc.State == "unknown" && wait > 0 {
		oc = neverStarted(op, heard, oc, wait)
	}
	reason := oneLine(pl.Reason)
	switch {
	case oc.State == "done":
		who := oc.WorkerID
		if who == "" {
			who = oc.Window
		}
		if who == "" {
			who = "-"
		}
		out.State, out.Exit, out.WorkerID, out.Window = "done", 0, oc.WorkerID, oc.Window
		out.Timing = oc.Timing
		out.WindowID, out.Key, out.Filed = oc.WindowID, oc.Key, oc.Filed
		out.Line = "REMOTE " + m + " " + opID + " done " + oneLine(who) + "\t" + reason
	case (oc.State == "refused" || oc.State == "failed") && oc.Exit != nil && *oc.Exit > 0:
		out.State, out.Exit = oc.State, 5
		out.Line = "DECLINED " + m + " " + opID + " " + strconv.Itoa(*oc.Exit) + "\t" + oneLine(oc.Stderr)
	case !operationFinal(asString(op["status"])):
		// Still on its way: the client asks again with status.
		out.State, out.Exit = "pending", 6
		out.Line = "UNKNOWN " + m + " " + opID + "\t" + oneLine(oc.Stderr)
	default:
		out.State, out.Exit = "unknown", 6
		out.Line = "UNKNOWN " + m + " " + opID + "\t" + oneLine(oc.Stderr)
	}
	return out, oc
}

// clientPlaceStatus answers a poll of an operation this person's client
// started: only one's own (the journal's actor) is ever read.
func (s *Server) clientPlaceStatus(w http.ResponseWriter, r *http.Request, p fleetPrincipal, opID string, wait time.Duration) {
	o, err := s.Store.FleetOperation(opID)
	if err != nil || o.Actor != p.Actor || (o.Action != "worker_start" && o.Action != "worker_resume") {
		httpError(w, http.StatusNotFound, "no such operation of yours")
		return
	}
	var pl Placement
	if o.Placement != "" {
		_ = json.Unmarshal([]byte(o.Placement), &pl)
	}
	if pl.Machine == "" {
		if f, err := s.Store.Fleet(o.FleetID); err == nil {
			pl.Machine = f.Hostname
		}
	}
	out, _ := s.clientPlaceAnswer(r, operationView(o), &pl, wait)
	if (out.State == "refused" || out.State == "failed") && o.Action == "worker_start" {
		// The start there did not open: its lease goes back to the pool,
		// as a place answered on the spot gives it back.
		var q struct {
			Params struct {
				Issue int    `json:"issue"`
				Repo  string `json:"repo"`
			} `json:"params"`
		}
		if json.Unmarshal([]byte(o.Request), &q) == nil && q.Params.Issue > 0 {
			if ls, err := s.Store.Leases(time.Now()); err == nil {
				for _, l := range ls {
					if l.Repo == store.NormRepo(q.Params.Repo) && l.Issue == q.Params.Issue && l.FleetID == o.FleetID && !l.Seen {
						_, _ = s.Store.ReleaseLease(l.Repo, l.Issue, l.WorkerID)
					}
				}
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// restoreTarget is the fleet whose /fleet-history row key is: the machine
// named, else the one whose reaped worker of that key the hub holds the
// history record of (fleet-worker-records.sh push, claude-fleet#1609) — the
// newest, among the fleets this person may see that host repo.
func (s *Server) restoreTarget(p fleetPrincipal, repo, key, node string, now time.Time) (Placement, store.FleetRow, error) {
	pl := Placement{Requested: node, Repo: repo, Candidates: []Candidate{}, At: now.UTC()}
	_, rows, err := s.visibleFleets(p, now)
	if err != nil {
		return pl, store.FleetRow{}, err
	}
	bare := clientPlaceKeyRE.FindStringSubmatch(key)[1]
	hosting := map[string]store.FleetRow{}
	owners := map[string]bool{}
	accts := s.activeAccounts()
	for _, r := range rows {
		if !r.Present || !hostsRepo(r, repo) {
			continue
		}
		if node != "auto" && !sameMachine(r.Hostname, node) {
			continue
		}
		hosting[r.FleetID] = r
		owners[s.relayOwner(r.EndpointID, r.Hostname, r.OSUser, accts)] = true
	}
	if len(hosting) == 0 {
		where := "any of your machines"
		if node != "auto" {
			where = node
		}
		return pl, store.FleetRow{}, fault("NOT_FOUND", "No fleet hosting "+repo+" on "+where)
	}
	var best *store.FleetWorkerRecord
	for o := range owners {
		recs, err := s.Store.WorkerRecords(store.WorkerRecordQuery{Owner: o, Repo: repo, Kind: "history"})
		if err != nil {
			return pl, store.FleetRow{}, err
		}
		for i := range recs {
			rc := recs[i]
			if _, ok := hosting[rc.FleetID]; !ok || (rc.Key != bare && !(rc.Key == "" && "issue-"+strconv.Itoa(rc.Issue) == bare)) {
				continue
			}
			if best == nil || rc.CreatedAt.After(best.CreatedAt) {
				best = &rc
			}
		}
	}
	var target store.FleetRow
	switch {
	case best != nil:
		target = hosting[best.FleetID]
		pl.Reason = "its /fleet-history row is on " + s.nodeMachineLabel(target.Hostname)
	case node != "auto" && len(hosting) == 1:
		// A machine named: its own ledger is asked, a row the hub never got
		// (reaped before #1609) included.
		for _, r := range hosting {
			target = r
		}
		pl.Reason = "named " + node
	default:
		return pl, store.FleetRow{}, fault("NOT_FOUND", "no /fleet-history row of "+key+" in "+repo+
			" on any of your machines — name the machine with --node")
	}
	pl.Machine, pl.FleetID = target.Hostname, target.FleetID
	// A resumed session runs there like a start: never on a login that only
	// coordinates (compute off), nor on someone's personal computer asked
	// from elsewhere (submitWrite holds that rule for a named fleet too).
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return pl, target, err
	}
	hb, _, _ := s.nodeStatusOf(target.EndpointID, now)
	if cv := s.computeOf(target.EndpointID, hb, settings, now); cv.Off {
		return pl, target, fault("NO_ELIGIBLE_NODE", s.nodeMachineLabel(target.Hostname)+": "+cv.Why)
	}
	return pl, target, nil
}
