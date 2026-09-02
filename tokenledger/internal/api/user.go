package api

import (
	"net/http"
	"strings"

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

	sum, err := s.Store.UserSummary(login, start, end)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	projects, err := s.Store.UsageByUser(login, store.ByProject, start, end, 12)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	machines, err := s.Store.UsageByUser(login, store.ByEndpoint, start, end, 20)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
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
	writeJSON(w, http.StatusOK, UserView{
		UserSummary: sum, TopProjects: projects, MachinesBreakdown: machines,
		Disclaimer: shareDisclaimer,
	})
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
