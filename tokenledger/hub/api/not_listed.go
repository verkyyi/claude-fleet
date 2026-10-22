package api

import (
	"html/template"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// 名单外那一页 (claude-fleet#4050, EPIC #4048 C2): a sign-in that worked —
// GitHub, WeChat, a proven mail — by a way the list does not name is not a
// dead end any more. Where the three ways used to answer a 403 page and a
// line to copy to an admin, they now give the browser the applicant note
// (applicant.go: no principal, no hub_users row, no /app session) and send
// it to /apply. With nothing asked yet, /apply is this page: what the
// person's situation is, and what they can do — try it first (when
// fleet.trial is on and they have not), apply, read how an invite they got
// works, or sign in another way. With a request in, /apply is its progress.
// denyTmpl is left to the real refusals: removed, renamed, an invite that
// cannot be used.

// notListedAudit is the refused sign-in's audit detail: the old words, and
// that the person was given the applicant note.
const notListedAudit = "not on the list applicant=1"

// notListedSignIn answers a sign-in the list does not name (the admit
// functions audited it): the applicant note for (kind, subject), shown as
// display; a waiting `fleet login` hears where to apply; the browser goes
// to /apply.
func (s *Server) notListedSignIn(w http.ResponseWriter, r *http.Request, kind, subject, display string, now time.Time) {
	s.issueApplicant(w, r, kind, subject, display)
	if to := s.loginRefusedHop(w, r, denyNotListed, display, now); to != "" {
		http.Redirect(w, r, to, http.StatusFound)
		return
	}
	if !wantsHTML(r) {
		httpError(w, http.StatusForbidden, "this sign-in is not on this hub's list yet: apply at "+ApplyPath)
		return
	}
	http.Redirect(w, r, ApplyPath, http.StatusFound)
}

// notListedView is what notListedTmpl draws.
type notListedView struct {
	pageView
	// Screen: "" the situation and its buttons, "invite" how an invite works.
	Screen     string
	Lead       string
	InviteLead string
	Trial      bool
	TrialHref  string
	Fine       string
}

// applyNotListed draws the page for a, who has asked nothing yet.
func (s *Server) applyNotListed(w http.ResponseWriter, r *http.Request, loc string, a applicant) {
	v := notListedView{pageView: newPageView(r, loc), TrialHref: TryPagePath}
	way := applyWayWord(loc, a.Kind)
	name := strings.TrimSpace(a.Display)
	who := map[string]string{"way": way, "name": name}
	key := "nl.who.email"
	switch {
	case isWeChatKind(a.Kind):
		key = "nl.who.wechat"
		if name == "" {
			key = "nl.who.wechat.anon"
		}
	case a.Kind == store.IdentityGitHub:
		key = "nl.who.github"
	}
	noun := "nl.noun.email"
	switch {
	case isWeChatKind(a.Kind):
		noun = "nl.noun.wechat"
	case a.Kind == store.IdentityGitHub:
		noun = "nl.noun.github"
	}
	v.Lead = i18n.Interpolate(pageT(loc, "nl.lead"), map[string]string{
		"who": i18n.Interpolate(pageT(loc, key), who), "way": pageT(loc, noun)})
	v.InviteLead = i18n.Interpolate(pageT(loc, "nl.inv.lead"), map[string]string{
		"link": r.Host + InvitePath + "…", "way": spacedWord(loc, way)})
	v.Trial = s.trialOn() && !s.applicantTried(a)
	reach := "nl.reach.email"
	switch {
	case isWeChatKind(a.Kind):
		reach = "nl.reach.wechat"
	case a.Kind == store.IdentityGitHub:
		reach = "nl.reach.github"
	}
	v.Fine = pageT(loc, reach)
	if v.Trial {
		v.Fine = pageT(loc, "nl.fine.trial") + v.Fine
	}
	if r.URL.Query().Get("invite") == "1" {
		v.Screen = "invite"
	}
	entryHeaders(w, loc)
	w.Header().Add("Vary", "Accept-Language, Cookie")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	c, err := notListedTmpl.Clone()
	if err != nil {
		return
	}
	if err := c.Funcs(pageFuncs(loc)).Execute(w, v); err != nil {
		log.Printf("not-listed page: %v", err)
	}
}

// applicantTried: a's way of signing in already went through the trial.
func (s *Server) applicantTried(a applicant) bool {
	pid, err := s.Store.IdentityPrincipal(a.Kind, a.Subject)
	return err == nil && pid != "" && s.trialPerson(pid)
}

const (
	userPlusIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><line x1="19" x2="19" y1="8" y2="14"/><line x1="22" x2="16" y1="11" y2="11"/></svg>`
	linkIcon     = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>`
)

var notListedTmpl = template.Must(template.New("not-listed").Funcs(pageFuncs(i18n.EN)).Parse(entryHead + `
<title>{{t "nl.title"}}</title></head><body><div class="page">` + entryTop + `
{{if eq .Screen "invite"}}<main class="col"><div class="tile wait">` + linkIcon + `</div><h1>{{t "nl.inv.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{.InviteLead}}</p>
<div class="stack"><a class="btn outline" href="/apply">{{t "nl.back"}}</a></div>
<p class="fine">{{t "nl.inv.fine"}}</p></main>
{{else}}<main class="col"><div class="tile wait">` + userPlusIcon + `</div><h1>{{t "nl.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{.Lead}}</p>
<div class="stack">{{if .Trial}}<a class="btn primary" href="{{.TrialHref}}">{{t "nl.trial"}}</a><a class="btn outline" href="/apply?new=1">{{t "nl.apply"}}</a>{{else}}<a class="btn primary" href="/apply?new=1">{{t "nl.apply"}}</a>{{end}}<a class="btn outline" href="/apply?invite=1">{{t "nl.invited"}}</a><a class="btn ghost" href="/app/signin">{{t "nl.another"}}</a></div>
<p class="fine">{{.Fine}}</p></main>
{{end}}</div></body></html>`))

func init() {
	for k, v := range map[string]i18n.Text{
		"nl.title": {i18n.EN: "Not on the list yet · {brand}", i18n.ZhCN: "还不在名单上 · {brand}"},
		"nl.h1":    {i18n.EN: "You're not on the list yet", i18n.ZhCN: "你还不在名单上"},
		"nl.lead": {
			i18n.EN:   "{brand} is in limited access for now. {who}, but this {way} hasn't been invited and hasn't applied yet.",
			i18n.ZhCN: "{brand} 目前限定开放。{who}，但这个{way}还没有被邀请，也还没有申请过。",
		},
		"nl.who.wechat":      {i18n.EN: "You're signed in with WeChat as “{name}”", i18n.ZhCN: "你已经用微信「{name}」登录"},
		"nl.who.wechat.anon": {i18n.EN: "You're signed in with WeChat", i18n.ZhCN: "你已经用微信登录"},
		"nl.who.github":      {i18n.EN: "You're signed in with the GitHub account @{name}", i18n.ZhCN: "你已经用 GitHub 账号 @{name} 登录"},
		"nl.who.email":       {i18n.EN: "You're signed in with the email {name}", i18n.ZhCN: "你已经用邮箱 {name} 登录"},
		"nl.noun.wechat":     {i18n.EN: "WeChat", i18n.ZhCN: "微信"},
		"nl.noun.github":     {i18n.EN: "GitHub account", i18n.ZhCN: " GitHub 账号"},
		"nl.noun.email":      {i18n.EN: "address", i18n.ZhCN: "邮箱"},
		"nl.trial":           {i18n.EN: "Try it for 15 minutes", i18n.ZhCN: "先试 15 分钟"},
		"nl.apply":           {i18n.EN: "Apply to use it", i18n.ZhCN: "申请使用"},
		"nl.invited":         {i18n.EN: "I got an invite link", i18n.ZhCN: "我收到过邀请链接"},
		"nl.another":         {i18n.EN: "Use another account", i18n.ZhCN: "换个账号"},
		"nl.fine.trial": {
			i18n.EN:   "A trial is one go of 15 minutes or 20 messages; when it is full you wait in line. ",
			i18n.ZhCN: "试用一次 15 分钟或 20 条消息，满了排队。",
		},
		"nl.reach.wechat": {
			i18n.EN:   "Requests are usually answered within one working day, on your WeChat.",
			i18n.ZhCN: "申请通常 1 个工作日内答复，结果会发到你的微信。",
		},
		"nl.reach.github": {
			i18n.EN:   "Requests are usually answered within one working day, at the address you leave on the request.",
			i18n.ZhCN: "申请通常 1 个工作日内答复，结果发到你在申请里留的邮箱。",
		},
		"nl.reach.email": {
			i18n.EN:   "Requests are usually answered within one working day, at this address.",
			i18n.ZhCN: "申请通常 1 个工作日内答复，结果会发到这个邮箱。",
		},
		"nl.inv.h1": {i18n.EN: "Just open that invite link", i18n.ZhCN: "打开那条邀请链接就行"},
		"nl.inv.lead": {
			i18n.EN:   "An invite link looks like {link}. Open it in this browser and sign in with this {way} again — you're in, no request needed.",
			i18n.ZhCN: "邀请链接长这样：{link}。在这个浏览器里打开它，再用这个{way}登录一次就进来了，不用再申请。",
		},
		"nl.inv.fine": {
			i18n.EN:   "Can't find it? An invite lasts 7 days — ask whoever sent it for a new one, or apply instead.",
			i18n.ZhCN: "找不到了？邀请 7 天有效，过期请发邀请的人再发一条；或者直接申请。",
		},
		"nl.back": {i18n.EN: "Back", i18n.ZhCN: "返回"},
	} {
		pageText[k] = v
	}
}
