// internal/api/findings.go
package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/store"
)

// handleFindings answers GET /v1/findings?view=review|now. Both views share
// one envelope shape with the rest of the rollup-backed endpoints
// (handleSummary, handleLimitsHistory, MCP usage_history): account_uuid,
// all_accounts and the ALIGNED window actually queried -- s.scope() widens
// the requested range out to whole UTC hours because the rollup cannot
// answer at finer resolution, and a caller comparing this window against
// another endpoint's needs to see that alignment, not the raw query string.
//
// "now" has no period to align -- it is a snapshot of the current minute --
// so since/until are omitted entirely rather than echoing a fake window.
func (s *Server) handleFindings(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("view") == "now" {
		s.handleNowFindings(w, r)
		return
	}
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	in, err := s.GatherReview(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": f.Account, "all_accounts": f.Account == store.AllAccounts,
		"since": f.Start, "until": f.End, "view": "review",
		// findings.Review always returns a non-nil slice (finish() converts
		// nil to []Finding{}), so this is never a JSON null.
		"findings": findings.Review(in),
	})
}

// GatherReview assembles findings.Inputs for one Filter -- the period-scale
// rules (runaway sessions, unpriced models, time in the critical rate-limit
// band, cache-hit drops, spend spikes). Exported so internal/mcp's
// get_findings tool can call it across the package boundary; the HTTP
// handler above and that tool are the only two callers, and both then pass
// the result to findings.Review.
func (s *Server) GatherReview(f store.Filter) (findings.Inputs, error) {
	var in findings.Inputs
	in.SelectionSeconds = int64(f.End.Sub(f.Start) / time.Second)

	// 50, not the population: runaway()'s threshold now comes from
	// SessionTokenMedian below, computed by the store over every session in
	// the window, so this pull only needs enough of the tokens-descending
	// order to find candidates above that threshold -- the actual outlier
	// this rule exists to catch is always near the top. Pulling more here
	// used to be how the median got silently computed from a biased sample
	// instead of the population; see SessionTokenMedian's doc comment.
	sessions, err := s.Store.Sessions(f, "tokens", 50, 0)
	if err != nil {
		return in, err
	}
	for _, sr := range sessions {
		in.Sessions = append(in.Sessions, findings.SessionStat{SessionID: sr.SessionID, CWD: sr.CWD, Model: sr.Model,
			Tokens: sr.Tokens, Turns: sr.Turns, Duration: sr.Ended.Sub(sr.Started)})
	}
	in.SessionTokenMedian, err = s.Store.SessionTokenMedian(f)
	if err != nil {
		return in, err
	}
	models, err := s.Store.UsageByFiltered(f, store.ByModel, 50)
	if err != nil {
		return in, err
	}
	for _, m := range models {
		in.Models = append(in.Models, findings.ModelStat{Model: m.Key, Tokens: m.Tokens, Unpriced: m.Unpriced})
	}
	pts, err := s.Store.LimitsHistory(f.Account, f.Start, f.End)
	if err != nil {
		return in, err
	}
	prev := f.Prev()
	prevPts, err := s.Store.LimitsHistory(f.Account, prev.Start, prev.End)
	if err != nil {
		return in, err
	}
	labels := s.accountLabels()
	byAcct := map[string][]store.LimitPoint{}
	var order []string
	for _, p := range pts {
		if _, ok := byAcct[p.AccountUUID]; !ok {
			order = append(order, p.AccountUUID)
		}
		byAcct[p.AccountUUID] = append(byAcct[p.AccountUUID], p)
	}
	prevBy := map[string][]store.LimitPoint{}
	for _, p := range prevPts {
		prevBy[p.AccountUUID] = append(prevBy[p.AccountUUID], p)
	}
	for _, a := range order {
		secs, eps := criticalTime(byAcct[a])
		prevSecs, _ := criticalTime(prevBy[a])
		in.Critical = append(in.Critical, findings.AccountCritical{Label: labels[a], Seconds: secs, PrevSeconds: prevSecs, Episodes: eps})
	}
	cur, err := s.Store.UsageByFiltered(f, store.ByProject, 50)
	if err != nil {
		return in, err
	}
	prevProj, err := s.Store.UsageByFiltered(prev, store.ByProject, 500)
	if err != nil {
		return in, err
	}
	prevTok := map[string]int64{}
	for _, p := range prevProj {
		prevTok[p.Key] = p.Tokens
		in.PrevProjects = append(in.PrevProjects, projectStat(p, 0))
	}
	for _, p := range cur {
		in.Projects = append(in.Projects, projectStat(p, prevTok[p.Key]))
	}
	sum, err := s.Store.Summary(f)
	if err != nil {
		return in, err
	}
	psum, err := s.Store.Summary(prev)
	if err != nil {
		return in, err
	}
	in.Tokens, in.PrevTokens = sum.Tokens, psum.Tokens
	return in, nil
}

func projectStat(b store.Bucket, prevTokens int64) findings.ProjectStat {
	var hit float64
	if d := b.CacheReadTokens + b.InputTokens + b.CacheCreateTokens; d > 0 {
		hit = float64(b.CacheReadTokens) / float64(d)
	}
	return findings.ProjectStat{CWD: b.Key, Turns: b.Events, CacheHit: hit, Tokens: b.Tokens, PrevTokens: prevTokens}
}

func (s *Server) handleNowFindings(w http.ResponseWriter, r *http.Request) {
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	in, err := s.GatherNow(account)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": account, "all_accounts": account == store.AllAccounts,
		"view":     "now",
		"findings": findings.Now(in),
	})
}

// GatherNow assembles findings.NowInputs for one account (or AllAccounts) --
// the minute-scale rules (a rate-limit window running hot, an endpoint that
// has stopped reporting, a live session burning through tokens right now).
// Exported for the same cross-package reason as GatherReview; callers pass
// the result to findings.Now.
func (s *Server) GatherNow(account string) (findings.NowInputs, error) {
	in := findings.NowInputs{Now: time.Now().UTC()}
	accts, err := s.Store.ListAccounts()
	if err != nil {
		return in, err
	}
	for _, a := range accts {
		if account != store.AllAccounts && a.AccountUUID != account {
			continue
		}
		snap, err := s.Store.LatestLimits(a.AccountUUID)
		if err != nil || snap == nil {
			continue
		}
		in.Windows = append(in.Windows, findings.WindowStat{Label: a.Label(), FiveHourPct: snap.FiveHour.Utilization})
	}
	scopeAcct := account
	if scopeAcct == store.AllAccounts {
		scopeAcct = ""
	}
	eps, err := s.Store.ListEndpoints(scopeAcct)
	if err != nil {
		return in, err
	}
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		in.Endpoints = append(in.Endpoints, findings.EndpointSeen{Label: label, LastSeen: e.LastSeen})
	}
	for _, l := range s.liveStore().Snapshot().Sessions {
		if account != store.AllAccounts && l.Account != "" && l.Account != account {
			continue
		}
		in.Live = append(in.Live, findings.LiveStat{SessionID: l.SessionID, CWD: l.CWD, Tokens: l.InputTokens + l.OutputTokens})
	}
	return in, nil
}
