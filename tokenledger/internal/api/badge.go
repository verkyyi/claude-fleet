package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/badge"
	"github.com/verkyyi/ccquota/internal/store"
)

// Badge routes exist so an internal repo README can carry a figure served by
// the company's own hub.
//
// That forces one property: a README image cannot send a viewer token, and
// GitHub's camo proxy strips cookies. So a badge that actually works in a
// README has to be readable without a credential. Whether an internal hub
// should expose ANY unauthenticated route is an open question, so this is
// opt-in (`ccquota hub --public-badges`) and off by default -- an operator who
// upgrades does not silently start publishing.
const badgeMaxAge = "public, max-age=300"

// allTimeFloor is earlier than any Claude Code transcript can be.
//
// The per-user queries take a start bound, and "all time" still needs one.
var allTimeFloor = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)

// badgeTheme reads the explicit ?theme=. There is deliberately no
// prefers-color-scheme fallback: inside an SVG loaded as an image it is
// inconsistently supported, and camo caches one copy for every reader.
func badgeTheme(r *http.Request) string {
	if r.URL.Query().Get("theme") == "light" {
		return "light"
	}
	return "dark"
}

// badgePeriod reads ?period=. Anything unrecognised becomes all-time, which is
// the only window that cannot be mislabelled.
func badgePeriod(r *http.Request) (period string, start time.Time) {
	switch r.URL.Query().Get("period") {
	case "30d":
		return "30d", time.Now().UTC().AddDate(0, 0, -30)
	case "7d":
		return "7d", time.Now().UTC().AddDate(0, 0, -7)
	default:
		return "all", allTimeFloor
	}
}

// writeBadge emits an SVG or shields JSON, depending on the extension.
func writeBadge(w http.ResponseWriter, status int, d badge.Data, asJSON bool) {
	w.Header().Set("Cache-Control", badgeMaxAge)
	if asJSON {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(badge.ToShields(d))
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(badge.Render(d))
}

// notFoundBadge is what an unknown handle gets.
//
// Never a zeroed badge: "0 tokens" reads as "this person did nothing", which is
// a different claim -- and a false one -- from "there is no such person here".
func notFoundBadge(w http.ResponseWriter, theme string, asJSON bool) {
	w.Header().Set("Cache-Control", badgeMaxAge)
	if asJSON {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(badge.Shields{
			SchemaVersion: 1, Label: "ccquota", Message: "no such handle", Color: "9c3050",
		})
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	w.WriteHeader(http.StatusNotFound)
	_, _ = w.Write(badge.RenderMessage("ccquota", "no such handle", theme))
}

// splitBadgePath turns "/badge/u/alice.svg" into ("alice", false).
func splitBadgePath(path, prefix string) (name string, asJSON bool, ok bool) {
	rest := strings.TrimPrefix(path, prefix)
	if rest == "" || rest == path || strings.Contains(rest, "/") {
		return "", false, false
	}
	switch {
	case strings.HasSuffix(rest, ".svg"):
		return strings.TrimSuffix(rest, ".svg"), false, true
	case strings.HasSuffix(rest, ".json"):
		return strings.TrimSuffix(rest, ".json"), true, true
	default:
		return "", false, false
	}
}

func (s *Server) handleUserBadge(w http.ResponseWriter, r *http.Request) {
	login, asJSON, ok := splitBadgePath(r.URL.Path, "/badge/u/")
	if !ok {
		http.NotFound(w, r)
		return
	}
	theme := badgeTheme(r)
	period, start := badgePeriod(r)

	sum, err := s.Store.UserSummary(login, start, time.Now().UTC())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if sum.Turns == 0 {
		notFoundBadge(w, theme, asJSON)
		return
	}
	writeBadge(w, http.StatusOK, badge.Data{
		Tokens: sum.Tokens, Turns: sum.Turns, Period: period, Theme: theme,
	}, asJSON)
}

func (s *Server) handleTeamBadge(w http.ResponseWriter, r *http.Request) {
	team, asJSON, ok := splitBadgePath(r.URL.Path, "/badge/team/")
	if !ok {
		http.NotFound(w, r)
		return
	}
	theme := badgeTheme(r)
	period, start := badgePeriod(r)

	buckets, err := s.Store.UsageBy(store.AllAccounts, store.ByTeam, start, time.Now().UTC(), 1000)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, b := range buckets {
		if b.Key == team {
			writeBadge(w, http.StatusOK, badge.Data{
				Tokens: b.Tokens, Turns: b.Events, Period: period, Theme: theme,
			}, asJSON)
			return
		}
	}
	notFoundBadge(w, theme, asJSON)
}
