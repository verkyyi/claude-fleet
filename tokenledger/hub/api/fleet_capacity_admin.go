package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

const planCapacitiesPath = "/v1/fleet/plans/capacity"
const codexPreviewPath = "/v1/fleet/credproxy/preview"

func capacityJSON(w http.ResponseWriter, r *http.Request, v any) error {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return errors.New("exactly one JSON object is required")
	}
	return nil
}

// Admin-only catalog, including reversible history. The durable revision and
// actor are the audit; no routing/account labels or credential content is saved.
func (s *Server) handlePlanCapacities(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
		current, err := s.Store.PlanCapacities()
		if err != nil {
			httpError(w, 500, "capacity catalog read failed")
			return
		}
		history, err := s.Store.PlanCapacityHistory()
		if err != nil {
			httpError(w, 500, "capacity history read failed")
			return
		}
		writeJSON(w, 200, map[string]any{"current": current, "history": history})
	case http.MethodPut:
		var req struct {
			ExpectedRevision int64                     `json:"expected_revision"`
			Catalog          store.PlanCapacityCatalog `json:"catalog"`
		}
		if err := capacityJSON(w, r, &req); err != nil {
			httpError(w, 400, "invalid capacity catalog: "+err.Error())
			return
		}
		if req.ExpectedRevision < 0 || req.ExpectedRevision > 1e12 {
			httpError(w, 400, "expected_revision is out of range")
			return
		}
		if err := req.Catalog.Validate(); err != nil {
			httpError(w, 400, err.Error())
			return
		}
		actor := principalOf(r.Context())
		if actor == "" {
			actor = "operator"
		}
		out, err := s.Store.SetPlanCapacities(req.Catalog, req.ExpectedRevision, actor, time.Now())
		if errors.Is(err, store.ErrCapacityConflict) {
			httpError(w, 409, err.Error())
			return
		}
		if err != nil {
			httpError(w, 500, "capacity catalog save failed")
			return
		}
		writeJSON(w, 200, out)
	default:
		httpError(w, 405, "GET or PUT capacity catalog")
	}
}

// Preview is admin-only and scoped to an actual live worker's principal and
// endpoint. It performs metadata reads and the SAME chooser as resolve, never
// sessionBind, lease/refresh, bind CAS, affinity recording or inference.
func (s *Server) handleCodexPreview(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, 405, "POST {worker_id, new_session?}")
		return
	}
	if s.vaultOff(w) || s.vaultLocked(w) {
		return
	}
	var req struct {
		WorkerID   string `json:"worker_id"`
		NewSession bool   `json:"new_session"`
	}
	if err := capacityJSON(w, r, &req); err != nil || req.WorkerID == "" || len(req.WorkerID) > 256 {
		httpError(w, 400, "worker_id of a live session is required")
		return
	}
	now := time.Now()
	live, err := s.Store.SessionCredsForWorker(req.WorkerID, now)
	if err != nil {
		httpError(w, 500, "session scope read failed")
		return
	}
	if len(live) == 0 {
		httpError(w, 404, "no live session pass for worker")
		return
	}
	// Fail closed if contradictory live identities exist for one worker.
	scope := live[0]
	for _, c := range live {
		if c.PrincipalID != scope.PrincipalID || c.EndpointID != scope.EndpointID {
			httpError(w, 409, "ambiguous worker scope")
			return
		}
	}
	if !hasString(scope.Providers, credvault.Codex) {
		httpError(w, 403, "worker pass does not authorize codex")
		return
	}
	choices, err := s.sessionBindChoices(scope.PrincipalID, scope.EndpointID, credvault.Codex)
	if err != nil {
		httpError(w, 500, "subscription policy read failed")
		return
	}
	if isSvcPrincipal(scope.PrincipalID) {
		choices = s.svcYield(scope.PrincipalID, choices, now)
	}
	if len(choices) == 0 {
		httpError(w, 409, "no authorized eligible Codex subscriptions")
		return
	}
	b, err := s.Store.SessionBindFor(req.WorkerID, credvault.Codex)
	if err != nil && !errors.Is(err, store.ErrNoSessionBind) {
		httpError(w, 500, "binding read failed")
		return
	}
	if errors.Is(err, store.ErrNoSessionBind) || req.NewSession {
		b = store.SessionBind{WorkerID: req.WorkerID, Provider: credvault.Codex}
	}
	cat, err := s.Store.PlanCapacities()
	if err != nil {
		httpError(w, 500, "capacity catalog read failed")
		return
	}
	proposed := cat.Catalog
	// Even off mode can inspect registered profiles without activating them.
	proposed.Mode = "shadow"
	inputs := s.codexSelectionInputs(choices, b, now, proposed)
	boundary := !isSvcPrincipal(scope.PrincipalID)
	pick, reason := codexChoose(choices, inputs, b, now, boundary)
	actualCat := cat.Catalog
	if actualCat.Mode != "active" {
		actualCat = store.PlanCapacityCatalog{Mode: "off"}
	}
	actualInputs := s.codexSelectionInputs(choices, b, now, actualCat)
	actual, actualReason := codexChoose(choices, actualInputs, b, now, boundary)
	writeJSON(w, 200, map[string]any{"policy": "codex-capacity-v2", "catalog_revision": cat.Revision, "mode": cat.Catalog.Mode,
		"worker_id": req.WorkerID, "principal_id": scope.PrincipalID, "endpoint_id": scope.EndpointID, "binding": b, "new_session": req.NewSession,
		"proposed":       map[string]any{"owner": choices[pick].PrincipalID, "account": choices[pick].Account, "reason": reason},
		"current_policy": map[string]any{"owner": choices[actual].PrincipalID, "account": choices[actual].Account, "reason": actualReason}, "inputs": inputs,
		"load_basis": "distinct workers with live unrevoked passes and Codex bindings; evaluated worker excluded", "mutates_bindings": false})
}
