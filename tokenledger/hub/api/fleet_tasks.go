package api

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// The task record (claude-fleet#3325, EPIC #3178): what a person asked for, as
// the hub keeps it — T<n>, written before the session is placed
// (fleet_client_place.go, a place with `task`), filled from the start's answer,
// read by the 任务 page (/tasks). A task that chose a repo is a `new` start, so
// its issue comes with it; a task with no repo has none — the record is its
// ticket (claude-fleet#4898: 「建 GitHub 单」 is gone).
//
//	GET  /v1/fleet/tasks                 the viewer's records, newest first, each
//	                                     with its session's live word (`live`)
//	                                     off the inventory; ?all=1 an admin's view
//	                                     of everyone's
//	GET  /v1/fleet/tasks/<T>             one of them
const (
	FleetTasksPath = "/v1/fleet/tasks"
	TasksPagePath  = "/tasks"
	// taskTitleMax bounds a record's title: the words' first line, clipped.
	taskTitleMax = 200
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
	Live    map[string]any `json:"live,omitempty"`
	PRState string         `json:"pr_state"`
	// Progress is the current execution's newest workflow word — an EPIC
	// driver's tick on its parent task (claude-fleet#4957); absent when none.
	Progress *store.TaskProgress `json:"progress,omitempty"`
}

// Use the same owner/generation-fenced landing projection as repo migration.
// Work can finish before a later merge report; the immutable outcome/evidence
// must not be rewritten to show that later landing. All reads are local to the
// hub, once per (owner, repo) in this response, with no GitHub request.
func (s *Server) taskViews(tasks []store.FleetTask) ([]taskView, error) {
	rows := map[string][]map[string]any{}
	landings := map[[2]string]map[string]map[string]any{}
	out := make([]taskView, 0, len(tasks))
	for _, t := range tasks {
		live := s.taskLive(&t, rows)
		v := taskView{FleetTask: t, Live: live, PRState: "unverified"}
		if t.AuthorityVersion == store.TaskAuthorityVersion {
			key := [2]string{t.Owner, t.Repo}
			byTask, ok := landings[key]
			if !ok {
				items, err := s.Store.RepoTaskInventory(t.Repo, t.Owner)
				if err != nil {
					return nil, err
				}
				byTask = map[string]map[string]any{}
				for _, item := range items {
					byTask[item["task"].(string)] = item
				}
				landings[key] = byTask
			}
			if p := byTask[t.Ref]; p != nil && p["generation"] == t.Generation && p["worker_id"] == t.ExecutionOwner && p["ticket_ref"] == t.TicketRef {
				v.PRState, _ = p["pr_state"].(string)
				v.PR, _ = p["pr"].(string)
			}
			progress, err := s.Store.FleetTaskProgress(t)
			if err != nil {
				return nil, err
			}
			v.Progress = progress
		}
		out = append(out, v)
	}
	return out, nil
}

// taskLiveFields are the inventory fields the page shows beside a record.
var taskLiveFields = []string{"key", "state", "needs", "status_kind", "status_msg", "ctx_left", "title", "repo", "issue", "observed_at", "stale", "source"}

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
		if err == nil {
			_ = json.Unmarshal([]byte(f.WorkersJSON), &ws)
			// Retain the last inventory when the node disappears. Its original
			// observation time is not the time of this Tasks GET.
			for _, w := range ws {
				if w == nil {
					continue
				}
				if f.State != "unknown" {
					w["observed_at"] = f.ObservedAt.UTC().Format(time.RFC3339Nano)
				}
				w["stale"] = !f.Present || f.State == "unknown" || time.Since(f.ObservedAt) > 2*time.Minute || f.ObservedAt.After(time.Now())
				w["source"] = "inventory"
			}
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
		if t.AuthorityVersion == 0 && t.Repo != "" && t.Issue == "" {
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
		if what == "" && r.Method == http.MethodGet {
			t, err := s.ownTask(p, ref)
			if err != nil {
				httpError(w, http.StatusNotFound, "no such task of yours")
				return
			}
			views, err := s.taskViews([]store.FleetTask{t})
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, views[0])
			return
		}
		httpError(w, http.StatusNotFound, "GET "+FleetTasksPath+"/<T>")
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
	out, err := s.taskViews(ts)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
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
