package api

import (
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The whole hub, in the admin area (claude-fleet#2515, EPIC #2512 C3). An
// admin's Overview, Sessions and Devices show only their own now (ownView,
// roles.go); what those pages used to show an admin moved here, behind
// adminOnly: All sessions, By person and All devices. Each is the uncut
// implementation the daily route had, mounted where only an admin reaches it.
const (
	// AdminSessionsPath is fleet_sessions, every person's.
	AdminSessionsPath = "/v1/admin/sessions"
	// AdminOverviewPath is the hub by login: tokens, sessions and machines.
	AdminOverviewPath = "/v1/admin/overview"
	// AdminDevicesPath is /v1/fleet/devices, every person's.
	AdminDevicesPath = "/v1/admin/devices"
)

// handleAdminSessions serves GET AdminSessionsPath: fleet_sessions with no
// cut — the answer /v1/fleet/fleet_sessions gave an admin before #2515.
func (s *Server) handleAdminSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	args := map[string]any{}
	if b, err := strconv.ParseBool(r.URL.Query().Get("refresh")); err == nil {
		args["refresh"] = b
	}
	out, err := s.CallFleetTool(r, "fleet_sessions", args)
	writeFleetResult(w, r, out, err)
}

// AdminPerson is one login's row on the By person page.
type AdminPerson struct {
	// Login is the machine login the usage and the sessions report as.
	Login string `json:"login"`
	// People are the signed-in people who hold this login on some machine
	// (a login name is not a person: the same name on two machines can be
	// two people, claude-fleet#2514). Empty when the hub has none on record.
	People      []string `json:"people"`
	Machines    []string `json:"machines"`
	Sessions    int      `json:"sessions"`
	Running     int      `json:"running"`
	Tokens      int64    `json:"tokens"`
	TokensToday int64    `json:"tokens_today"`
}

// AdminOverview is AdminOverviewPath's answer.
type AdminOverview struct {
	Since  time.Time     `json:"since"`
	Until  time.Time     `json:"until"`
	People []AdminPerson `json:"people"`
	Totals struct {
		Tokens         int64 `json:"tokens"`
		TokensToday    int64 `json:"tokens_today"`
		Sessions       int   `json:"sessions"`
		Running        int   `json:"running"`
		Machines       int   `json:"machines"`
		MachinesOnline int   `json:"machines_online"`
	} `json:"totals"`
	// Nodes are fleet_sessions' machines, for the lost / maintenance list.
	Nodes []FleetNode `json:"nodes"`
	// Fleet is false on a hub without the fleet module: tokens only.
	Fleet bool `json:"fleet"`
}

// runningStates are the worker states the pages count as running.
var runningStates = map[string]bool{"working": true, "waiting": true, "blocked": true}

// handleAdminOverview serves GET AdminOverviewPath[?since=7d]: every login's
// tokens over the range and today (UTC), and its open sessions — the By
// person panel an admin's Overview used to carry, with the hub's totals.
func (s *Server) handleAdminOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if s.Store == nil {
		httpError(w, http.StatusNotFound, "no store")
		return
	}
	now := time.Now().UTC()
	start := now.Add(-7 * 24 * time.Hour)
	if v := r.URL.Query().Get("since"); v != "" {
		t, ok := parseWhen(v, now)
		if !ok || !t.Before(now) {
			httpError(w, http.StatusBadRequest, "since: want RFC3339 or a relative duration like 7d")
			return
		}
		start = t
	}
	rng := store.Filter{Account: store.AllAccounts, Start: start, End: now}.AlignHours()
	day := store.Filter{Account: store.AllAccounts, Start: now.Truncate(24 * time.Hour), End: now}.AlignHours()
	byRange, err := s.Store.UsageByFiltered(rng, store.ByUser, 500)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	byDay, err := s.Store.UsageByFiltered(day, store.ByUser, 500)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}

	out := AdminOverview{Since: rng.Start, Until: rng.End, Nodes: []FleetNode{}, Fleet: s.Fleet}
	rows := map[string]*AdminPerson{}
	row := func(login string) *AdminPerson {
		p := rows[login]
		if p == nil {
			p = &AdminPerson{Login: login, People: []string{}, Machines: []string{}}
			rows[login] = p
		}
		return p
	}
	for _, b := range byRange {
		row(b.Key).Tokens += b.Tokens
		out.Totals.Tokens += b.Tokens
	}
	for _, b := range byDay {
		row(b.Key).TokensToday += b.Tokens
		out.Totals.TokensToday += b.Tokens
	}

	if s.Fleet {
		fs, err := s.FleetSessions(r) // no ownView here: every person's
		if err != nil {
			writeFleetResult(w, r, nil, err)
			return
		}
		sessions, _ := fs["sessions"].([]FleetSession)
		nodes, _ := fs["nodes"].([]FleetNode)
		machines := map[string]map[string]bool{}
		for _, fsn := range sessions {
			p := row(fsn.OSUser)
			p.Sessions++
			out.Totals.Sessions++
			if st, _ := fsn.Worker["state"].(string); runningStates[st] {
				p.Running++
				out.Totals.Running++
			}
			if machines[fsn.OSUser] == nil {
				machines[fsn.OSUser] = map[string]bool{}
			}
			machines[fsn.OSUser][fsn.MachineName] = true
		}
		for login, ms := range machines {
			for m := range ms {
				rows[login].Machines = append(rows[login].Machines, m)
			}
			sort.Strings(rows[login].Machines)
		}
		if nodes != nil {
			out.Nodes = nodes
		}
		out.Totals.Machines = len(out.Nodes)
		for _, n := range out.Nodes {
			if n.Availability == "online" {
				out.Totals.MachinesOnline++
			}
		}
		// Who holds each login: the ACTIVE (machine, login) accounts.
		accts, err := s.Store.FleetAccounts("")
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		names := map[string]string{}
		if ps, err := s.Store.Principals(); err == nil {
			for _, p := range ps {
				names[p.ID] = p.DisplayName
				if names[p.ID] == "" {
					names[p.ID] = p.Login
				}
			}
		}
		seen := map[[2]string]bool{}
		for _, a := range accts {
			p := rows[a.Login]
			if p == nil || a.State != store.AccountActive || seen[[2]string{a.Login, a.PrincipalID}] {
				continue
			}
			seen[[2]string{a.Login, a.PrincipalID}] = true
			name := names[a.PrincipalID]
			if name == "" {
				name = a.PrincipalID
			}
			p.People = append(p.People, name)
		}
	}

	out.People = make([]AdminPerson, 0, len(rows))
	for _, p := range rows {
		sort.Strings(p.People)
		out.People = append(out.People, *p)
	}
	sort.Slice(out.People, func(i, j int) bool {
		a, b := out.People[i], out.People[j]
		if a.Tokens != b.Tokens {
			return a.Tokens > b.Tokens
		}
		if a.Sessions != b.Sessions {
			return a.Sessions > b.Sessions
		}
		return a.Login < b.Login
	})
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
