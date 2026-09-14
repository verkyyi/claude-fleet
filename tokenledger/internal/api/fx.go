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
	base := r.URL.Query().Get("base")
	if base == "" {
		base = "USD"
	}
	target := r.URL.Query().Get("target")
	if target == "" {
		target = base
	}
	rate, ok := s.FX.Get(base, target)
	if !ok {
		// Not an error: "this hub cannot convert that pair" is an answer, and
		// the page responds by showing each figure in its billed currency —
		// which is the truthful rendering anyway.
		writeJSON(w, http.StatusOK, map[string]any{
			"base": base, "target": target, "available": false,
			"reason": "no rate for this pair",
		})
		return
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
		"note":     fxNote.In(localeOf(r)),
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
	writeJSON(w, http.StatusOK, out)
}
