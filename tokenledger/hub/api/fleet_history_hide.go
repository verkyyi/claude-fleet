package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
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
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		httpError(w, 400, "invalid manifest")
		return
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(&in); err != nil {
		httpError(w, 400, "invalid manifest")
		return
	}
	if d.Decode(new(any)) != io.EOF {
		httpError(w, 400, "invalid manifest")
		return
	}
	if !in.Undo {
		rec, err := s.Store.FleetIDOf(in.Manifest.Owner, in.Manifest.ID)
		if err != nil {
			writeJSON(w, 409, map[string]any{"error": "history hide refused", "reason": "identity_not_found"})
			return
		}
		if peer, ok := s.chatRelayPeer(r, rec.Machine, rec.Login); ok {
			// Decode for routing, then forward the exact bounded reviewed body.
			// The owning replica authenticates again and rechecks every guard.
			r.Body = io.NopCloser(bytes.NewReader(raw))
			r.ContentLength = int64(len(raw))
			s.proxyRelay(w, r, peer, "history hide validation")
			return
		}
		if _, _, err := s.chatRelayNode(rec.Machine, rec.Login); err != nil {
			reason := "offline_unknown"
			var re *sshRelayError
			if errors.As(err, &re) && re.code == "NO_CHAT" {
				reason = "old_agent"
			}
			writeJSON(w, 409, map[string]any{"error": "history hide refused", "reason": reason})
			return
		}
	}
	actor := principalOf(r.Context())
	if actor == "" {
		actor = viewerOf(r.Context())
	}
	if actor == "" {
		// Same provenance as FleetPrincipal: the authorized shared operator
		// credential names a role, not an individual human.
		actor = "operator"
	}
	if err := s.Store.HideHistory(in.Manifest, actor, in.Undo, in.Apply, time.Now(), s.historyMirrorSession); err != nil {
		var refusal *store.HistoryHideError
		if errors.As(err, &refusal) {
			writeJSON(w, 409, map[string]any{"error": "history hide refused", "reason": refusal.Reason})
		} else {
			httpError(w, 500, "history validation unavailable")
		}
		return
	}
	out := map[string]any{"ok": true, "applied": in.Apply, "undo": in.Undo, "id": in.Manifest.ID}
	if !in.Undo {
		out["history_status"] = "missing_confirmed"
	}
	writeJSON(w, 200, out)
}
