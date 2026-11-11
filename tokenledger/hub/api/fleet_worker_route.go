package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// NodeWorkerRoutePath resolves a lifelong window identity when the sender's
// pushed worker map has not caught up with placement. It uses the same owner
// boundary as relay delivery, and never interprets a missing cache row as proof
// that a remotely placed window does not exist.
const NodeWorkerRoutePath = "/v1/node/worker-route"

type nodeWorkerRoute struct {
	WorkerID string `json:"worker_id"`
	Node     string `json:"node"`
	Key      string `json:"key,omitempty"`
	Source   string `json:"source"`
}

func (s *Server) handleNodeWorkerRoute(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET required")
		return
	}
	id := r.URL.Query().Get("id")
	if !store.IsFleetID(id) {
		httpError(w, http.StatusBadRequest, "id must be a lowercase window UUID")
		return
	}
	fleets, err := s.Store.Fleets()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read worker routes")
		return
	}
	accounts := s.activeAccounts()
	host, user := s.peerSelf(ep)
	owners := s.relayOwners(ep.ID, host, user, accounts)
	allowed := map[string]store.FleetRow{}
	for _, f := range fleets {
		if f.Present && sameRelayOwner(owners, s.relayOwners(f.EndpointID, f.Hostname, f.OSUser, accounts)) {
			allowed[f.FleetID] = f
		}
	}
	hits := map[string]nodeWorkerRoute{}
	add := func(f store.FleetRow, key, source string) {
		wid := f.FleetID + "/" + id
		hits[wid] = nodeWorkerRoute{WorkerID: wid, Node: shortNode(f.Hostname), Key: key, Source: source}
	}
	answer := func() bool {
		if len(hits) > 1 {
			writeJSON(w, http.StatusConflict, map[string]any{"code": "AMBIGUOUS", "error": "multiple fleets of this owner carry this identity; no route chosen"})
			return true
		}
		for _, hit := range hits {
			writeJSON(w, http.StatusOK, hit)
			return true
		}
		return false
	}
	// Current inventory wins over an old task placement after a move. Duplicate
	// identities in two inventories refuse instead of choosing a machine.
	for _, f := range allowed {
		var workers []struct {
			WorkerID string `json:"worker_id"`
			Identity string `json:"identity"`
			Key      string `json:"key"`
		}
		if json.Unmarshal([]byte(f.WorkersJSON), &workers) != nil {
			continue
		}
		for _, worker := range workers {
			fid, suffix, err := fleetid.ParseWorkerID(worker.WorkerID)
			if err == nil && fid == f.FleetID && (suffix == id || worker.Identity == id) {
				add(f, worker.Key, "inventory")
			}
		}
	}
	if answer() {
		return
	}
	known, closed := false, false
	var mirrors []store.FleetIDRecord
	for _, owner := range s.nodeTaskOwners(ep) {
		task, err := s.Store.ResolveFleetTask(owner, id)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			httpError(w, http.StatusInternalServerError, "could not read task route")
			return
		}
		if err == nil {
			known = true
			switch task.State {
			case store.TaskClosed, store.TaskSucceeded, store.TaskFailed, store.TaskCancelled, store.TaskRefused:
				closed = true
			default:
				fid, suffix, parseErr := fleetid.ParseWorkerID(task.WorkerID)
				// An old ID linked to a continued task is not the new window.
				if f, ok := allowed[fid]; ok && parseErr == nil && suffix == id {
					add(f, task.SessionKey, "placement")
				}
			}
		}
		rec, err := s.Store.FleetIDOf(owner, id)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			httpError(w, http.StatusInternalServerError, "could not read identity route")
			return
		}
		if err == nil {
			known = true
			closed = closed || rec.ClosedAt != 0
			mirrors = append(mirrors, rec)
		}
	}
	// A closed record without a live inventory row must not produce a relay
	// which can only remain queued forever.
	if !closed {
		if answer() {
			return
		}
		// A scratch session has no task placement. Its ID mirror pins the
		// endpoint; only a unique registered fleet on that endpoint is a route.
		for _, rec := range mirrors {
			if rec.EndpointID == "" {
				continue
			}
			for _, f := range allowed {
				if f.EndpointID == rec.EndpointID {
					add(f, rec.Key, "identity")
				}
			}
		}
		if answer() {
			return
		}
	}
	reason := "not_found"
	if known {
		reason = "no_route"
	}
	if closed {
		reason = "closed"
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"code": "NOT_FOUND", "reason": reason,
		"error": "no worker route for this owner: " + strings.ReplaceAll(reason, "_", " ")})
}
