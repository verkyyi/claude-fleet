package api

import (
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The same node authentication and account scope as task reads. No GitHub
// adapter, inventory inference, or new transport participates in these calls.
// Parent columns and children reads are historical compatibility only.
// New acceptance creates no relationship and takes no Parent report.
func (s *Server) nodeTaskCollaboration(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owners []string, ref string) bool {
	task, action, found := strings.Cut(ref, "/")
	if !found {
		return false
	}
	t, owner, err := s.nodeOwnTask(owners, task)
	if err != nil {
		taskRefError(w, task, err)
		return true
	}
	switch action {
	case "children":
		if r.Method != http.MethodGet {
			httpError(w, 405, "GET only")
			return true
		}
		if t.AuthorityVersion != 1 {
			httpError(w, 409, "legacy task has no authoritative children")
			return true
		}
		rows, err := s.Store.FleetTaskChildren(owner, t.Ref)
		if err != nil {
			taskWriteError(w, err)
			return true
		}
		// summary (claude-fleet#4957): an EPIC driver's one read of its batch —
		// each child counted by its outcome (its ID's result), "open" while it has none.
		views, err := s.taskViews(rows)
		if err != nil {
			taskWriteError(w, err)
			return true
		}
		children := make([]store.FleetTask, 0, len(views))
		summary := map[string]int{"open": 0, store.TaskSucceeded: 0, store.TaskFailed: 0, store.TaskCancelled: 0, store.TaskRefused: 0}
		for _, v := range views {
			children = append(children, v.FleetTask)
			if _, ok := summary[v.Outcome]; ok && v.Outcome != "" {
				summary[v.Outcome]++
			} else {
				summary["open"]++
			}
		}
		writeJSON(w, 200, map[string]any{"parent": t.Ref, "children": children, "summary": summary})
	case "reports":
		// compat-1v: 下一批删 — a node from before C8 posting a fenced report
		// reads the code and records the result on its window's ID instead.
		taskWriteError(w, store.ErrIDSwitch)
	default:
		httpError(w, 404, "unknown task action")
	}
	return true
}
