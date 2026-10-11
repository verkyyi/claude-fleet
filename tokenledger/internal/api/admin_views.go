package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
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

// AdminOverview is AdminOverviewPath's answer. People is one row per person
// (claude-fleet#3228, EPIC #3225 C3): their pool usage, their sessions and the
// (服务节点, 登录) pairs they hold, never a login's row; Pool is every
// subscription in the vault with who is on it right now.
type AdminOverview struct {
	Since  time.Time     `json:"since"`
	Until  time.Time     `json:"until"`
	People []AdminPerson `json:"people"`
	Pool   []AdminSub    `json:"pool"`
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
	// Fleet is false on a hub without the fleet module: nothing but zeros
	// (pool usage is the fleet module's).
	Fleet bool `json:"fleet"`
}

// runningStates are the worker states the pages count as running.
var runningStates = map[string]bool{"working": true, "waiting": true, "blocked": true}

// handleAdminOverview serves GET AdminOverviewPath[?since=7d]: every person's
// pool tokens over the range and today (UTC), their open sessions and logins,
// and the subscription pool with who is on each — the By person page, with
// the hub's totals. Only pool usage counts (EPIC #3225 共同约定 3): the
// per-machine scan (usage_events) is no person's number.
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
	out := AdminOverview{Since: start, Until: now, People: []AdminPerson{}, Pool: []AdminSub{}, Nodes: []FleetNode{}, Fleet: s.Fleet}
	// Pool usage, passes and logins are the fleet module's tables: a hub
	// without it has no person's number to show.
	if s.Fleet {
		if !s.adminByPerson(w, r, &out, now) {
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// adminByPerson fills out's people, pool and totals; false = it answered an
// error.
func (s *Server) adminByPerson(w http.ResponseWriter, r *http.Request, out *AdminOverview, now time.Time) bool {
	start := out.Since
	day := now.Truncate(24 * time.Hour)
	from := start
	if day.Before(from) {
		from = day
	}
	fail := func(err error) bool {
		httpError(w, http.StatusInternalServerError, err.Error())
		return false
	}
	usage, err := s.Store.PoolUsageFor("", from, time.Time{}) // to now, this second included
	if err != nil {
		return fail(err)
	}
	in := adminPeopleIn{Usage: usage, Since: start, Today: day, Names: map[string]string{}}
	if settings, err := s.Store.FleetSettings(); err == nil {
		in.Budgets = personBudgets(settings)
	}
	if ps, err := s.Store.Principals(); err == nil {
		for _, p := range ps {
			in.Names[p.ID] = p.DisplayName
			if in.Names[p.ID] == "" {
				in.Names[p.ID] = p.Login
			}
		}
	}
	creds, err := s.Store.Credentials("")
	if err != nil {
		return fail(err)
	}
	passes, err := s.livePasses(now)
	if err != nil {
		return fail(err)
	}
	in.Subs = passSubs(passes)
	if in.Accounts, err = s.Store.FleetAccounts(""); err != nil {
		return fail(err)
	}

	fs, err := s.FleetSessions(r) // no ownView here: every person's
	if err != nil {
		writeFleetResult(w, r, nil, err)
		return false
	}
	sessions, _ := fs["sessions"].([]FleetSession)
	nodes, _ := fs["nodes"].([]FleetNode)
	for _, fsn := range sessions {
		st, _ := fsn.Worker["state"].(string)
		in.Sessions = append(in.Sessions, adminSession{Host: fsn.MachineName, Login: fsn.OSUser, Running: runningStates[st]})
		out.Totals.Sessions++
		if runningStates[st] {
			out.Totals.Running++
		}
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
	for _, u := range usage {
		if !u.At.Before(start) {
			out.Totals.Tokens += u.Tokens()
		}
		if !u.At.Before(day) {
			out.Totals.TokensToday += u.Tokens()
		}
	}
	out.People = adminPeople(in)
	labels := s.accountLabels()
	out.Pool = adminPool(creds, passes, in.Names, func(c store.Credential) (string, *model.LimitsSnapshot) {
		uuid, err := s.Store.ResolveCredentialLabel(c.Provider, c.Account)
		if err != nil || uuid == "" {
			return "", nil
		}
		snap, _ := s.Store.LatestLimits(uuid)
		return labels[uuid], snap
	}, func(c store.Credential) string { return s.credAtLimit(c, now) })
	return true
}
