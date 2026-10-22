package api

import (
	"encoding/json"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"net/http"
	"time"
)

// Operator support tooling only. Explicit per-owner/FID manifest; no production
// sweep, and no mutation unless apply=true. A view-as never writes history.
func (s *Server) handleHistoryHide(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, 405, "POST only")
		return
	}
	if viewAsAsked(r) != "" {
		httpError(w, 403, "leave view-as before changing history")
		return
	}
	if r.Header.Get("X-Fleet-History-Review") != "1" {
		httpError(w, 400, "reviewed manifest required")
		return
	}
	var in struct {
		Manifest store.HistoryHideManifest `json:"manifest"`
		Apply    bool                      `json:"apply"`
		Undo     bool                      `json:"undo"`
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	d.DisallowUnknownFields()
	if err := d.Decode(&in); err != nil {
		httpError(w, 400, "invalid manifest")
		return
	}
	if !in.Undo {
		rec, err := s.Store.FleetIDOf(in.Manifest.Owner, in.Manifest.ID)
		if err != nil {
			httpError(w, 409, "unknown owner/FID")
			return
		}
		if _, _, err := s.chatRelayNode(rec.Machine, rec.Login); err != nil {
			httpError(w, 409, "offline_unknown: current placement must be online for hide, including dry-run")
			return
		}
	}
	actor := principalOf(r.Context())
	if actor == "" {
		actor = viewerOf(r.Context())
	}
	if err := s.Store.HideHistory(in.Manifest, actor, in.Undo, in.Apply, time.Now()); err != nil {
		httpError(w, 409, err.Error())
		return
	}
	out := map[string]any{"ok": true, "applied": in.Apply, "undo": in.Undo, "id": in.Manifest.ID}
	if !in.Undo {
		out["history_status"] = "missing_confirmed"
	}
	writeJSON(w, 200, out)
}
