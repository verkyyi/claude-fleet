package api

import (
	"net/http"
	"time"
)

// FXStaleAfter is when a feed's own timestamp stops counting as current.
//
// Generous on purpose: the default feed updates daily, so anything under a day
// is simply "today's rate". Past this the dashboard keeps converting but says
// the rate is old — stopping would replace a slightly stale figure with none at
// all, which helps nobody.
const FXStaleAfter = 48 * time.Hour

// handleFX answers one conversion, with everything a surface needs to disclose
// it: the rate, where it came from, when the FEED last moved, and whether it is
// a live reading at all.
//
// Deliberately its own endpoint rather than a field on every money response.
// The rate is one value for the whole page — attaching it to each response
// would let two cards render the same figure at two rates if their fetches
// straddled a refresh, which is exactly the kind of quietly-inconsistent money
// this hub is built to avoid.
func (s *Server) handleFX(w http.ResponseWriter, r *http.Request) {
	out := s.FXView(r.URL.Query().Get("base"), r.URL.Query().Get("target"))
	if _, ok := out["note"]; ok {
		out["note"] = fxNote.In(localeOf(r))
	}
	writeJSON(w, http.StatusOK, out)
}

// FXView is one conversion, with everything a reader needs to disclose it.
//
// Shared with MCP, which needs it for a reason the dashboard does not have: an
// agent handed a plan priced in CNY has otherwise no way to reach the rate it
// would have to convert through, nor to learn how stale that rate is — so it
// either invents one or silently compares two currencies. The prose here is
// English; handleFX restates it in the viewer's language, and MCP takes it as
// it is (its consumer is a model, and a translated note is one more thing that
// can drift).
func (s *Server) FXView(base, target string) map[string]any {
	if base == "" {
		base = "USD"
	}
	if target == "" {
		target = base
	}
	rate, ok := s.FX.Get(base, target)
	if !ok {
		// Not an error: "this hub cannot convert that pair" is an answer, and
		// the page responds by showing each figure in its billed currency —
		// which is the truthful rendering anyway.
		return map[string]any{
			"base": base, "target": target, "available": false,
			"reason": "no rate for this pair",
		}
	}
	now := time.Now().UTC()
	out := map[string]any{
		"base":      rate.Base,
		"target":    rate.Target,
		"rate":      rate.Rate,
		"source":    rate.Source,
		"available": true,
		// Fallback means the figure rests on a rate pinned in the binary because
		// the feed has not answered. The page says so next to every converted
		// number rather than letting a stale rate pass as today's.
		"fallback": rate.Fallback,
		"note":     fxNote.In(""),
	}
	if !rate.AsOf.IsZero() {
		out["as_of"] = rate.AsOf
		out["stale_seconds"] = int64(now.Sub(rate.AsOf).Seconds())
		out["stale"] = rate.Stale(now, FXStaleAfter)
	} else {
		out["stale"] = true
	}
	if err := s.FX.Err(); err != nil && rate.Fallback {
		out["error"] = err.Error()
	}
	return out
}
