// internal/api/findings.go
package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
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
		"findings": localizeFindings(findings.Review(in), localeOf(r)),
	})
}

// freeAllowanceStats measures each model that declares a free monthly allowance
// against THIS CALENDAR MONTH, not against the page's selection.
//
// The window is the whole point. An allowance resets on the first of the month,
// so "is it used up" is a question about the month however the viewer has the
// brush set -- asking it of a 7-day selection would report a fresh allowance
// every week and never fire.
//
// The scope's account and source filters are kept: a hub holding two gateways
// should answer for the one being looked at. Everything that narrows WITHIN a
// month (project, session, model chips) is dropped, for the same reason the
// range is: the vendor counts every call against the allowance, not the subset
// somebody is currently filtered to.
func (s *Server) freeAllowanceStats(f store.Filter) ([]findings.FreeAllowanceStat, error) {
	if s.Pricing == nil {
		return nil, nil
	}
	allowances := s.Pricing.FreeAllowances()
	if len(allowances) == 0 {
		return nil, nil
	}
	now := time.Now().UTC()
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	month := store.Filter{
		Account: f.Account, Source: f.Source,
		Start: monthStart, End: now,
	}
	rows, err := s.Store.UsageByFiltered(month.AlignHours(), store.ByModel, 200)
	if err != nil {
		return nil, err
	}
	var out []findings.FreeAllowanceStat
	for _, r := range rows {
		if n, ok := allowances[pricing.Normalize(r.Key)]; ok {
			out = append(out, findings.FreeAllowanceStat{Model: r.Key, Tokens: r.Tokens, Allowance: n})
		}
	}
	return out, nil
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

	// Gathered here rather than in each caller so both doors -- GET
	// /v1/findings and MCP get_findings -- see the same silences. A finding
	// muted on the dashboard must also be muted for an agent reading the same
	// hub, or "acknowledged" means two different things depending on who asks.
	mutes, err := s.activeMutes()
	if err != nil {
		return in, err
	}
	in.Mutes = mutes

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
	teams, err := s.endpointTeams(f.Account, f.Source)
	if err != nil {
		return in, err
	}
	for _, sr := range sessions {
		in.Sessions = append(in.Sessions, findings.SessionStat{SessionID: sr.SessionID, CWD: sr.CWD, Model: sr.Model,
			Tokens: sr.Tokens, Turns: sr.Turns, Duration: sr.Ended.Sub(sr.Started),
			// The login is on the row; the team lives only on the endpoint. A
			// runaway session has exactly one of each, so both are lookups --
			// see findings.Owner for why a rule that cannot do that lookup
			// leaves the field empty instead of approximating it.
			OSUser: sr.OSUser, Team: teams[sr.EndpointID]})
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
	in.FreeAllowances, err = s.freeAllowanceStats(f)
	if err != nil {
		return in, err
	}
	pts, err := s.Store.LimitsHistory(f.Account, f.Start, f.End, f.Source)
	if err != nil {
		return in, err
	}
	prev := f.Prev()
	prevPts, err := s.Store.LimitsHistory(f.Account, prev.Start, prev.End, f.Source)
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
		in.Critical = append(in.Critical, findings.AccountCritical{AccountUUID: a, Label: labels[a], Seconds: secs, PrevSeconds: prevSecs, Episodes: eps})
	}
	cur, err := s.Store.UsageByFiltered(f, store.ByProject, 50)
	qs, qerr := s.QuotaHistorySeries(f, 400)
	if qerr != nil {
		return in, qerr
	}
	for _, q := range qs {
		// The uuid AND the window id: one subscription has several provider
		// windows, they run hot independently, and their findings must not
		// share an identity -- see findings/identity.go. q.Label already
		// folds both in for display; the key does it without the prose.
		in.Critical = append(in.Critical, findings.AccountCritical{
			AccountUUID: q.AccountUUID + "\x1f" + q.WindowID,
			Label:       q.Label, Seconds: q.CriticalSeconds,
			PrevSeconds: q.PrevCriticalSeconds, Episodes: q.CriticalEpisodes})
	}
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

// endpointTeams maps endpoint id → the operator's team allocation for that
// endpoint, so a rule whose subject is a SESSION can still name the team: the
// assignment lives on the endpoint record and nowhere else, and a session row
// carries the endpoint id but not the team.
//
// One pull per findings request, deliberately: the endpoints table is the
// fleet's machine roster (tens of rows, not millions), which is far cheaper to
// read whole than to denormalise the team into every rollup row and then have
// to re-write history every time the operator re-allocates a machine.
//
// A miss leaves the team empty, which is the honest answer in both cases that
// produce one: the endpoint has been removed, or it was never allocated to a
// team at all.
func (s *Server) endpointTeams(account, source string) (map[string]string, error) {
	if account == store.AllAccounts {
		account = ""
	}
	eps, err := s.Store.ListEndpoints(account, source)
	if err != nil {
		return nil, err
	}
	return teamsByEndpoint(eps), nil
}

func teamsByEndpoint(eps []store.Endpoint) map[string]string {
	teams := make(map[string]string, len(eps))
	for _, e := range eps {
		if e.Team != "" {
			teams[e.ID] = e.Team
		}
	}
	return teams
}

func projectStat(b store.Bucket, prevTokens int64) findings.ProjectStat {
	var hit float64
	if d := b.CacheReadTokens + b.InputTokens + b.CacheCreateTokens; d > 0 {
		hit = float64(b.CacheReadTokens) / float64(d)
	}
	return findings.ProjectStat{CWD: b.Key, Turns: b.Events, CacheHit: hit, Tokens: b.Tokens, PrevTokens: prevTokens}
}

func (s *Server) handleNowFindings(w http.ResponseWriter, r *http.Request) {
	source, valid := querySource(w, r)
	if !valid {
		return
	}
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	in, err := s.GatherNowSource(account, source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": account, "all_accounts": account == store.AllAccounts,
		"view":     "now",
		"findings": localizeFindings(findings.Now(in), localeOf(r)),
	})
}

// GatherNow assembles findings.NowInputs for one account (or AllAccounts) --
// the minute-scale rules (a rate-limit window running hot, an endpoint that
// has stopped reporting, a live session burning through tokens right now).
// Exported for the same cross-package reason as GatherReview; callers pass
// the result to findings.Now.
func (s *Server) GatherNow(account string) (findings.NowInputs, error) {
	return s.GatherNowSource(account, "")
}

func (s *Server) GatherNowSource(account, source string) (findings.NowInputs, error) {
	in := findings.NowInputs{Now: time.Now().UTC()}
	mutes, err := s.activeMutes()
	if err != nil {
		return in, err
	}
	in.Mutes = mutes
	accts, err := s.Store.ListAccounts()
	if err != nil {
		return in, err
	}
	for _, a := range accts {
		if source != "" && model.UsageSource(a.Source) != source {
			continue
		}
		if account != store.AllAccounts && a.AccountUUID != account {
			continue
		}
		if a.Source == model.SourceCodex {
			v, err := s.codexLimitsFor(a.AccountUUID)
			if err != nil {
				return in, err
			}
			if !v.Available {
				continue
			}
			for _, w := range v.Windows {
				in.Windows = append(in.Windows, findings.WindowStat{AccountUUID: a.AccountUUID, Label: a.Label(), Window: w.Label, FiveHourPct: w.Utilization})
			}
			continue
		}
		snap, err := s.Store.LatestLimits(a.AccountUUID)
		if err != nil || snap == nil {
			continue
		}
		in.Windows = append(in.Windows, findings.WindowStat{AccountUUID: a.AccountUUID, Label: a.Label(), FiveHourPct: snap.FiveHour.Utilization})
	}
	scopeAcct := account
	if scopeAcct == store.AllAccounts {
		scopeAcct = ""
	}
	eps, err := s.Store.ListEndpoints(scopeAcct, source)
	if err != nil {
		return in, err
	}
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		// OSUser and Team, not just the label. The whole point of a stale-agent
		// alert is "go make the agent on this machine live again", and the hub
		// has always known whose machine that is -- an endpoint IS a (machine,
		// login) pair, and Team is the operator's own allocation of it. Passing
		// only Label was the alert refusing to say who to go to while holding
		// the answer.
		in.Endpoints = append(in.Endpoints, findings.EndpointSeen{
			// ID as well as Label: the label is what the alert PRINTS and it
			// defaults to the hostname, so two machines can carry the same
			// one. Muting is keyed on the id -- see findings/identity.go.
			ID: e.ID, Label: label, LastSeen: e.LastSeen, OSUser: e.OSUser, Team: e.Team,
		})
	}
	// Same roster, reused: the live sessions below are filtered to the same
	// account and source as eps, so this needs no second query.
	teams := teamsByEndpoint(eps)
	for _, l := range s.FilterLive(s.liveStore().Snapshot(), account, source).Sessions {
		in.Live = append(in.Live, findings.LiveStat{SessionID: l.SessionID, CWD: l.CWD,
			Tokens: l.InputTokens + l.OutputTokens,
			// OSUser is already on the heartbeat (the hub's enrich hook fills it
			// from this same endpoint record); the team comes off the roster.
			OSUser: l.OSUser, Team: teams[l.EndpointID]})
	}
	return in, nil
}
