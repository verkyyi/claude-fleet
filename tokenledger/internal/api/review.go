// internal/api/review.go
package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

func (s *Server) handleSummary(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	sum, reasons, err := s.Store.SummaryWithPricing(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	effort, err := s.Store.UsageByFiltered(f, store.ByEffort, 10)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	entry, err := s.Store.UsageByFiltered(f, store.ByEntrypoint, 10)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Real subscription invoices over the same period. Read here rather than
	// derived from the cost column because it is not in that column at all:
	// a plan is billed whether or not a token is spent.
	//
	// Scoped to the SAME account and source as everything else on the page. A
	// hub-wide invoice figure sitting beside one subscription's usage would be
	// the same category of error this endpoint exists to remove -- a number
	// that is correct about something the reader is not looking at.
	plans, err := s.Store.SubscriptionSpendOver(f.Account, f.Start, f.End)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	plans = PlansForSource(plans, f.Source)
	out := map[string]any{
		"account_uuid": f.Account, "all_accounts": f.Account == store.AllAccounts,
		"since": f.Start, "until": f.End,
		"events": sum.Events, "tokens": sum.Tokens, "sessions": sum.Sessions,
		// cost is a LIST, one entry per source, and there is no blended
		// cost_usd beside it. A single figure here would have to answer "which
		// kind of money", and over a scope spanning sources there is no answer.
		"cost": sum.Cost,
		// The two folds that mean something, named for what they mean. Their
		// sum is not a figure this hub reports anywhere.
		"cost_notional": sum.Cost.Notional(),
		"cost_billed":   sum.Cost.Billed(),
		// The only total that is money owed.
		"subscription_spend": nonNilSpend(plans),
		"real_spend":         RealSpendOver(sum.Cost, plans),
		"real_spend_note":    RealSpendNoteIn(localeOf(r)),
		// Provenance per source: rate date and the note each figure carries.
		// One entry when the scope is filtered to a source, every known source
		// when it is not -- there is one column per source either way.
		"pricing":          pricing.ProvenanceIn(localeOf(r), f.Source),
		"pricing_note":     pricing.NoteIn(f.Source, localeOf(r)),
		"unpriced_reasons": localizedReasons(reasons, localeOf(r)),
		"priced_events":    sum.Events - sum.Unpriced,
		"unpriced_events":  sum.Unpriced, "input_tokens": sum.InputTokens, "output_tokens": sum.OutputTokens,
		"cache_read_tokens": sum.CacheReadTokens, "cache_create_tokens": sum.CacheCreateTokens,
		"thinking_tokens": sum.ThinkingTokens, "sidechain_tokens": sum.SidechainTokens,
		"sidechain_events":   sum.SidechainEvents,
		"cache_write_tokens": sum.CacheWriteTokens, "cache_write_known_events": sum.CacheWriteKnownEvents,
		"effort": nonNil(effort), "entrypoint": nonNil(entry),
		"disclaimer": shareDisclaimerText.In(localeOf(r)), "scope_note": scopeNoteIn(f.Account, localeOf(r)),
	}
	if unclassified := sum.Cost.Unclassified(); len(unclassified) > 0 {
		// A source this build has no rate basis for belongs to neither fold.
		// Surfacing it is the point: money in no column is how an unreviewed
		// source stays unreviewed.
		out["cost_unclassified"] = unclassified
	}
	if wantsCompare(r) {
		prev, err := s.Store.Summary(f.Prev())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out["prev"] = prev
	}
	writeJSON(w, http.StatusOK, out)
}

// PlansForSource narrows subscription spend to the scope's source. A gateway-
// scoped page must not show a Claude plan's invoice next to its own charges:
// the gateway has no subscription, and the honest answer to "what does this
// source cost" is its metered bill alone.
func PlansForSource(in []store.SubscriptionSpend, source string) []store.SubscriptionSpend {
	if source == "" {
		return in
	}
	out := []store.SubscriptionSpend{}
	for _, p := range in {
		if p.Source == source {
			out = append(out, p)
		}
	}
	return out
}

func nonNilSpend(p []store.SubscriptionSpend) []store.SubscriptionSpend {
	if p == nil {
		return []store.SubscriptionSpend{}
	}
	return p
}

func nonNil(b []store.Bucket) []store.Bucket {
	if b == nil {
		return []store.Bucket{}
	}
	return b
}

func (s *Server) handleSessions(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	rows, err := s.Store.Sessions(f, q.Get("sort"), limit, offset)
	if err != nil {
		// Only an unknown sort is the client's fault; anything else (a
		// database error) is ours.
		status := http.StatusInternalServerError
		if errors.Is(err, store.ErrUnknownSort) {
			status = http.StatusBadRequest
		}
		httpError(w, status, err.Error())
		return
	}
	if rows == nil {
		rows = []store.SessionRow{}
	}
	writeJSON(w, http.StatusOK, rows)
}

// handleSession serves /v1/sessions/{id}: the header from the rollup and the
// turns from the raw events, which may have been pruned.
func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	source, valid := querySource(w, r)
	if !valid {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if id == "" {
		s.handleSessions(w, r)
		return
	}
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	head, err := s.Store.Session(account, id, source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if head == nil {
		httpError(w, http.StatusNotFound, "unknown session")
		return
	}
	turns, err := s.Store.SessionTurns(account, id, source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if turns == nil {
		turns = []store.Turn{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session": head,
		"turns":   turns,
		"pruned":  len(turns) == 0 && head.Turns > 0,
	})
}

func (s *Server) handleLimitsHistory(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	n, _ := strconv.Atoi(r.URL.Query().Get("points"))
	if n <= 0 {
		n = 400
	}
	pts, err := s.Store.LimitsHistory(f.Account, f.Start, f.End, f.Source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	prev := f.Prev()
	prevPts, err := s.Store.LimitsHistory(f.Account, prev.Start, prev.End, f.Source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	labels := s.accountLabels()
	byAcct := map[string]*LimitSeries{}
	var order []string
	for _, p := range pts {
		ls, ok := byAcct[p.AccountUUID]
		if !ok {
			ls = &LimitSeries{AccountUUID: p.AccountUUID, Label: labels[p.AccountUUID]}
			byAcct[p.AccountUUID] = ls
			order = append(order, p.AccountUUID)
		}
		ls.Points = append(ls.Points, p)
	}
	prevByAcct := map[string][]store.LimitPoint{}
	for _, p := range prevPts {
		prevByAcct[p.AccountUUID] = append(prevByAcct[p.AccountUUID], p)
	}
	out := make([]LimitSeries, 0, len(order))
	for _, a := range order {
		ls := byAcct[a]
		ls.CriticalSeconds, ls.CriticalEpisodes = criticalTime(ls.Points)
		ls.PrevCriticalSeconds, _ = criticalTime(prevByAcct[a])
		ls.Points = downsample(ls.Points, f.Start, f.End, n)
		out = append(out, *ls)
	}
	quotas, err := s.QuotaHistorySeries(f, n)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"since": f.Start, "until": f.End, "accounts": out, "quota_series": quotas})
}

// accountLabels maps uuid -> the display label the rest of the API uses.
func (s *Server) accountLabels() map[string]string {
	out := map[string]string{}
	accts, err := s.Store.ListAccounts()
	if err != nil {
		return out
	}
	for _, a := range accts {
		out[a.AccountUUID] = a.Label()
	}
	return out
}
