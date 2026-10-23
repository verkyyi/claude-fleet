package api

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// The task record's node road (claude-fleet#3330, EPIC #3178 ⑦): what the
// fleet's coordinators — an orchestrator session, an EPIC driver — write
// on a record from a machine, with that machine's node token
// (bin/fleet-task.sh). ⌘P's place road (#3325) writes a person's record; this
// one lets the orchestrator open one BEFORE it dispatches (a development task
// is that record alone), a session put a question or a park on it, and an
// EPIC driver open each member as a child record.
//
//	POST /v1/node/tasks          {token, title, via?, repo?, rule?, issue?,
//	                              worker_id?, key?, state?} → the record; the
//	                              same token twice is the same record
//	GET  /v1/node/tasks/<ref>    → {task, live}; <ref> is the task's code (K5,
//	                              K5F9 — a 409 {code: AMBIGUOUS, candidates}
//	                              when it names several), its full ID, or the
//	                              alias T<n> (EPIC T644 C1, store.ResolveFleetTask);
//	                              every /<ref> route below takes the same three
//	POST /v1/node/tasks/ids-backfill {apply?} → give this owner's records from
//	                              before C1 their ID (store.BackfillTaskIDs); dry
//	                              unless apply
//	POST /v1/node/tasks/reconcile {apply?, before?: "T480", undo?} → bring
//	                              this owner's records in line with what
//	                              happened (store.ReconcileTaskStates, EPIC
//	                              T644 C6): ended on their ID's result, and —
//	                              with before — the older unfinished ones no
//	                              live session holds cancelled; dry unless
//	                              apply; undo puts the cancelled back
//	POST /v1/node/tasks/<T>      {asked?, parked?, issue?, pr?, worker_id?,
//	                              key?, state?, note?, rule?, clear?: [asked,
//	                              parked, note]} → the record
//	POST /v1/node/tasks/settle   {repo, apply?} → ends legacy records whose
//	                              issue is closed and worker holds nothing
//	                              (fleet_task_settle.go, claude-fleet#4867)
//
// POST /v1/node/tasks/<ref>/stop {idempotency_key,evidence?} persists the
// same Task stop as the browser. Only the authenticated endpoint's exact owner
// may write; the operator's legacy read exception grants no stop authority.
//
// Version 1 (opt-in; no legacy adoption):
//
// POST /v1/node/tasks {authority_version:1, token, title, requested_agent,
//
//	resolved_agent, ticket_ref?:"gh:org/repo#7", request_payload?:{...}}
//	accepts a durable request. Old parent_task/parent_session inputs are ignored.
//
// POST /v1/node/tasks/<T> {authority_version:1, mutation:{kind,
//
//	idempotency_key, generation, expected_worker, ...}} claims or transitions
//	it. claim supplies worker_id; transition supplies state/actual_agent/evidence;
//	retry/transfer supply requested_agent/resolved_agent/evidence. Explicit
//	success/failure may retain the native session and its lease. stop_ack
//	releases that terminal execution; cancel_ack/transfer also require
//	execution_stopped:true. Retry requires release or fresh stopped evidence.
//
// Same key/input returns the original response; changed input returns 409.
// Expected worker and generation fence each write. The node's authenticated
// endpoint must own that worker's fleet. Actual process evidence is supplied
// by the receipt boundary, not inferred from inventory or a successful RPC.
// Legacy POSTs cannot mutate version 1 rows; GET/list retain their old shape
// with additive contract fields. No production cutover happens here.
//
// A node writes only its owner's records (relayOwner: the operator's machines
// are the operator's, a person's account is theirs). No hub, no call.
const NodeTasksPath = "/v1/node/tasks"

var (
	nodeTaskTokenRE = regexp.MustCompile(`^[A-Za-z0-9._:#/@-]{1,200}$`)
	nodeTaskIssueRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}#[1-9][0-9]{0,9}$`)
	nodeTaskKeyRE   = regexp.MustCompile(`^(?:[A-Za-z0-9_.-]{1,100}:)?(?:issue|scratch)-[1-9][0-9]{0,9}$`)
	nodeTaskRuleRE  = regexp.MustCompile(`^n=[1-9][0-9]{0,4}(?: v=[0-9a-f]{4,40})?$`)
	nodeTaskStates  = map[string]bool{store.TaskPlacing: true, store.TaskOpen: true, store.TaskRefused: true,
		store.TaskUnknown: true, "done": true}
)

// nodeTaskTextMax bounds a question or a park's words on the record.
const nodeTaskTextMax = 500

// nodeTaskOwner is whose record a node writes: the person its login belongs
// to, the operator's own machines "operator", else the endpoint itself.
func (s *Server) nodeTaskOwner(ep *store.Endpoint) string {
	o := s.workerRecordOwner(ep)
	if p, ok := strings.CutPrefix(o, "person:"); ok {
		return p
	}
	return o
}

// nodeTaskMutation is the one change a node still posts on a record (EPIC T497
// C13, kept by C8): fleet_task_control.py cancel's transition to cancelled of a
// record no window ever opened. Any other kind an older node sends (a claim, a
// fenced transition, a stop or cancel acknowledgement) is answered ID_SWITCH
// (compat-1v: 下一批删), so it records on its window's ID instead; the fields
// those carried are taken and ignored.
type nodeTaskMutation struct {
	Key            string `json:"idempotency_key"`
	Kind           string `json:"kind"`
	ExpectedWorker string `json:"expected_worker"`
	Generation     int64  `json:"generation"`
	State          string `json:"state,omitempty"`
	Evidence       string `json:"evidence,omitempty"`
	From           string `json:"from,omitempty"`
	Title          string `json:"title,omitempty"`
}

// UnmarshalJSON keeps the cancel's fields and drops the rest.
func (m *nodeTaskMutation) UnmarshalJSON(b []byte) error {
	var all map[string]json.RawMessage
	if err := json.Unmarshal(b, &all); err != nil {
		return err
	}
	type plain nodeTaskMutation
	var p plain
	keep := map[string]json.RawMessage{}
	for _, k := range []string{"idempotency_key", "kind", "expected_worker", "generation", "state", "evidence", "from", "title"} {
		if v, ok := all[k]; ok {
			keep[k] = v
		}
	}
	kb, _ := json.Marshal(keep)
	if err := json.Unmarshal(kb, &p); err != nil {
		return err
	}
	*m = nodeTaskMutation(p)
	return nil
}

func (m nodeTaskMutation) cancelsUnopened() bool {
	return m.Kind == "transition" && m.State == store.TaskCancelled && m.ExpectedWorker == ""
}

// retitles is the other change a node posts (claude-fleet T652, EPIC T651 C1):
// a blank new session's placeholder title (`from`) replaced by its first prompt's
// first line (`title`), once — store.RetitleTask compares and sets.
func (m nodeTaskMutation) retitles() bool {
	return m.Kind == "retitle" && strings.TrimSpace(m.From) != "" && strings.TrimSpace(m.Title) != "" &&
		utf8.RuneCountInString(m.Title) <= taskTitleMax && utf8.RuneCountInString(m.From) <= taskTitleMax
}

type nodeTaskWrite struct {
	AuthorityVersion int               `json:"authority_version"`
	RequestedAgent   string            `json:"requested_agent"`
	ResolvedAgent    string            `json:"resolved_agent"`
	TicketRef        string            `json:"ticket_ref"`
	ParentTask       string            `json:"parent_task"`
	ParentSession    string            `json:"parent_session"`
	RequestPayload   json.RawMessage   `json:"request_payload"`
	Mutation         *nodeTaskMutation `json:"mutation"`
	Token            string            `json:"token"`
	Title            string            `json:"title"`
	Via              string            `json:"via"`
	Repo             string            `json:"repo"`
	Rule             string            `json:"rule"`
	Issue            string            `json:"issue"`
	PR               string            `json:"pr"`
	WorkerID         string            `json:"worker_id"`
	Key              string            `json:"key"`
	State            string            `json:"state"`
	Note             string            `json:"note"`
	Asked            string            `json:"asked"`
	Parked           string            `json:"parked"`
	Clear            []string          `json:"clear"`
}

// annotatesOnly says the write is a session's ask / park alone — asked, parked
// or a clear of them, nothing else (claude-fleet T792): the one plain write an
// authoritative record takes.
func (in *nodeTaskWrite) annotatesOnly() bool {
	if in.AuthorityVersion != 0 || in.Mutation != nil || in.Token != "" || in.Title != "" || in.Via != "" ||
		in.Repo != "" || in.Rule != "" || in.Issue != "" || in.PR != "" || in.WorkerID != "" || in.Key != "" ||
		in.State != "" || in.Note != "" || in.RequestedAgent != "" || in.ResolvedAgent != "" || in.TicketRef != "" ||
		in.ParentTask != "" || in.ParentSession != "" || len(in.RequestPayload) != 0 {
		return false
	}
	for _, c := range in.Clear {
		if c != "asked" && c != "parked" {
			return false
		}
	}
	return in.Asked != "" || in.Parked != "" || len(in.Clear) != 0
}

// clipText is s on one line, at most n characters.
func clipText(s string, n int) string {
	s = oneLine(strings.TrimSpace(s))
	if utf8.RuneCountInString(s) > n {
		s = string([]rune(s)[:n-1]) + "…"
	}
	return s
}

// check refuses what a node may not write; "" when it fits.
func (in *nodeTaskWrite) check(s *Server, ep *store.Endpoint) string {
	if in.AuthorityVersion != 0 && in.AuthorityVersion != store.TaskAuthorityVersion {
		return "unsupported task authority_version"
	}
	if in.AuthorityVersion == store.TaskAuthorityVersion {
		// The versioned command has its own lifecycle states and worker fields.
		// Legacy fields must not silently bypass or amend its accepted payload.
		if in.State != "" || in.Issue != "" || in.WorkerID != "" || in.Key != "" || in.Note != "" || in.Asked != "" || in.Parked != "" || in.PR != "" || in.Rule != "" || len(in.Clear) != 0 {
			return "authoritative tasks use ticket_ref and mutation, not legacy updates"
		}
		if in.Mutation == nil && (!codingAgentOK(in.ResolvedAgent) || (in.RequestedAgent != "default" && (!codingAgentOK(in.RequestedAgent) || in.RequestedAgent != in.ResolvedAgent))) {
			return "invalid or contradictory requested/resolved coding agent"
		}
		if in.Mutation != nil {
			if in.Title != "" || in.RequestedAgent != "" || in.ResolvedAgent != "" || in.TicketRef != "" || in.ParentTask != "" || in.ParentSession != "" || len(in.RequestPayload) != 0 || in.Repo != "" || in.Token != "" || in.Via != "" {
				return "mutation cannot amend the accepted request"
			}
			m := in.Mutation
			if !nodeTaskTokenRE.MatchString(m.Key) || len(m.Evidence) > 8000 {
				return "mutation needs a bounded idempotency key and evidence"
			}
		}
		return ""
	}
	if in.Mutation != nil || in.RequestedAgent != "" || in.ResolvedAgent != "" || in.TicketRef != "" || in.ParentTask != "" || in.ParentSession != "" || len(in.RequestPayload) != 0 {
		return "task contract fields require authority_version 1"
	}
	switch {
	case in.Repo != "" && !leaseRepoRE.MatchString(in.Repo):
		return "repo must be owner/name"
	case in.Issue != "" && !nodeTaskIssueRE.MatchString(in.Issue):
		return "issue must be owner/name#N"
	case in.Key != "" && !nodeTaskKeyRE.MatchString(in.Key):
		return "key must be [<slug>:]issue-<N> or [<slug>:]scratch-<N>"
	case in.Rule != "" && !nodeTaskRuleRE.MatchString(in.Rule):
		return "rule must be n=<N>[ v=<version>]"
	case in.State != "" && !nodeTaskStates[in.State]:
		return "state must be placing, open, refused, unknown or done (closed only by settle, on evidence)"
	case in.PR != "" && !nodeTaskIssueRE.MatchString(in.PR):
		return "pr must be owner/name#N"
	}
	for _, c := range in.Clear {
		if c != "asked" && c != "parked" && c != "note" {
			return "clear names asked, parked or note"
		}
	}
	if in.WorkerID != "" {
		fid, _, err := fleetid.ParseWorkerID(in.WorkerID)
		if err != nil {
			return "worker_id: " + err.Error()
		}
		if f, err := s.Store.Fleet(fid); err != nil || f.EndpointID != ep.ID {
			return "worker_id names a fleet this node does not report"
		}
	}
	return ""
}

func (s *Server) handleNodeTasks(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	owner := s.nodeTaskOwner(ep)
	ref := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, NodeTasksPath), "/")
	if task, route, found := strings.Cut(ref, "/"); found && route == "stop" {
		if r.Method != http.MethodPost {
			httpError(w, http.StatusMethodNotAllowed, "POST")
			return
		}
		t, err := s.nodeOwnTask(owner, task)
		// Do not extend the operator's legacy read exception to stop authority.
		if err != nil || t.Owner != owner {
			httpError(w, http.StatusNotFound, "no such task of this node's owner")
			return
		}
		s.requestFleetTaskStop(w, r, t)
		return
	}
	if s.nodeTaskExecution(w, r, ep, owner, ref) {
		return
	}
	if ref == nodeTaskSettleRef {
		s.nodeTaskSettle(w, r, owner)
		return
	}
	if ref == nodeTaskReconcileRef {
		s.nodeTaskReconcile(w, r, owner)
		return
	}
	if ref == nodeTaskIDsBackfillRef {
		s.nodeTaskIDsBackfill(w, r, owner)
		return
	}
	if s.nodeTaskCollaboration(w, r, ep, owner, ref) {
		return
	}
	var in nodeTaskWrite
	if r.Method == http.MethodPost {
		var raw json.RawMessage
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&raw); err != nil {
			httpError(w, http.StatusBadRequest, "the body is one JSON object")
			return
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			httpError(w, http.StatusBadRequest, "the body is one JSON object")
			return
		}
		if in.AuthorityVersion != 0 {
			decoder := json.NewDecoder(bytes.NewReader(raw))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&in); err != nil {
				httpError(w, http.StatusBadRequest, "unknown or invalid task contract field")
				return
			}
		}
		in.ParentTask, in.ParentSession = "", ""
		if why := in.check(s, ep); why != "" {
			httpError(w, http.StatusBadRequest, why)
			return
		}
	}
	now := time.Now()
	if ref == "" {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			httpError(w, http.StatusMethodNotAllowed, "POST "+NodeTasksPath+" or GET "+NodeTasksPath+"/<T>")
			return
		}
		if in.Mutation != nil {
			httpError(w, http.StatusBadRequest, "mutation requires a task ID")
			return
		}
		title := clipText(in.Title, taskTitleMax)
		if in.AuthorityVersion != 0 {
			if utf8.RuneCountInString(in.Title) > taskTitleMax || strings.TrimSpace(in.Title) == "" {
				httpError(w, http.StatusBadRequest, "title must be 1..200 characters")
				return
			}
			title = in.Title
		}
		if !nodeTaskTokenRE.MatchString(in.Token) || title == "" {
			httpError(w, http.StatusBadRequest, "a record needs a token and a title")
			return
		}
		state := in.State
		if state == "" {
			state = store.TaskPlacing
		}
		t := store.FleetTask{Owner: owner, Title: title, Via: clipText(in.Via, 60), Repo: in.Repo, Rule: in.Rule,
			Issue: in.Issue, PR: in.PR, WorkerID: in.WorkerID, SessionKey: in.Key, State: state, Note: clipText(in.Note, nodeTaskTextMax),
			Machine: shortNode(ep.Hostname), Login: ep.OSUser}
		if in.AuthorityVersion != 0 {
			t = store.FleetTask{Owner: owner, Title: title, Via: in.Via, Repo: in.Repo,
				Agent: in.ResolvedAgent, AuthorityVersion: in.AuthorityVersion, RequestedAgent: in.RequestedAgent, ResolvedAgent: in.ResolvedAgent,
				TicketRef: in.TicketRef, RequestPayload: string(in.RequestPayload)}
		}
		rec, err := s.Store.CreateFleetTask(t, "node:"+owner+":"+in.Token, now)
		if err != nil {
			taskWriteError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, rec)
		return
	}
	t, err := s.nodeOwnTask(owner, ref)
	if err != nil {
		taskRefError(w, ref, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		// The same landing projection as the person's list (taskViews): an
		// authoritative task's PR lives in its reports, and ⌘P's row reads it
		// here (issue #4902) — the record's pr, else the landed report's.
		views, err := s.taskViews([]store.FleetTask{t})
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		v := views[0]
		out := map[string]any{"task": v.FleetTask, "live": v.Live, "pr_state": v.PRState}
		if v.Progress != nil {
			out["progress"] = v.Progress // claude-fleet#4957: a parent task's tick
		}
		if v.Started != nil {
			out["started"] = v.Started // claude-fleet T629: its window's agent is up
		}
		writeJSON(w, http.StatusOK, out)
	case http.MethodPost:
		if t.AuthorityVersion == store.TaskAuthorityVersion && in.annotatesOnly() {
			// A session's ask / park (claude-fleet T792): 「问过你」 / 「停放」 are
			// words beside the record, never its state or accepted request.
			rec, err := s.Store.AnnotateTask(t.ID, owner, clipText(in.Asked, nodeTaskTextMax),
				clipText(in.Parked, nodeTaskTextMax), in.Clear, now)
			if err != nil {
				taskWriteError(w, err)
				return
			}
			writeJSON(w, http.StatusOK, rec)
			return
		}
		if t.AuthorityVersion != 0 || in.AuthorityVersion != 0 {
			if t.AuthorityVersion != store.TaskAuthorityVersion || in.AuthorityVersion != store.TaskAuthorityVersion || in.Mutation == nil {
				taskWriteError(w, store.ErrTaskFence)
				return
			}
			if in.Mutation.Kind == "retitle" {
				if !in.Mutation.retitles() {
					httpError(w, http.StatusBadRequest, "retitle needs from and title, each 1..200 characters")
					return
				}
				rec, err := s.Store.RetitleTask(t.ID, owner, in.Mutation.From, clipText(in.Mutation.Title, taskTitleMax), now)
				if err != nil {
					taskWriteError(w, err)
					return
				}
				writeJSON(w, http.StatusOK, rec)
				return
			}
			if !in.Mutation.cancelsUnopened() {
				taskWriteError(w, store.ErrIDSwitch)
				return
			}
			rec, err := s.Store.CancelUnopenedTask(t.ID, owner, in.Mutation.Evidence, now)
			if err != nil {
				taskWriteError(w, err)
				return
			}
			writeJSON(w, http.StatusOK, rec)
			return
		}
		u := store.FleetTaskUpdate{Issue: in.Issue, PR: in.PR, WorkerID: in.WorkerID, SessionKey: in.Key, State: in.State,
			Note: clipText(in.Note, nodeTaskTextMax), Asked: clipText(in.Asked, nodeTaskTextMax),
			Parked: clipText(in.Parked, nodeTaskTextMax), Rule: in.Rule, Clear: in.Clear}
		if u.State == "done" {
			u.State = store.TaskOpen // the session's own word is the inventory's; the record keeps its start's
		}
		if u.WorkerID != "" {
			u.Machine, u.Login = shortNode(ep.Hostname), ep.OSUser
		}
		rec, err := s.Store.UpdateFleetTask(t.ID, u, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, rec)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// nodeOwnTask is the record ref names (a code, the task's ID or T<n> —
// store.ResolveFleetTask) when owner holds it — any legacy record for the
// operator's machines, like the operator's door on /v1/fleet/tasks.
func (s *Server) nodeOwnTask(owner, ref string) (store.FleetTask, error) {
	t, err := s.Store.ResolveFleetTask(owner, ref)
	if err != nil {
		return store.FleetTask{}, err
	}
	if t.Owner != owner && (t.AuthorityVersion != 0 || owner != "operator") {
		return store.FleetTask{}, sql.ErrNoRows
	}
	return t, nil
}

// taskRefError answers a reference that names no task of the caller's (404) or
// several (409 {code: AMBIGUOUS, candidates} — never a pick).
func taskRefError(w http.ResponseWriter, ref string, err error) {
	var amb *store.TaskAmbiguity
	switch {
	case errors.As(err, &amb):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "AMBIGUOUS", "candidates": amb.Candidates,
			"error": ref + " names more than one task — name it longer"})
	case errors.Is(err, sql.ErrNoRows):
		httpError(w, http.StatusNotFound, "no task "+ref+" of this machine's owner")
	default:
		httpError(w, http.StatusInternalServerError, err.Error())
	}
}

// nodeTaskIDsBackfillRef is the route that gives records from before EPIC T644
// C1 their ID; never a code (it has a dash).
const nodeTaskIDsBackfillRef = "ids-backfill"

func (s *Server) nodeTaskIDsBackfill(w http.ResponseWriter, r *http.Request, owner string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST "+NodeTasksPath+"/"+nodeTaskIDsBackfillRef)
		return
	}
	var in struct {
		Apply bool `json:"apply"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&in); err != nil {
			httpError(w, http.StatusBadRequest, `the body is {"apply": true|false}`)
			return
		}
	}
	out, err := s.Store.BackfillTaskIDs(owner, in.Apply, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// nodeTaskReconcileRef is the route that brings records in line with what
// happened (EPIC T644 C6); matched before any code is read.
const nodeTaskReconcileRef = "reconcile"

func (s *Server) nodeTaskReconcile(w http.ResponseWriter, r *http.Request, owner string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST "+NodeTasksPath+"/"+nodeTaskReconcileRef)
		return
	}
	var in struct {
		Apply  bool   `json:"apply"`
		Before string `json:"before"`
		Undo   bool   `json:"undo"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&in); err != nil {
			httpError(w, http.StatusBadRequest, `the body is {"apply": true|false, "before": "T<n>", "undo": true|false}`)
			return
		}
	}
	if in.Undo {
		n, err := s.Store.UndoReconcileCancel(owner, time.Now())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"undone": n})
		return
	}
	var before int64
	if in.Before != "" {
		if before = store.ParseTaskRef(in.Before); before == 0 || !strings.HasPrefix(in.Before, "T") {
			httpError(w, http.StatusBadRequest, "before is a record number, T<n>")
			return
		}
	}
	out, err := s.Store.ReconcileTaskStates(owner, before, in.Apply, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// Contract conflicts are caller-visible, not generic server errors.
func taskWriteError(w http.ResponseWriter, err error) {
	if errors.Is(err, store.ErrIDSwitch) { // EPIC T497 C6: the node reads the code
		writeJSON(w, http.StatusConflict, map[string]any{"code": "ID_SWITCH", "error": err.Error()})
		return
	}
	status := http.StatusInternalServerError
	switch {
	case errors.Is(err, store.ErrTaskInvalid):
		status = http.StatusBadRequest
	case errors.Is(err, store.ErrTaskConflict), errors.Is(err, store.ErrTaskFence):
		status = http.StatusConflict
	case errors.Is(err, sql.ErrNoRows):
		status = http.StatusNotFound
	}
	httpError(w, status, err.Error())
}
