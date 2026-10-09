package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// UserView is one person's page.
//
// INTERNAL ONLY. It carries project paths and machine names on purpose --
// inside a company, behind the viewer token, that is the whole value. It is
// also exactly why it must never be reachable with a badge-level credential:
// the public payload is a type defined from scratch, not this one redacted.
type UserView struct {
	*store.UserSummary
	TopProjects []store.Bucket `json:"top_projects"`
	// Named apart from the embedded UserSummary.Machines, which is a COUNT.
	// Two fields promoted to the same JSON key does not error -- the outer one
	// wins and the count silently disappears from the response.
	MachinesBreakdown []store.Bucket `json:"machines_breakdown"`
	Disclaimer        string         `json:"disclaimer"`
}

func (s *Server) handleUserData(w http.ResponseWriter, r *http.Request) {
	login := r.URL.Query().Get("user")
	// A user's page is their own (claude-fleet#1985), whatever was asked.
	who, ok := s.userScope(w, r)
	if !ok {
		return
	}
	if who != nil {
		login = who.Login
	}
	if login == "" {
		httpError(w, http.StatusBadRequest, "a user is required: /v1/user?user=<os login>")
		return
	}
	start, end := timeRange(r.URL.Query().Get("since"), r.URL.Query().Get("until"))
	view, err := s.UserPage(login, who.OwnerOf(), start, end)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, view)
}

// UserPage assembles one person's page: their totals, the projects they worked
// in and the machines they worked on.
//
// Shared with MCP, where it answers a question usage_by_user cannot. That tool
// returns one BUCKET per login — a row in a ranking. This is the person: which
// teams their machines belong to, which projects the time went into, how many
// machines they touched. An agent asked "what is alice spending it on" needs
// the second, and building it out of several usage_by_* calls would produce a
// different answer, because top_projects is scoped to the login rather than
// filtered from a fleet-wide ranking.
//
// owner, when set, is the person's own (endpoint, login) pairs: login then only
// names the page (claude-fleet#2514).
func (s *Server) UserPage(login string, owner *store.Owner, start, end time.Time) (*UserView, error) {
	sum, err := s.Store.UserSummary(login, owner, start, end)
	if err != nil {
		return nil, err
	}
	projects, err := s.Store.UsageByUser(login, owner, store.ByProject, start, end, 12)
	if err != nil {
		return nil, err
	}
	machines, err := s.Store.UsageByUser(login, owner, store.ByEndpoint, start, end, 20)
	if err != nil {
		return nil, err
	}
	if projects == nil {
		projects = []store.Bucket{}
	}
	if machines == nil {
		machines = []store.Bucket{}
	}
	if sum.Teams == nil {
		sum.Teams = []string{}
	}
	return &UserView{
		UserSummary: sum, TopProjects: projects, MachinesBreakdown: machines,
		Disclaimer: shareDisclaimer,
	}, nil
}
