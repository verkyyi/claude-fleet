package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func (s *Server) recordStartFailure(w http.ResponseWriter, r *http.Request, t store.FleetTask) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var in struct {
		Generation int64  `json:"generation"`
		Reason     string `json:"reason"`
	}
	if !taskExecutionBody(w, r, &in) {
		return
	}
	rec, err := s.Store.RecordTaskStartFailure(t.ID, t.Owner, in.Generation, in.Reason, time.Now())
	if err != nil {
		taskWriteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, rec)
}

// Reconstruct only accepted work. The same request ID is retained: duplicate
// clicks replay one operation, and control admission serializes against cancel
// and every other first start. A missing window is never proof of non-execution.
func taskRetryArgs(t store.FleetTask) (map[string]any, error) {
	var payload map[string]any
	if json.Unmarshal([]byte(t.RequestPayload), &payload) != nil {
		return nil, store.ErrTaskInvalid
	}
	params, placed := payload["params"].(map[string]any)
	if !placed {
		params = payload
	}
	d, err := resolveDispatch("", "", params["dispatch"], "")
	if err != nil || d == nil {
		return nil, store.ErrTaskInvalid
	}
	d.Task, d.Generation, d.AttemptID = t.Ref, t.Generation, t.AttemptID
	args := map[string]any{}
	if placed {
		for k, v := range params {
			args[k] = v
		}
	} else {
		args["kind"] = "scratch"
		args["name"] = clipText(strings.ReplaceAll(oneLine(t.Title), "#", ""), maxScratchName)
		if t.Repo == "" {
			args["no_repo"] = true
		} else {
			args["repo"] = t.Repo
		}
		for _, k := range []string{"reap", "model"} {
			if v := asString(payload[k]); v != "" {
				args[k] = v
			}
		}
		if v := asString(payload["template"]); v != "" {
			args["as"] = v
		}
		blank, hasBlank := payload["blank"].(bool)
		if !hasBlank {
			blank = asString(payload["body"]) == "" && (t.Title == "新会话" || t.Title == "New session")
		}
		if !blank {
			body := asString(payload["body"])
			if body == "" {
				body = t.Title
			} else if t.Repo != "" {
				body = t.Title + "\n\n" + body
			}
			if len([]rune(body)) > 4000 {
				note := "\n\n…（全文见任务记录 " + t.Ref + "）"
				body = clipText(body, 4000-len([]rune(note))) + note
			}
			args["body"] = body
		}
	}
	args["dispatch"], args["task"], args["agent"] = d, t.Ref, d.ResolvedAgent
	args["idempotency_key"], args["node"], args["control_version"] = d.RequestID, "auto", 1
	return args, nil
}

func (s *Server) retryFleetTaskStart(w http.ResponseWriter, r *http.Request, p fleetPrincipal, ref string) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if p.Worker != nil || p.Actor == "" {
		httpError(w, http.StatusForbidden, "retry requires the task's person")
		return
	}
	if err := s.authorize(p, "worker:start", ""); err != nil {
		taskExecutionError(w, err)
		return
	}
	t, err := s.ownTask(p, ref)
	if errors.Is(err, sql.ErrNoRows) || err == nil && t.Owner != p.Actor {
		httpError(w, http.StatusNotFound, "no such task of yours")
		return
	}
	if err != nil {
		taskRefError(w, ref, err)
		return
	}
	var in struct {
		Generation int64 `json:"expected_generation"`
	}
	if !taskExecutionBody(w, r, &in) {
		return
	}
	if in.Generation != t.Generation {
		taskExecutionError(w, store.ErrTaskFence)
		return
	}
	args, err := taskRetryArgs(t)
	if err != nil {
		taskExecutionError(w, err)
		return
	}
	// An exact replay is safe even after admission; submitWrite compares the
	// immutable operation. Do not pick a second node on a lost response.
	if _, err := s.Store.FleetOperationByIdem(p.Actor, asString(args["idempotency_key"])); errors.Is(err, sql.ErrNoRows) {
		ok, e := s.Store.TaskStartRetryable(t)
		if e != nil {
			taskExecutionError(w, e)
			return
		}
		if !ok {
			taskExecutionError(w, store.ErrTaskConflict)
			return
		}
	} else if err != nil {
		taskExecutionError(w, err)
		return
	}
	out, err := s.submitWrite(r.Context(), p, "worker_start", args, nil)
	if err != nil {
		_, _ = s.Store.RecordTaskStartFailure(t.ID, t.Owner, t.Generation, errorObject(err)["message"], time.Now())
		taskExecutionError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, out)
}

// Capture only the placement response, never a credential/request body. This
// includes validation failures before a worker_start operation can be journalled.
type taskPlacementResponse struct {
	http.ResponseWriter
	body   strings.Builder
	status int
}

func (w *taskPlacementResponse) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (w *taskPlacementResponse) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if w.body.Len() < 32<<10 {
		w.body.Write(b)
	}
	return w.ResponseWriter.Write(b)
}
func (s *Server) placementFailure(w *taskPlacementResponse, owner string, d *dispatchChoice) {
	if d == nil || d.Task == "" {
		return
	}
	var response struct {
		Error   any `json:"error"`
		Outcome struct {
			State  string `json:"state"`
			Stderr string `json:"stderr"`
		} `json:"outcome"`
	}
	if json.Unmarshal([]byte(w.body.String()), &response) != nil {
		return
	}
	reason := ""
	if response.Error != nil {
		switch e := response.Error.(type) {
		case string:
			reason = e
		case map[string]any:
			reason = asString(e["code"]) + ": " + asString(e["message"])
		}
	} else if response.Outcome.State == "refused" || response.Outcome.State == "failed" {
		reason = response.Outcome.Stderr
	}
	if reason != "" {
		_, _ = s.Store.RecordTaskStartFailure(store.ParseTaskRef(d.Task), owner, d.Generation, clipText(reason, 2000), time.Now())
	}
}
