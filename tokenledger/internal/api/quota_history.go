package api

import (
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

type QuotaPoint struct {
	T           time.Time `json:"t"`
	Utilization float64   `json:"utilization"`
}
type QuotaSeries struct {
	AccountUUID         string       `json:"account_uuid"`
	Label               string       `json:"label"`
	WindowID            string       `json:"window_id"`
	Minutes             int64        `json:"minutes"`
	Points              []QuotaPoint `json:"points"`
	CriticalSeconds     int64        `json:"critical_seconds"`
	CriticalEpisodes    int          `json:"critical_episodes"`
	PrevCriticalSeconds int64        `json:"prev_critical_seconds"`
}

// handleQuotaHistory serves /v1/quota/history: the provider-defined quota
// windows over a range, on their own.
//
// They were reachable over HTTP only as the quota_series key folded inside
// /v1/limits/history, which made the one caller that wants just these windows
// pay for every account's utilization series as well — and left the API the
// only one of the three doors (web, MCP, API) without a way to ask for them
// directly. /v1/limits/history keeps its folded copy: the dashboard draws both
// on one axis and splitting that into two round-trips would let the halves
// straddle a refresh.
func (s *Server) handleQuotaHistory(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	n, _ := strconv.Atoi(r.URL.Query().Get("points"))
	if n <= 0 {
		n = 400
	}
	series, err := s.QuotaHistorySeries(f, n)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": f.Account, "all_accounts": f.Account == store.AllAccounts,
		"since": f.Start, "until": f.End, "series": series,
		"scope_note": scopeNoteIn(f.Account, localeOf(r)),
	})
}

func (s *Server) QuotaHistorySeries(f store.Filter, n int) ([]QuotaSeries, error) {
	current, err := s.Store.QuotaHistory(f.Account, f.Source, f.Start, f.End)
	if err != nil {
		return nil, err
	}
	prev := f.Prev()
	previous, err := s.Store.QuotaHistory(f.Account, f.Source, prev.Start, prev.End)
	if err != nil {
		return nil, err
	}
	by := map[string][]store.LimitPoint{}
	old := map[string][]store.LimitPoint{}
	series := map[string]QuotaSeries{}
	labels := s.accountLabels()
	for _, q := range current {
		for _, w := range q.Windows {
			key := q.AccountUUID + "\x00" + w.ID + fmt.Sprint(w.Minutes)
			by[key] = append(by[key], store.LimitPoint{T: q.ObservedAt, FiveHour: w.UsedPercent})
			series[key] = QuotaSeries{AccountUUID: q.AccountUUID, WindowID: w.ID, Minutes: w.Minutes, Label: labels[q.AccountUUID] + " · " + w.Label + fmt.Sprintf(" (%dm)", w.Minutes)}
		}
	}
	for _, q := range previous {
		for _, w := range q.Windows {
			key := q.AccountUUID + "\x00" + w.ID + fmt.Sprint(w.Minutes)
			old[key] = append(old[key], store.LimitPoint{T: q.ObservedAt, FiveHour: w.UsedPercent})
		}
	}
	keys := make([]string, 0, len(by))
	for k := range by {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := []QuotaSeries{}
	for _, k := range keys {
		ss := series[k]
		ss.CriticalSeconds, ss.CriticalEpisodes = criticalTime(by[k])
		ss.PrevCriticalSeconds, _ = criticalTime(old[k])
		for _, p := range downsample(by[k], f.Start, f.End, n) {
			ss.Points = append(ss.Points, QuotaPoint{T: p.T, Utilization: p.FiveHour})
		}
		out = append(out, ss)
	}
	return out, nil
}
