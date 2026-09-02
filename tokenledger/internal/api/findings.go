// internal/api/findings.go
package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/store"
)

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
	writeJSON(w, http.StatusOK, findings.Review(in))
}

func (s *Server) GatherReview(f store.Filter) (findings.Inputs, error) {
	var in findings.Inputs
	in.SelectionSeconds = int64(f.End.Sub(f.Start) / time.Second)

	sessions, err := s.Store.Sessions(f, "tokens", 500, 0)
	if err != nil {
		return in, err
	}
	for _, sr := range sessions {
		in.Sessions = append(in.Sessions, findings.SessionStat{SessionID: sr.SessionID, CWD: sr.CWD, Model: sr.Model,
			Tokens: sr.Tokens, Turns: sr.Turns, Duration: sr.Ended.Sub(sr.Started)})
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
	writeJSON(w, http.StatusOK, findings.Now(in))
}

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
