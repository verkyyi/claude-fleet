package api

import (
	"net/http"
	"testing"
	"testing/fstest"
)

// 任务 and 我的单子 are one page (claude-fleet#3928, EPIC #3923 C5): /app/tasks
// and a ticket's /app/tasks/tickets/<owner>/<name>/<N> are the new console's;
// every old 我的单子 address (GET / HEAD) is ONE 301 there, its query kept;
// the old page's forms still reach it until C16; a stranger is asked to sign
// in; with no console build /app/tasks stays the old page.
func TestConsoleTasksPage(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("OLD-APP")}}
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	hd := h.srv.Handler()
	for _, who := range []*http.Cookie{user, admin} {
		for _, p := range []string{AppPrefix + TasksPagePath, AppPrefix + TasksPagePath + "?tab=tickets",
			AppPrefix + ticketPagesPrefix + "team/app/1", AppPrefix + ticketPagesPrefix} {
			if got := consoleDo(hd, http.MethodGet, p, who); got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
				t.Errorf("GET %s = %d %.60q; want the console's page", p, got.Code, got.Body.String())
			}
		}
		for from, to := range map[string]string{
			TicketsPagePath:                            AppPrefix + TasksPagePath + "?tab=tickets",
			TicketsPagePath + "?repo=team/app":         AppPrefix + TasksPagePath + "?tab=tickets&repo=team/app",
			TicketsPagePath + "/":                      AppPrefix + ticketPagesPrefix,
			TicketsPagePath + "/team/app/1":            AppPrefix + ticketPagesPrefix + "team/app/1",
			TicketsPagePath + "/team/app/1?ok=comment": AppPrefix + ticketPagesPrefix + "team/app/1?ok=comment",
			TasksPagePath:                              AppPrefix + TasksPagePath,
		} {
			for _, m := range []string{http.MethodGet, http.MethodHead} {
				got := consoleDo(hd, m, from, who)
				if got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != to {
					t.Errorf("%s %s = %d → %q; want 301 %s", m, from, got.Code, got.Header().Get("Location"), to)
				}
			}
		}
		if got := consoleDo(hd, http.MethodPost, TicketsPagePath+"/team/app/1", who); got.Code == http.StatusMovedPermanently {
			t.Errorf("POST %s/team/app/1 = 301; the old page's form is not moved", TicketsPagePath)
		}
	}
	for _, p := range []string{AppPrefix + TasksPagePath, AppPrefix + ticketPagesPrefix + "team/app/1"} {
		if got := consoleDo(hd, http.MethodGet, p, nil); got.Code == http.StatusOK {
			t.Errorf("stranger GET %s = 200; want the gate", p)
		}
	}
	// no build: 任务 is the old page, a ticket's new address has nothing to show
	h.srv.ConsoleFS = nil
	if got := consoleDo(hd, http.MethodGet, AppPrefix+TasksPagePath, user); got.Body.String() == "APP-ENTRY" || got.Code == http.StatusMovedPermanently {
		t.Errorf("no console build: GET /app/tasks = %d %.60q; want the old page", got.Code, got.Body.String())
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+ticketPagesPrefix+"team/app/1", user); got.Code != http.StatusNotFound {
		t.Errorf("no console build: GET a ticket's new page = %d; want 404", got.Code)
	}
}

// The list says how long each ticket's thread is — the page's 「N 条讨论」.
func TestTicketListCommentCount(t *testing.T) {
	h, n := ticketHarness(t)
	bob := asNode(n["bob4"].token)
	const repo = "team/app"
	for _, title := range []string{"一", "二"} {
		if st, out := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath, map[string]any{"repo": repo, "title": title}); st != 201 {
			t.Fatalf("open %s: %d %v", title, st, out)
		}
	}
	for _, body := range []string{"a", "b", "c"} {
		if st, out := ticketCall(t, h, asSession(pBob), http.MethodPost, FleetTicketsPath+"/"+repo+"/1/comments", map[string]any{"body": body}); st != 201 {
			t.Fatalf("comment: %d %v", st, out)
		}
	}
	st, out := ticketCall(t, h, asSession(pBob), http.MethodGet, FleetTicketsPath, nil)
	if st != 200 {
		t.Fatalf("list: %d %v", st, out)
	}
	got := map[float64]float64{}
	for _, x := range out["tickets"].([]any) {
		tk := x.(map[string]any)
		c, ok := tk["comments"].(float64)
		if !ok || tk["title"] == nil {
			t.Fatalf("a row without its count: %v", tk)
		}
		got[tk["number"].(float64)] = c
	}
	if len(got) != 2 || got[1] != 3 || got[2] != 0 {
		t.Fatalf("counts: %v", got)
	}
}
