package api

import (
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/recon"
	"github.com/verkyyi/ccquota/internal/store"
)

func querySource(w http.ResponseWriter, r *http.Request) (string, bool) {
	source := r.URL.Query().Get("source")
	if source != "" && source != model.SourceClaude && source != model.SourceCodex {
		httpError(w, 400, "source must be claude or codex")
		return "", false
	}
	return source, true
}

func (s *Server) LimitsForSource(account, source string) (*LimitsView, error) {
	if source != "" {
		actual, err := s.Store.SourceForAccount(account)
		if err != nil {
			return nil, err
		}
		if actual != source {
			return &LimitsView{AccountUUID: account, Source: source, Reason: "account does not belong to the selected source"}, nil
		}
	}
	return s.LimitsFor(account)
}

func (s *Server) codexLimitsFor(account string) (*LimitsView, error) {
	v := &LimitsView{Source: model.SourceCodex, AccountUUID: account, Disclaimer: shareDisclaimer}
	if account == "codex:local" {
		v.Reason = "Historical or unassigned Codex usage; select a linked Codex account to view its quota"
		return v, nil
	}
	q, err := s.Store.LatestQuota(account)
	if err != nil {
		return nil, err
	}
	if q == nil {
		v.Reason = "No verified Codex quota reading; local usage history is retained separately"
		cs, err := s.Store.Collectors(account, model.SourceCodex)
		if err != nil {
			return nil, err
		}
		for _, c := range cs {
			if c.LimitsReason != "" {
				v.Reason = c.LimitsReason
			}
		}
		return v, nil
	}
	v.ObservedAt = &q.ObservedAt
	v.StaleSeconds = int64(time.Since(q.ObservedAt).Seconds())
	v.Plan = q.Plan
	if v.StaleSeconds > 600 {
		v.Reason = "Codex quota reading is stale; waiting for a fresh observation"
		return v, nil
	}
	v.Credits = q.Credits
	v.Blocked = q.Blocked
	v.Reason = q.Reason
	for _, w := range q.Windows {
		// Passing a reset cannot prove remaining capacity. Wait for a new read.
		if w.ResetsAt != nil && !w.ResetsAt.After(time.Now()) {
			continue
		}
		observed := q.ObservedAt
		if w.ObservedAt != nil {
			observed = *w.ObservedAt
		}
		p := ProviderWindow{ID: w.ID, LimitID: w.LimitID, Label: w.Label, Minutes: w.Minutes, ObservedAt: &observed, WindowView: WindowView{Utilization: w.UsedPercent, ResetsAt: w.ResetsAt}}
		if w.Minutes > 0 {
			win := recon.WindowFor(w.ResetsAt, observed, time.Duration(w.Minutes)*time.Minute)
			p.Burn = recon.Burn(win, w.UsedPercent, time.Now().UTC())
		}
		v.Windows = append(v.Windows, p)
	}
	v.Available = len(v.Windows) > 0 || len(v.Credits) > 0 || q.Blocked
	if !v.Available {
		v.Reason = "Codex quota window reset; waiting for a fresh reading"
	}
	return v, nil
}

func (s *Server) ingestObservations(endpoint string, b *model.Batch) error {
	for _, q := range b.Quotas {
		if q.ObservedAt.IsZero() || q.ObservedAt.After(time.Now().Add(5*time.Minute)) {
			return fmt.Errorf("invalid quota observation time")
		}
		for _, w := range q.Windows {
			if math.IsNaN(w.UsedPercent) || math.IsInf(w.UsedPercent, 0) || w.UsedPercent < 0 || w.UsedPercent > 100 || w.Minutes < 0 {
				return fmt.Errorf("invalid quota window")
			}
		}
		q.Source = model.UsageSource(b.Identity.Source)
		q.AccountUUID = b.Identity.AccountUUID
		q.EndpointID = endpoint
		if err := s.Store.InsertQuota(q); err != nil {
			return err
		}
	}
	if b.Collector != nil {
		c := *b.Collector
		c.Source = model.UsageSource(b.Identity.Source)
		c.EndpointID = endpoint
		c.AccountUUID = b.Identity.AccountUUID
		if c.ObservedAt.IsZero() || c.ObservedAt.After(time.Now().Add(5*time.Minute)) {
			return fmt.Errorf("invalid collector observation time")
		}
		if err := s.Store.UpsertCollector(c); err != nil {
			return err
		}
	}
	if b.AccountUsage != nil {
		u := *b.AccountUsage
		u.Source = model.UsageSource(b.Identity.Source)
		u.AccountUUID = b.Identity.AccountUUID
		u.EndpointID = endpoint
		if u.ObservedAt.IsZero() || u.ObservedAt.After(time.Now().Add(5*time.Minute)) {
			return fmt.Errorf("invalid account usage observation time")
		}
		if err := s.Store.InsertAccountUsage(u); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) handleCollectors(w http.ResponseWriter, r *http.Request) {
	source, ok := querySource(w, r)
	if !ok {
		return
	}
	rows, err := s.Store.Collectors(r.URL.Query().Get("account"), source)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, rows)
}

func (s *Server) handleAccountUsage(w http.ResponseWriter, r *http.Request) {
	source, ok := querySource(w, r)
	if !ok {
		return
	}
	result, err := s.AccountUsageView(r.URL.Query().Get("account"), source)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, result)
}

func (s *Server) AccountUsageView(account, source string) (map[string]any, error) {
	rows, err := s.Store.AccountUsage(account, source)
	if err != nil {
		return nil, err
	}
	type observation struct {
		model.AccountUsage
		LocalTokens   int64 `json:"local_attributed_tokens"`
		LocalRequests int64 `json:"local_attributed_requests"`
	}
	out := []observation{}
	for _, u := range rows {
		sum, err := s.Store.Summary(store.Filter{Account: u.AccountUUID, Source: u.Source, Start: time.Unix(0, 0).UTC(), End: time.Date(2200, 1, 1, 0, 0, 0, 0, time.UTC)})
		if err != nil {
			return nil, err
		}
		out = append(out, observation{AccountUsage: u, LocalTokens: sum.Tokens, LocalRequests: sum.Events})
	}
	return map[string]any{"observations": out, "comparable": false, "note": "Service totals and local attributed details overlap and must not be added. Historical unassigned sessions are excluded from the local account figure. Date boundaries, coverage and update delay are not yet comparable; a difference does not prove missing or cloud usage."}, nil
}
