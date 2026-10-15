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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The task record's node road (claude-fleet#3330, EPIC #3178 ⑦): what the
// fleet's coordinators — the orchestrator, the steward, an EPIC driver — write
// on a record from a machine, with that machine's node token
// (bin/fleet-task.sh). ⌘P's place road (#3325) writes a person's record; this
// one lets the orchestrator open one BEFORE it dispatches (a development task
// then files its issue), the steward put a question or a park on it, and an
// EPIC driver give each member a read-only record beside its issue.
//
//	POST /v1/node/tasks          {token, title, via?, repo?, rule?, issue?,
//	                              worker_id?, key?, state?} → the record; the
//	                              same token twice is the same record
//	GET  /v1/node/tasks/<T>      → {task, live}
//	POST /v1/node/tasks/<T>      {asked?, parked?, issue?, pr?, worker_id?,
//	                              key?, state?, note?, rule?, clear?: [asked,
//	                              parked, note]} → the record
//
// Version 1 (opt-in; no legacy adoption):
//
// POST /v1/node/tasks {authority_version:1, token, title, requested_agent,
//
//	resolved_agent, ticket_ref?:"gh:org/repo#7"|"hub:repo#7", parent_task?,
//	parent_session?, request_payload?:{...}} accepts a durable request.
//
// POST /v1/node/tasks/<T> {authority_version:1, mutation:{kind,
//
//	idempotency_key, generation, expected_worker, ...}} claims or transitions
//	it. claim supplies worker_id; transition supplies state/actual_agent/evidence;
//	retry/transfer supply requested_agent/resolved_agent/evidence. A terminal
//	result or transfer from an executor requires execution_stopped:true.
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

type nodeTaskWrite struct {
	AuthorityVersion int                 `json:"authority_version"`
	RequestedAgent   string              `json:"requested_agent"`
	ResolvedAgent    string              `json:"resolved_agent"`
	TicketRef        string              `json:"ticket_ref"`
	ParentTask       string              `json:"parent_task"`
	ParentSession    string              `json:"parent_session"`
	RequestPayload   json.RawMessage     `json:"request_payload"`
	Mutation         *store.TaskMutation `json:"mutation"`
	Token            string              `json:"token"`
	Title            string              `json:"title"`
	Via              string              `json:"via"`
	Repo             string              `json:"repo"`
	Rule             string              `json:"rule"`
	Issue            string              `json:"issue"`
	PR               string              `json:"pr"`
	WorkerID         string              `json:"worker_id"`
	Key              string              `json:"key"`
	State            string              `json:"state"`
	Note             string              `json:"note"`
	Asked            string              `json:"asked"`
	Parked           string              `json:"parked"`
	Clear            []string            `json:"clear"`
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
		if in.Mutation != nil {
			if in.Title != "" || in.RequestedAgent != "" || in.ResolvedAgent != "" || in.TicketRef != "" || in.ParentTask != "" || in.ParentSession != "" || len(in.RequestPayload) != 0 || in.Repo != "" || in.Token != "" || in.Via != "" {
				return "mutation cannot amend the accepted request"
			}
			m := in.Mutation
			if !nodeTaskTokenRE.MatchString(m.Key) || len(m.Evidence) > 8000 {
				return "mutation needs a bounded idempotency key and evidence"
			}
			if m.SessionKey != "" && !nodeTaskKeyRE.MatchString(m.SessionKey) {
				return "invalid session_key"
			}
			for _, worker := range []string{m.ExpectedWorker, m.WorkerID} {
				if worker == "" {
					continue
				}
				fid, sid, err := fleetid.ParseWorkerID(worker)
				if err != nil || !fleetid.IsUUID(sid) {
					return "authoritative worker_id requires a stable session UUID"
				}
				if f, err := s.Store.Fleet(fid); err != nil || f.EndpointID != ep.ID {
					return "worker_id names a fleet this node does not report"
				}
				m.FleetID = fid
			}
			m.EndpointID = ep.ID
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
		return "state must be placing, open, refused, unknown or done"
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
				AuthorityVersion: in.AuthorityVersion, RequestedAgent: in.RequestedAgent, ResolvedAgent: in.ResolvedAgent,
				TicketRef: in.TicketRef, ParentTask: in.ParentTask, ParentSession: in.ParentSession, RequestPayload: string(in.RequestPayload)}
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
		httpError(w, http.StatusNotFound, "no task "+ref+" of this machine's owner")
		return
	}
	switch r.Method {
	case http.MethodGet:
		live := s.taskLive(&t, map[string][]map[string]any{})
		writeJSON(w, http.StatusOK, map[string]any{"task": t, "live": live})
	case http.MethodPost:
		if t.AuthorityVersion != 0 || in.AuthorityVersion != 0 {
			if t.AuthorityVersion != store.TaskAuthorityVersion || in.AuthorityVersion != store.TaskAuthorityVersion || in.Mutation == nil {
				taskWriteError(w, store.ErrTaskFence)
				return
			}
			rec, err := s.Store.MutateFleetTask(t.ID, owner, *in.Mutation, now)
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

// nodeOwnTask is the record ref names when owner holds it — any record for
// the operator's machines, like the operator's door on /v1/fleet/tasks.
func (s *Server) nodeOwnTask(owner, ref string) (store.FleetTask, error) {
	id := store.ParseTaskRef(ref)
	if id == 0 {
		return store.FleetTask{}, sql.ErrNoRows
	}
	t, err := s.Store.FleetTask(id)
	if err != nil {
		return store.FleetTask{}, err
	}
	if t.Owner != owner && (t.AuthorityVersion != 0 || owner != "operator") {
		return store.FleetTask{}, errors.New("not this owner's")
	}
	return t, nil
}

// Contract conflicts are caller-visible, not generic server errors.
func taskWriteError(w http.ResponseWriter, err error) {
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
