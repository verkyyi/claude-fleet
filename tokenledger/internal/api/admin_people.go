package api

import (
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// By person, one person a row (claude-fleet#3228, EPIC #3225 C3). A login is
// not a person — the same person holds logins on several machines — so the
// admin's table groups by principal: their pool usage (store.PoolUsage, the
// only number a person's page reads), the sessions running under any of their
// logins, and the (服务节点, 登录) pairs themselves for the detail drawer. A
// session or a login that no person holds has no row. The subscription pool
// lists every vault account with the people whose live session pass is bound
// to it right now.

// AdminPerson is one person's row on the By person page.
type AdminPerson struct {
	Principal string `json:"principal"`
	Name      string `json:"name"`
	// Today and Week are pool tokens (input + cache writes + output) since
	// 00:00 UTC and over the asked range (7 days by default).
	Today int64 `json:"today"`
	Week  int64 `json:"week"`
	// Limit is fleet.person_budget.<principal>; nil = 不限额.
	Limit *PersonBudget `json:"limit"`
	// Doing is the task the range's tokens went to most; nil = none on a task.
	Doing    *AdminDoing `json:"doing"`
	Sessions int         `json:"sessions"`
	Running  int         `json:"running"`
	// Logins are the person's active (服务节点, 登录) pairs.
	Logins [][2]string `json:"logins"`
	// Subs are the subscriptions the person's live passes are bound to.
	Subs []string `json:"subs"`
}

// AdminDoing is a person's main task: the repo their tokens went to most, and
// within it the issue (0 = on that repo but no issue). The batch is the
// issue's parent, read where the page draws it.
type AdminDoing struct {
	Repo   string `json:"repo"`
	Issue  int    `json:"issue,omitempty"`
	Tokens int64  `json:"tokens"`
}

// AdminSub is one subscription on the pool panel.
type AdminSub struct {
	// Account is the vault's name for it; Label the subscription's own (the
	// account it resolves to), "" when it has reported no reading.
	Account  string `json:"account"`
	Label    string `json:"label"`
	Provider string `json:"provider"`
	// Owner is the person it belongs to, or store.PoolPrincipal (shared).
	Owner     string     `json:"owner"`
	Used5hPct *float64   `json:"used_5h_pct"`
	Used7dPct *float64   `json:"used_7d_pct"`
	ResetsAt  *time.Time `json:"resets_at,omitempty"`    // the 7-day window's
	Resets5h  *time.Time `json:"resets_5h_at,omitempty"` // the 5-hour window's
	// People are the names holding a live pass bound to it; Sessions how many
	// sessions those passes are.
	People   []string `json:"people"`
	Sessions int      `json:"sessions"`
	// State: reauth (the provider refused its refresh) · limited (known at a
	// limit) · in_use · idle.
	State string `json:"state"`
	// Limited says which limit when State is limited: 5h · 7d · 429.
	Limited string `json:"limited,omitempty"`
}

// adminSession is one open session, as fleet_sessions names it.
type adminSession struct {
	Host, Login string
	Running     bool
}

// adminPass is one live session pass and the accounts its session is bound to.
type adminPass struct {
	Principal, WorkerID string
	Binds               []store.SessionBind
}

type adminPeopleIn struct {
	Usage    []store.PoolUsage // since min(Since, Today)
	Since    time.Time
	Today    time.Time
	Accounts []store.FleetAccount
	Sessions []adminSession
	Names    map[string]string
	Budgets  map[string]PersonBudget
	Subs     map[string][]string // principal → subscriptions
}

// adminPeople folds everything into one row per person: anyone with pool usage
// in the range, an open session, an active login or a live pass.
func adminPeople(in adminPeopleIn) []AdminPerson {
	rows := map[string]*AdminPerson{}
	row := func(pid string) *AdminPerson {
		p := rows[pid]
		if p == nil {
			name := in.Names[pid]
			if name == "" {
				name = pid
			}
			p = &AdminPerson{Principal: pid, Name: name, Logins: [][2]string{}, Subs: []string{}}
			if b, ok := in.Budgets[pid]; ok && (b.H5 > 0 || b.Week > 0) {
				b := b
				p.Limit = &b
			}
			rows[pid] = p
		}
		return p
	}
	type task struct {
		repo  string
		issue int
	}
	byRepo := map[string]map[string]int64{}
	byTask := map[string]map[task]int64{}
	for _, u := range in.Usage {
		if u.Principal == "" {
			continue
		}
		p := row(u.Principal)
		if !u.At.Before(in.Today) {
			p.Today += u.Tokens()
		}
		if u.At.Before(in.Since) {
			continue
		}
		p.Week += u.Tokens()
		if u.Repo == "" {
			continue
		}
		if byRepo[u.Principal] == nil {
			byRepo[u.Principal], byTask[u.Principal] = map[string]int64{}, map[task]int64{}
		}
		byRepo[u.Principal][u.Repo] += u.Tokens()
		byTask[u.Principal][task{u.Repo, u.Issue}] += u.Tokens()
	}
	for pid, repos := range byRepo {
		var d AdminDoing
		for repo, n := range repos {
			if n > d.Tokens || (n == d.Tokens && repo < d.Repo) {
				d = AdminDoing{Repo: repo, Tokens: n}
			}
		}
		var best int64 = -1
		for t, n := range byTask[pid] {
			if t.repo == d.Repo && t.issue != 0 && (n > best || (n == best && t.issue < d.Issue)) {
				best, d.Issue = n, t.issue
			}
		}
		rows[pid].Doing = &d
	}
	owner := map[[2]string]string{}
	seen := map[[3]string]bool{}
	for _, a := range in.Accounts {
		if a.State != store.AccountActive || a.PrincipalID == "" {
			continue
		}
		pair := [2]string{a.Hostname, a.Login}
		owner[pair] = a.PrincipalID
		if k := [3]string{a.PrincipalID, a.Hostname, a.Login}; !seen[k] {
			seen[k] = true
			p := row(a.PrincipalID)
			p.Logins = append(p.Logins, pair)
		}
	}
	for _, se := range in.Sessions {
		pid := owner[[2]string{se.Host, se.Login}]
		if pid == "" {
			continue // a login no person holds: no row
		}
		p := row(pid)
		p.Sessions++
		if se.Running {
			p.Running++
		}
	}
	for pid, subs := range in.Subs {
		row(pid).Subs = append([]string{}, subs...)
	}
	out := make([]AdminPerson, 0, len(rows))
	for _, p := range rows {
		sort.Slice(p.Logins, func(i, j int) bool {
			if p.Logins[i][0] != p.Logins[j][0] {
				return p.Logins[i][0] < p.Logins[j][0]
			}
			return p.Logins[i][1] < p.Logins[j][1]
		})
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Week != b.Week {
			return a.Week > b.Week
		}
		if a.Sessions != b.Sessions {
			return a.Sessions > b.Sessions
		}
		return a.Name < b.Name
	})
	return out
}

// livePasses is every unrevoked, unexpired session pass, one per session,
// with the accounts that session is bound to.
func (s *Server) livePasses(now time.Time) ([]adminPass, error) {
	creds, err := s.Store.SessionCreds(true, now, 1000)
	if err != nil {
		return nil, err
	}
	var out []adminPass
	seen := map[string]bool{}
	for _, c := range creds {
		if c.WorkerID == "" || seen[c.WorkerID] {
			continue
		}
		seen[c.WorkerID] = true
		binds, err := s.Store.SessionBinds(c.WorkerID)
		if err != nil {
			return nil, err
		}
		out = append(out, adminPass{Principal: c.PrincipalID, WorkerID: c.WorkerID, Binds: binds})
	}
	return out, nil
}

// passSubs is each person's subscriptions: the accounts their live passes
// are bound to, sorted, once each.
func passSubs(passes []adminPass) map[string][]string {
	set := map[string]map[string]bool{}
	for _, p := range passes {
		for _, b := range p.Binds {
			if set[p.Principal] == nil {
				set[p.Principal] = map[string]bool{}
			}
			set[p.Principal][b.Account] = true
		}
	}
	out := map[string][]string{}
	for pid, m := range set {
		for a := range m {
			out[pid] = append(out[pid], a)
		}
		sort.Strings(out[pid])
	}
	return out
}

// adminPool is every vault account with its reading and who is on it: the
// people whose live pass is bound to exactly that (provider, owner, account).
// reading names the account's subscription and its latest limits snapshot;
// atLimit is credAtLimit.
func adminPool(creds []store.Credential, passes []adminPass, names map[string]string,
	reading func(store.Credential) (string, *model.LimitsSnapshot), atLimit func(store.Credential) string) []AdminSub {
	type key struct{ provider, owner, account string }
	people := map[key]map[string]bool{}
	sessions := map[key]int{}
	for _, p := range passes {
		for _, b := range p.Binds {
			k := key{b.Provider, b.Owner, b.Account}
			if people[k] == nil {
				people[k] = map[string]bool{}
			}
			name := names[p.Principal]
			if name == "" {
				name = p.Principal
			}
			people[k][name] = true
			sessions[k]++
		}
	}
	out := make([]AdminSub, 0, len(creds))
	for _, c := range creds {
		k := key{c.Provider, c.PrincipalID, c.Account}
		sub := AdminSub{Account: c.Account, Provider: c.Provider, Owner: c.PrincipalID, People: []string{}, Sessions: sessions[k]}
		for n := range people[k] {
			sub.People = append(sub.People, n)
		}
		sort.Strings(sub.People)
		label, snap := reading(c)
		sub.Label = label
		if snap != nil {
			h5, d7 := snap.FiveHour.Utilization, snap.SevenDay.Utilization
			sub.Used5hPct, sub.Used7dPct = &h5, &d7
			sub.Resets5h, sub.ResetsAt = snap.FiveHour.ResetsAt, snap.SevenDay.ResetsAt
		}
		switch lim := atLimit(c); {
		case c.ReauthRequired || c.ReauthRequiredAt != nil:
			sub.State = "reauth"
		case lim != "":
			sub.State, sub.Limited = "limited", lim
		case sub.Sessions > 0:
			sub.State = "in_use"
		default:
			sub.State = "idle"
		}
		out = append(out, sub)
	}
	return out
}
