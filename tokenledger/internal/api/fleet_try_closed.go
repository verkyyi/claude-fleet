package api

import (
	"html/template"
	"net/http"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// 试用暂未开放 (claude-fleet#4269): with fleet.trial off, a trial link that is
// already out there — the site's old 「立即体验」 (/app/try, a cached page, the
// official account's 「立即体验」, a forwarded message) or a drill trial's
// redeem link (/auth/drill/trial?code=) — answers this page instead of a
// redirect or a 404: the trial is not open for now, apply. Nothing about the
// trial itself changes; with fleet.trial on these paths are the trial again.

// serveTryClosed draws the page, 200.
func (s *Server) serveTryClosed(w http.ResponseWriter, r *http.Request) {
	loc := s.pageLocale(w, r)
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	writeAuthPage(w, http.StatusOK, tryClosedTmpl, loc, newPageView(r, loc))
}

var tryClosedTmpl = template.Must(template.New("try-closed").Funcs(pageFuncs(i18n.EN)).Parse(entryHead + `
<title>{{t "tc.title"}}</title></head><body><div class="page">` + entryTop + `
<main class="col">` + limitedPill + `<div class="tile wait">` + clockIcon + `</div><h1>{{t "tc.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{t "tc.lead"}}</p>
<div class="stack"><a class="btn primary" href="` + ApplyPath + `">{{t "nl.apply"}}</a><a class="btn ghost" href="/app">{{t "tc.member"}}</a></div>
<p class="fine">{{t "tc.fine"}}</p></main>
</div></body></html>`))

func init() {
	for k, v := range map[string]i18n.Text{
		"tc.title": {i18n.EN: "The trial isn't open · claudefleet", i18n.ZhCN: "试用暂未开放 · claudefleet"},
		"tc.h1":    {i18n.EN: "The trial isn't open for now", i18n.ZhCN: "试用暂未开放"},
		"tc.lead": {
			i18n.EN:   "ClaudeFleet is in limited access, by application. Tell us what you want to use it for and we'll open an account for you.",
			i18n.ZhCN: "ClaudeFleet 目前限定开放，请申请使用。说说你想用它做什么，审核通过后给你开号。",
		},
		"tc.member": {i18n.EN: "I already have an account", i18n.ZhCN: "我已经有账号"},
		"tc.fine": {
			i18n.EN:   "Requests are usually answered within one working day.",
			i18n.ZhCN: "申请通常 1 个工作日内答复。",
		},
	} {
		pageText[k] = v
	}
}
