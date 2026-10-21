package api

import (
	"net/http"
	"testing"
	"testing/fstest"
)

// 任务 (claude-fleet#3928, EPIC #3923 C5) is one list with 会话 since T769:
// /app/tasks and the bare /tasks are ONE 301 to /app/sessions, a code's ?q=
// carried along so the page opens that row; /app/sessions is the console's
// page, a stranger asked to sign in there. The old 我的单子 addresses and the
// tickets tab left with the hub's tickets (claude-fleet#4898, T477): they
// move nowhere and answer nothing.
func TestConsoleTasksPage(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("OLD-APP")}}
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	hd := h.srv.Handler()
	for _, who := range []*http.Cookie{user, admin} {
		if got := consoleDo(hd, http.MethodGet, AppPrefix+"/sessions", who); got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
			t.Errorf("GET /app/sessions = %d %.60q; want the console's page", got.Code, got.Body.String())
		}
		for _, m := range []string{http.MethodGet, http.MethodHead} {
			for from, to := range map[string]string{
				TasksPagePath:                       AppPrefix + "/sessions",
				AppPrefix + TasksPagePath:           AppPrefix + "/sessions",
				AppPrefix + TasksPagePath + "?q=K5": AppPrefix + "/sessions?q=K5",
				TasksPagePath + "?q=K5":             AppPrefix + "/sessions?q=K5",
			} {
				got := consoleDo(hd, m, from, who)
				if got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != to {
					t.Errorf("%s %s = %d → %q; want 301 %s", m, from, got.Code, got.Header().Get("Location"), to)
				}
			}
		}
		for _, p := range []string{"/fleet/tickets", "/fleet/tickets/team/app/1"} {
			if got := consoleDo(hd, http.MethodGet, p, who); got.Code == http.StatusMovedPermanently || got.Body.String() == "APP-ENTRY" {
				t.Errorf("GET %s = %d → %q; the ticket pages are gone", p, got.Code, got.Header().Get("Location"))
			}
		}
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/sessions", nil); got.Code == http.StatusOK {
		t.Errorf("stranger GET /app/sessions = 200; want the gate")
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+TasksPagePath, nil); got.Code == http.StatusOK || got.Body.String() == "APP-ENTRY" {
		t.Errorf("stranger GET /app/tasks = %d; want a move or the gate, never the page", got.Code)
	}
}
