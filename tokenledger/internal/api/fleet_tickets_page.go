package api

import (
	"database/sql"
	"errors"
	"html/template"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 我的单子 (claude-fleet#3596, EPIC #3570 C3): the tickets C1 keeps on the hub,
// as two pages a person opens on a computer, an iPad or a phone without a
// GitHub account — the list, filtered by repo and state, with a form that
// opens a new one; and one ticket, its body, its thread, a comment box (the
// comment reaches the session doing the ticket on its next turn, C1's push)
// and close / reopen.
//
//	GET  /fleet/tickets[?repo=<owner/name>&state=open|closed|all]
//	POST /fleet/tickets                          do=new  repo title body
//	GET  /fleet/tickets/<owner>/<name>/<N>
//	POST /fleet/tickets/<owner>/<name>/<N>       do=comment body · do=close · do=reopen
//
// Drawn on the server like the keys page (fleet_entry_page.go): no script,
// every change a same-origin form POST answered by a redirect back (?ok=),
// a refusal the page again with one sentence. Who sees what is C1's rule
// (ticketCallerOf + sees): someone else's ticket is 404, the same as none.
// The page loads nothing from GitHub; a ticket whose home is GitHub (a gh
// row) is listed with a plain link out and is not written here.

// TicketsPagePath is the list; a ticket is TicketsPagePath/<owner>/<name>/<N>.
const TicketsPagePath = "/fleet/tickets"

// ticketsPageLimit caps the list (most recently touched first).
const ticketsPageLimit = 300

var ticketsPageOK = map[string]string{
	"opened":   "已开单。",
	"comment":  "已送出。正在做这张单的会话下一轮会看到。",
	"closed":   "已关上。",
	"reopened": "已重新打开。",
}

// ticketPageReturnRe is every path the sign-in may send a browser back to
// (entryReturnTo): the list or one ticket, nothing else.
var ticketPageReturnRe = regexp.MustCompile(`^/fleet/tickets(/[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}/[1-9][0-9]{0,9})?$`)

type ticketRow struct {
	store.FleetTicket
	Href     string // this page's address, or the GitHub page of a gh row
	External bool
	When     string
	Status   string // 没开始 · 在做 · 已关 · …
	Tone     string // css class for Status
}

type ticketCommentView struct {
	store.TicketComment
	Who  string
	Mine bool
	Bot  bool // written by a session (source fleet / a node)
	When string
}

type ticketsPageData struct {
	pageView
	Me      string // the person signed in, as they read
	OK, Err string

	// the list
	Rows   []ticketRow
	Repos  []string
	Repo   string // the repo filter, "" = every one
	State  string // open | closed | all
	Counts map[string]int
	NewOK  bool // the person may open one (a ticket needs an owner)
	Draft  ticketDraft
	Detail bool // this is a ticket's page (the list stays beside it on a wide screen)

	// one ticket
	T        ticketRow
	Comments []ticketCommentView
	Back     string // the list, with its filters
	Body     string // the comment box's words, kept on a refusal
}

type ticketDraft struct{ Repo, Title, Body string }

// handleTicketsPage serves TicketsPagePath and every ticket under it.
func (s *Server) handleTicketsPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	c, ok := s.ticketCallerOf(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "sign in first")
		return
	}
	page := ticketsPageData{pageView: newPageView(r, i18n.ZhCN), Me: s.ticketWho(c.owner), NewOK: c.owner != ""}
	if c.owner == "operator" {
		page.Me = "管理员口令"
	}
	q := r.URL.Query()
	page.Repo, page.State = q.Get("repo"), q.Get("state")
	if page.Repo != "" && !leaseRepoRE.MatchString(page.Repo) {
		page.Repo = ""
	}
	if page.State != "closed" && page.State != "all" {
		page.State = "open"
	}
	page.Back = ticketsListHref(page.Repo, page.State)
	if r.Method == http.MethodPost {
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-origin form")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, ticketRequestMax)
		if err := r.ParseForm(); err != nil {
			httpError(w, http.StatusBadRequest, "unreadable form")
			return
		}
	}
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, TicketsPagePath), "/")
	if rest == "" {
		if r.Method == http.MethodPost {
			if to, status := s.ticketsPageOpen(r, c, &page); to != "" {
				http.Redirect(w, r, to, http.StatusSeeOther)
				return
			} else if status != 0 {
				s.drawTicketsList(w, c, status, page)
				return
			}
		}
		page.OK = ticketsPageOK[q.Get("ok")]
		s.drawTicketsList(w, c, http.StatusOK, page)
		return
	}
	parts := strings.Split(rest, "/")
	if len(parts) != 3 || !leaseRepoRE.MatchString(parts[0]+"/"+parts[1]) {
		http.NotFound(w, r)
		return
	}
	n, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || n <= 0 || strconv.FormatInt(n, 10) != parts[2] {
		http.NotFound(w, r)
		return
	}
	t, err := s.Store.FleetTicketAt(parts[0]+"/"+parts[1], n)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !c.sees(t)) {
		s.writeTicketsPage(w, http.StatusNotFound, ticketsPageData{pageView: page.pageView, Me: page.Me,
			Detail: true, Back: page.Back, Err: "没有这张单子，或者它不是你的。"})
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if r.Method == http.MethodPost {
		if ok, status := s.ticketPagePost(r, c, t, &page); ok != "" {
			http.Redirect(w, r, ticketPageHref(t.Repo, t.Number)+"?ok="+ok+ticketsFilterQuery(page.Repo, page.State, "&"), http.StatusSeeOther)
			return
		} else if status != 0 {
			s.drawTicket(w, c, t, status, page)
			return
		}
	}
	page.OK = ticketsPageOK[q.Get("ok")]
	s.drawTicket(w, c, t, http.StatusOK, page)
}

// ticketsPageOpen opens a ticket from the list's form: where to go next, or
// the status to draw the list again with page.Err said.
func (s *Server) ticketsPageOpen(r *http.Request, c ticketCaller, page *ticketsPageData) (string, int) {
	if r.PostFormValue("do") != "new" {
		page.Err = "看不懂这个表单。"
		return "", http.StatusBadRequest
	}
	page.Draft = ticketDraft{Repo: strings.TrimSpace(r.PostFormValue("repo")), Title: r.PostFormValue("title"), Body: r.PostFormValue("body")}
	if c.owner == "" {
		page.Err = "这个登录不属于任何人，开出的单子会没有主人。"
		return "", http.StatusForbidden
	}
	title, ok := oneShort(page.Draft.Title, ticketTitleMax)
	switch {
	case !leaseRepoRE.MatchString(page.Draft.Repo):
		page.Err = "仓库写成 owner/name，例如 team/app。"
	case !ok || title == "":
		page.Err = "标题是一行字，1–200 个字。"
	case len(page.Draft.Body) > ticketBodyMax:
		page.Err = "正文最多 64 KiB。"
	}
	if page.Err != "" {
		return "", http.StatusBadRequest
	}
	t, err := s.Store.CreateFleetTicket(store.FleetTicket{Repo: page.Draft.Repo, Owner: c.owner, Title: title,
		Body: page.Draft.Body, Labels: []string{}, Origin: "page"}, 0, time.Now())
	if err != nil {
		page.Err = "没开成：" + err.Error()
		return "", http.StatusInternalServerError
	}
	return ticketPageHref(t.Repo, t.Number) + "?ok=opened", 0
}

// ticketPagePost is one change on a ticket's page: the ?ok= word, or the
// status to draw the page again with page.Err said.
func (s *Server) ticketPagePost(r *http.Request, c ticketCaller, t store.FleetTicket, page *ticketsPageData) (string, int) {
	if t.Backend != store.TicketHub {
		page.Err = "这张单在 GitHub 上，评论和关单请到 GitHub。"
		return "", http.StatusConflict
	}
	switch r.PostFormValue("do") {
	case "comment":
		body := r.PostFormValue("body")
		page.Body = body
		if strings.TrimSpace(body) == "" {
			page.Err = "先写点什么。"
			return "", http.StatusBadRequest
		}
		if len(body) > ticketBodyMax {
			page.Err = "一条评论最多 64 KiB。"
			return "", http.StatusBadRequest
		}
		// A person writes as themself (C1's rule for the page): the author
		// is who signed in, never a name the form carries.
		if _, err := s.addTicketComment(t, c.actor, body, "hub", ""); err != nil {
			page.Err = "没送出：" + err.Error()
			return "", http.StatusInternalServerError
		}
		return "comment", 0
	case "close", "reopen":
		state, reason, ok := "closed", "completed", "closed"
		if r.PostFormValue("do") == "reopen" {
			state, reason, ok = "open", "reopened", "reopened"
		}
		if t.State == state {
			return ok, 0
		}
		if r.PostFormValue("reason") == "not_planned" && state == "closed" {
			reason = "not_planned"
		}
		out, err := s.Store.EditFleetTicket(t.Repo, t.Number, store.TicketEdit{State: &state, StateReason: &reason}, time.Now())
		if err != nil {
			page.Err = "没改成：" + err.Error()
			return "", http.StatusInternalServerError
		}
		s.pushTicket(out.Owner, control.Ticket{Repo: out.Repo, Number: out.Number, Kind: "state"})
		return ok, 0
	}
	page.Err = "看不懂这个表单。"
	return "", http.StatusBadRequest
}

// ticketsFor is the caller's tickets (everyone's for the operator's door),
// most recently touched first.
func (s *Server) ticketsFor(c ticketCaller) ([]store.FleetTicket, error) {
	f := store.TicketFilter{Owner: c.owner, All: c.all, Limit: ticketsPageLimit}
	if c.all {
		f.Owner = ""
	}
	if f.Owner == "" && !f.All {
		return nil, nil
	}
	return s.Store.FleetTickets(f)
}

// fillTicketsList fills the list half of page (the list page, and the column
// beside a ticket on a wide screen).
func (s *Server) fillTicketsList(c ticketCaller, page *ticketsPageData) error {
	all, err := s.ticketsFor(c)
	if err != nil {
		return err
	}
	now := time.Now()
	seen := map[string]bool{}
	page.Counts = map[string]int{"open": 0, "closed": 0, "all": 0}
	for _, t := range all {
		if !seen[t.Repo] {
			seen[t.Repo] = true
			page.Repos = append(page.Repos, t.Repo)
		}
		if page.Repo != "" && !strings.EqualFold(t.Repo, page.Repo) {
			continue
		}
		page.Counts[t.State]++
		page.Counts["all"]++
		if page.State != "all" && t.State != page.State {
			continue
		}
		page.Rows = append(page.Rows, s.ticketRowOf(t, now))
	}
	sort.Strings(page.Repos)
	if page.Draft.Repo == "" {
		page.Draft.Repo = page.Repo
		if page.Draft.Repo == "" && len(page.Repos) == 1 {
			page.Draft.Repo = page.Repos[0]
		}
	}
	return nil
}

func (s *Server) drawTicketsList(w http.ResponseWriter, c ticketCaller, status int, page ticketsPageData) {
	if err := s.fillTicketsList(c, &page); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.writeTicketsPage(w, status, page)
}

func (s *Server) drawTicket(w http.ResponseWriter, c ticketCaller, t store.FleetTicket, status int, page ticketsPageData) {
	if err := s.fillTicketsList(c, &page); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	page.Detail, page.T = true, s.ticketRowOf(t, now)
	if t.Backend == store.TicketHub {
		cs, err := s.Store.TicketComments(t.Repo, t.Number)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		for _, cm := range cs {
			v := ticketCommentView{TicketComment: cm, When: ticketWhen(cm.CreatedAt, now),
				Bot: cm.Source == "fleet" || strings.Contains(cm.Author, "(node:")}
			switch {
			case cm.Author == c.actor:
				v.Who, v.Mine = "你", true
			case v.Bot:
				v.Who = cm.Author
				if i := strings.Index(v.Who, " (node:"); i > 0 {
					v.Who = v.Who[:i]
				}
				v.Who = "会话 " + v.Who
			default:
				v.Who = s.ticketWho(cm.Author)
			}
			page.Comments = append(page.Comments, v)
		}
	}
	s.writeTicketsPage(w, status, page)
}

func (s *Server) ticketRowOf(t store.FleetTicket, now time.Time) ticketRow {
	row := ticketRow{FleetTicket: t, Href: ticketPageHref(t.Repo, t.Number), When: ticketWhen(t.UpdatedAt, now)}
	if t.Backend != store.TicketHub {
		row.External = true
		if strings.HasPrefix(t.URL, "https://github.com/") {
			row.Href = t.URL
		}
	}
	switch {
	case t.State == "closed" && t.StateReason == "not_planned":
		row.Status, row.Tone = "不做了", "done"
	case t.State == "closed":
		row.Status, row.Tone = "已关", "done"
	case t.Assignee != "":
		row.Status, row.Tone = "在做 · "+t.Assignee, "run"
	default:
		row.Status, row.Tone = "没开始", "wait"
	}
	return row
}

// ticketWho is how a principal reads on the page: their name, else the id.
func (s *Server) ticketWho(pid string) string {
	if pid == "" {
		return ""
	}
	n := s.personName(pid)
	if i := strings.LastIndex(n, " ("+pid+")"); i > 0 {
		return n[:i]
	}
	return n
}

func ticketWhen(t, now time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "刚才"
	case d < time.Hour:
		return strconv.Itoa(int(d/time.Minute)) + " 分钟前"
	case d < 24*time.Hour:
		return strconv.Itoa(int(d/time.Hour)) + " 小时前"
	case d < 30*24*time.Hour:
		return strconv.Itoa(int(d/(24*time.Hour))) + " 天前"
	}
	return t.Local().Format("2006-01-02")
}

// ticketPageHref is one ticket's page.
func ticketPageHref(repo string, n int64) string {
	return TicketsPagePath + "/" + repo + "/" + strconv.FormatInt(n, 10)
}

// ticketsFilterQuery is the list's filters as a query string after sep ("?"
// or "&"), "" when they are the defaults.
func ticketsFilterQuery(repo, state, sep string) string {
	v := url.Values{}
	if repo != "" {
		v.Set("repo", repo)
	}
	if state != "" && state != "open" {
		v.Set("state", state)
	}
	if len(v) == 0 {
		return ""
	}
	return sep + v.Encode()
}

func ticketsListHref(repo, state string) string {
	return TicketsPagePath + ticketsFilterQuery(repo, state, "?")
}

func (s *Server) writeTicketsPage(w http.ResponseWriter, status int, page ticketsPageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "same-origin")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	// Nothing from anywhere else: no script, no GitHub picture, no font.
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
	w.WriteHeader(status)
	_ = ticketsPageTmpl.Execute(w, page)
}

var ticketsPageTmpl = template.Must(template.New("tickets").Funcs(template.FuncMap{
	"listHref": ticketsListHref,
	"filterQ":  ticketsFilterQuery,
	"initial": func(s string) string {
		for _, r := range s {
			return string(r)
		}
		return "?"
	},
}).Parse(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>{{if and .Detail .T.Title}}{{.T.Title}} · {{end}}单子 · claudefleet</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Crect width='24' height='24' rx='6' fill='%230e6e5e'/%3E%3Cpath d='M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18' stroke='%23fff' stroke-width='2.2' fill='none' stroke-linecap='round'/%3E%3C/svg%3E">
<style>
` + authPaletteCSS + zhTypeCSS + `*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 var(--f-ui);-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
a{color:var(--brand)}
nav{display:flex;align-items:center;gap:10px;padding:10px 16px;border-bottom:1px solid var(--line);background:var(--panel)}
.logo{display:inline-flex;align-items:center;gap:8px;font:700 16px var(--f-display);color:var(--ink);text-decoration:none}
.mark{width:22px;height:22px;border-radius:6px;background:var(--brand);display:grid;place-items:center}
.mark svg{width:14px;height:14px;stroke:var(--brand-ink);stroke-width:2.2;fill:none;stroke-linecap:round}
nav .here{color:var(--muted)}nav .me{margin-left:auto;color:var(--muted);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:45%}
.wrap{display:grid;grid-template-columns:minmax(300px,380px) 1fr;max-width:1180px;margin:0 auto;min-height:calc(100vh - 47px)}
.list{border-right:1px solid var(--line);padding:12px 12px 80px;background:var(--bg)}
.det{padding:16px 22px 120px;min-width:0}
.wrap.solo{grid-template-columns:1fr;max-width:760px}.wrap.solo .list{border-right:0}
h1{font:700 1.25rem/1.35 var(--f-display);margin:2px 0 6px;overflow-wrap:anywhere}
h2{font-size:.95rem;margin:0 0 8px}
p{margin:0}.hint{color:var(--muted);font-size:13px}
.filters{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 10px}
.chip{display:inline-flex;align-items:center;gap:5px;font-size:13px;padding:4px 10px;border-radius:99px;border:1px solid var(--line);background:var(--panel);color:var(--ink-2);text-decoration:none;min-height:32px}
.chip.on{background:var(--brand);border-color:var(--brand);color:var(--brand-ink)}
.chip .n{opacity:.7}
select{font:14px var(--f-ui);color:var(--ink);background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:5px 8px;min-height:32px;max-width:100%}
.t{display:block;padding:10px 12px;margin:6px 0;border:1px solid var(--line-2);border-radius:10px;background:var(--panel);color:var(--ink);text-decoration:none}
.t.sel{border-color:var(--brand);box-shadow:0 0 0 1px var(--brand)}
.t .ti{font-weight:600;overflow-wrap:anywhere}
.t .me2{display:flex;flex-wrap:wrap;gap:4px 10px;font-size:12.5px;color:var(--muted);margin-top:3px}
.mono{font:12.5px ui-monospace,Menlo,monospace}
.st{display:inline-block;font-size:12px;border-radius:99px;padding:0 8px;background:var(--line-2);color:var(--ink-2)}
.st.run{background:var(--line-2);color:var(--brand)}.st.wait{background:var(--warn-soft);color:var(--warn)}.st.done{background:var(--line-2);color:var(--muted)}
.empty{color:var(--muted);text-align:center;padding:28px 10px;font-size:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:14px;margin:12px 0;overflow-wrap:anywhere}
.body{white-space:pre-wrap;overflow-wrap:anywhere}
.meta{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:13px;color:var(--muted);margin:2px 0 8px}
.c{display:flex;gap:10px;margin:12px 0}
.av{width:30px;height:30px;flex:none;border-radius:99px;display:grid;place-items:center;font:600 13px var(--f-ui);background:var(--line-2);color:var(--ink-2)}
.av.bot{background:var(--brand);color:var(--brand-ink)}.av.me{background:var(--ink-2);color:#fff}
.c .w{flex:1;min-width:0;background:var(--panel);border:1px solid var(--line-2);border-radius:10px;padding:8px 12px}
.c .h{font-size:12.5px;color:var(--muted);margin-bottom:2px}
.c .x{white-space:pre-wrap;overflow-wrap:anywhere}
textarea,input[type=text]{width:100%;font:16px/1.45 var(--f-ui);color:var(--ink);background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:10px}
textarea{min-height:96px;resize:vertical}
label.f{display:block;font-size:13px;color:var(--muted);margin:8px 0 3px}
button,.btn{font:500 15px var(--f-ui);border:1px solid var(--line);background:var(--panel);color:var(--ink);padding:9px 14px;border-radius:9px;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;min-height:44px;cursor:pointer}
button.go,.btn.go{background:var(--brand);border-color:var(--brand);color:var(--brand-ink)}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:10px}
.msg{border-radius:9px;padding:9px 12px;font-size:14px;margin:10px 0}
.msg.ok{background:var(--line-2);color:var(--brand)}
.msg.err{background:var(--bad-soft);color:var(--bad)}
.msg.info{background:var(--line-2);color:var(--ink-2)}
details.new{margin:0 0 10px}details.new summary{cursor:pointer;list-style:none;display:inline-flex}
details.new summary::-webkit-details-marker{display:none}
.back{display:none;margin:0 0 8px;font-size:14px;text-decoration:none}
@media (max-width:760px){
 .wrap{grid-template-columns:1fr}
 .list{border-right:0}
 .wrap.detail .list{display:none}
 .det{padding:12px 14px 110px}
 .back{display:inline-block}
 .wrap:not(.detail) .det{display:none}
}
</style></head><body>
<nav><a class="logo" href="/"><span class="mark"><svg viewBox="0 0 24 24"><path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/></svg></span>claudefleet</a><span class="here">· 单子</span>{{if .Me}}<span class="me">{{.Me}}</span>{{end}}</nav>
<div class="wrap{{if .Detail}} detail{{else}} solo{{end}}">
<section class="list" aria-label="单子">
{{if not .Detail}}{{if .OK}}<p class="msg ok" role="status">{{.OK}}</p>{{end}}{{if .Err}}<p class="msg err" role="alert">{{.Err}}</p>{{end}}{{end}}
<form class="filters" method="get" action="/fleet/tickets">
<a class="chip{{if eq .State "open"}} on{{end}}" href="{{listHref .Repo "open"}}">没做完 <span class="n">{{index .Counts "open"}}</span></a>
<a class="chip{{if eq .State "closed"}} on{{end}}" href="{{listHref .Repo "closed"}}">已关 <span class="n">{{index .Counts "closed"}}</span></a>
<a class="chip{{if eq .State "all"}} on{{end}}" href="{{listHref .Repo "all"}}">全部 <span class="n">{{index .Counts "all"}}</span></a>
{{if gt (len .Repos) 1}}<input type="hidden" name="state" value="{{.State}}"><select name="repo" aria-label="仓库"><option value="">所有仓库</option>{{range .Repos}}<option value="{{.}}"{{if eq . $.Repo}} selected{{end}}>{{.}}</option>{{end}}</select><button type="submit" style="min-height:32px;padding:4px 10px;font-size:13px">看</button>{{end}}
</form>
{{if and .NewOK (not .Detail)}}<details class="new"{{if .Err}} open{{end}}><summary class="btn go">+ 新单子</summary>
<form class="card" method="post" action="/fleet/tickets{{filterQ .Repo .State "?"}}"><input type="hidden" name="do" value="new">
<label class="f" for="nr">仓库</label><input type="text" id="nr" name="repo" value="{{.Draft.Repo}}" placeholder="team/app" autocapitalize="off" autocorrect="off" spellcheck="false" list="repos" required>
<datalist id="repos">{{range .Repos}}<option value="{{.}}">{{end}}</datalist>
<label class="f" for="nt">标题</label><input type="text" id="nt" name="title" value="{{.Draft.Title}}" maxlength="200" required>
<label class="f" for="nb">说明（可不写）</label><textarea id="nb" name="body">{{.Draft.Body}}</textarea>
<div class="row"><button class="go" type="submit">开单</button></div></form></details>{{end}}
{{range .Rows}}<a class="t{{if and $.Detail (eq .ID $.T.ID)}} sel{{end}}" href="{{.Href}}{{if not .External}}{{filterQ $.Repo $.State "?"}}{{end}}"{{if .External}} rel="noopener"{{end}}>
<div class="ti">{{.Title}}</div><div class="me2"><span class="mono">{{.Repo}}#{{.Number}}</span><span class="st {{.Tone}}">{{.Status}}</span>{{if .External}}<span>在 GitHub ↗</span>{{end}}<span>{{.When}}</span></div></a>
{{else}}<div class="empty">{{if eq .Counts.all 0}}还没有单子。<br>对编排会话说一句话，或点「+ 新单子」。{{else}}这里没有单子。{{end}}</div>{{end}}
</section>
<section class="det">
{{if .Detail}}<a class="back" href="{{.Back}}">← 单子</a>
{{if .OK}}<p class="msg ok" role="status">{{.OK}}</p>{{end}}{{if .Err}}<p class="msg err" role="alert">{{.Err}}</p>{{end}}
{{if .T.ID}}<h1>{{.T.Title}}</h1>
<div class="meta"><span class="mono">{{.T.Repo}}#{{.T.Number}}</span><span class="st {{.T.Tone}}">{{.T.Status}}</span>{{if .T.When}}<span>{{.T.When}}更新</span>{{end}}{{if .T.Parent}}<span>属于 <span class="mono">{{.T.Parent}}</span></span>{{end}}</div>
{{if .T.External}}<p class="msg info">这张单的家在 GitHub 上，这里只记着它的标题和状态。{{if ne .T.Href ""}}<a href="{{.T.Href}}" rel="noopener">到 GitHub 上看 ↗</a>{{end}}</p>
{{else}}{{if .T.Body}}<div class="card body">{{.T.Body}}</div>{{end}}
{{range .Comments}}<div class="c" id="c{{.ID}}"><div class="av{{if .Bot}} bot{{else if .Mine}} me{{end}}" aria-hidden="true">{{if .Bot}}⚙{{else if .Mine}}我{{else}}{{initial .Who}}{{end}}</div><div class="w"><div class="h">{{.Who}} · {{.When}}</div><div class="x">{{.Body}}</div></div></div>{{end}}
{{if eq .T.State "closed"}}<p class="msg info">这张单已经关上。还有话就写在下面；要接着做，点「重新打开」。</p>{{end}}
<form method="post" action="{{.T.Href}}{{filterQ .Repo .State "?"}}"><input type="hidden" name="do" value="comment">
<label class="f" for="cm">写一句</label><textarea id="cm" name="body" placeholder="写给正在做这张单的会话…" required>{{.Body}}</textarea>
<div class="row"><button class="go" type="submit">发送</button><span class="hint">{{if .T.Assignee}}发给：{{.T.Assignee}}，它下一轮就会看到{{else}}还没有会话在做；写下的话留在单子上{{end}}</span></div></form>
<form method="post" action="{{.T.Href}}{{filterQ .Repo .State "?"}}" class="row">{{if eq .T.State "closed"}}<input type="hidden" name="do" value="reopen"><button type="submit">重新打开</button>{{else}}<input type="hidden" name="do" value="close"><button type="submit">做完了，关掉</button><button type="submit" name="reason" value="not_planned">不做了，关掉</button>{{end}}</form>
{{end}}{{end}}
{{else}}<div class="empty">选一张单子看详情。</div>{{end}}
</section>
</div>
</body></html>`))
