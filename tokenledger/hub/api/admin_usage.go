package api

import (
	"net/http"
	"sort"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 全队用量 (claude-fleet#3936, EPIC #3923 C13): the admin's /admin/usage reads
// each person exactly as their own 我的用量 does — the same rows
// (personEventUsage), the same count (meUsageCount), the same limit
// (meUsageLimit) — so a person's today / 7 days / limit on the team page is
// the number they see on theirs, never a second computation.
const AdminUsagePath = "/v1/admin/usage"

// AdminUsagePerson is one person's head numbers, as MeUsage says them.
type AdminUsagePerson struct {
	Principal string       `json:"principal"`
	Name      string       `json:"name"`
	Today     int64        `json:"today"`
	Week      int64        `json:"week"`
	Limit     MeUsageLimit `json:"limit"`
}

// AdminUsage is AdminUsagePath's answer with no ?principal=: every person,
// the largest week first; and the same rows by model and by machine over the
// week — so each sums to the people's weeks, never a second scan.
type AdminUsage struct {
	People   []AdminUsagePerson  `json:"people"`
	Models   []MeUsageModel      `json:"models"`
	Machines []AdminUsageMachine `json:"machines"`
	// Sources splits the week's pool rows by where they were served —
	// subscription or bedrock (task PNWW); Bedrock is the fallback's month
	// against its cap.
	Sources []store.SourceUsage `json:"sources,omitempty"`
	Bedrock *BedrockSpend       `json:"bedrock,omitempty"`
}

// AdminUsageMachine is one machine's share of the people's rows: what ran on
// it today and this week, and how many people.
type AdminUsageMachine struct {
	Node   string `json:"node"`
	Today  int64  `json:"today"`
	Week   int64  `json:"week"`
	People int    `json:"people"`
}

// handleAdminUsage serves GET AdminUsagePath: every person's today, week and
// limit; ?principal=P[&range=today|7d|30d] is P's whole /v1/me/usage answer.
func (s *Server) handleAdminUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if s.Store == nil {
		httpError(w, http.StatusNotFound, "no store")
		return
	}
	now := s.budgetClock()
	ps, err := s.Store.Principals()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	q := r.URL.Query()
	if p := q.Get("principal"); p != "" {
		rng := q.Get("range")
		if rng == "" {
			rng = "7d"
		}
		if _, ok := meUsageRanges[rng]; !ok {
			httpError(w, http.StatusBadRequest, "range is today, 7d or 30d")
			return
		}
		known := false
		for _, x := range ps {
			known = known || x.ID == p
		}
		if !known {
			httpError(w, http.StatusNotFound, "no such person")
			return
		}
		out, err := s.meUsage(r.Context(), p, rng, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, out)
		return
	}
	out := AdminUsage{People: []AdminUsagePerson{}, Machines: []AdminUsageMachine{}}
	var week []store.PoolUsage
	byNode := map[string]*AdminUsageMachine{}
	nodePeople := map[string]map[string]bool{}
	for _, p := range ps {
		cnt := newMeUsageCount(now)
		rows, err := s.personEventUsage(p.ID, cnt.from())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		for _, u := range rows {
			cnt.add(u)
			inToday, inWeek := !u.At.Before(cnt.today), !u.At.Before(cnt.weekCut)
			if !inToday && !inWeek {
				continue
			}
			if inWeek {
				week = append(week, u)
			}
			m := byNode[u.Node]
			if m == nil {
				m = &AdminUsageMachine{Node: u.Node}
				byNode[u.Node], nodePeople[u.Node] = m, map[string]bool{}
			}
			if inToday {
				m.Today += u.Tokens()
			}
			if inWeek {
				m.Week += u.Tokens()
			}
			nodePeople[u.Node][p.ID] = true
		}
		lim, _, err := s.meUsageLimit(p.ID, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		name := p.DisplayName
		if name == "" {
			name = p.Login
		}
		out.People = append(out.People, AdminUsagePerson{Principal: p.ID, Name: name, Today: cnt.Today, Week: cnt.Week, Limit: lim})
	}
	out.Models = meUsageModels(week)
	for n, m := range byNode {
		m.People = len(nodePeople[n])
		out.Machines = append(out.Machines, *m)
	}
	sort.Slice(out.Machines, func(i, j int) bool {
		if out.Machines[i].Week != out.Machines[j].Week {
			return out.Machines[i].Week > out.Machines[j].Week
		}
		return out.Machines[i].Node < out.Machines[j].Node
	})
	sort.SliceStable(out.People, func(i, j int) bool {
		if out.People[i].Week != out.People[j].Week {
			return out.People[i].Week > out.People[j].Week
		}
		return out.People[i].Name < out.People[j].Name
	})
	// the split by source (task PNWW): the same week as the people's rows
	if src, err := s.Store.PoolUsageBySource(newMeUsageCount(now).weekCut); err == nil {
		out.Sources = src
	}
	if b, err := s.bedrockSpendView(now); err == nil {
		out.Bedrock = b
	}
	writeJSON(w, http.StatusOK, out)
}
