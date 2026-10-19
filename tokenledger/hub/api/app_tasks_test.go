package api

import (
	"net/http"
	"testing"
	"testing/fstest"
)

// 任务 (claude-fleet#3928, EPIC #3923 C5): /app/tasks is the new console's;
// /tasks is ONE 301 there; a stranger is asked to sign in; with no console
// build /app/tasks stays the old page. The old 我的单子 addresses and the
// tickets tab left with the hub's tickets (claude-fleet#4898, T477): they move
// nowhere and answer nothing.
func TestConsoleTasksPage(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("OLD-APP")}}
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	hd := h.srv.Handler()
	for _, who := range []*http.Cookie{user, admin} {
		if got := consoleDo(hd, http.MethodGet, AppPrefix+TasksPagePath, who); got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
			t.Errorf("GET /app/tasks = %d %.60q; want the console's page", got.Code, got.Body.String())
		}
		for _, m := range []string{http.MethodGet, http.MethodHead} {
			got := consoleDo(hd, m, TasksPagePath, who)
			if got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix+TasksPagePath {
				t.Errorf("%s /tasks = %d → %q; want 301 /app/tasks", m, got.Code, got.Header().Get("Location"))
			}
		}
		for _, p := range []string{"/fleet/tickets", "/fleet/tickets/team/app/1"} {
			if got := consoleDo(hd, http.MethodGet, p, who); got.Code == http.StatusMovedPermanently || got.Body.String() == "APP-ENTRY" {
				t.Errorf("GET %s = %d → %q; the ticket pages are gone", p, got.Code, got.Header().Get("Location"))
			}
		}
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+TasksPagePath, nil); got.Code == http.StatusOK {
		t.Errorf("stranger GET /app/tasks = 200; want the gate")
	}
	// no build: 任务 is the old page
	h.srv.ConsoleFS = nil
	if got := consoleDo(hd, http.MethodGet, AppPrefix+TasksPagePath, user); got.Body.String() == "APP-ENTRY" || got.Code == http.StatusMovedPermanently {
		t.Errorf("no console build: GET /app/tasks = %d %.60q; want the old page", got.Code, got.Body.String())
	}
}
