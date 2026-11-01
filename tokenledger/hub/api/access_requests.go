package api

import (
	"errors"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// 申请页和「我的申请」(claude-fleet#4051, EPIC #4048 C3): a person the list
// does not name asks to be let in, at ONE address that is two pages — the
// form while they have nothing waiting, their request's progress once they
// have. Everything about the request is store.RequestStore; who is asking is
// the applicant note (applicant.go), or a signed-in trial person coming from
// /app/try (?from=trial). A member is sent to /app, anyone else to sign in.
//
//	GET  /apply             nothing asked yet: the not-listed page
//	                        (not_listed.go, #4050; ?invite=1 how an invite
//	                        works); ?new=1 the form; else where their
//	                        request stands (?edit=1 the form again for a pending one,
//	                        ?withdraw=1 the confirmation, ?again=1 a new form
//	                        after a refusal whose cooldown is over)
//	POST /apply             submit: 303 → /apply; 409 and the existing one
//	                        for a second pending or inside the cooldown; 429
//	                        past applyPerIPHour from one address
//	POST /apply/edit        change the pending one
//	POST /apply/withdraw    take it back (a new one may follow at once)
//
// Every page is a way-in page (entry_pages.go): server-drawn, no script.

const (
	ApplyPath         = "/apply"
	ApplyEditPath     = "/apply/edit"
	ApplyWithdrawPath = "/apply/withdraw"

	// ApplyCooldownKey is how many days a refused person waits before asking
	// again (共同约定 7): C4's reject takes it as its default.
	ApplyCooldownKey = "fleet.apply.cooldown_days"

	// applyPerIPHour is how many requests one address may make an hour.
	applyPerIPHour = 5

	// The lengths (runes) a request's fields may have.
	applyUseMin, applyUseMax = 10, 500
	applyShortMax            = 80
)

// applyCooldown is ApplyCooldownKey as a duration.
func (s *Server) applyCooldown() time.Duration {
	n, err := strconv.Atoi(s.setting(ApplyCooldownKey))
	if err != nil || n < 0 {
		n = 30
	}
	return time.Duration(n) * 24 * time.Hour
}

// applyWho is who is asking: the applicant, and trialPID when they are a
// signed-in trial person. to is where to send anyone else.
func (s *Server) applyWho(r *http.Request) (a applicant, trialPID, to string) {
	if _, pid, ok := s.personSession(r); ok {
		if role, err := s.personRole(pid); err == nil && role != "" {
			if a, ok := s.trialApplicant(pid); ok {
				return a, pid, ""
			}
			return applicant{}, "", AppPrefix
		}
	}
	if a, ok := s.applicantFrom(r); ok {
		return a, "", ""
	}
	return applicant{}, "", appURL("/signin") + "?next=" + applyNext
}

// trialApplicant: pid came in through the trial (a fleet_trials row) and has
// not been approved since — they apply as the way they signed in.
func (s *Server) trialApplicant(pid string) (applicant, bool) {
	if t, err := s.Store.Trial(pid); err != nil || t == nil {
		return applicant{}, false
	}
	ids, err := s.Store.HubIdentities(pid)
	if err != nil || len(ids) == 0 {
		return applicant{}, false
	}
	pick := ids[0]
	for _, k := range store.IdentityKinds {
		if i := identityOfKind(ids, k); i != nil {
			pick = *i
			break
		}
	}
	a := applicant{Kind: pick.Kind, Subject: pick.Subject, Display: pick.Subject}
	if u, err := s.Store.HubUserByPrincipal(pid); err == nil && u != nil && u.Login != "" {
		a.Display = u.Login
	}
	if rs, err := s.Store.Requests().ByIdentity(a.Kind, a.Subject); err == nil && len(rs) > 0 &&
		rs[0].State == store.RequestApproved {
		return applicant{}, false
	}
	return a, true
}

func identityOfKind(ids []store.HubIdentity, kind string) *store.HubIdentity {
	for i := range ids {
		if ids[i].Kind == kind {
			return &ids[i]
		}
	}
	return nil
}

// handleApply is /apply: GET the page, POST a new request.
func (s *Server) handleApply(w http.ResponseWriter, r *http.Request) {
	if s.Store == nil || !s.signinOn() {
		s.notFoundPage(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		s.applyGet(w, r)
	case http.MethodPost:
		s.applyPost(w, r, ApplyPath)
	default:
		w.Header().Set("Allow", "GET, HEAD, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// handleApplyEdit is POST /apply/edit.
func (s *Server) handleApplyEdit(w http.ResponseWriter, r *http.Request) {
	s.applyAction(w, r, ApplyEditPath)
}

// handleApplyWithdraw is POST /apply/withdraw.
func (s *Server) handleApplyWithdraw(w http.ResponseWriter, r *http.Request) {
	s.applyAction(w, r, ApplyWithdrawPath)
}

func (s *Server) applyAction(w http.ResponseWriter, r *http.Request, path string) {
	if s.Store == nil || !s.signinOn() {
		s.notFoundPage(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	s.applyPost(w, r, path)
}

func (s *Server) applyGet(w http.ResponseWriter, r *http.Request) {
	a, trialPID, to := s.applyWho(r)
	if to != "" {
		http.Redirect(w, r, to, http.StatusFound)
		return
	}
	reqs, err := s.Store.Requests().ByIdentity(a.Kind, a.Subject)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the requests")
		return
	}
	loc := s.pageLocale(w, r)
	v := s.newApplyView(r, loc, a)
	v.FromTrial = trialPID != "" || r.URL.Query().Get("from") == "trial"
	q := r.URL.Query()
	now := time.Now()
	var last *store.AccessRequest
	if len(reqs) > 0 {
		last = &reqs[0]
	}
	switch {
	case last != nil && last.State == store.RequestPending && q.Get("edit") == "1":
		v.formFrom(loc, a, last, true)
	case last != nil && last.State == store.RequestPending:
		v.statusOf(loc, last, now)
		v.Confirm = q.Get("withdraw") == "1"
	case last != nil && last.State == store.RequestApproved:
		v.statusOf(loc, last, now)
	case last != nil && last.State == store.RequestRejected && (now.Before(last.CooldownUntil) || q.Get("again") != "1"):
		v.statusOf(loc, last, now)
	default:
		if trialPID == "" {
			if on, err := s.listed(a); err == nil && on {
				// Let in another way since (an invite, an admin): sign in.
				http.Redirect(w, r, appURL("/signin"), http.StatusFound)
				return
			}
			if last == nil && q.Get("new") != "1" && !v.FromTrial &&
				(q.Get("invite") == "1" || (s.trialOn() && !s.applicantTried(a))) {
				// Just turned away at the door, nothing asked yet, and a
				// choice to make (a trial, or an invite link): where they
				// stand and what they can do (not_listed.go, #4050). With
				// nothing to choose the form is the page (T794).
				s.applyNotListed(w, r, loc, a)
				return
			}
		}
		v.formFrom(loc, a, last, false)
		if last == nil && trialPID != "" {
			v.Use = s.trialFirstWords(trialPID)
			v.UseCarried = v.Use != ""
		}
	}
	s.writeApply(w, r, http.StatusOK, loc, v)
}

// listed: a's way of signing in is someone's on the list now.
func (s *Server) listed(a applicant) (bool, error) {
	pid, err := s.Store.IdentityPrincipal(a.Kind, a.Subject)
	if err != nil || pid == "" {
		return false, err
	}
	role, err := s.personRole(pid)
	return role != "", err
}

func (s *Server) applyPost(w http.ResponseWriter, r *http.Request, path string) {
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	a, trialPID, to := s.applyWho(r)
	if to != "" {
		http.Redirect(w, r, to, http.StatusSeeOther)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := r.ParseForm(); err != nil {
		httpError(w, http.StatusBadRequest, "the form could not be read")
		return
	}
	loc := s.pageLocale(w, r)
	now := time.Now()
	rq := s.Store.Requests()
	actor := a.Kind + ":?"
	if trialPID != "" {
		actor = trialPID
	}
	target := a.Display + " (" + a.Kind + ")"
	id := r.PostForm.Get("id")

	if path == ApplyWithdrawPath {
		got, err := rq.Withdraw(id, a.Kind, a.Subject, now)
		if s.applyStoreErr(w, r, loc, a, got, err) {
			return
		}
		_ = s.Store.HubAudit(actor, "request.withdraw", target, "ok", got.ID, now)
		http.Redirect(w, r, ApplyPath, http.StatusSeeOther)
		return
	}

	v := s.newApplyView(r, loc, a)
	v.FromTrial = trialPID != ""
	f, bad := v.readForm(loc, a, r.PostForm)
	if path == ApplyEditPath {
		v.Action, v.ID = ApplyEditPath, id
	}
	if bad {
		s.writeApply(w, r, http.StatusBadRequest, loc, v)
		return
	}
	if path == ApplyEditPath {
		got, err := rq.Edit(id, a.Kind, a.Subject, f)
		if s.applyStoreErr(w, r, loc, a, got, err) {
			return
		}
		_ = s.Store.HubAudit(actor, "request.edit", target, "ok", got.ID, now)
		_ = rq.SetLang(got.ID, loc)
		http.Redirect(w, r, ApplyPath, http.StatusSeeOther)
		return
	}

	ipHash := hashHex("apply-ip", chatClientIP(r).String())
	if n, err := rq.SubmittedFrom(ipHash, now.Add(-time.Hour)); err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the requests")
		return
	} else if n >= applyPerIPHour {
		_ = s.Store.HubAudit(actor, "request.submit", target, "refused", "too many from one address", now)
		v.Alert, v.AlertBad = pageT(loc, "apply.err.ip"), true
		w.Header().Set("Retry-After", "3600")
		s.writeApply(w, r, http.StatusTooManyRequests, loc, v)
		return
	}
	rid, err := randomToken(12)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	got, err := rq.Create(store.AccessRequest{ID: "rq-" + rid, Kind: a.Kind, Subject: a.Subject, Display: a.Display,
		Use: f.Use, Team: f.Team, Referrer: f.Referrer, NotifyChannel: f.NotifyChannel, NotifyAddr: f.NotifyAddr,
		CreatedAt: now, IPHash: ipHash})
	var cool *store.CooldownError
	switch {
	case errors.Is(err, store.ErrRequestPending), errors.As(err, &cool):
		why := "already pending"
		if cool != nil {
			why = "inside the cooldown"
		}
		_ = s.Store.HubAudit(actor, "request.submit", target, "refused", why, now)
		s.applyShowExisting(w, r, loc, a, http.StatusConflict)
		return
	case err != nil:
		log.Printf("apply: %v", err)
		httpError(w, http.StatusInternalServerError, "could not record the request")
		return
	}
	_ = s.Store.HubAudit(actor, "request.submit", target, "ok", got.ID, now)
	// The result is told in the language they asked in; the admins hear of
	// it now (C5, notify.go).
	_ = rq.SetLang(got.ID, loc)
	s.notifyAdmins(got)
	http.Redirect(w, r, ApplyPath, http.StatusSeeOther)
}

// applyStoreErr answers an edit / withdraw the store refused; false when
// err is nil and the caller goes on.
func (s *Server) applyStoreErr(w http.ResponseWriter, r *http.Request, loc string, a applicant, got *store.AccessRequest, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, store.ErrRequestNotFound):
		s.notFoundPage(w, r)
	case errors.Is(err, store.ErrRequestNotPending):
		s.applyShowExisting(w, r, loc, a, http.StatusConflict)
	default:
		log.Printf("apply: %v", err)
		httpError(w, http.StatusInternalServerError, "could not change the request")
	}
	return true
}

// applyShowExisting answers with where a's newest request stands, and why
// what they asked for did not happen.
func (s *Server) applyShowExisting(w http.ResponseWriter, r *http.Request, loc string, a applicant, code int) {
	reqs, err := s.Store.Requests().ByIdentity(a.Kind, a.Subject)
	if err != nil || len(reqs) == 0 {
		httpError(w, http.StatusInternalServerError, "could not read the requests")
		return
	}
	v := s.newApplyView(r, loc, a)
	v.statusOf(loc, &reqs[0], time.Now())
	switch reqs[0].State {
	case store.RequestPending:
		v.Alert = pageT(loc, "apply.err.pending")
	case store.RequestRejected:
		v.Alert = pageT(loc, "apply.err.cooldown")
	default:
		v.Alert = pageT(loc, "apply.err.decided")
	}
	s.writeApply(w, r, code, loc, v)
}

// ── the page ────────────────────────────────────────────────────────────────

// applyView is everything applyTmpl draws.
type applyView struct {
	SubscribeTemplate, SubscribeConfig string
	pageView
	Screen string // form · pending · rejected · approved

	Initial, Display, Way string
	FromTrial             bool
	Alert                 string
	AlertBad              bool

	// the form
	Action, ID, Submit      string
	Lead                    string
	Use, Team, Referrer     string
	UseHint                 string
	UseCount                int
	UseCarried              bool
	UseBad, TeamBad, RefBad bool
	Notify                  []notifyOpt
	Editing                 bool
	// NotifyFold: a WeChat sign-in's result goes to that WeChat — one line,
	// the other channel folded under it (T794); NotifyOpen when it is chosen.
	NotifyFold, NotifyOpen bool

	// the status
	Title, When, Waited, Dest string
	Reason, Again             string
	CanAgain, Confirm         bool
	R                         *store.AccessRequest
}

// notifyOpt is one way a result can reach the person.
type notifyOpt struct {
	Value, Title, Sub string
	Checked           bool
	// Addr: the option carries an address field, prefilled with Addr.
	Field   bool
	Addr    string
	AddrBad bool
}

func (s *Server) newApplyView(r *http.Request, loc string, a applicant) *applyView {
	ini := "?"
	if c, _ := utf8.DecodeRuneInString(strings.TrimSpace(a.Display)); c != utf8.RuneError {
		ini = strings.ToUpper(string(c))
	}
	return &applyView{pageView: newPageView(r, loc), Initial: ini, Display: a.Display,
		Way: i18n.Interpolate(pageT(loc, "apply.way"), map[string]string{"way": spacedWord(loc, applyWayWord(loc, a.Kind))})}
}

// spacedWord sets a Latin word apart inside Chinese: 「用 GitHub 登录」.
func spacedWord(loc, w string) string {
	if loc == i18n.ZhCN && w != "" && w[0] < utf8.RuneSelf {
		return " " + w + " "
	}
	return w
}

func applyWayWord(loc, kind string) string {
	if strings.HasPrefix(kind, store.IdentityWeChat) {
		return pageT(loc, "way.wechat")
	}
	return identityWord(loc, kind)
}

func isWeChatKind(kind string) bool { return strings.HasPrefix(kind, store.IdentityWeChat) }

// applyChannels are the ways a result may reach a, the default first.
// WeChat for a WeChat sign-in; otherwise a mail — the address they signed in
// with, or one they give — or only this page. (The 「扫码关注收微信」 code for a
// GitHub / mail sign-in comes with C6's scan.)
func applyChannels(kind string) []string {
	switch {
	case isWeChatKind(kind):
		return []string{store.NotifyWeChat, store.NotifyEmail}
	case kind == store.IdentityEmail:
		return []string{store.NotifyEmail}
	}
	return []string{store.NotifyEmail, store.NotifyPage}
}

// formFrom fills the form: empty, or from prev (an edit, or a new request
// after a refusal carrying the last one's words).
func (v *applyView) formFrom(loc string, a applicant, prev *store.AccessRequest, editing bool) {
	v.Screen, v.Action, v.Editing = "form", ApplyPath, editing
	v.Submit = pageT(loc, "apply.submit")
	channel, addr := "", ""
	if prev != nil && (editing || prev.State == store.RequestRejected) {
		v.Use, v.Team, v.Referrer = prev.Use, prev.Team, prev.Referrer
		channel, addr = prev.NotifyChannel, prev.NotifyAddr
	}
	if editing {
		v.Action, v.ID, v.Submit = ApplyEditPath, prev.ID, pageT(loc, "apply.save")
	}
	if channel == "" && v.FromTrial && isWeChatKind(a.Kind) {
		channel = store.NotifyWeChat
	}
	v.fillNotify(loc, a, channel, addr, false)
	v.finishForm(loc)
}

func (v *applyView) finishForm(loc string) {
	v.Lead = pageT(loc, "apply.lead")
	if v.FromTrial {
		v.Lead = pageT(loc, "apply.lead.trial")
	}
	v.UseCount = utf8.RuneCountInString(v.Use)
	if v.UseHint == "" {
		v.UseHint = pageT(loc, "apply.use.hint")
		if v.UseCarried {
			v.UseHint = pageT(loc, "apply.use.carried")
		}
	}
}

// fillNotify draws the options with channel chosen ("" = the default).
func (v *applyView) fillNotify(loc string, a applicant, channel, addr string, addrBad bool) {
	chs := applyChannels(a.Kind)
	if !hasString(chs, channel) {
		channel = chs[0]
	}
	v.Notify = nil
	v.NotifyFold = isWeChatKind(a.Kind) && len(chs) > 1
	v.NotifyOpen = v.NotifyFold && (channel != store.NotifyWeChat || addrBad)
	for _, ch := range chs {
		o := notifyOpt{Value: ch, Checked: ch == channel}
		switch ch {
		case store.NotifyWeChat:
			o.Title, o.Sub = pageT(loc, "apply.n.wechat"), pageT(loc, "apply.n.wechat.sub")
		case store.NotifyEmail:
			if a.Kind == store.IdentityEmail {
				o.Title = pageT(loc, "apply.n.email") + " " + a.Subject
				o.Sub = pageT(loc, "apply.n.email.own")
			} else {
				o.Title, o.Sub = pageT(loc, "apply.n.email"), pageT(loc, "apply.n.email.sub")
				o.Field = true
				if ch == channel {
					o.Addr, o.AddrBad = addr, addrBad
				}
			}
		case store.NotifyPage:
			o.Title, o.Sub = pageT(loc, "apply.n.page"), pageT(loc, "apply.n.page.sub")
		}
		v.Notify = append(v.Notify, o)
	}
}

// readForm reads and checks a posted form into v (kept for a redraw) and
// the edit it makes; bad when it cannot be taken as it is.
func (v *applyView) readForm(loc string, a applicant, form url.Values) (store.RequestEdit, bool) {
	v.Screen, v.Action, v.Submit = "form", ApplyPath, pageT(loc, "apply.submit")
	if form.Get("id") != "" {
		v.Submit, v.Editing = pageT(loc, "apply.save"), true
	}
	v.Use = strings.TrimSpace(form.Get("use"))
	v.Team = strings.TrimSpace(form.Get("team"))
	v.Referrer = strings.TrimSpace(form.Get("referrer"))
	channel := form.Get("notify")
	addr := store.NormIdentitySubject(store.IdentityEmail, form.Get("email"))
	var problems []string
	// Empty is allowed (T794: one tap from WeChat applies, the words can
	// come later by an edit); a few words are not.
	if n := utf8.RuneCountInString(v.Use); n > 0 && n < applyUseMin {
		v.UseBad = true
		v.UseHint = pageT(loc, "apply.err.short")
	} else if n > applyUseMax {
		v.UseBad = true
		v.UseHint = pageT(loc, "apply.err.long")
	}
	// The use field says its own problem under it; the alert carries the
	// ones that have no line of their own.
	if utf8.RuneCountInString(v.Team) > applyShortMax {
		v.TeamBad = true
		problems = append(problems, pageT(loc, "apply.err.team"))
	}
	if utf8.RuneCountInString(v.Referrer) > applyShortMax {
		v.RefBad = true
		problems = append(problems, pageT(loc, "apply.err.ref"))
	}
	chs := applyChannels(a.Kind)
	if !hasString(chs, channel) {
		channel = chs[0]
	}
	addrBad := false
	switch {
	case channel == store.NotifyEmail && a.Kind == store.IdentityEmail:
		addr = a.Subject
	case channel == store.NotifyEmail && !validEmail(addr):
		addrBad = true
		problems = append(problems, pageT(loc, "apply.err.email"))
	case channel != store.NotifyEmail:
		addr = ""
	}
	v.fillNotify(loc, a, channel, addr, addrBad)
	v.finishForm(loc)
	if len(problems) > 0 {
		v.Alert, v.AlertBad = problems[0], true
	}
	if v.UseBad || len(problems) > 0 {
		return store.RequestEdit{}, true
	}
	return store.RequestEdit{Use: v.Use, Team: v.Team, Referrer: v.Referrer,
		NotifyChannel: channel, NotifyAddr: addr}, false
}

// applyZone is the clock the pages tell time in: Beijing's, said as such in
// English.
var applyZone = time.FixedZone("UTC+8", 8*3600)

func applyWhen(loc string, t time.Time) string {
	t = t.In(applyZone)
	if loc == i18n.ZhCN {
		return t.Format("1 月 2 日 15:04")
	}
	return t.Format("Jan 2, 15:04") + " (UTC+8)"
}

func applyDay(loc string, t time.Time) string {
	t = t.In(applyZone)
	if loc == i18n.ZhCN {
		return t.Format("2006 年 1 月 2 日")
	}
	return t.Format("Jan 2, 2006")
}

// applyWaited is d as 「N 分钟 / 小时 / 天」.
func applyWaited(loc string, d time.Duration) string {
	n, key := int(d.Minutes()), "apply.dur.min"
	switch {
	case d >= 48*time.Hour:
		n, key = int(d.Hours()/24), "apply.dur.day"
	case d >= time.Hour:
		n, key = int(d.Hours()), "apply.dur.hour"
	}
	if n < 1 {
		n = 1
	}
	return i18n.Interpolate(pageT(loc, key), map[string]string{"n": strconv.Itoa(n)})
}

// statusOf fills the page for where req stands.
func (v *applyView) statusOf(loc string, req *store.AccessRequest, now time.Time) {
	v.R = req
	v.When = applyWhen(loc, req.CreatedAt)
	switch req.NotifyChannel {
	case store.NotifyWeChat:
		v.Dest = pageT(loc, "apply.dest.wechat")
	case store.NotifyEmail:
		v.Dest = i18n.Interpolate(pageT(loc, "apply.dest.email"), map[string]string{"addr": req.NotifyAddr})
	default:
		v.Dest = pageT(loc, "apply.dest.page")
	}
	switch req.State {
	case store.RequestApproved:
		v.Screen = "approved"
	case store.RequestRejected:
		v.Screen = "rejected"
		v.When = applyWhen(loc, req.DecidedAt)
		v.Reason = req.Reason
		if now.Before(req.CooldownUntil) {
			days := int(req.CooldownUntil.Sub(req.DecidedAt).Hours()/24 + 0.5)
			v.Again = i18n.Interpolate(pageT(loc, "apply.no.again"),
				map[string]string{"day": applyDay(loc, req.CooldownUntil), "n": strconv.Itoa(days)})
		} else {
			v.CanAgain = true
			v.Again = pageT(loc, "apply.no.now")
		}
	default:
		v.Screen = "pending"
		v.Waited = applyWaited(loc, now.Sub(req.CreatedAt))
	}
}

func (s *Server) writeApply(w http.ResponseWriter, r *http.Request, code int, loc string, v *applyView) {
	entryHeaders(w, loc)
	s.applySubscribeView(r, v)
	if v.SubscribeTemplate != "" {
		w.Header().Set("Content-Security-Policy", strings.Replace(entryCSP, "script-src 'none'", "script-src 'self' https://res.wx.qq.com", 1))
	}
	w.Header().Add("Vary", "Accept-Language, Cookie")
	w.WriteHeader(code)
	if r.Method == http.MethodHead {
		return
	}
	c, err := applyTmpl.Clone()
	if err != nil {
		return
	}
	if err := c.Funcs(pageFuncs(loc)).Execute(w, v); err != nil {
		log.Printf("apply page: %v", err)
	}
}

const (
	clockIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>`
	xIcon     = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/></svg>`
	userIcon  = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="5"/><path d="M20 21a8 8 0 0 0-16 0"/></svg>`
)

// The who-is-asking card, on every screen of the form.
const applyWhoCard = `<div class="who"><span class="av" aria-hidden="true">{{.Initial}}</span><span><div class="n">{{.Display}}</div><div class="m">` + userIcon + `{{.Way}}</div></span><a href="/app/signin">{{t "apply.switch"}}</a></div>`

var applyTmpl = template.Must(template.New("apply").Funcs(pageFuncs(i18n.EN)).Parse(entryHead + `
<title>{{if eq .Screen "form"}}{{t "apply.title"}}{{else}}{{t "apply.mine.title"}}{{end}}</title>
<style>details.fold{margin:0 0 20px}details.fold>summary{cursor:pointer;list-style:none;font-size:14px;font-weight:500;color:var(--muted-foreground)}details.fold>summary::-webkit-details-marker{display:none}details.fold>summary b{font-weight:500;text-decoration:underline;text-underline-offset:3px}details.fold[open]>summary{margin-bottom:12px}details.fold .field:last-child{margin-bottom:0}</style></head><body><div class="page">` + entryTop + `
{{if eq .Screen "form"}}<main class="col lift"><h1>{{if .Editing}}{{t "apply.h1.edit"}}{{else}}{{t "apply.h1"}}{{end}}<span class="dot">.</span></h1><p class="lead">{{.Lead}}</p>
{{if .Alert}}<p class="alert{{if .AlertBad}} bad{{end}}" role="alert">` + alertIcon + `<span>{{.Alert}}</span></p>{{end}}
` + applyWhoCard + `
<form method="post" action="{{.Action}}">{{if .ID}}<input type="hidden" name="id" value="{{.ID}}">{{end}}
<div class="field"><label for="use">{{t "apply.use"}}</label><textarea class="input area{{if .UseBad}} bad{{end}}" id="use" name="use" required minlength="10" maxlength="500" placeholder="{{t "apply.use.ph"}}"{{if .UseBad}} aria-invalid="true"{{end}} aria-describedby="use-hint">{{.Use}}</textarea>
<div class="hint{{if .UseBad}} bad{{end}}" id="use-hint"><span>{{.UseHint}}</span><span>{{.UseCount}}/500</span></div></div>
<details class="fold"{{if or .Team .Referrer .TeamBad .RefBad}} open{{end}}><summary>+ {{t "apply.more"}}</summary>
<div class="field"><label for="team">{{t "apply.team"}}<small>{{t "apply.optional"}}</small></label><input class="input{{if .TeamBad}} bad{{end}}" id="team" name="team" maxlength="80" value="{{.Team}}" placeholder="{{t "apply.team.ph"}}"></div>
<div class="field"><label for="referrer">{{t "apply.ref"}}<small>{{t "apply.optional"}}</small></label><input class="input{{if .RefBad}} bad{{end}}" id="referrer" name="referrer" maxlength="80" value="{{.Referrer}}" placeholder="{{t "apply.ref.ph"}}"></div></details>
{{if .NotifyFold}}<details class="fold"{{if .NotifyOpen}} open{{end}}><summary>{{t "apply.n.line"}} · <b>{{t "apply.n.change"}}</b></summary>{{end}}<fieldset class="field" style="border:0;padding:0;margin:0 0 24px;min-width:0"><legend style="padding:0;margin-bottom:6px;font-size:14px;font-weight:500">{{t "apply.notify"}}</legend><div class="opts" role="radiogroup">
{{range .Notify}}<label class="opt"><input type="radio" name="notify" value="{{.Value}}"{{if .Checked}} checked{{end}}><span class="dot"></span><span class="b">{{.Title}}<div class="s">{{.Sub}}</div>{{if .Field}}<input class="input{{if .AddrBad}} bad{{end}}" type="email" name="email" value="{{.Addr}}" placeholder="you@example.com" autocomplete="email" aria-label="{{$.EmailLabel}}">{{end}}</span></label>
{{end}}</div></fieldset>{{if .NotifyFold}}</details>{{end}}
{{if .Editing}}<div class="twin"><a class="btn outline" href="/apply">{{t "apply.cancel"}}</a><button class="btn primary" type="submit">{{.Submit}}</button></div>{{else}}<button class="btn primary" type="submit">{{.Submit}}</button>{{end}}
</form>
{{if not (or .Editing .FromTrial)}}<p class="fine">{{t "apply.invited.q"}} <a href="/apply?invite=1" style="text-decoration:underline">{{t "apply.invited.go"}}</a></p>{{end}}
<p class="fine">{{t "apply.keep"}}</p></main>
{{else if eq .Screen "pending"}}<main class="col lift" style="padding-top:32px"><div class="tile wait">` + clockIcon + `</div><h1>{{t "apply.pending.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{.PendingLead}}</p>
{{if .SubscribeTemplate}}<div id="review-subscribe" hidden data-config="{{.SubscribeConfig}}" data-request="{{.R.ID}}" data-ok="{{t "apply.sub.ok"}}" data-failed="{{t "apply.sub.failed"}}">
<wx-open-subscribe id="review-subscribe-tag" template="{{.SubscribeTemplate}}"><script type="text/wxtag-template"><style>button{padding:12px 24px;border:1px solid #888;border-radius:24px;background:white;font-size:16px;cursor:pointer}</style><button>{{t "apply.sub.button"}}</button></script></wx-open-subscribe>
<p class="fine" id="review-subscribe-status" role="status">{{t "apply.sub.hint"}}</p></div>
<script src="https://res.wx.qq.com/open/js/jweixin-1.6.0.js" defer></script><script src="/apply/subscribe.js" defer></script>{{end}}
{{if .Alert}}<p class="alert" role="status">` + alertIcon + `<span>{{.Alert}}</span></p>{{end}}
<ol class="steps"><li class="done"><span class="k"></span><span><div class="t">{{t "apply.step.sent"}}</div><div class="s">{{.When}}</div></span></li>
<li class="now"><span class="k"></span><span><div class="t">{{t "apply.step.review"}}</div><div class="s">{{.WaitedLine}}</div></span></li>
<li class="later"><span class="k"></span><span><div class="t">{{.ResultLine}}</div></span></li></ol>
<div class="card">{{if .R.Use}}<p class="label">{{t "apply.you.wrote"}}</p><p class="pre">{{.R.Use}}</p>{{end}}{{if .R.Team}}<p class="label">{{t "apply.team.short"}}</p><p>{{.R.Team}}</p>{{end}}{{if .R.Referrer}}<p class="label">{{t "apply.ref.short"}}</p><p>{{.R.Referrer}}</p>{{end}}</div>
<div class="twin"><a class="btn outline" href="/apply?edit=1">{{t "apply.edit"}}</a><a class="btn ghost" href="/apply?withdraw=1">{{t "apply.withdraw"}}</a></div>
<p class="fine">{{t "apply.pending.fine"}}</p></main>
{{if .Confirm}}<div class="scrim"><div class="dlg" role="alertdialog" aria-modal="true" aria-labelledby="wd-h"><h2 id="wd-h">{{t "apply.wd.h"}}</h2><p>{{t "apply.wd.p"}}</p><div class="twin"><a class="btn outline" href="/apply">{{t "apply.cancel"}}</a><form method="post" action="/apply/withdraw"><input type="hidden" name="id" value="{{.R.ID}}"><button class="btn primary" type="submit">{{t "apply.wd.go"}}</button></form></div></div></div>{{end}}
{{else if eq .Screen "rejected"}}<main class="col"><div class="tile mute">` + xIcon + `</div><h1>{{t "apply.no.h1"}}<span class="dot">.</span></h1>
{{if .Alert}}<p class="alert" role="status">` + alertIcon + `<span>{{.Alert}}</span></p>{{end}}
{{if .Reason}}<p class="lead">{{.ReasonLead}}</p><p class="quote">{{.Reason}}</p>{{else}}<p class="lead">{{.When}}</p>{{end}}
<div class="card"><p class="label">{{t "apply.no.label"}}</p><p>{{.Again}}</p></div>
<div class="stack">{{if .CanAgain}}<a class="btn primary" href="/apply?again=1">{{t "apply.no.go"}}</a>{{end}}<a class="btn outline" href="/">{{t "apply.site"}}</a></div>
<p class="fine">{{t "apply.no.fine"}}</p></main>
{{else}}<main class="col"><div class="tile ok">` + checkIcon + `</div><h1>{{t "apply.ok.h1"}}<span class="dot">.</span></h1>
{{if .Alert}}<p class="alert ok" role="status">` + checkIcon + `<span>{{.Alert}}</span></p>{{end}}
<p class="lead">{{t "apply.ok.lead"}}</p>
<div class="stack"><a class="btn primary" href="/app/signin">{{t "apply.ok.go"}}</a></div></main>
{{end}}</div></body></html>`))

// The lines a status screen composes from several values.
func (v *applyView) PendingLead() string {
	return i18n.Interpolate(pageT(v.Lang, "apply.pending.lead"), map[string]string{"when": v.When, "dest": v.Dest})
}
func (v *applyView) WaitedLine() string {
	return i18n.Interpolate(pageT(v.Lang, "apply.step.waited"), map[string]string{"d": v.Waited})
}
func (v *applyView) ResultLine() string {
	return i18n.Interpolate(pageT(v.Lang, "apply.step.result"), map[string]string{"dest": v.Dest})
}
func (v *applyView) ReasonLead() string {
	return i18n.Interpolate(pageT(v.Lang, "apply.no.lead"), map[string]string{"when": v.When})
}
func (v *applyView) EmailLabel() string { return pageT(v.Lang, "apply.n.email") }

func init() {
	hubSettings[ApplyCooldownKey] = hubSetting{def: "30",
		help: "days a person whose request was turned down waits before asking again (/apply, claude-fleet#4051)",
		check: func(_ *Server, v string) (string, string) {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			if err != nil || n < 0 || n > 365 {
				return "", ApplyCooldownKey + " is a number of days 0–365, or \"\" for the default (30)"
			}
			return strconv.Itoa(n), ""
		}}
	for k, v := range map[string]i18n.Text{
		"apply.title":      {i18n.EN: "Apply · {brand}", i18n.ZhCN: "申请使用 · {brand}"},
		"apply.sub.button": {i18n.EN: "Notify me of the result", i18n.ZhCN: "审批结果通知我"},
		"apply.sub.hint":   {i18n.EN: "Allow one WeChat notification for this request.", i18n.ZhCN: "授权一次，只接收这次申请的审批结果。"},
		"apply.sub.ok":     {i18n.EN: "Enabled: we'll send this result on WeChat.", i18n.ZhCN: "已开启：这次审批结果会通过微信通知你。"},
		"apply.sub.failed": {i18n.EN: "Could not save. Tap again; your existing notification method still works.", i18n.ZhCN: "暂未保存，请再点一次；原有通知方式仍然有效。"},
		"apply.mine.title": {i18n.EN: "My request · {brand}", i18n.ZhCN: "我的申请 · {brand}"},
		"apply.h1":         {i18n.EN: "Apply to use it", i18n.ZhCN: "申请使用"},
		"apply.h1.edit":    {i18n.EN: "Change your request", i18n.ZhCN: "修改申请"},
		"apply.lead": {
			i18n.EN:   "{brand} is open to a limited group for now. Tell us what you want to use it for — we usually answer within one working day.",
			i18n.ZhCN: "{brand} 目前限定开放。说说你想用它做什么，通常 1 个工作日内答复。",
		},
		"apply.lead.trial": {
			i18n.EN:   "Your trial conversation is kept; once you are approved the trial becomes a full account and you carry on in that conversation.",
			i18n.ZhCN: "试用里的对话会一直留着；通过后试用直接转正式，在那段对话里接着聊。",
		},
		"apply.way":          {i18n.EN: "Signed in with {way}", i18n.ZhCN: "用{way}登录"},
		"apply.switch":       {i18n.EN: "Switch account", i18n.ZhCN: "换个账号"},
		"apply.use":          {i18n.EN: "What do you want to use it for", i18n.ZhCN: "你想用它做什么"},
		"apply.use.ph":       {i18n.EN: "For example: a weekly sales dashboard for a five-person ops team — today someone spends half of every Monday stitching spreadsheets.", i18n.ZhCN: "比如：给 5 个人的运营小组做每周销售看板，现在每周一手工拼 Excel 要半天。"},
		"apply.use.hint":     {i18n.EN: "The more concrete, the faster the review", i18n.ZhCN: "说得具体，审核更快"},
		"apply.use.carried":  {i18n.EN: "Carried over from your trial — change it as you like", i18n.ZhCN: "从你的试用里带过来的，可以改"},
		"apply.optional":     {i18n.EN: "optional", i18n.ZhCN: "选填"},
		"apply.more":         {i18n.EN: "Add your team or who sent you (optional)", i18n.ZhCN: "补充团队、推荐人（选填）"},
		"apply.n.line":       {i18n.EN: "We'll tell you on the WeChat you signed in with", i18n.ZhCN: "结果发到你登录用的这个微信"},
		"apply.n.change":     {i18n.EN: "use email instead", i18n.ZhCN: "改用邮箱"},
		"apply.invited.q":    {i18n.EN: "Got an invite link?", i18n.ZhCN: "收到过邀请链接？"},
		"apply.invited.go":   {i18n.EN: "Use it instead", i18n.ZhCN: "用邀请链接进入"},
		"apply.team":         {i18n.EN: "Your team or company", i18n.ZhCN: "你在哪个团队或公司"},
		"apply.team.ph":      {i18n.EN: "For example: an e-commerce company in Hangzhou · ops", i18n.ZhCN: "比如：杭州一家电商公司 · 运营"},
		"apply.team.short":   {i18n.EN: "Team", i18n.ZhCN: "团队"},
		"apply.ref":          {i18n.EN: "Who sent you", i18n.ZhCN: "谁推荐你来的"},
		"apply.ref.ph":       {i18n.EN: "A member's name or WeChat nickname", i18n.ZhCN: "成员的名字或微信昵称"},
		"apply.ref.short":    {i18n.EN: "Referred by", i18n.ZhCN: "推荐人"},
		"apply.notify":       {i18n.EN: "Send the result to", i18n.ZhCN: "结果通知到"},
		"apply.n.wechat":     {i18n.EN: "WeChat", i18n.ZhCN: "微信"},
		"apply.n.wechat.sub": {i18n.EN: "The WeChat you signed in with, through the 二四网络科技 account", i18n.ZhCN: "发到你登录用的这个微信（公众号「二四网络科技」）"},
		"apply.n.email":      {i18n.EN: "Email", i18n.ZhCN: "邮箱"},
		"apply.n.email.own":  {i18n.EN: "The address you signed in with", i18n.ZhCN: "你登录用的这个"},
		"apply.n.email.sub":  {i18n.EN: "We send one mail with the result", i18n.ZhCN: "结果发一封邮件给你"},
		"apply.n.page":       {i18n.EN: "Only this page", i18n.ZhCN: "只在这一页看"},
		"apply.n.page.sub":   {i18n.EN: "Nothing is sent; come back here for the result", i18n.ZhCN: "不发通知，回这一页看结果"},
		"apply.submit":       {i18n.EN: "Send the request", i18n.ZhCN: "提交申请"},
		"apply.save":         {i18n.EN: "Save changes", i18n.ZhCN: "保存修改"},
		"apply.cancel":       {i18n.EN: "Cancel", i18n.ZhCN: "取消"},
		"apply.keep": {
			i18n.EN:   "We keep only your way of signing in, this form and the decision; a request that is not approved is deleted after 180 days.",
			i18n.ZhCN: "我们只保存你的登录方式、这张表和审核结果；没通过的 180 天后删除。",
		},
		"apply.err.short":    {i18n.EN: "Say a little more: what you plan to do with it (at least 10 characters)", i18n.ZhCN: "再多说一点：打算拿它做什么事（至少 10 个字）"},
		"apply.err.long":     {i18n.EN: "Keep it under 500 characters", i18n.ZhCN: "写在 500 字以内"},
		"apply.err.team":     {i18n.EN: "Team or company: 80 characters at most", i18n.ZhCN: "团队或公司最多 80 个字"},
		"apply.err.ref":      {i18n.EN: "Who sent you: 80 characters at most", i18n.ZhCN: "推荐人最多 80 个字"},
		"apply.err.email":    {i18n.EN: "Give an email address for the result, or choose another way", i18n.ZhCN: "填一个收结果的邮箱，或者选别的通知方式"},
		"apply.err.ip":       {i18n.EN: "Too many requests from this network in the last hour. Try again in an hour.", i18n.ZhCN: "这个网络一小时内交的申请太多了，过一小时再试。"},
		"apply.err.pending":  {i18n.EN: "You already have a request waiting — this is it. Change it instead of sending another.", i18n.ZhCN: "你已经有一条申请在审核中，就是这一条；要补充请直接修改。"},
		"apply.err.cooldown": {i18n.EN: "A new request is possible only after the date below.", i18n.ZhCN: "要到下面这个日期以后才能再申请。"},
		"apply.err.decided":  {i18n.EN: "This request has been decided already.", i18n.ZhCN: "这条申请已经有结果了。"},
		"apply.pending.h1":   {i18n.EN: "Your request is under review", i18n.ZhCN: "申请审核中"},
		"apply.pending.lead": {
			i18n.EN:   "Sent {when} · we usually answer within one working day; the result goes to {dest}.",
			i18n.ZhCN: "{when} 提交 · 通常 1 个工作日内答复，结果会发到{dest}。",
		},
		"apply.dest.wechat":  {i18n.EN: "your WeChat", i18n.ZhCN: "你的微信"},
		"apply.dest.email":   {i18n.EN: "{addr}", i18n.ZhCN: "你的邮箱 {addr}"},
		"apply.dest.page":    {i18n.EN: "this page", i18n.ZhCN: "这一页"},
		"apply.step.sent":    {i18n.EN: "Sent", i18n.ZhCN: "已提交"},
		"apply.step.review":  {i18n.EN: "An admin reviews it", i18n.ZhCN: "管理员审核"},
		"apply.step.waited":  {i18n.EN: "In progress · waiting {d}", i18n.ZhCN: "进行中 · 已等 {d}"},
		"apply.step.result":  {i18n.EN: "The result goes to {dest}", i18n.ZhCN: "结果发到{dest}"},
		"apply.dur.min":      {i18n.EN: "{n} min", i18n.ZhCN: "{n} 分钟"},
		"apply.dur.hour":     {i18n.EN: "{n} h", i18n.ZhCN: "{n} 小时"},
		"apply.dur.day":      {i18n.EN: "{n} days", i18n.ZhCN: "{n} 天"},
		"apply.you.wrote":    {i18n.EN: "What you wrote", i18n.ZhCN: "你写的"},
		"apply.edit":         {i18n.EN: "Change it", i18n.ZhCN: "修改申请"},
		"apply.withdraw":     {i18n.EN: "Withdraw", i18n.ZhCN: "撤回申请"},
		"apply.pending.fine": {i18n.EN: "You can close this page; signing in again brings you back here.", i18n.ZhCN: "可以关掉这一页；下次登录会直接回到这里。"},
		"apply.wd.h":         {i18n.EN: "Withdraw this request?", i18n.ZhCN: "撤回这条申请？"},
		"apply.wd.p":         {i18n.EN: "Admins will no longer see it. You can apply again right away.", i18n.ZhCN: "撤回后管理员就看不到它了，你可以马上重新申请。"},
		"apply.wd.go":        {i18n.EN: "Withdraw", i18n.ZhCN: "撤回"},
		"apply.no.h1":        {i18n.EN: "Not approved this time", i18n.ZhCN: "这次没有通过"},
		"apply.no.lead":      {i18n.EN: "{when} · the admin wrote:", i18n.ZhCN: "{when} · 管理员的话："},
		"apply.no.label":     {i18n.EN: "You can apply again", i18n.ZhCN: "可以再申请"},
		"apply.no.again":     {i18n.EN: "After {day} ({n} days)", i18n.ZhCN: "{day}以后（{n} 天）"},
		"apply.no.now":       {i18n.EN: "Now", i18n.ZhCN: "现在就可以"},
		"apply.no.go":        {i18n.EN: "Apply again", i18n.ZhCN: "再申请"},
		"apply.no.fine":      {i18n.EN: "When you apply again you can add to what you wrote; the last request's words come along.", i18n.ZhCN: "再申请时可以补充说明，上一次的内容会带过去。"},
		"apply.site":         {i18n.EN: "Back to the website", i18n.ZhCN: "回到官网"},
		"apply.ok.h1":        {i18n.EN: "You're approved", i18n.ZhCN: "申请通过了"},
		"apply.ok.lead":      {i18n.EN: "Welcome! You are on the list now — sign in the way you did to start.", i18n.ZhCN: "欢迎！你已经在名单上了，用同样的方式登录就能开始用。"},
		"apply.ok.go":        {i18n.EN: "Start", i18n.ZhCN: "开始用"},
	} {
		pageText[k] = v
	}
}
