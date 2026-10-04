package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The write half of the Fleet Hub, in the hub (claude-fleet#1410).
//
// The tools are bin/fleet_hub.py's — worker_start, worker_message,
// worker_stop, worker_resume, config_set, gh_comment, plus the gh_* reads —
// with its semantics kept to the letter (docs/FLEET-HUB.md, "Writes,
// concurrency and disconnected machines"):
//
//   - The hub journals a write BEFORE it sends it, keyed (actor,
//     idempotency_key): a repeat with the same request returns the first
//     record, a changed one is refused, and no second copy ever reaches a node.
//   - The node journals it AGAIN under the same operation id (fleet-control.py
//     submit) before its detached executor runs, so the outcome survives the
//     channel, the agent and the hub.
//   - Anything the hub cannot confirm is unknown, and unknown is never
//     replayed. A node that is not connected is refused up front — there is
//     no write queue — so "offline" fails fast instead of firing later.
//
// What is new is where a start lands. worker_start may name no fleet at all:
// node=auto (the default) asks PickNode for the best of the caller's machines
// — load, free memory, the per-person cap, then account headroom — and the
// reasoning is journalled beside the operation.
//
// Transport is the control channel (control.TypeWrite → the agent → the
// login's own fleet-control.py rpc), never SSH: the hub cannot reach a node.

// Scopes, one per action, as the Python grant model has them. A lifecycle
// tool is never reachable through worker:start.
var fleetScopeOf = map[string]string{
	"worker_start":   "worker:start",
	"worker_message": "worker:message",
	"worker_stop":    "worker:stop",
	"worker_resume":  "worker:resume",
	// What a sidebar on another machine does to a row here (claude-fleet#1487,
	// EPIC #1479 C8): answer the pane's open prompt, reap the row.
	"worker_answer": "worker:answer",
	"worker_reap":   "worker:reap",
	// A session moved in through the hub (claude-fleet#1426) opens a worker
	// like a start does.
	"worker_move_in": "worker:start",
	"config_set":     "config:write",
	"gh_comment":     "gh:comment",
	"gh_issue_view":  "gh:read",
	"gh_pr_view":     "gh:read",
	"gh_pr_checks":   "gh:read",
}

// FleetScopes is every scope a grant may hold.
var FleetScopes = []string{"fleet:read", "worker:start", "worker:message", "worker:stop",
	"worker:resume", "worker:answer", "worker:reap", "config:write", "gh:read", "gh:comment"}

// DefaultPersonScopes is what a person signed in through WeCom may do on
// their OWN logins when the hub sets nothing (CCQUOTA_FLEET_PERSON_SCOPES):
// run their workers and read/comment on GitHub. config:write is the
// operator's — a fleet's caps and autofill are not a colleague's to move.
var DefaultPersonScopes = []string{"fleet:read", "worker:start", "worker:message", "worker:stop",
	"worker:resume", "worker:answer", "worker:reap", "gh:read", "gh:comment"}

// fleetConfigKeys is the remotely writable configuration, as fleet-control.py
// allows it: key → inclusive integer range.
var fleetConfigKeys = map[string][2]int{
	"FLEET_MAX_SESSIONS":          {0, 256},
	"FLEET_AUTOFILL":              {0, 1},
	"FLEET_AUTOFILL_MAX_PER_TICK": {1, 16},
}

// fleetWriteTools are the journalled tools; fleetGHReads the synchronous
// GitHub reads.
var (
	fleetWriteTools = map[string]bool{"worker_start": true, "worker_message": true, "worker_stop": true,
		"worker_resume": true, "worker_answer": true, "worker_reap": true, "config_set": true, "gh_comment": true}
	fleetGHReads = map[string]bool{"gh_issue_view": true, "gh_pr_view": true, "gh_pr_checks": true}
)

var (
	idemRE     = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
	repoRE     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}(/[A-Za-z0-9_.-]{1,100})?$`)
	ghFieldRE  = regexp.MustCompile(`^[A-Za-z]{1,40}$`)
	nodeNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)
	revisionRE = regexp.MustCompile(`^[a-f0-9]{64}$`)
	// answerRE is fleet_hub_common.ANSWER_RE: yes / no for a permission prompt,
	// else an AskUserQuestion's option numbers — one pick per question, `1,3`
	// toggling several in a multiSelect. Each word becomes an argv word of a
	// script that types into a pane, so nothing else passes.
	answerRE = regexp.MustCompile(`^(?:yes|no|[1-9][0-9]{0,2}(?:,[1-9][0-9]{0,2}){0,15}(?: [1-9][0-9]{0,2}(?:,[1-9][0-9]{0,2}){0,15}){0,7})$`)
)

// maxFleetText is the longest worker_message text / gh_comment body.
const maxFleetText = 4000

// fleetWriteWait bounds how long the hub waits for a node to say it took a
// write. Its controller only journals and forks, so this is generous; past it
// the operation is unknown, never re-sent.
var fleetWriteWait = 25 * time.Second

// ghReadTimeout bounds a gh_* read: the node may fall through its local copy
// to gh and then REST.
const ghReadTimeout = 35 * time.Second

// --- grants ----------------------------------------------------------------

// authorize checks one scope (and, for config:write, the key) against the
// caller's grant. The operator's doors hold every scope and key, as a
// break-glass grant does; a person holds PersonScopes, on their own logins
// only — the login half is enforced by fleetScope, never here.
func (s *Server) authorize(p fleetPrincipal, scope, configKey string) error {
	if p.Person == "" {
		return nil
	}
	scopes := s.FleetPersonScopes
	if scopes == nil {
		scopes = DefaultPersonScopes
	}
	if !hasString(scopes, scope) {
		return fault("FORBIDDEN", "Operation is outside this caller's Fleet grant ("+scope+")")
	}
	if configKey != "" && !hasString(s.FleetPersonConfigKeys, configKey) {
		return fault("FORBIDDEN", "Configuration key is outside this caller's grant")
	}
	return nil
}

func hasString(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// --- argument checks (fleet_hub_common.validate_write, in Go) --------------

// checkFields refuses a missing required or an unknown argument.
func checkFields(args map[string]any, required []string, optional ...string) error {
	allowed := map[string]bool{}
	for _, k := range required {
		if _, ok := args[k]; !ok {
			return fault("INVALID_ARGUMENT", "Missing or unsupported request fields")
		}
		allowed[k] = true
	}
	for _, k := range optional {
		allowed[k] = true
	}
	for k := range args {
		if !allowed[k] {
			return fault("INVALID_ARGUMENT", "Missing or unsupported request fields")
		}
	}
	return nil
}

// argInt reads a positive integer argument. JSON gives float64; an integral
// one is accepted (and a numeric string from an HTTP query), nothing else.
func argInt(v any, what string, lo, hi int) (int, error) {
	bad := fault("INVALID_ARGUMENT", fmt.Sprintf("%s must be an integer in %d–%d", what, lo, hi))
	var f float64
	switch x := v.(type) {
	case float64:
		f = x
	case int:
		f = float64(x)
	case json.Number:
		n, err := x.Float64()
		if err != nil {
			return 0, bad
		}
		f = n
	default:
		return 0, bad
	}
	if f != math.Trunc(f) || f < float64(lo) || f > float64(hi) {
		return 0, bad
	}
	return int(f), nil
}

func argString(args map[string]any, k string) (string, error) {
	v, ok := args[k]
	if !ok {
		return "", nil
	}
	s, ok := v.(string)
	if !ok {
		return "", fault("INVALID_ARGUMENT", k+" must be a string")
	}
	return s, nil
}

func checkRepo(args map[string]any) (string, error) {
	repo, err := argString(args, "repo")
	if err != nil || (repo != "" && !repoRE.MatchString(repo)) {
		return "", fault("INVALID_ARGUMENT", "repo must be owner/name or a hosted repo's name")
	}
	return repo, nil
}

// checkText is check_text: 1–4000 characters, not blank, and nothing that
// could forge the bridge's <!-- fleet:… --> markers or drive a pane.
func checkText(v any, what string) (string, error) {
	t, ok := v.(string)
	if !ok || strings.TrimSpace(t) == "" || len([]rune(t)) > maxFleetText {
		return "", fault("INVALID_ARGUMENT", fmt.Sprintf("%s must be 1-%d characters", what, maxFleetText))
	}
	if strings.Contains(t, "<!--") {
		return "", fault("INVALID_ARGUMENT", what+" must not contain HTML comments or control characters")
	}
	for _, c := range t {
		if c < 32 && c != '\n' && c != '\t' {
			return "", fault("INVALID_ARGUMENT", what+" must not contain HTML comments or control characters")
		}
	}
	return t, nil
}

// repoNamed is fleet_repo_for_slug's match rule: owner/name, its slug, or
// the bare name.
func repoNamed(repo, want string) bool {
	if repo == "" {
		return false
	}
	name := repo
	if i := strings.Index(repo, "/"); i >= 0 {
		name = repo[i+1:]
	}
	return want == repo || want == fleetid.RepoSlug(repo) || want == name
}

// writeRequest is one validated write: what the node is sent, and what the
// journal compares a retry against.
type writeRequest struct {
	action string
	// fleetID is the target fleet, "" for a worker_start the hub places.
	fleetID string
	// node is worker_start's machine choice: "auto" or a roster hostname.
	node string
	// repo is worker_start's repo (placement needs it).
	repo string
	// params is exactly what fleet-control.py's validate_write accepts.
	params map[string]any
	// configKey is config_set's key, for the key grant.
	configKey string
	// canonical is the caller's whole request, for idempotency.
	canonical string
}

// parseWrite validates one write tool's arguments and builds its request.
func parseWrite(tool string, args map[string]any) (writeRequest, string, error) {
	idem, _ := args["idempotency_key"].(string)
	if !idemRE.MatchString(idem) {
		return writeRequest{}, "", fault("INVALID_ARGUMENT", "idempotency_key must be 1–128 letters, digits or ._:-")
	}
	w := writeRequest{action: tool, params: map[string]any{}}
	var err error
	switch tool {
	case "worker_start":
		if err = checkFields(args, []string{"issue", "idempotency_key"}, "fleet_id", "agent", "repo", "node", "origin_wid"); err != nil {
			break
		}
		var issue int
		if issue, err = argInt(args["issue"], "issue", 1, math.MaxInt32); err != nil {
			break
		}
		w.params["issue"] = issue
		agent, aerr := argString(args, "agent")
		if aerr != nil || (agent != "" && agent != "claude" && agent != "codex") {
			err = fault("INVALID_ARGUMENT", "agent must be claude or codex")
			break
		}
		if agent != "" {
			w.params["agent"] = agent
		}
		if w.repo, err = checkRepo(args); err != nil {
			break
		}
		if w.repo != "" {
			w.params["repo"] = w.repo
		}
		if w.fleetID, err = argString(args, "fleet_id"); err != nil {
			break
		}
		if w.node, err = argString(args, "node"); err != nil {
			break
		}
		// origin_wid (claude-fleet#1425): the worker that asked for this one,
		// on another machine — the new window records it as its parent.
		var owid string
		if owid, err = argString(args, "origin_wid"); err != nil {
			break
		}
		if owid != "" {
			if _, _, perr := fleetid.ParseWorkerID(owid); perr != nil {
				err = fault("INVALID_ARGUMENT", "origin_wid must be a worker_id (<fleet UUID>/<key>)")
				break
			}
			w.params["origin_wid"] = owid
		}
		if w.node == "" {
			w.node = "auto"
		}
		if w.node != "auto" && !nodeNameRE.MatchString(w.node) {
			err = fault("INVALID_ARGUMENT", "node must be auto or a machine name from the roster")
			break
		}
		if w.fleetID == "" && w.repo == "" {
			// A placed start must say which repo: the machine is chosen
			// among fleets that host it.
			err = fault("INVALID_ARGUMENT", "Name the repo (owner/name) when no fleet_id is given")
		}
	case "worker_move_in":
		w.fleetID, w.params, err = parseMoveIn(args)
		w.repo, _ = w.params["repo"].(string)
	case "gh_comment":
		if err = checkFields(args, []string{"fleet_id", "issue", "body", "idempotency_key"}, "repo"); err != nil {
			break
		}
		var issue int
		if issue, err = argInt(args["issue"], "issue", 1, math.MaxInt32); err != nil {
			break
		}
		w.params["issue"] = issue
		var body string
		if body, err = checkText(args["body"], "body"); err != nil {
			break
		}
		w.params["body"] = body
		if w.repo, err = checkRepo(args); err != nil {
			break
		}
		if w.repo != "" {
			w.params["repo"] = w.repo
		}
		w.fleetID, _ = args["fleet_id"].(string)
	case "worker_message", "worker_stop", "worker_resume", "worker_answer", "worker_reap":
		opt := []string{}
		req := []string{"worker_id", "idempotency_key"}
		if tool == "worker_message" {
			opt = append(opt, "text")
		}
		if tool == "worker_answer" {
			req = append(req, "answer")
		}
		if err = checkFields(args, req, opt...); err != nil {
			break
		}
		wid, _ := args["worker_id"].(string)
		fid, _, perr := fleetid.ParseWorkerID(wid)
		if perr != nil {
			err = fault("INVALID_ARGUMENT", fleetid.ErrBadWorkerID.Error())
			break
		}
		w.fleetID = fid
		w.params["worker_id"] = wid
		if tool == "worker_message" {
			var text string
			if text, err = checkText(args["text"], "text"); err != nil {
				break
			}
			w.params["text"] = text
		}
		if tool == "worker_answer" {
			answer, _ := args["answer"].(string)
			if !answerRE.MatchString(answer) {
				err = fault("INVALID_ARGUMENT", "answer must be yes, no, or option numbers (`2`, `1,3`, one per question)")
				break
			}
			w.params["answer"] = answer
		}
	case "config_set":
		if err = checkFields(args, []string{"fleet_id", "key", "value", "expected_revision", "idempotency_key"}); err != nil {
			break
		}
		key, _ := args["key"].(string)
		rng, ok := fleetConfigKeys[key]
		if !ok {
			err = fault("FORBIDDEN", "Configuration key is not remotely writable")
			break
		}
		var value int
		if value, err = argInt(args["value"], "value", rng[0], rng[1]); err != nil {
			err = fault("INVALID_ARGUMENT", "Configuration value is outside its permitted range")
			break
		}
		rev, _ := args["expected_revision"].(string)
		if !revisionRE.MatchString(rev) {
			err = fault("INVALID_ARGUMENT", "expected_revision must come from config_get")
			break
		}
		w.params["key"], w.params["value"], w.params["expected_revision"] = key, value, rev
		w.configKey = key
		w.fleetID, _ = args["fleet_id"].(string)
	default:
		err = fault("INVALID_ARGUMENT", "Unsupported operation")
	}
	if err != nil {
		return writeRequest{}, "", err
	}
	if w.fleetID != "" && !fleetid.IsUUID(w.fleetID) {
		return writeRequest{}, "", fault("INVALID_ARGUMENT", "fleet_id must be a canonical UUID")
	}
	// The whole request, minus the key itself: a retry must ask for the
	// same thing to get the same operation back.
	whole := map[string]any{"action": tool, "fleet_id": w.fleetID, "node": w.node, "params": w.params}
	b, _ := json.Marshal(whole)
	w.canonical = string(b)
	return w, idem, nil
}

// --- the journal -------------------------------------------------------

// SubmitWrite is one journalled write: check the grant and the arguments,
// return the existing operation for a repeated key, resolve (or place) the
// target, refuse a node that cannot take it, journal, send, and record what
// the node said. The returned map is operation_get's shape.
func (s *Server) SubmitWrite(ctx context.Context, p fleetPrincipal, tool string, args map[string]any) (map[string]any, error) {
	return s.submitWrite(ctx, p, tool, args, nil)
}

// submitWrite is SubmitWrite with a placement already made (a node's own
// /v1/node/place, claude-fleet#1425): the start goes to args' fleet_id and the
// journal keeps placed as the operation's placement.
func (s *Server) submitWrite(ctx context.Context, p fleetPrincipal, tool string, args map[string]any, placed *Placement) (map[string]any, error) {
	w, idem, err := parseWrite(tool, args)
	if err != nil {
		return nil, err
	}
	if err := s.authorize(p, fleetScopeOf[tool], w.configKey); err != nil {
		return nil, err
	}
	if o, err := s.Store.FleetOperationByIdem(p.Actor, idem); err == nil {
		return replayed(o, w)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	var target store.FleetRow
	var placement *Placement
	switch {
	case w.fleetID != "":
		if target, err = s.visibleFleet(p, w.fleetID); err != nil {
			return nil, err
		}
		if !target.Present {
			return nil, fault("NOT_FOUND", "Fleet is no longer configured on its machine")
		}
		if tool == "worker_start" && w.node != "auto" && !sameMachine(target.Hostname, w.node) {
			return nil, fault("INVALID_ARGUMENT", "fleet_id is on "+target.Hostname+", not "+w.node)
		}
		if placed != nil && placed.FleetID == target.FleetID {
			placement = placed
		}
	default:
		pl, err := s.pickNode(p, w.repo, w.node, time.Now())
		if err != nil {
			return nil, err
		}
		placement = &pl
		if target, err = s.Store.Fleet(pl.FleetID); err != nil {
			return nil, err
		}
	}

	// Refuse what cannot be sent BEFORE journalling: there is no queue, and
	// a refused call leaves the key free for a retry once the node is back.
	c, err := s.writableConn(target.EndpointID)
	if err != nil {
		return nil, err
	}
	if tool == "worker_start" || tool == "worker_resume" {
		// The per-person cap holds for a named fleet too; a placed start
		// was already checked against it by pickNode.
		if placement == nil {
			if err := s.checkNodeCap(target, time.Now()); err != nil {
				return nil, err
			}
		}
	}

	now := time.Now()
	op := store.FleetOperation{ID: newOperationID(), FleetID: target.FleetID, Action: tool,
		Request: w.canonical, Actor: p.Actor, Idem: idem, Status: "pending", Created: now, Updated: now}
	if placement != nil {
		b, _ := json.Marshal(placement)
		op.Placement = string(b)
	}
	if err := s.Store.InsertFleetOperation(op); err != nil {
		if errors.Is(err, store.ErrIdemTaken) {
			// A concurrent call with the same key journalled first: it
			// is the one that runs.
			o, rerr := s.Store.FleetOperationByIdem(p.Actor, idem)
			if rerr != nil {
				return nil, rerr
			}
			return replayed(o, w)
		}
		return nil, err
	}

	envelope := map[string]any{"operation_id": op.ID, "fleet_id": target.FleetID, "action": tool,
		"params": w.params, "actor": p.Actor}
	status, result := s.sendWrite(ctx, c, target, op, envelope)
	if err := s.Store.UpdateFleetOperation(op.ID, status, result, time.Now()); err != nil {
		log.Printf("fleet operation %s: record %s: %v", op.ID, status, err)
	}
	stored, err := s.Store.FleetOperation(op.ID)
	if err != nil {
		return nil, err
	}
	return operationView(stored), nil
}

// replayed answers a repeated idempotency key: the first operation, if the
// request is the same; a refusal if the key now asks for something else.
func replayed(o store.FleetOperation, w writeRequest) (map[string]any, error) {
	if o.Request != w.canonical {
		return nil, fault("IDEMPOTENCY_CONFLICT", "Key was used for a different operation")
	}
	return operationView(o), nil
}

// writableConn is the open, compatible, write-capable channel to a node.
func (s *Server) writableConn(endpointID string) (*nodeConn, error) {
	c := s.nodes.get(endpointID)
	if c == nil {
		return nil, fault("UNAVAILABLE", "the fleet's machine is not connected; nothing was sent (writes are never queued)")
	}
	if !control.Compatible(int(c.proto.Load())) {
		return nil, fault(control.CodeProtoMismatch, control.ErrIncompatible.Error())
	}
	if !c.canWrite {
		return nil, fault("UNAVAILABLE", "this node's agent predates writes; upgrade ccquota there")
	}
	return c, nil
}

// sendWrite sends one journalled operation and returns the status and result
// to record. It never returns succeeded: the node's answer is that it TOOK the
// operation (accepted/running), or an executor's outcome if it was quick.
func (s *Server) sendWrite(ctx context.Context, c *nodeConn, target store.FleetRow, op store.FleetOperation, envelope map[string]any) (string, string) {
	errResult := func(code, msg string) string {
		b, _ := json.Marshal(map[string]any{"error": map[string]string{"code": code, "message": msg}})
		return string(b)
	}
	params, _ := json.Marshal(envelope)
	msg, err := control.New(control.TypeWrite, control.Request{Method: "submit", Params: params})
	if err != nil {
		return "failed", errResult("INTERNAL", err.Error())
	}
	// The connection checked a moment ago may have been replaced or dropped
	// since; the one in the map now is the one to use, or nothing was sent.
	if cur, err := s.writableConn(target.EndpointID); err != nil {
		e := errorObject(err)
		return "failed", errResult(e["code"], "before the write was sent: "+e["message"])
	} else {
		c = cur
	}
	ch := c.pending.add(msg.OpID)
	defer c.pending.remove(msg.OpID)
	// Not the caller's context: a client that hangs up must not turn a
	// write the node is about to acknowledge into an unknown one.
	wait := fleetWriteWait
	if op.Action == "worker_move_in" {
		// The target's agent downloads the transcript before it answers.
		wait = moveWriteWait
	}
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), wait)
	defer cancel()
	if err := wsjson.Write(wctx, c.conn, msg); err != nil {
		// A frame may have left before the error: unknown, not failed.
		return "unknown", errResult(control.CodeUnknownOutcome, "control channel write failed: "+err.Error())
	}
	select {
	case <-wctx.Done():
		return "unknown", errResult("TIMEOUT", "the node did not acknowledge the write in time; read operation_get before retrying")
	case reply := <-ch:
		if reply.Type == control.TypeError {
			e := reply.Error
			if e == nil {
				e = &control.Error{Code: "REMOTE_ERROR", Message: "the node refused the write"}
			}
			switch e.Code {
			case control.CodeUnknownOutcome, "TIMEOUT", "INTERNAL":
				return "unknown", errResult(e.Code, e.Message)
			}
			// A refusal before the node's controller journalled it: definite.
			return "failed", errResult(e.Code, e.Message)
		}
		var r control.Result
		if json.Unmarshal(reply.Payload, &r) != nil {
			return "unknown", errResult("PROTOCOL_ERROR", "malformed result from the node")
		}
		if r.MachineID != "" && r.MachineID != target.MachineID {
			return "unknown", errResult("IDENTITY_MISMATCH", "the node now answers as a different machine")
		}
		var remote struct {
			OperationID string          `json:"operation_id"`
			FleetID     string          `json:"fleet_id"`
			Action      string          `json:"action"`
			Status      string          `json:"status"`
			Result      json.RawMessage `json:"result"`
		}
		if json.Unmarshal(r.Result, &remote) != nil || remote.OperationID != op.ID ||
			remote.FleetID != op.FleetID || remote.Action != op.Action {
			return "unknown", errResult("PROTOCOL_ERROR", "remote operation identity does not match")
		}
		switch remote.Status {
		case "accepted", "running", "succeeded", "failed", "unknown":
		default:
			return "unknown", errResult("PROTOCOL_ERROR", "remote operation status is not one this hub knows")
		}
		res := string(remote.Result)
		if res == "null" {
			res = ""
		}
		return remote.Status, res
	}
}

// newOperationID mints a canonical (v4) UUID — fleet-control.py's identifier
// check accepts nothing else.
func newOperationID() string {
	b := control.NewOpID() // 32 random hex digits
	v := []byte(b)
	v[12] = '4'
	v[16] = "89ab"[strings.IndexByte("0123456789abcdef", v[16])%4]
	return string(v[0:8]) + "-" + string(v[8:12]) + "-" + string(v[12:16]) + "-" + string(v[16:20]) + "-" + string(v[20:32])
}

// --- the GitHub reads --------------------------------------------------

// GHRead is gh_issue_view / gh_pr_view / gh_pr_checks: one issue, PR or PR's
// checks through the fleet's node (fleet-gh.sh: its daemons' copy when fresh,
// else gh, else REST). Live only — there is no heartbeat copy to fall back on.
func (s *Server) GHRead(ctx context.Context, p fleetPrincipal, tool string, args map[string]any) (json.RawMessage, error) {
	if err := checkFields(args, []string{"fleet_id", "number"}, "repo", "fields"); err != nil {
		return nil, err
	}
	n, err := argInt(args["number"], "number", 1, math.MaxInt32)
	if err != nil {
		return nil, err
	}
	params := map[string]any{"fleet_id": args["fleet_id"], "number": n}
	repo, err := checkRepo(args)
	if err != nil {
		return nil, err
	}
	if repo != "" {
		params["repo"] = repo
	}
	fields, err := argString(args, "fields")
	if err != nil || (fields != "" && !validGHFields(fields)) {
		return nil, fault("INVALID_ARGUMENT", "fields must be comma-separated gh --json field names")
	}
	if fields != "" {
		params["fields"] = fields
	}
	if err := s.authorize(p, "gh:read", ""); err != nil {
		return nil, err
	}
	fid, _ := args["fleet_id"].(string)
	r, err := s.visibleFleet(p, fid)
	if err != nil {
		return nil, err
	}
	res, machine, err := s.NodeRead(ctx, r.EndpointID, tool, params)
	if err != nil {
		if errors.Is(err, ErrNodeOffline) {
			return nil, fault("UNAVAILABLE", "the fleet's machine is not connected")
		}
		return nil, err
	}
	if machine != "" && machine != r.MachineID {
		return nil, fault("IDENTITY_MISMATCH", "the node now answers as a different machine")
	}
	return res, nil
}

// validGHFields is GH_FIELDS_RE: 1–30 comma-separated names of 1–40 letters
// (spelled out, since RE2 refuses that nested repeat).
func validGHFields(s string) bool {
	parts := strings.Split(s, ",")
	if len(parts) > 30 {
		return false
	}
	for _, p := range parts {
		if !ghFieldRE.MatchString(p) {
			return false
		}
	}
	return true
}

// --- placement ---------------------------------------------------------

// Placement thresholds (EPIC #1407 C3): a machine above maxLoadPerCore or
// below minFreeMem is never chosen. Variables so tests can move them.
var (
	maxLoadPerCore         = 0.8
	minFreeMem     float64 = 1 << 30
)

// defaultNodeCaps is fleet.node_cap.<node> when the hub sets nothing: the
// 2026-10-03 decision — everyone may use m4, at most 6 sessions each.
var defaultNodeCaps = map[string]int{"m4": 6}

// NodeCapPrefix names the per-person, per-machine session cap setting.
const NodeCapPrefix = "fleet.node_cap."

// Candidate is one machine pickNode considered, and its verdict.
type Candidate struct {
	Machine    string `json:"machine"`
	OSUser     string `json:"os_user"`
	EndpointID string `json:"endpoint_id"`
	FleetID    string `json:"fleet_id"`
	FleetName  string `json:"fleet_name"`
	// LoadPerCore is load1 / ncpu; nil when the node did not say.
	LoadPerCore  *float64 `json:"load_per_core"`
	MemFreeBytes uint64   `json:"mem_free_bytes"`
	// Sessions is this login's sessions on the machine; Cap the per-person
	// cap there (nil: none).
	Sessions int  `json:"sessions"`
	Cap      *int `json:"cap"`
	// QuotaUsedPct is the busier of the 5-hour and 7-day windows of the
	// account this login's Claude Code runs on; nil when unknown.
	QuotaUsedPct *float64 `json:"quota_used_pct"`
	Eligible     bool     `json:"eligible"`
	Excluded     string   `json:"excluded,omitempty"`
	Score        float64  `json:"score"`
	// Kind is ephemeral for a SPOT node (claude-fleet#1428): its score is
	// multiplied by the SPOT weight, so a fixed machine with room wins.
	Kind string `json:"kind,omitempty"`
	// Ready is the node's own word on whether it can take a NEW session
	// (claude-fleet#1475: gh logged in, a usable credential, the checkouts
	// present); nil from an agent that does not say. An `auto` placement
	// never picks a node that says false — only a name asks for it.
	Ready    *bool  `json:"ready,omitempty"`
	NotReady string `json:"not_ready,omitempty"`
}

// Placement is pickNode's answer, journalled with the operation.
type Placement struct {
	Requested  string      `json:"requested"` // auto | a machine name
	Repo       string      `json:"repo"`
	Machine    string      `json:"machine"`
	FleetID    string      `json:"fleet_id"`
	Reason     string      `json:"reason"`
	Candidates []Candidate `json:"candidates"`
	At         time.Time   `json:"at"`
}

// PickNode is pick_node(user, repo) — the placement EPIC B's dispatcher
// calls (claude-fleet#1410): among the machines where person has an active
// login with a fleet hosting repo, drop the offline ones, those above 0.8
// load per core, short of free memory, or at the person's cap there; score
// the rest by account headroom (60%) and load (40%); return the best, with
// every candidate's verdict. person "" is the operator.
func (s *Server) PickNode(person, repo string) (Placement, error) {
	scope, err := s.scopeFor(person)
	if err != nil {
		return Placement{}, err
	}
	return s.pickNode(fleetPrincipal{Actor: person, Person: person, scope: scope}, repo, "auto", time.Now())
}

// scopeFor is FleetScope for a person named directly, not through a request.
func (s *Server) scopeFor(person string) (func(hostname, osUser string) bool, error) {
	if person == "" {
		return nil, nil
	}
	r, _ := http.NewRequest(http.MethodGet, "/", nil)
	return s.fleetScope(r.WithContext(context.WithValue(r.Context(), principalKey{}, person)))
}

// sameMachine matches a roster hostname against a name a caller gave: the
// whole name, or its first label ("m4" for "m4.local"), case-insensitively.
func sameMachine(hostname, name string) bool {
	h, n := strings.ToLower(hostname), strings.ToLower(name)
	if h == n {
		return true
	}
	if i := strings.IndexByte(h, '.'); i > 0 && h[:i] == n {
		return true
	}
	return false
}

// nodeCap is the per-person session cap on hostname, from the hub's settings
// or the defaults; ok false when there is none.
func (s *Server) nodeCap(hostname string, settings map[string]string) (int, bool) {
	for k, v := range settings {
		if strings.HasPrefix(k, NodeCapPrefix) && sameMachine(hostname, k[len(NodeCapPrefix):]) {
			if n, err := strconv.Atoi(v); err == nil {
				return n, true
			}
		}
	}
	for k, n := range defaultNodeCaps {
		if _, set := settings[NodeCapPrefix+k]; !set && sameMachine(hostname, k) {
			return n, true
		}
	}
	return 0, false
}

// nodeStatusOf reads one endpoint's newest heartbeat from the roster.
func (s *Server) nodeStatusOf(endpointID string, now time.Time) (control.Heartbeat, string, bool) {
	rows, err := s.Store.Nodes()
	if err != nil {
		return control.Heartbeat{}, "", false
	}
	for _, n := range rows {
		if n.EndpointID == endpointID {
			var hb control.Heartbeat
			_ = json.Unmarshal([]byte(n.StatusJSON), &hb)
			return hb, NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now), true
		}
	}
	return control.Heartbeat{}, "lost", false
}

// checkNodeCap refuses a start or resume that would take a person past their
// cap on the fleet's machine.
func (s *Server) checkNodeCap(r store.FleetRow, now time.Time) error {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	limit, ok := s.nodeCap(r.Hostname, settings)
	if !ok {
		return nil
	}
	hb, _, _ := s.nodeStatusOf(r.EndpointID, now)
	if hb.Sessions >= limit {
		return fault("AT_CAPACITY", fmt.Sprintf("%s@%s already runs %d sessions; the per-person cap there is %d",
			r.OSUser, r.Hostname, hb.Sessions, limit))
	}
	return nil
}

// loginAccounts maps endpoint → the account its own Claude Code login uses,
// the most recently seen one.
func (s *Server) loginAccounts() map[string]string {
	out := map[string]string{}
	rows, err := s.Store.EndpointAccounts(store.AllAccounts, 2000)
	if err != nil {
		return out
	}
	for _, r := range rows { // newest first
		if r.Origin != "login" {
			continue
		}
		if _, seen := out[r.EndpointID]; !seen {
			out[r.EndpointID] = r.AccountUUID
		}
	}
	return out
}

func (s *Server) pickNode(p fleetPrincipal, repo, node string, now time.Time) (Placement, error) {
	pl := Placement{Requested: node, Repo: repo, Candidates: []Candidate{}, At: now.UTC()}
	_, rows, err := s.visibleFleets(p, now)
	if err != nil {
		return pl, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return pl, err
	}
	accounts := s.loginAccounts()
	// SPOT nodes (claude-fleet#1428): which endpoints are ephemeral, and
	// where each is in its life. Empty maps on a hub without any.
	kinds, _ := s.Store.EphemeralEndpoints()
	spotState := map[string]string{}
	if spots, err := s.Store.SpotNodes(false, 0); err == nil {
		for _, sp := range spots {
			if sp.EndpointID != "" {
				spotState[sp.EndpointID] = sp.State
			}
		}
	}
	weight := s.spotWeight(settings)
	seen := map[string]bool{}
	for _, r := range rows {
		if !r.Present || seen[r.EndpointID] || !repoNamed(r.Repo, repo) {
			continue
		}
		if node != "auto" && !sameMachine(r.Hostname, node) {
			continue
		}
		if p.Person == "" && len(s.FleetAdmins) > 0 && !hasString(s.FleetAdmins, r.OSUser) {
			// The operator's doors see every login; placing the operator's
			// own start on a colleague's fleet is never what was meant.
			continue
		}
		seen[r.EndpointID] = true // one fleet per login: the first by name
		c := s.judge(r, settings, accounts, now)
		if node == "auto" && c.Eligible && c.Ready != nil && !*c.Ready {
			// The node says it cannot take a new session (claude-fleet#1475:
			// no gh login, no credential, a missing checkout). auto never
			// sends work there; naming it with --node still does.
			c.Eligible, c.Excluded = false, "not ready: "+c.NotReady
		}
		if k := kinds[r.EndpointID]; k != "" {
			c.Kind = k
			if st := spotState[r.EndpointID]; st != "" && st != store.SpotOnline && c.Eligible {
				// Starting, releasing or being reclaimed: not a place for
				// new work.
				c.Eligible, c.Excluded = false, "SPOT node "+st
			}
			c.Score = math.Round(c.Score*weight*1000) / 1000
		}
		pl.Candidates = append(pl.Candidates, c)
	}
	if len(pl.Candidates) == 0 {
		where := "any of your machines"
		if node != "auto" {
			where = node
		}
		return pl, fault("NOT_FOUND", "No fleet hosting "+repo+" on "+where)
	}
	best := -1
	for i, c := range pl.Candidates {
		if !c.Eligible {
			continue
		}
		if best < 0 || better(c, pl.Candidates[best]) {
			best = i
		}
	}
	if best < 0 {
		reasons := []string{}
		for _, c := range pl.Candidates {
			reasons = append(reasons, c.Machine+": "+c.Excluded)
		}
		msg := "No machine can take a new session now — " + strings.Join(reasons, "; ")
		if s.Spot != nil && node == "auto" {
			// Peak: every fixed machine is out. Ask for a SPOT node
			// (claude-fleet#1428); the next placement finds it.
			msg += "; " + s.Spot.Want("placement for "+repo+" found no eligible machine: "+strings.Join(reasons, "; "))
		}
		return pl, fault("NO_ELIGIBLE_NODE", msg)
	}
	c := pl.Candidates[best]
	pl.Machine, pl.FleetID = c.Machine, c.FleetID
	pl.Reason = placementReason(c, pl.Candidates)
	return pl, nil
}

// judge scores one candidate login.
func (s *Server) judge(r store.FleetRow, settings map[string]string, accounts map[string]string, now time.Time) Candidate {
	c := Candidate{Machine: r.Hostname, OSUser: r.OSUser, EndpointID: r.EndpointID, FleetID: r.FleetID, FleetName: r.Name}
	hb, status, _ := s.nodeStatusOf(r.EndpointID, now)
	c.Sessions, c.MemFreeBytes = hb.Sessions, hb.MemFreeBytes
	c.Ready, c.NotReady = hb.Ready, hb.NotReady
	if hb.Ready == nil || *hb.Ready {
		c.NotReady = ""
	}
	if hb.NCPU > 0 {
		l := hb.Load1 / float64(hb.NCPU)
		c.LoadPerCore = &l
	}
	if n, ok := s.nodeCap(r.Hostname, settings); ok {
		c.Cap = &n
	}
	if acct := accounts[r.EndpointID]; acct != "" {
		if snap, err := s.Store.LatestLimits(acct); err == nil && snap != nil {
			u := math.Max(snap.FiveHour.Utilization, snap.SevenDay.Utilization)
			c.QuotaUsedPct = &u
		}
	}
	_, connErr := s.writableConn(r.EndpointID)
	switch {
	case status != "online":
		c.Excluded = "offline"
	case connErr != nil:
		c.Excluded = errorObject(connErr)["message"]
	case c.LoadPerCore != nil && *c.LoadPerCore > maxLoadPerCore:
		c.Excluded = fmt.Sprintf("load %.2f/core > %.1f", *c.LoadPerCore, maxLoadPerCore)
	case hb.MemTotalBytes > 0 && float64(hb.MemFreeBytes) < minFreeMem:
		c.Excluded = fmt.Sprintf("free memory %.1f GiB < %.1f GiB", float64(hb.MemFreeBytes)/(1<<30), minFreeMem/(1<<30))
	case c.Cap != nil && c.Sessions >= *c.Cap:
		c.Excluded = fmt.Sprintf("at the per-person cap (%d/%d sessions)", c.Sessions, *c.Cap)
	default:
		c.Eligible = true
	}
	headroom, idle := 0.5, 0.5 // unknown reads as middling, never as best
	if c.QuotaUsedPct != nil {
		headroom = math.Max(0, 1-*c.QuotaUsedPct/100)
	}
	if c.LoadPerCore != nil {
		idle = math.Max(0, 1-*c.LoadPerCore/maxLoadPerCore)
	}
	c.Score = math.Round((0.6*headroom+0.4*idle)*1000) / 1000
	return c
}

// better orders two eligible candidates: score, then fewer sessions, then name.
func better(a, b Candidate) bool {
	if a.Score != b.Score {
		return a.Score > b.Score
	}
	if a.Sessions != b.Sessions {
		return a.Sessions < b.Sessions
	}
	return a.Machine+"/"+a.OSUser < b.Machine+"/"+b.OSUser
}

func placementReason(c Candidate, all []Candidate) string {
	parts := []string{fmt.Sprintf("chose %s (score %.3f", c.Machine, c.Score)}
	if c.Kind == store.NodeKindEphemeral {
		parts = append(parts, "SPOT node")
	}
	if c.LoadPerCore != nil {
		parts = append(parts, fmt.Sprintf("load %.2f/core", *c.LoadPerCore))
	}
	if c.QuotaUsedPct != nil {
		parts = append(parts, fmt.Sprintf("account %.0f%% used", *c.QuotaUsedPct))
	}
	if c.Cap != nil {
		parts = append(parts, fmt.Sprintf("%d/%d sessions", c.Sessions, *c.Cap))
	} else {
		parts = append(parts, fmt.Sprintf("%d sessions", c.Sessions))
	}
	out := strings.Join(parts, ", ") + ")"
	others := []string{}
	for _, o := range all {
		if o.EndpointID == c.EndpointID {
			continue
		}
		if o.Eligible {
			others = append(others, fmt.Sprintf("%s scored %.3f", o.Machine, o.Score))
		} else {
			others = append(others, o.Machine+" excluded: "+o.Excluded)
		}
	}
	sort.Strings(others)
	if len(others) > 0 {
		out += "; " + strings.Join(others, "; ")
	}
	return out
}

// --- settings ----------------------------------------------------------

// handleFleetSettings serves GET/PUT /v1/fleet/settings — the operator's
// (mounted behind operatorOnly). Only fleet.node_cap.<machine> exists: an
// integer 0–256, or "" to fall back to the default.
func (s *Server) handleFleetSettings(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
	case http.MethodPut, http.MethodPost:
		var body struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
			httpError(w, http.StatusBadRequest, "body must be {\"key\":…,\"value\":…}")
			return
		}
		switch {
		case body.Key == SpotWeightKey:
			// The SPOT placement weight (claude-fleet#1428): 0–2, or ""
			// for CCQUOTA_FLEET_SPOT_WEIGHT's value.
			if body.Value != "" {
				if f, err := strconv.ParseFloat(body.Value, 64); err != nil || f < 0 || f > 2 {
					httpError(w, http.StatusBadRequest, "the SPOT weight is a number 0–2, or \"\" for the default")
					return
				}
			}
		case strings.HasPrefix(body.Key, NodeCapPrefix) && nodeNameRE.MatchString(body.Key[len(NodeCapPrefix):]):
			if body.Value != "" {
				if n, err := strconv.Atoi(body.Value); err != nil || n < 0 || n > 256 {
					httpError(w, http.StatusBadRequest, "a node cap is an integer 0–256, or \"\" for the default")
					return
				}
			}
		default:
			httpError(w, http.StatusBadRequest, "only fleet.node_cap.<machine> and "+SpotWeightKey+" are settable")
			return
		}
		if err := s.Store.SetFleetSetting(body.Key, body.Value, time.Now()); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	default:
		w.Header().Set("Allow", "GET, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET or PUT")
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	eff := map[string]any{}
	for k, n := range defaultNodeCaps {
		eff[NodeCapPrefix+k] = n
	}
	for k, v := range settings {
		if n, err := strconv.Atoi(v); err == nil {
			eff[k] = n
		}
	}
	eff[SpotWeightKey] = s.spotWeight(settings)
	writeJSON(w, http.StatusOK, map[string]any{"settings": settings, "effective": eff})
}
