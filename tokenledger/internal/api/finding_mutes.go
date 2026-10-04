// internal/api/finding_mutes.go — the hub's second write, and the first one
// that records a person's judgement.
//
// # Where this sits in the trust boundary
//
// Until now the hub had exactly one viewer-facing write: POST
// /v1/accounts/label, which renames a subscription for display. Everything
// else a viewer can reach is a read. Adding a second write is worth stating
// plainly rather than discovering later, so: this route sits behind the SAME
// gate as that one, s.viewerOnly, and nothing else changes.
//
// Concretely, that means:
//
//   - The ingest tokens are not involved. An ENDPOINT cannot mute a finding.
//     That matters more than it sounds: the stale-agent alert is about an
//     endpoint having gone quiet, and a machine that could silence the alarm
//     about its own silence is a machine that can disappear unnoticed.
//   - Share links (s.shareOnly) and the badge/embed routes do not reach it.
//     A shared page is a read-only view of somebody else's hub.
//   - MCP stays read-only. get_findings reports `id` and `muted`, and there is
//     no mute tool: the server is described to every agent as read-only, and
//     an agent silencing the fleet's alerts on its own initiative is not a
//     capability anyone asked for. An agent that thinks something should be
//     muted can say so to a person, who has this endpoint.
//
// So the blast radius of a mute is exactly the blast radius of a rename:
// whoever holds the viewer token, a tailnet identity, or an SSO session. What
// is new is that a write can now make the hub QUIETER, which a rename cannot
// — hence the expiry, the ceiling, and the fact that muted findings keep
// being rendered rather than dropped.
package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/store"
)

// activeMutes reads the silences in force and keys them the way
// internal/findings wants them. One pull per findings request: the table holds
// at most a handful of rows on any real hub (one per thing an operator
// bothered to silence, each self-expiring), which is cheaper to read whole
// than to look up per finding.
func (s *Server) activeMutes() (findings.Mutes, error) {
	rows, err := s.Store.ActiveFindingMutes(time.Now().UTC())
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	out := make(findings.Mutes, len(rows))
	for _, m := range rows {
		out[m.FindingID] = findings.Mute{Until: m.ExpiresAt, Note: m.Note, By: m.By}
	}
	return out, nil
}

// handleFindingMutes serves /v1/findings/mutes.
//
//	GET   lists every mute, expired ones included, so the roster can answer
//	      "what have we silenced, and what has already come back".
//	POST  {"id","kind","note","hours"}          mutes (or extends) one finding
//	      {"id","action":"unmute"}              lifts it early
//
// `hours` is clamped by the store (see store.MaxMuteFor); the response echoes
// the mute that was actually written, expiry included, so the page states the
// real duration rather than the requested one.
func (s *Server) handleFindingMutes(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		rows, err := s.Store.AllFindingMutes()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		now := time.Now().UTC()
		// active is derived here rather than stored: a row is in force iff
		// its expiry is still ahead, and the reader should not have to
		// compare timestamps to find that out.
		out := make([]map[string]any, 0, len(rows))
		for _, m := range rows {
			out = append(out, map[string]any{
				"finding_id": m.FindingID, "kind": m.Kind, "note": m.Note,
				"by": m.By, "muted_at": m.MutedAt, "expires_at": m.ExpiresAt,
				"active": m.ExpiresAt.After(now),
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"mutes": out, "now": now})

	case http.MethodPost:
		var body struct {
			ID     string  `json:"id"`
			Kind   string  `json:"kind"`
			Note   string  `json:"note"`
			Hours  float64 `json:"hours"`
			Action string  `json:"action"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
			httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
			return
		}
		id := strings.TrimSpace(body.ID)
		if id == "" {
			httpError(w, http.StatusBadRequest, "id is required: the finding's id, as GET /v1/findings reports it")
			return
		}
		now := time.Now().UTC()
		if body.Action == "unmute" {
			existed, err := s.Store.UnmuteFinding(id, now)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"id": id, "muted": false, "was_muted": existed})
			return
		}
		m, err := s.Store.MuteFinding(
			store.FindingMute{FindingID: id, Kind: body.Kind, Note: body.Note, By: viewerOf(r.Context())},
			time.Duration(body.Hours*float64(time.Hour)), now)
		if err != nil {
			httpError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"id": m.FindingID, "muted": true, "kind": m.Kind, "note": m.Note,
			"by": m.By, "muted_at": m.MutedAt, "expires_at": m.ExpiresAt,
			// The ceiling is not a secret: a caller that asked for a year and
			// got a month should be able to say so without guessing why.
			"max_hours": store.MaxMuteFor.Hours(),
		})

	default:
		httpError(w, http.StatusMethodNotAllowed, "GET or POST required")
	}
}
