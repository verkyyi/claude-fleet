package api

import (
	"net/http"
	"sync"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

type scopedCounters struct {
	mu     sync.Mutex
	values map[string]*Counter
}

func (s *Server) invalidateCounters() {
	s.counter.Invalidate()
	s.sourceCounters.mu.Lock()
	defer s.sourceCounters.mu.Unlock()
	for _, c := range s.sourceCounters.values {
		c.Invalidate()
	}
}

func liveScope(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	source, ok := querySource(w, r)
	account := r.URL.Query().Get("account")
	if account == "" || account == "all" {
		account = store.AllAccounts
	}
	return account, source, ok
}

// FilterLive recomputes every aggregate after selecting sessions. The ledger
// counter uses the same account/source scope, never a sum of live heartbeats.
func (s *Server) FilterLive(in Snapshot, account, source string) Snapshot {
	if account == "all" {
		account = store.AllAccounts
	}
	if (account == "" || account == store.AllAccounts) && source == "" {
		return in
	}
	out := Snapshot{At: in.At, Note: in.Note, Sessions: []LiveSession{}}
	eps := map[string]bool{}
	for _, l := range in.Sessions {
		if source != "" && model.UsageSource(l.Source) != source {
			continue
		}
		if account != "" && account != store.AllAccounts && l.Account != account {
			continue
		}
		out.Sessions = append(out.Sessions, l)
		eps[l.EndpointID] = true
		out.SessionTokens += l.InputTokens + l.OutputTokens
		out.SessionCost += l.CostUSD
		out.TokensPerMin += l.TokensPerMin
		out.USDPerHour += l.USDPerHour
		out.LinesAdded += l.LinesAdded
		out.LinesRemoved += l.LinesRemoved
		if l.CostUnknown {
			out.UnpricedSessions++
		}
		if l.Billing == "api" {
			out.APISessions++
		}
	}
	out.ActiveSessions = len(out.Sessions)
	out.Endpoints = len(eps)
	if s.Store == nil {
		return out
	}
	if account == "" {
		account = store.AllAccounts
	}
	key := account + "\x00" + source
	s.sourceCounters.mu.Lock()
	if s.sourceCounters.values == nil || len(s.sourceCounters.values) > 128 {
		s.sourceCounters.values = map[string]*Counter{}
	}
	c := s.sourceCounters.values[key]
	if c == nil {
		c = &Counter{}
		s.sourceCounters.values[key] = c
	}
	s.sourceCounters.mu.Unlock()
	turns, tokens, at, err := c.Total(func() (int64, int64, error) {
		sum, err := s.Store.Summary(store.Filter{Account: account, Source: source, Start: time.Unix(0, 0).UTC(), End: time.Date(2200, 1, 1, 0, 0, 0, 0, time.UTC)})
		if err != nil {
			return 0, 0, err
		}
		return sum.Events, sum.Tokens, nil
	})
	if err == nil {
		c.ObserveLiveRate(out.TokensPerMin)
		v := counterView(turns, tokens, at, c.Rate())
		out.Counter = &v
	}
	return out
}
