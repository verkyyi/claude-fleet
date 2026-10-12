package api

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// pageReq is one browser request to the tickets page as principal (their
// session cookie), never following a redirect. form != nil posts it, from
// origin ("" = this hub).
func pageReq(t *testing.T, h *harness, principal, method, path string, form url.Values, origin string) (int, string, http.Header) {
	t.Helper()
	var rd io.Reader
	if form != nil {
		rd = strings.NewReader(form.Encode())
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if origin == "" {
			origin = h.http.URL
		}
		req.Header.Set("Origin", origin)
	}
	req.Header.Set("Accept", "text/html")
	if principal != "" {
		req.AddCookie(personCookie(principal, ""))
	}
	cl := *h.http.Client()
	cl.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	res, err := cl.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(b), res.Header
}

// 我的单子 (claude-fleet#3596): a person reads their own tickets as a page,
// writes a comment that reaches the session doing it, closes and reopens it,
// opens a new one — and someone else's ticket is 404.
func TestTicketsPage(t *testing.T) {
	h, n := ticketHarness(t, control.CapTicket)
	bob := asNode(n["bob4"].token)
	const repo = "team/app"
	if st, out := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath, map[string]any{"repo": repo,
		"title": "登录页在 iPad 上按钮被键盘挡住", "body": "iPad 竖屏，<b>键盘</b>弹出后按钮被盖住。"}); st != 201 {
		t.Fatalf("open: %d %v", st, out)
	}
	if st, out := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath+"/"+repo+"/1/claim", map[string]any{"by": "issue-1"}); st != 200 {
		t.Fatalf("claim: %d %v", st, out)
	}
	if st, out := ticketCall(t, h, bob, http.MethodPost, FleetTicketsPath+"/"+repo+"/1/comments", map[string]any{"body": "已复现。",
		"author": "issue-1", "source": "fleet"}); st != 201 {
		t.Fatalf("a session's comment: %d %v", st, out)
	}
	nextTicket(t, n["bob4"], "the claim")
	nextTicket(t, n["bob4"], "the session's comment")
	page := TicketsPagePath + "/" + repo + "/1"

	// the list and the ticket, as Bob
	st, body, hdr := pageReq(t, h, pBob, http.MethodGet, TicketsPagePath, nil, "")
	if st != 200 || !strings.Contains(body, "登录页在 iPad 上按钮被键盘挡住") || !strings.Contains(body, `href="`+page+`"`) ||
		!strings.Contains(body, "在做 · issue-1") || !strings.Contains(body, `class="wrap solo"`) {
		t.Fatalf("Bob's list: %d %s", st, body)
	}
	if !strings.Contains(hdr.Get("Content-Security-Policy"), "default-src 'none'") || hdr.Get("X-Robots-Tag") == "" {
		t.Fatalf("headers: %v", hdr)
	}
	st, body, _ = pageReq(t, h, pBob, http.MethodGet, page, nil, "")
	if st != 200 || !strings.Contains(body, "&lt;b&gt;键盘&lt;/b&gt;") || !strings.Contains(body, "会话 issue-1") ||
		!strings.Contains(body, "已复现。") || !strings.Contains(body, `class="wrap detail"`) {
		t.Fatalf("Bob's ticket: %d %s", st, body)
	}
	// nothing from GitHub, nothing from anywhere: no script, no stylesheet, no picture
	for _, bad := range []string{"<script", "<img", `rel="stylesheet"`, "github", " src="} {
		if strings.Contains(strings.ToLower(body), bad) {
			t.Fatalf("the page carries %q: %s", bad, body)
		}
	}
	// the phone's two screens: one column, the list hidden on a ticket, a way back
	for _, want := range []string{`name="viewport"`, "@media (max-width:760px)", ".wrap.detail .list{display:none}", `class="back" href="/fleet/tickets"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("phone width: want %q", want)
		}
	}

	// someone else's ticket: 404 to Alice, and her list is empty; a stranger signs in
	if st, body, _ := pageReq(t, h, pAlice, http.MethodGet, page, nil, ""); st != 404 || strings.Contains(body, "键盘") {
		t.Fatalf("Alice reads Bob's: %d %s", st, body)
	}
	if st, body, _ := pageReq(t, h, pAlice, http.MethodPost, page, url.Values{"do": {"comment"}, "body": {"x"}}, ""); st != 404 {
		t.Fatalf("Alice writes on Bob's: %d %s", st, body)
	}
	if st, body, _ := pageReq(t, h, pAlice, http.MethodGet, TicketsPagePath, nil, ""); st != 200 || strings.Contains(body, "键盘") || !strings.Contains(body, "还没有单子") {
		t.Fatalf("Alice's list: %d %s", st, body)
	}
	if st, _, _ := pageReq(t, h, "", http.MethodGet, page, nil, ""); st != 401 && st != 302 {
		t.Fatalf("no sign-in: %d", st)
	}
	if st, _, _ := pageReq(t, h, pBob, http.MethodGet, TicketsPagePath+"/"+repo+"/9", nil, ""); st != 404 {
		t.Fatalf("no such ticket: %d", st)
	}

	// a comment from the page: written as Bob, pushed to his machine, back to the page
	st, _, hdr = pageReq(t, h, pBob, http.MethodPost, page, url.Values{"do": {"comment"}, "body": {"地址拆成三列"}}, "")
	if st != http.StatusSeeOther || hdr.Get("Location") != page+"?ok=comment" {
		t.Fatalf("comment: %d %v", st, hdr)
	}
	if ev := nextTicket(t, n["bob4"], "the page's comment"); ev.Repo != repo || ev.Number != 1 || ev.Kind != "comment" || ev.CommentID == 0 {
		t.Fatalf("pushed: %+v", ev)
	}
	noTicket(t, n["alice5"], "Alice's machine hears nothing of Bob's")
	cs, err := h.srv.Store.TicketComments(repo, 1)
	if err != nil || len(cs) != 2 || cs[1].Author != pBob || cs[1].Source != "hub" || cs[1].Body != "地址拆成三列" {
		t.Fatalf("stored: %v %v", cs, err)
	}
	if _, body, _ := pageReq(t, h, pBob, http.MethodGet, page+"?ok=comment", nil, ""); !strings.Contains(body, "下一轮会看到") || !strings.Contains(body, "你 · ") {
		t.Fatalf("after the comment: %s", body)
	}
	// a cross-site form and an empty one are refused, nothing written
	if st, _, _ := pageReq(t, h, pBob, http.MethodPost, page, url.Values{"do": {"comment"}, "body": {"x"}}, "https://evil.example"); st != 403 {
		t.Fatalf("cross-origin: %d", st)
	}
	if st, body, _ := pageReq(t, h, pBob, http.MethodPost, page, url.Values{"do": {"comment"}, "body": {"  "}}, ""); st != 400 || !strings.Contains(body, "先写点什么") {
		t.Fatalf("empty: %d %s", st, body)
	}
	if cs, _ := h.srv.Store.TicketComments(repo, 1); len(cs) != 2 {
		t.Fatalf("refusals wrote: %v", cs)
	}

	// close (不做了), reopen
	if st, _, hdr := pageReq(t, h, pBob, http.MethodPost, page, url.Values{"do": {"close"}, "reason": {"not_planned"}}, ""); st != 303 || hdr.Get("Location") != page+"?ok=closed" {
		t.Fatalf("close: %d %v", st, hdr)
	}
	if tk, _ := h.srv.Store.FleetTicketAt(repo, 1); tk.State != "closed" || tk.StateReason != "not_planned" {
		t.Fatalf("closed: %+v", tk)
	}
	if ev := nextTicket(t, n["bob4"], "the close"); ev.Kind != "state" {
		t.Fatalf("close pushed: %+v", ev)
	}
	if _, body, _ := pageReq(t, h, pBob, http.MethodGet, TicketsPagePath, nil, ""); strings.Contains(body, "键盘挡住") {
		t.Fatalf("a closed ticket is off 没做完: %s", body)
	}
	if _, body, _ := pageReq(t, h, pBob, http.MethodGet, TicketsPagePath+"?state=closed", nil, ""); !strings.Contains(body, "不做了") {
		t.Fatalf("已关: %s", body)
	}
	if st, _, _ := pageReq(t, h, pBob, http.MethodPost, page, url.Values{"do": {"reopen"}}, ""); st != 303 {
		t.Fatalf("reopen: %d", st)
	}
	if tk, _ := h.srv.Store.FleetTicketAt(repo, 1); tk.State != "open" {
		t.Fatalf("reopened: %+v", tk)
	}

	// a new ticket from the list's form, and a refusal that keeps the words
	st, _, hdr = pageReq(t, h, pBob, http.MethodPost, TicketsPagePath, url.Values{"do": {"new"}, "repo": {repo}, "title": {"订单导出要带上收货地址"}, "body": {"加一列"}}, "")
	if st != 303 || hdr.Get("Location") != TicketsPagePath+"/"+repo+"/2?ok=opened" {
		t.Fatalf("new: %d %v", st, hdr)
	}
	if tk, err := h.srv.Store.FleetTicketAt(repo, 2); err != nil || tk.Owner != pBob || tk.Body != "加一列" || tk.Backend != store.TicketHub {
		t.Fatalf("new ticket: %+v %v", tk, err)
	}
	if st, body, _ := pageReq(t, h, pBob, http.MethodPost, TicketsPagePath, url.Values{"do": {"new"}, "repo": {"app"}, "title": {"留着的标题"}}, ""); st != 400 ||
		!strings.Contains(body, "owner/name") || !strings.Contains(body, `value="留着的标题"`) {
		t.Fatalf("bad repo: %d %s", st, body)
	}
}

// A ticket whose home is GitHub is listed with a link out and is not written
// here; the GitHub link is the registry's own URL, untouched.
func TestTicketsPageGitHubRow(t *testing.T) {
	h, n := ticketHarness(t)
	row := map[string]any{"id": "gh:verkyyi/claude-fleet#3017", "title": "Codex 会话能跑命令",
		"url": "https://github.com/verkyyi/claude-fleet/issues/3017"}
	if st, out := ticketCall(t, h, asNode(n["bob4"].token), http.MethodPost, FleetTicketRegisterPath, row); st != 201 {
		t.Fatalf("register: %d %v", st, out)
	}
	_, body, _ := pageReq(t, h, pBob, http.MethodGet, TicketsPagePath, nil, "")
	if !strings.Contains(body, `href="https://github.com/verkyyi/claude-fleet/issues/3017"`) || !strings.Contains(body, "在 GitHub ↗") {
		t.Fatalf("the gh row: %s", body)
	}
	page := TicketsPagePath + "/verkyyi/claude-fleet/3017"
	if _, body, _ := pageReq(t, h, pBob, http.MethodGet, page, nil, ""); !strings.Contains(body, "家在 GitHub 上") || strings.Contains(body, `name="do" value="comment"`) {
		t.Fatalf("the gh ticket's page: %s", body)
	}
	if st, _, _ := pageReq(t, h, pBob, http.MethodPost, page, url.Values{"do": {"comment"}, "body": {"x"}}, ""); st != http.StatusConflict {
		t.Fatalf("a comment on a gh ticket: %d", st)
	}
}
