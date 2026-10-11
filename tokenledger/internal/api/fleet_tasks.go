package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The task record (claude-fleet#3325, EPIC #3178): what a person asked for, as
// the hub keeps it — T<n>, written before the session is placed
// (fleet_client_place.go, a place with `task`), filled from the start's answer,
// read by the 任务 page (/tasks) and, through 「建 GitHub 单」, given an issue
// on demand. A task that chose a repo is a `new` start, so its issue comes
// with it; a task with no repo has none until a person asks for one.
//
//	GET  /v1/fleet/tasks                 the viewer's records, newest first, each
//	                                     with its session's live word (`live`)
//	                                     off the inventory; ?all=1 an admin's view
//	                                     of everyone's
//	POST /v1/fleet/tasks/<T>/issue       {repo?} file its GitHub issue now and
//	                                     hang it on the record
//
// The client reaches the second through its signed place road
// (`action: task_issue`), the same lease that opened the session.
const (
	FleetTasksPath = "/v1/fleet/tasks"
	TasksPagePath  = "/tasks"
	// taskTitleMax bounds a record's title: the words' first line, clipped.
	taskTitleMax = 200
	// taskIssueWait is how long a 「建 GitHub 单」 waits on the machine.
	taskIssueWait = 60 * time.Second
)

var taskIssueKeyRE = regexp.MustCompile(`(?:^|:)issue-([1-9][0-9]{0,9})$`)
var issueURLRE = regexp.MustCompile(`^https://[^/]+/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([1-9][0-9]{0,9})$`)

// taskTitle is a task's title: a new start's title, else the scratch's name,
// else the first line of its words — one line, clipped by character.
func taskTitle(req clientPlaceRequest) string {
	t := strings.TrimSpace(req.Title)
	if t == "" {
		t = strings.TrimSpace(req.Name)
	}
	if t == "" {
		for _, l := range strings.Split(req.Body, "\n") {
			if l = strings.TrimSpace(l); l != "" {
				t = l
				break
			}
		}
	}
	t = oneLine(t)
	if utf8.RuneCountInString(t) > taskTitleMax {
		t = string([]rune(t)[:taskTitleMax-1]) + "…"
	}
	return t
}

// taskAnswered fills a task's record from a place's answer and names the
// record in it. A nil task is no task: nothing happens.
func (s *Server) taskAnswered(task *store.FleetTask, out *ClientPlaceResponse) {
	if task == nil {
		return
	}
	out.Task = task.Ref
	u := store.FleetTaskUpdate{Machine: out.Machine, Login: out.Login, WorkerID: out.WorkerID, OperationID: out.OperationID}
	u.SessionKey = out.Key
	if u.SessionKey == "" && out.WorkerID != "" {
		if _, k, err := fleetid.ParseWorkerID(out.WorkerID); err == nil && !fleetid.IsUUID(k) {
			u.SessionKey = k
		}
	}
	switch out.State {
	case "done":
		u.State = store.TaskOpen
	case "refused", "failed", "held":
		u.State = store.TaskRefused
		_, why, _ := strings.Cut(out.Line, "\t")
		u.Note = oneLine(why)
		if u.Note == "" {
			u.Note = oneLine(out.Line)
		}
	default:
		u.State = store.TaskUnknown
	}
	// A repo's task is a `new` start: its issue is the session's key (a cold
	// start), or what the machine said it filed.
	if task.Repo != "" && task.Issue == "" {
		if m := taskIssueKeyRE.FindStringSubmatch(u.SessionKey); m != nil {
			u.Issue = store.NormRepo(task.Repo) + "#" + m[1]
		} else if m := issueURLRE.FindStringSubmatch(out.Filed); m != nil {
			u.Issue = m[1] + "#" + m[2]
		}
	}
	rec, err := s.Store.UpdateFleetTask(task.ID, u, time.Now())
	if err != nil {
		log.Printf("fleet task %s: record the answer: %v", task.Ref, err)
		return
	}
	*task = rec
}

// taskView is one record as the page reads it: the record, plus its session's
// live word off the inventory (empty when the session is gone or unknown).
type taskView struct {
	store.FleetTask
	Live map[string]any `json:"live,omitempty"`
}

// taskLiveFields are the inventory fields the page shows beside a record.
var taskLiveFields = []string{"key", "state", "needs", "status_kind", "status_msg", "ctx_left", "title", "repo", "issue"}

func (s *Server) taskLive(t *store.FleetTask, rows map[string][]map[string]any) map[string]any {
	if t.WorkerID == "" {
		return nil
	}
	fid, _, err := fleetid.ParseWorkerID(t.WorkerID)
	if err != nil {
		return nil
	}
	ws, ok := rows[fid]
	if !ok {
		f, err := s.Store.Fleet(fid)
		if err == nil && f.Present {
			_ = json.Unmarshal([]byte(f.WorkersJSON), &ws)
		}
		rows[fid] = ws
	}
	for _, w := range ws {
		if id, _ := w["worker_id"].(string); id != t.WorkerID {
			continue
		}
		out := map[string]any{}
		for _, k := range taskLiveFields {
			if v, ok := w[k]; ok && v != nil && v != "" {
				out[k] = v
			}
		}
		// A warm start's issue is filed after it opened (claude-fleet#2234):
		// the session's key says it once it is bound.
		if t.Repo != "" && t.Issue == "" {
			key, _ := w["key"].(string)
			if m := taskIssueKeyRE.FindStringSubmatch(key); m != nil {
				if rec, err := s.Store.UpdateFleetTask(t.ID, store.FleetTaskUpdate{SessionKey: key,
					Issue: store.NormRepo(t.Repo) + "#" + m[1]}, time.Now()); err == nil {
					*t = rec
				}
			}
		}
		return out
	}
	return nil
}

func (s *Server) handleFleetTasks(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	p, err := s.FleetPrincipal(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rest := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, FleetTasksPath), "/")
	if rest != "" {
		ref, what, _ := strings.Cut(rest, "/")
		if what != "issue" || r.Method != http.MethodPost {
			httpError(w, http.StatusNotFound, "POST "+FleetTasksPath+"/<T>/issue")
			return
		}
		var req struct {
			Repo string `json:"repo"`
		}
		if r.ContentLength != 0 {
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
				httpError(w, http.StatusBadRequest, "the body is {repo?}")
				return
			}
		}
		t, err := s.ownTask(p, ref)
		if err != nil {
			httpError(w, http.StatusNotFound, "no such task of yours")
			return
		}
		rec, err := s.taskFileIssue(r.Context(), p, t, req.Repo, time.Now())
		if err != nil {
			e := errorObject(err)
			writeJSON(w, faultStatus(e["code"]), map[string]any{"error": e})
			return
		}
		writeJSON(w, http.StatusOK, rec)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	owner := p.Actor
	if p.Person == "" || (r.URL.Query().Get("all") != "" && roleOf(r.Context()) == roleAdmin) {
		owner = "" // the operator's door, or an admin asking for everyone's
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	ts, err := s.Store.FleetTasksFor(owner, limit)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rows := map[string][]map[string]any{}
	out := make([]taskView, 0, len(ts))
	for i := range ts {
		live := s.taskLive(&ts[i], rows)
		out = append(out, taskView{FleetTask: ts[i], Live: live})
	}
	writeJSON(w, http.StatusOK, map[string]any{"tasks": out, "observed_at": time.Now().UTC().Format(time.RFC3339)})
}

// faultStatus is the HTTP status a fleet fault answers with on this page's
// own routes: the caller's mistake 400, nothing to act on 404/409, the rest 502.
func faultStatus(code string) int {
	switch code {
	case "INVALID_ARGUMENT":
		return http.StatusBadRequest
	case "NOT_FOUND":
		return http.StatusNotFound
	case "CONFLICT", "INVALID_STATE":
		return http.StatusConflict
	case "PERMISSION_DENIED", "FORBIDDEN":
		return http.StatusForbidden
	}
	return http.StatusBadGateway
}

// ownTask is the record ref names when it is the caller's — any for the
// operator's door.
func (s *Server) ownTask(p fleetPrincipal, ref string) (store.FleetTask, error) {
	id := store.ParseTaskRef(ref)
	if id == 0 {
		return store.FleetTask{}, sql.ErrNoRows
	}
	t, err := s.Store.FleetTask(id)
	if err != nil {
		return store.FleetTask{}, err
	}
	if p.Person != "" && t.Owner != p.Actor {
		return store.FleetTask{}, sql.ErrNoRows
	}
	return t, nil
}

// taskFileIssue is 「建 GitHub 单」: the record's issue, filed now in repo (the
// task's own when none is named) by a machine of the person's that hosts it —
// the task's session's own fleet first, so it can bind it there — and hung on
// the record. A record that already has one answers it unchanged.
func (s *Server) taskFileIssue(ctx context.Context, p fleetPrincipal, t store.FleetTask, repo string, now time.Time) (store.FleetTask, error) {
	if t.Issue != "" {
		return t, nil
	}
	if repo == "" {
		repo = t.Repo
	}
	repo = strings.TrimSpace(repo)
	if !leaseRepoRE.MatchString(repo) {
		return t, fault("INVALID_ARGUMENT", "name the repo to file it in (owner/name)")
	}
	body := t.Title + "\n\n" + "hub 任务 " + t.Ref + " 补建的单"
	if t.Machine != "" {
		body += "（会话在 " + t.Machine + "）"
	}
	body += "。"
	title, err := checkIssueTitle(t.Title)
	if err != nil {
		return t, err
	}
	args := map[string]any{"repo": repo, "task": t.Ref, "title": title, "body": body,
		"idempotency_key": "task-issue:" + t.Ref + ":" + strconv.FormatInt(now.UnixNano(), 36)}
	if fid, _, err := fleetid.ParseWorkerID(t.WorkerID); err == nil {
		if f, err := s.Store.Fleet(fid); err == nil && f.Present && fleetHosts(f, repo) && s.canTask(ctx, f.EndpointID) {
			args["fleet_id"], args["worker_id"] = fid, t.WorkerID
		}
	}
	op, err := s.submitWrite(ctx, p, "task_issue", args, nil)
	if err != nil {
		return t, err
	}
	op, _ = s.awaitOperation(ctx, op, time.Now().Add(taskIssueWait))
	var res struct {
		IssueURL string `json:"issue_url"`
		Error    struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if raw, ok := op["result"].(json.RawMessage); ok {
		_ = json.Unmarshal(raw, &res)
	}
	m := issueURLRE.FindStringSubmatch(strings.TrimSpace(res.IssueURL))
	if asString(op["status"]) != "succeeded" || m == nil {
		why := res.Error.Message
		if why == "" {
			why = "the machine did not say the issue was filed (operation " + asString(op["operation_id"]) + ", " + asString(op["status"]) + ")"
		}
		return t, fault("EXECUTION_FAILED", why)
	}
	return s.Store.UpdateFleetTask(t.ID, store.FleetTaskUpdate{Issue: m[1] + "#" + m[2]}, time.Now())
}

// fleetHosts reports whether f hosts repo.
func fleetHosts(f store.FleetRow, repo string) bool {
	n := store.NormRepo(repo)
	if store.NormRepo(f.Repo) == n {
		return true
	}
	for _, r := range f.Repos {
		if store.NormRepo(r) == n {
			return true
		}
	}
	return false
}

// clientTaskIssue is the client's 「建 GitHub 单」 (the session row's Tab menu):
// the signed place road's `action: task_issue`, answered as a place line —
// `FILED <owner/name#N>` (exit 0), or REFUSED.
func (s *Server) clientTaskIssue(w http.ResponseWriter, r *http.Request, p fleetPrincipal, req clientPlaceRequest) {
	t, err := s.ownTask(p, req.TaskRef)
	if err != nil {
		writeJSON(w, http.StatusOK, ClientPlaceResponse{Line: "REFUSED NOT_FOUND\tno task " + req.TaskRef + " of yours",
			Exit: 4, State: "refused"})
		return
	}
	rec, err := s.taskFileIssue(r.Context(), p, t, req.Repo, time.Now())
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			err = fault("NOT_FOUND", "no such task")
		}
		e := errorObject(err)
		writeJSON(w, http.StatusOK, ClientPlaceResponse{Line: "REFUSED " + e["code"] + "\t" + oneLine(e["message"]),
			Exit: 4, State: "refused", Task: t.Ref})
		return
	}
	writeJSON(w, http.StatusOK, ClientPlaceResponse{Line: "FILED " + rec.Issue + "\t" + rec.Ref, Exit: 0, State: "done",
		Task: rec.Ref, Filed: rec.Issue, Machine: rec.Machine})
}
