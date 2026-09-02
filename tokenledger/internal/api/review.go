// internal/api/review.go
package api

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/verkyyi/ccquota/internal/store"
)

func (s *Server) handleSummary(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	sum, err := s.Store.Summary(f)
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
	out := map[string]any{
		"account_uuid": f.Account, "all_accounts": f.Account == store.AllAccounts,
		"since": f.Start, "until": f.End,
		"events": sum.Events, "tokens": sum.Tokens, "sessions": sum.Sessions, "cost_usd": sum.CostUSD,
		"unpriced_events": sum.Unpriced, "input_tokens": sum.InputTokens, "output_tokens": sum.OutputTokens,
		"cache_read_tokens": sum.CacheReadTokens, "cache_create_tokens": sum.CacheCreateTokens,
		"thinking_tokens": sum.ThinkingTokens, "sidechain_tokens": sum.SidechainTokens,
		"sidechain_events": sum.SidechainEvents,
		"effort":           nonNil(effort), "entrypoint": nonNil(entry),
		"disclaimer": shareDisclaimer, "scope_note": scopeNote(f.Account),
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
		httpError(w, http.StatusBadRequest, err.Error())
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
	id := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if id == "" {
		s.handleSessions(w, r)
		return
	}
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	head, err := s.Store.Session(account, id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if head == nil {
		httpError(w, http.StatusNotFound, "unknown session")
		return
	}
	turns, err := s.Store.SessionTurns(account, id)
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
	pts, err := s.Store.LimitsHistory(f.Account, f.Start, f.End)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	prev := f.Prev()
	prevPts, err := s.Store.LimitsHistory(f.Account, prev.Start, prev.End)
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
	writeJSON(w, http.StatusOK, map[string]any{"since": f.Start, "until": f.End, "accounts": out})
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
