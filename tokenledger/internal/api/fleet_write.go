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
// — load per core, free memory and memory pressure, any per-person cap set,
// then the tighter of CPU and memory idle; never account quota, which every
// machine shares (claude-fleet#1994) — and the reasoning is journalled beside
// the operation.
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

// DefaultPersonScopes is what a person signed in with GitHub may do on
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

// maxScratchName bounds a scratch's name (claude-fleet#1541): the opener clips
// it to 24 display columns anyway; the hub only keeps it a label.
const maxScratchName = 64

// checkScratchName reads a scratch start's optional name: absent or blank is
// no name; otherwise 1–64 characters with no control characters and no `#`
// (tmux's format character — dash-raw-session.sh strips it, the hub refuses
// it so the name that opens is the name that was asked for).
func checkScratchName(v any) (string, error) {
	if v == nil {
		return "", nil
	}
	t, ok := v.(string)
	if !ok {
		return "", fault("INVALID_ARGUMENT", "name must be a string")
	}
	t = strings.TrimSpace(t)
	if t == "" {
		return "", nil
	}
	if len([]rune(t)) > maxScratchName {
		return "", fault("INVALID_ARGUMENT", fmt.Sprintf("name must be at most %d characters", maxScratchName))
	}
	for _, c := range t {
		if c < 32 || c == 127 || c == '#' {
			return "", fault("INVALID_ARGUMENT", "name must not contain control characters or #")
		}
	}
	return t, nil
}

// maxIssueTitle is GitHub's own bound on an issue title.
const maxIssueTitle = 256

// checkIssueTitle reads a new-issue start's title (claude-fleet#1953): one
// line, 1–256 characters, nothing that could forge a <!-- fleet:… --> marker
// or drive a pane — check_issue_title on the node, letter for letter.
func checkIssueTitle(v any) (string, error) {
	t, ok := v.(string)
	if !ok || strings.TrimSpace(t) == "" || len([]rune(t)) > maxIssueTitle {
		return "", fault("INVALID_ARGUMENT", fmt.Sprintf("title must be one line of 1-%d characters", maxIssueTitle))
	}
	if strings.Contains(t, "<!--") {
		return "", fault("INVALID_ARGUMENT", "title must not contain HTML comments or control characters")
	}
	for _, c := range t {
		if c < 32 || c == 127 {
			return "", fault("INVALID_ARGUMENT", "title must not contain HTML comments or control characters")
		}
	}
	return strings.TrimSpace(t), nil
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

// hostsRepo is repoNamed over every repo a fleet hosts (claude-fleet#1512):
// its own and each repos/ overlay (#788), so a fleet whose first repo is
// another one is still a candidate for this one's issues.
func hostsRepo(r store.FleetRow, want string) bool {
	for _, repo := range r.HostedRepos() {
		if repoNamed(repo, want) {
			return true
		}
	}
	return false
}

// targetKey is the key a session gets in the fleet it is placed or moved
// into. A key carries its repo's slug only in a fleet hosting several
// (fleetid.WorkerKey), so the source's spelling is re-made for the target:
// bare in a one-repo fleet, <slug>:… in a multi-repo one. A target from an
// agent that did not report its repos keeps the source's key, as before.
func targetKey(key string, target store.FleetRow, repo string) string {
	if len(target.Repos) == 0 {
		return key
	}
	bare := key
	if i := strings.LastIndex(key, ":"); i >= 0 {
		bare = key[i+1:]
	}
	if len(target.Repos) < 2 {
		return bare
	}
	return fleetid.RepoSlug(repo) + ":" + bare
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
		if err = checkFields(args, []string{"idempotency_key"}, "issue", "kind", "name", "title", "body", "fleet_id", "agent", "repo", "no_repo", "node", "origin_wid", "account_class", "reap"); err != nil {
			break
		}
		// kind (claude-fleet#1541): "issue" (the default — a worker on an
		// issue, `issue` required) or "scratch" (a raw scratch session: no
		// issue, an optional name; it is dash-raw-session.sh that opens it) or
		// "new" (claude-fleet#1953: the client's writing area — a title and an
		// optional body; the node files the issue, then opens its worker).
		var kind string
		if kind, err = argString(args, "kind"); err != nil {
			break
		}
		switch kind {
		case "", "issue":
			if _, ok := args["issue"]; !ok {
				err = fault("INVALID_ARGUMENT", "Missing or unsupported request fields")
			} else if _, ok := args["name"]; ok {
				err = fault("INVALID_ARGUMENT", "name belongs to a scratch start (kind=scratch)")
			}
		case "scratch":
			if _, ok := args["issue"]; ok {
				err = fault("INVALID_ARGUMENT", "a scratch start has no issue")
			}
		case "new":
			if _, ok := args["issue"]; ok {
				err = fault("INVALID_ARGUMENT", "a new-issue start has no issue: the node files it")
			} else if _, ok := args["name"]; ok {
				err = fault("INVALID_ARGUMENT", "name belongs to a scratch start (kind=scratch)")
			}
		default:
			err = fault("INVALID_ARGUMENT", "kind must be issue, scratch or new")
		}
		if err == nil && kind != "new" {
			if _, ok := args["title"]; ok {
				err = fault("INVALID_ARGUMENT", "title belongs to a new-issue start (kind=new)")
			} else if _, ok := args["body"]; ok && kind != "scratch" {
				err = fault("INVALID_ARGUMENT", "body belongs to a new-issue or scratch start (kind=new / scratch)")
			}
		}
		// no_repo (claude-fleet#1956): a scratch that belongs to no repo — the
		// node opens it in $HOME, stamped @norepo (dash-raw-session.sh
		// --no-repo). Only a scratch, only `true`, never beside a repo.
		noRepo := false
		if v, ok := args["no_repo"]; err == nil && ok {
			if b, isBool := v.(bool); !isBool || !b {
				err = fault("INVALID_ARGUMENT", "no_repo must be true when given")
			} else if kind != "scratch" {
				err = fault("INVALID_ARGUMENT", "no_repo belongs to a scratch start (kind=scratch)")
			} else if r, _ := args["repo"].(string); r != "" {
				err = fault("INVALID_ARGUMENT", "no_repo names no repo")
			} else {
				noRepo = true
			}
		}
		if err != nil {
			break
		}
		if kind == "new" {
			w.params["kind"] = "new"
			var title, body string
			if title, err = checkIssueTitle(args["title"]); err != nil {
				break
			}
			w.params["title"] = title
			if b, ok := args["body"]; ok && b != "" {
				if body, err = checkText(b, "body"); err != nil {
					break
				}
				w.params["body"] = body
			}
		} else if kind == "scratch" {
			w.params["kind"] = "scratch"
			var name string
			if name, err = checkScratchName(args["name"]); err != nil {
				break
			}
			if name != "" {
				w.params["name"] = name
			}
			// body (claude-fleet#1956): the writing area's text — the
			// scratch starts working on it (dash-raw-session.sh --prompt).
			if b, ok := args["body"]; ok && b != "" {
				var body string
				if body, err = checkText(b, "body"); err != nil {
					break
				}
				w.params["body"] = body
			}
			if noRepo {
				w.params["no_repo"] = true
			}
		} else {
			var issue int
			if issue, err = argInt(args["issue"], "issue", 1, math.MaxInt32); err != nil {
				break
			}
			w.params["issue"] = issue
		}
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
		// account_class (claude-fleet#1540): the kind of subscription the
		// session runs on — local / pool bind the node's pick, any / absent
		// leave it. One of three words, never free text.
		var acls string
		if acls, err = argString(args, "account_class"); err != nil {
			break
		}
		if !accountClassOK(acls) {
			err = fault("INVALID_ARGUMENT", "account_class must be local, pool or any")
			break
		}
		if accountClassBinds(acls) {
			w.params["account_class"] = acls
		}
		// reap (claude-fleet#1902): when the fleet may close the session on
		// its own — the node's dash-*-session.sh --reap canonicalizes it; here
		// it is held to the grammar's shape so it is one argv word, never text.
		var reap string
		if reap, err = argString(args, "reap"); err != nil {
			break
		}
		if !reapPolicyOK(reap) {
			err = fault("INVALID_ARGUMENT", "reap must be merged[:<dur>], done[:<dur>], loop-end, at:<time> or keep")
			break
		}
		if reap != "" {
			w.params["reap"] = reap
		}
		if w.node == "" {
			w.node = "auto"
		}
		if w.node != "auto" && !nodeNameRE.MatchString(w.node) {
			err = fault("INVALID_ARGUMENT", "node must be auto or a machine name from the roster")
			break
		}
		if w.fleetID == "" && w.repo == "" && !noRepo {
			// A placed start must say which repo: the machine is chosen
			// among fleets that host it (a no-repo scratch: among all).
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
		if tool == "worker_start" && placement == nil {
			// A start named straight at a personal machine's fleet
			// (claude-fleet#1721) is held to placement's rule: only from it.
			now := time.Now()
			hb, _, _ := s.nodeStatusOf(target.EndpointID, now)
			if s.personalOf(target.EndpointID, hb) && !s.isMachine(target.Hostname, s.askedFrom(p, now)) {
				return nil, fault("NO_ELIGIBLE_NODE", target.Hostname+": "+excludedPersonal+" — open it from that computer's own client")
			}
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
	if p.Worker != nil {
		op.WorkerID = p.Worker.WorkerID // the session the node asked for (claude-fleet#1810)
	}
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
	s.progressOp(stored) // the asking parent's stream (claude-fleet#1648)
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

// Placement thresholds (EPIC #1407 C3, claude-fleet#1994): a machine above
// maxLoadPerCore, below its free-memory floor (minFreeMem or minFreeMemFrac
// of its total, whichever is larger) or at memory pressure memPressureWarn
// is never chosen. Variables so tests can move them.
//
// The floor: a worker's claude is ~300-400 MB, with node / MCP children a new
// session wants ~1 GB, and the system keeps one session's worth on top.
var (
	maxLoadPerCore          = 0.8
	minFreeMem      float64 = 2 << 30
	minFreeMemFrac          = 0.10
	memPressureWarn         = 2
)

// memFloor is the free memory a machine of total bytes must keep to take a
// new session: max(minFreeMem, minFreeMemFrac × total).
func memFloor(total uint64) float64 {
	return math.Max(minFreeMem, minFreeMemFrac*float64(total))
}

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
	LoadPerCore   *float64 `json:"load_per_core"`
	MemFreeBytes  uint64   `json:"mem_free_bytes"`
	MemTotalBytes uint64   `json:"mem_total_bytes,omitempty"`
	// MemPressure is the node's memory-pressure level (darwin: 1 normal,
	// 2 warn, 4 critical); absent when it did not say.
	MemPressure int `json:"mem_pressure,omitempty"`
	// Sessions is this login's sessions on the machine — nil when a fleet of
	// the login could not be read (claude-fleet#1465), SessionsUnknown then
	// says which and why; Cap the per-person cap there (nil: none).
	Sessions        *int   `json:"sessions"`
	SessionsUnknown string `json:"sessions_unknown,omitempty"`
	Cap             *int   `json:"cap"`
	// MaxSessions is the login's OWN cap (claude-fleet#1587, its
	// FLEET_GLOBAL_MAX_SESSIONS) and CapSessions the count its gate reads;
	// absent from a node that does not say. Full there = never a candidate.
	MaxSessions int  `json:"max_sessions,omitempty"`
	CapSessions *int `json:"cap_sessions,omitempty"`
	// QuotaUsedPct is the busier of the 5-hour and 7-day windows of the
	// account this login's Claude Code runs on; nil when unknown. Shown, never
	// scored (claude-fleet#1994): every machine spends the same shared quota.
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
	// Personal is a person's own computer (claude-fleet#1721): a candidate
	// only for a start asked from it.
	Personal bool `json:"personal,omitempty"`
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
// load per core, below max(2 GiB, 10% of total) free memory, under memory
// pressure, or at a cap set for the person there; score the rest by load
// alone — min(cpu idle, memory idle), whichever resource is tighter
// (claude-fleet#1994: account quota is shared by every machine, so it never
// decides where); return the best, with every candidate's verdict. person ""
// is the operator.
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

// nodeCap is the per-person session cap on hostname, from the hub's settings;
// ok false when there is none — no machine has a default (claude-fleet#1994:
// load decides).
func (s *Server) nodeCap(hostname string, settings map[string]string) (int, bool) {
	for k, v := range settings {
		if strings.HasPrefix(k, NodeCapPrefix) && sameMachine(hostname, k[len(NodeCapPrefix):]) {
			if n, err := strconv.Atoi(v); err == nil {
				return n, true
			}
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
	if u := hb.UnreadableFleets(); len(u) > 0 {
		// An unread fleet may hold the whole cap (claude-fleet#1465).
		return fault("AT_CAPACITY", fmt.Sprintf("%s@%s's session count is unknown (%s); the per-person cap there is %d",
			r.OSUser, r.Hostname, strings.Join(u, "; "), limit))
	}
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
	from := s.askedFrom(p, now) // claude-fleet#1721: who may land on a personal machine
	seen := map[string]bool{}
	for _, r := range rows {
		if !r.Present || seen[r.EndpointID] || (repo != "" && !hostsRepo(r, repo)) {
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
		if c.Eligible && c.Personal && !s.isMachine(r.Hostname, from) {
			// A person's own computer (claude-fleet#1721): only what is
			// asked from it lands there — auto or named.
			c.Eligible, c.Excluded = false, excludedPersonal
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
		if repo == "" {
			return pl, fault("NOT_FOUND", "No fleet on "+where)
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
		reasons, full := []string{}, true
		for _, c := range pl.Candidates {
			reasons = append(reasons, c.Machine+": "+c.Excluded)
			full = full && excludedForFullness(c.Excluded)
		}
		msg := "No machine can take a new session now — " + strings.Join(reasons, "; ")
		if full {
			// Every candidate is at its own cap (claude-fleet#1587): say so
			// as the refusal a full machine gives, not as "no machine".
			msg = "all-full: every machine is at its session cap — " + strings.Join(reasons, "; ")
		}
		if s.Spot != nil && node == "auto" {
			// Peak: every fixed machine is out. Ask for a SPOT node
			// (claude-fleet#1428); the next placement finds it.
			msg += "; " + s.Spot.Want("placement for "+repo+" found no eligible machine: "+strings.Join(reasons, "; "))
		}
		if full {
			return pl, fault("AT_CAPACITY", msg)
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
	c.Sessions, c.MemFreeBytes = hb.SessionsCount(), hb.MemFreeBytes
	c.MemTotalBytes, c.MemPressure = hb.MemTotalBytes, hb.MemPressure
	if c.Sessions == nil {
		c.SessionsUnknown = strings.Join(hb.UnreadableFleets(), "; ")
	}
	c.Ready, c.NotReady = hb.Ready, hb.NotReady
	c.Personal = s.personalOf(r.EndpointID, hb)
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
	full, used, own := hb.Full()
	c.MaxSessions, c.CapSessions = hb.MaxSessions, hb.CapSessions
	if acct := accounts[r.EndpointID]; acct != "" {
		if snap, err := s.Store.LatestLimits(acct); err == nil && snap != nil {
			u := math.Max(snap.FiveHour.Utilization, snap.SevenDay.Utilization)
			c.QuotaUsedPct = &u
		}
	}
	_, connErr := s.writableConn(r.EndpointID)
	maint, flagged := maintenanceOf(r.Hostname, settings)
	cv := s.computeOf(r.EndpointID, hb, settings, now)
	switch {
	case status != "online":
		c.Excluded = "offline"
	case cv.Off:
		// 只协调 (claude-fleet#1719): the login asked for no sessions, or its
		// egress region closed it (#1720) — out for auto AND for a start
		// that names it.
		c.Excluded = cv.Why
	case flagged:
		// 维护中 (claude-fleet#1427): the operator is taking the machine down.
		// Out for auto AND for a start that names it — unlike not-ready, this
		// is a decision about the machine, not a report from it.
		c.Excluded = "maintenance"
		if maint.Reason != "" {
			c.Excluded += ": " + maint.Reason
		}
	case connErr != nil:
		c.Excluded = errorObject(connErr)["message"]
	case c.LoadPerCore != nil && *c.LoadPerCore > maxLoadPerCore:
		c.Excluded = fmt.Sprintf("load %.2f/core > %.1f", *c.LoadPerCore, maxLoadPerCore)
	case hb.MemTotalBytes > 0 && float64(hb.MemFreeBytes) < memFloor(hb.MemTotalBytes):
		c.Excluded = fmt.Sprintf("free memory %.1f GiB < %.1f GiB", float64(hb.MemFreeBytes)/(1<<30), memFloor(hb.MemTotalBytes)/(1<<30))
	case hb.MemPressure >= memPressureWarn:
		c.Excluded = fmt.Sprintf("memory pressure %s", memPressureName(hb.MemPressure))
	case c.Cap != nil && c.Sessions == nil:
		c.Excluded = fmt.Sprintf("session count unknown (%s); the per-person cap %d cannot be checked", c.SessionsUnknown, *c.Cap)
	case c.Cap != nil && *c.Sessions >= *c.Cap:
		c.Excluded = fmt.Sprintf("%s (%d/%d sessions)", excludedPersonCap, *c.Sessions, *c.Cap)
	case full:
		// The login's own cap (claude-fleet#1587): its spawn gate would refuse
		// the start, so it is no candidate — named or auto.
		c.Excluded = fmt.Sprintf("%s (%d/%d sessions, the login's own cap)", excludedFull, used, own)
	default:
		c.Eligible = true
	}
	score := loadScore(c.LoadPerCore, hb.MemFreeBytes, hb.MemTotalBytes)
	if c.Sessions == nil {
		// A login whose fleet could not be read may run any number of
		// sessions (claude-fleet#1465): never scored as the idle 0 the
		// heartbeat's sum says. better() also ranks it after every known one.
		score *= unknownSessionsWeight
	}
	c.Score = math.Round(score*1000) / 1000
	return c
}

// loadScore is how much room a machine has (claude-fleet#1994): the tighter of
// its CPU idle (1 − load per core / maxLoadPerCore) and its memory idle (free /
// total), each clamped to 0..1 — whichever runs out first decides. A reading
// the node did not give counts as middling (0.5), never as best.
func loadScore(loadPerCore *float64, memFree, memTotal uint64) float64 {
	cpu, mem := 0.5, 0.5
	if loadPerCore != nil {
		cpu = clamp01(1 - *loadPerCore/maxLoadPerCore)
	}
	if memTotal > 0 {
		mem = clamp01(float64(memFree) / float64(memTotal))
	}
	return math.Min(cpu, mem)
}

func clamp01(x float64) float64 { return math.Max(0, math.Min(1, x)) }

// memPressureName spells a darwin memory-pressure level.
func memPressureName(lv int) string {
	switch lv {
	case 2:
		return "warn"
	case 4:
		return "critical"
	}
	return strconv.Itoa(lv)
}

// excludedFull opens the verdict on a login at its own session cap
// (claude-fleet#1587); excludedPersonCap the one at the hub's per-person cap.
const (
	excludedFull      = "full"
	excludedPersonCap = "at the per-person cap"
)

// excludedForFullness reports whether a candidate is out only because it has
// no free session slot: when every candidate is, placement refuses
// AT_CAPACITY "all-full" (claude-fleet#1587) rather than NO_ELIGIBLE_NODE.
func excludedForFullness(why string) bool {
	return strings.HasPrefix(why, excludedFull) || strings.HasPrefix(why, excludedPersonCap)
}

// unknownSessionsWeight discounts the score of a candidate whose session count
// is unknown (claude-fleet#1465).
const unknownSessionsWeight = 0.5

// better orders two eligible candidates: a known session count before an
// unknown one (claude-fleet#1465), then score, then fewer sessions, then name.
func better(a, b Candidate) bool {
	if (a.Sessions == nil) != (b.Sessions == nil) {
		return a.Sessions != nil
	}
	if a.Score != b.Score {
		return a.Score > b.Score
	}
	if a.Sessions != nil && *a.Sessions != *b.Sessions {
		return *a.Sessions < *b.Sessions
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
	if c.MemTotalBytes > 0 {
		parts = append(parts, fmt.Sprintf("%.1f/%.0f GiB free", float64(c.MemFreeBytes)/(1<<30), float64(c.MemTotalBytes)/(1<<30)))
	}
	switch {
	case c.Sessions == nil:
		parts = append(parts, "sessions unknown: "+c.SessionsUnknown)
	case c.Cap != nil:
		parts = append(parts, fmt.Sprintf("%d/%d sessions", *c.Sessions, *c.Cap))
	default:
		parts = append(parts, fmt.Sprintf("%d sessions", *c.Sessions))
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
// (mounted behind adminOnly). fleet.node_cap.<machine> is an integer 0–256,
// or "" to fall back to the default; fleet.spot_weight a number 0–2;
// fleet.node_maintenance.<machine> (claude-fleet#1427) a reason — any text,
// "" to end the maintenance — stored as the dated record the roster shows;
// fleet.client_defaults.<KEY> (claude-fleet#1722) a client's team default;
// fleet.node_trust.<machine> (claude-fleet#1968) trusted | untrusted;
// fleet.node_relay.<machine> (claude-fleet#1974) "" only — a revocation.
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
		case strings.HasPrefix(body.Key, NodeMaintenancePrefix) && nodeNameRE.MatchString(body.Key[len(NodeMaintenancePrefix):]):
			machine, now := body.Key[len(NodeMaintenancePrefix):], time.Now()
			reason := strings.TrimSpace(body.Value)
			if len(reason) > 200 {
				httpError(w, http.StatusBadRequest, "the maintenance reason is at most 200 characters")
				return
			}
			if reason == "" {
				was, err := s.leaveMaintenance(machine, now)
				if err != nil {
					httpError(w, http.StatusInternalServerError, err.Error())
					return
				}
				s.maintenanceAudit("operator", machine, map[bool]string{true: "LEAVE", false: "NOT_FLAGGED"}[was], now)
			} else {
				m, already, err := s.enterMaintenance(machine, reason, "operator", now)
				if err != nil {
					httpError(w, http.StatusInternalServerError, err.Error())
					return
				}
				s.maintenanceAudit("operator", machine, map[bool]string{true: "ALREADY", false: "ENTER"}[already]+": "+m.Reason, now)
			}
			s.writeFleetSettings(w)
			return
		case strings.HasPrefix(body.Key, NodeTrustPrefix) && nodeNameRE.MatchString(body.Key[len(NodeTrustPrefix):]):
			// Trust (claude-fleet#1968): trusted | untrusted, "" drops the
			// key (= untrusted). The operator's only — no node route sets it.
			v := strings.TrimSpace(body.Value)
			if v != "" && v != TrustTrusted && v != TrustUntrusted {
				httpError(w, http.StatusBadRequest, "a machine's trust is trusted | untrusted, or \"\" (untrusted)")
				return
			}
			if _, err := s.setTrust(body.Key[len(NodeTrustPrefix):], v, time.Now()); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			s.relayCacheReset()
			s.writeFleetSettings(w)
			return
		case strings.HasPrefix(body.Key, NodeRelayPrefix) && nodeNameRE.MatchString(body.Key[len(NodeRelayPrefix):]):
			// A machine's relay credentials (claude-fleet#1974): the
			// operator only drops them ("" = revoke every login's); a
			// node mints its own through /v1/node/relay-credential.
			if body.Value != "" {
				httpError(w, http.StatusBadRequest, "a relay credential is only revoked here (value \"\"); a node mints its own")
				return
			}
			if err := s.revokeRelay(body.Key[len(NodeRelayPrefix):], time.Now()); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			s.writeFleetSettings(w)
			return
		case strings.HasPrefix(body.Key, ClientDefaultsPrefix):
			// A client's team default (claude-fleet#1722): whitelisted
			// keys, plain one-line values, never a credential; "" clears.
			if body.Value != "" {
				if why := clientDefaultCheck(body.Key, body.Value); why != "" {
					httpError(w, http.StatusBadRequest, why)
					return
				}
			}
		case strings.HasPrefix(body.Key, PersonBudgetPrefix) && principalKeyRE.MatchString(body.Key[len(PersonBudgetPrefix):]):
			// A person's budget (claude-fleet#1977): 5h=<tokens>,week=<tokens>;
			// "" removes it (= no limit).
			if body.Value != "" {
				b, err := parsePersonBudget(body.Value)
				if err != nil {
					httpError(w, http.StatusBadRequest, err.Error())
					return
				}
				body.Value = b.String()
			}
		case body.Key == SpotWeightKey:
			// The SPOT placement weight (claude-fleet#1428): 0–2, or ""
			// for CCQUOTA_FLEET_SPOT_WEIGHT's value.
			if body.Value != "" {
				if f, err := strconv.ParseFloat(body.Value, 64); err != nil || f < 0 || f > 2 {
					httpError(w, http.StatusBadRequest, "the SPOT weight is a number 0–2, or \"\" for the default")
					return
				}
			}
		case body.Key == ComputeAutoKey:
			// The team policy (claude-fleet#1720): on opens a login whose
			// fresh probe is ok; "" or off is the default — only a hint.
			if body.Value != "" && body.Value != "on" && body.Value != "off" {
				httpError(w, http.StatusBadRequest, ComputeAutoKey+" is on | off, or \"\" for the default (off)")
				return
			}
			s.computeAutoAudit(body.Value, time.Now())
		case body.Key == MeterKey:
			// The public counter (claude-fleet#1988): off hides /meter.json
			// and /odometer.svg; "" or on is the default — shown.
			if body.Value != "" && body.Value != "on" && body.Value != "off" {
				httpError(w, http.StatusBadRequest, MeterKey+" is on | off, or \"\" for the default (on)")
				return
			}
		case strings.HasPrefix(body.Key, NodeCapPrefix) && nodeNameRE.MatchString(body.Key[len(NodeCapPrefix):]):
			if body.Value != "" {
				if n, err := strconv.Atoi(body.Value); err != nil || n < 0 || n > 256 {
					httpError(w, http.StatusBadRequest, "a node cap is an integer 0–256, or \"\" for the default")
					return
				}
			}
		default:
			httpError(w, http.StatusBadRequest, "only fleet.node_cap.<machine>, "+NodeMaintenancePrefix+"<machine>, "+NodeTrustPrefix+"<machine>, "+NodeRelayPrefix+"<machine> (\"\" only), "+ClientDefaultsPrefix+"<KEY>, "+PersonBudgetPrefix+"<principal>, "+SpotWeightKey+", "+ComputeAutoKey+" and "+MeterKey+" are settable")
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
	s.writeFleetSettings(w)
}

// writeFleetSettings answers a settings call: what is set, and what applies.
func (s *Server) writeFleetSettings(w http.ResponseWriter) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	eff := map[string]any{}
	for k, v := range settings {
		if strings.HasPrefix(k, NodeMaintenancePrefix) {
			eff[k] = parseMaintenance(k[len(NodeMaintenancePrefix):], v)
			continue
		}
		if strings.HasPrefix(k, NodeTrustPrefix) {
			eff[k] = v
			continue
		}
		if strings.HasPrefix(k, PersonBudgetPrefix) {
			if b, err := parsePersonBudget(v); err == nil {
				eff[k] = b
			}
			continue
		}
		if n, err := strconv.Atoi(v); err == nil {
			eff[k] = n
		}
	}
	eff[SpotWeightKey] = s.spotWeight(settings)
	// A relay credential's hash never leaves the hub (claude-fleet#1974).
	settings = relayRedact(settings)
	for k, v := range settings {
		if strings.HasPrefix(k, NodeRelayPrefix) {
			eff[k] = v
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": settings, "effective": eff})
}

// reapPolicyRE is the shape of a session's reap policy (claude-fleet#1902,
// bin/fleet_reap_policy.py is the grammar): merged[:<dur>] · done[:<dur>] ·
// loop-end · at:<ISO time | HH:MM | epoch> · keep. "" = the kind's default.
var reapPolicyRE = regexp.MustCompile(`^(?:(?:merged|done)(?::[1-9][0-9]{0,6}[smhd]?)?|loop-end|keep|at:[0-9][0-9TZ:+-]{0,31})$`)

func reapPolicyOK(p string) bool { return p == "" || reapPolicyRE.MatchString(p) }
