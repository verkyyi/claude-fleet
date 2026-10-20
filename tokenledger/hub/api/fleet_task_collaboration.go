package api

import (
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// The same node authentication and account scope as task reads. No GitHub
// adapter, inventory inference, or new transport participates in these calls.
// A session's result is its window's ID's (EPIC T497 C8): the record takes no
// report; a child report travels as the parent's message (a relay), routed by
// the parent's ID on the receiving machine.
func (s *Server) nodeTaskCollaboration(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner, ref string) bool {
	task, action, found := strings.Cut(ref, "/")
	if !found {
		return false
	}
	t, err := s.nodeOwnTask(owner, task)
	if err != nil {
		httpError(w, 404, "no such task")
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

// An explicit parent session is a lifelong identity from the same account.
// Parent task binding is then snapshotted transactionally by store.
func (s *Server) checkTaskParentSession(owner, session string) error {
	if session == "" {
		return nil
	}
	fid, sid, err := fleetid.ParseWorkerID(session)
	if err != nil || !fleetid.IsUUID(sid) {
		return store.ErrTaskFence
	}
	fleet, err := s.Store.Fleet(fid)
	if err != nil {
		return store.ErrTaskFence
	}
	ep, err := s.Store.LiveEndpoint(fleet.EndpointID)
	if err != nil || s.nodeTaskOwner(ep) != owner {
		return store.ErrTaskFence
	}
	return nil
}
