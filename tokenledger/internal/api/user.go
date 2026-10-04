package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
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
	if login == "" {
		httpError(w, http.StatusBadRequest, "a user is required: /v1/user?user=<os login>")
		return
	}
	start, end := timeRange(r.URL.Query().Get("since"), r.URL.Query().Get("until"))
	view, err := s.UserPage(login, start, end)
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
func (s *Server) UserPage(login string, start, end time.Time) (*UserView, error) {
	sum, err := s.Store.UserSummary(login, start, end)
	if err != nil {
		return nil, err
	}
	projects, err := s.Store.UsageByUser(login, store.ByProject, start, end, 12)
	if err != nil {
		return nil, err
	}
	machines, err := s.Store.UsageByUser(login, store.ByEndpoint, start, end, 20)
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

// serveUserPage serves /u/<login>. The page fetches its own data from
// /v1/user, so the login never has to be templated into HTML.
func (s *Server) serveUserPage(w http.ResponseWriter, r *http.Request) {
	if s.UI == nil {
		httpError(w, http.StatusNotFound, "this binary was built without the UI")
		return
	}
	if strings.TrimPrefix(r.URL.Path, "/u/") == "" {
		httpError(w, http.StatusNotFound, "no login in the path: /u/<os login>")
		return
	}
	f, err := s.UI.Open("user.html")
	if err != nil {
		httpError(w, http.StatusNotFound, "no user page in this build")
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	rs, ok := f.(interface {
		Read([]byte) (int, error)
		Seek(int64, int) (int64, error)
	})
	if !ok {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	http.ServeContent(w, r, "user.html", st.ModTime(), rs)
}
