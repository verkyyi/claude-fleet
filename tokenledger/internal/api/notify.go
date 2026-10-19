package api

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// The hub's ONE way to tell someone something about their account
// (claude-fleet#4053, EPIC #4048 C5 · 共同约定 9): a request's result to the
// person who asked, new requests to every admin. Tell writes a notice into
// hub_notify_outbox where the event happens; the notice desk (RunNotify, on
// every replica — a notice is claimed with a lease, so it goes out once) sends
// it down the first road that works:
//
//  1. they follow the service account (an openid in hub_reach, followed) and
//     the kind has a template (CCQUOTA_WX_TPL_REVIEW / _NEWREQ) ⇒ a template
//     message;
//  2. no template — or WeChat refused the template — and they talked to the
//     account in the last 48 hours ⇒ a customer-service message;
//  3. else a mail (CCQUOTA_SMTP_URL): the address the request named, else
//     their email sign-in;
//  4. nothing works ⇒ only the page says it: notify.undelivered.
//
// WeChat's 43004 (they no longer follow) marks the openid unfollowed and goes
// on to the mail. A road that could not be reached (workbench or WeChat down,
// the mail server refusing) is retried three times, 15 s · 30 s · 60 s apart,
// every try audited. Someone who asked for the page only is told nothing.
//
// An admin hears of a new request at once; the ones that come in during the
// next ten minutes reach them as one notice when the window ends
// (store.GatherNotice).
//
// Nothing secret goes out of here (BREAK-IT notify-leaks-secret): the
// workbench gate is wxgw.go's alone, a failure is audited as its errcode at
// most, and every word sent is built from the request itself.
//
// Templates (claude-fleet#4214): two of 「二四网络科技」's category templates —
// a result is 「项目申请审核结果通知」 (申请项目 thing3 · 申请账号
// character_string14 · 审核结果 thing5 · 审核时间 time6), new requests
// 「用户注册申请审核提醒」 (平台名称 thing1 · 用户名称 thing2 · 申请时间 time6 ·
// 待审批数 character_string10). WeChat holds a thing to 20 runes and a
// character_string to 32 of letters, digits and symbols — no Chinese — and a
// time to a bare time: reviewMsg / newReqMsg fill them within that. A refusal
// for a reason has no field; tapping through to /apply shows it.
//
// An admin's service notice (claude-fleet#4063, admin_notices.go) is a third
// kind, notice: one desk row per member, the words read from hub_notices, the
// same roads in the same order; its template is CCQUOTA_WX_TPL_NOTICE, its
// fields named by CCQUOTA_WX_TPL_NOTICE_FIELDS (noticeTplFields).

const (
	// notifyGather is how long an admin's new-request notice gathers.
	notifyGather = 10 * time.Minute
	// notifyRetries is how many times a failed notice is tried again.
	notifyRetries = 3
	// notifyBackoff is the first retry's wait; each next one doubles it.
	notifyBackoff = 15 * time.Second
	// notifyLease is how long a claimed notice is the claimer's.
	notifyLease = time.Minute
	// notifyTick is how often the desk looks for due notices.
	notifyTick = 5 * time.Second
	// notifyChat is how long after the last interaction WeChat still takes a
	// customer-service message.
	notifyChat = 48 * time.Hour
	// notifyActor is the audit trail's actor for a notice.
	notifyActor = "notify"
)

// WeChat's errcodes the desk acts on.
const (
	wxUnfollowed = 43004 // they no longer follow the account
	wxOutOfChat  = 45015 // a customer-service message past the 48-hour window
)

// The roads a notice went by (store.Notice.Channel).
const (
	viaTemplate = "wechat-tpl"
	viaChat     = "wechat-kf"
	viaMail     = "email"
)

// Recipient is who a notice is for.
type Recipient struct {
	// Owner is a principal, or store.ApplicantReachOwner(kind, subject) for
	// someone not on the list: whose hub_reach rows say where.
	Owner string
	// Email is the address to mail, when the request named one.
	Email string
	// Prefer is the road the request chose (store.NotifyWeChat | NotifyEmail |
	// NotifyPage); "" = WeChat first.
	Prefer string
	// Lang is the language to say it in ("" = Chinese).
	Lang string
}

// Fields is what a notice is about.
type Fields struct {
	// Request is the access request.
	Request string
}

// Tell is 共同约定 9's Notify (the name is the svc alert seam's, server.go):
// it writes a notice of kind (store.NotifyKindReview | NotifyKindNewReq)
// for to and wakes the desk. A request's result is written once whoever calls
// it how often; an admin's notice gathers (notifyGather).
func (s *Server) Tell(ctx context.Context, to Recipient, kind string, f Fields) error {
	if s.Store == nil || to.Owner == "" || f.Request == "" {
		return nil
	}
	now := time.Now()
	n := store.Notice{Kind: kind, Owner: to.Owner, Email: to.Email, Prefer: to.Prefer, Lang: to.Lang,
		Refs: []string{f.Request}}
	switch kind {
	case store.NotifyKindReview:
		n.ID = "nt-review-" + f.Request
		if err := s.Store.EnqueueNotice(n, now); err != nil {
			if isDupNotice(s, n.ID) {
				return nil
			}
			return err
		}
	case store.NotifyKindNewReq:
		tok, err := randomToken(9)
		if err != nil {
			return err
		}
		n.ID = "nt-" + tok
		if _, err := s.Store.GatherNotice(n, notifyGather, now); err != nil {
			return err
		}
	default:
		return fmt.Errorf("no notice of kind %q", kind)
	}
	s.notifyKick()
	return nil
}

// isDupNotice: id is written already (the insert lost to a retry).
func isDupNotice(s *Server, id string) bool {
	n, err := s.Store.Notice(id)
	return err == nil && n != nil
}

// notifyResult tells req's person how it was decided.
func (s *Server) notifyResult(req *store.AccessRequest) {
	lang, _ := s.Store.Requests().Lang(req.ID)
	to := Recipient{Owner: store.ApplicantReachOwner(req.Kind, req.Subject), Prefer: req.NotifyChannel, Lang: lang}
	if req.NotifyChannel == store.NotifyEmail {
		to.Email = req.NotifyAddr
	}
	if err := s.Tell(context.Background(), to, store.NotifyKindReview, Fields{Request: req.ID}); err != nil {
		log.Printf("notify %s: %v", req.ID, err)
	}
}

// notifyAdmins tells every admin a request came in.
func (s *Server) notifyAdmins(req *store.AccessRequest) {
	users, err := s.Store.HubUsers()
	if err != nil {
		log.Printf("notify admins of %s: %v", req.ID, err)
		return
	}
	set, _ := s.Store.FleetSettings()
	for _, u := range users {
		if u.Role != roleAdmin {
			continue
		}
		to := Recipient{Owner: u.PrincipalID, Lang: parseLang(set[langSettingKey(u.PrincipalID)])}
		if err := s.Tell(context.Background(), to, store.NotifyKindNewReq, Fields{Request: req.ID}); err != nil {
			log.Printf("notify %s of %s: %v", u.PrincipalID, req.ID, err)
		}
	}
}

// The desk's wake-up, so a notice goes out now rather than at the next tick.
var notifyWakes sync.Map // *Server → chan struct{}

func (s *Server) notifyWake() chan struct{} {
	ch, _ := notifyWakes.LoadOrStore(s, make(chan struct{}, 1))
	return ch.(chan struct{})
}

func (s *Server) notifyKick() {
	select {
	case s.notifyWake() <- struct{}{}:
	default:
	}
}

// RunNotify is the notice desk: every notifyTick, and whenever a notice is
// written here, it sends what is due. No store: returns at once.
func (s *Server) RunNotify(ctx context.Context) {
	if s.Store == nil {
		return
	}
	t := time.NewTicker(notifyTick)
	defer t.Stop()
	wake := s.notifyWake()
	for {
		s.notifyPass(ctx, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-wake:
		}
	}
}

// notifyPass sends every notice due by now that it can claim.
func (s *Server) notifyPass(ctx context.Context, now time.Time) {
	ns, err := s.Store.ClaimNotices(now, notifyLease, 20)
	if err != nil {
		log.Printf("notify: %v", err)
		return
	}
	for _, n := range ns {
		s.deliverNotice(ctx, n, now)
	}
}

// noticeMsg is one notice in words.
type noticeMsg struct {
	Subject, Body string            // a mail
	Text          string            // a customer-service message
	Tpl           map[string]string // a template's values
	Link          string            // where tapping it lands ("" = nowhere)
}

// reachOf is where a notice can go.
type reachOf struct {
	OpenID   string
	Followed bool
	ChatAt   time.Time // their last interaction with the account (the openid's record)
	Email    string
	owner    string // the hub_reach row the openid is on
}

// deliverNotice sends one claimed notice, or puts it back for a retry, or
// gives it up: every outcome audited.
func (s *Server) deliverNotice(ctx context.Context, n store.Notice, now time.Time) {
	about := n.Kind + " " + strings.Join(n.Refs, ",")
	finish := func(state, via, detail string) {
		if err := s.Store.FinishNotice(n.ID, state, via, now); err != nil {
			log.Printf("notify %s: %v", n.ID, err)
		}
		action := "notify.sent"
		if state == store.NoticeUndelivered {
			action = "notify.undelivered"
		}
		_ = s.Store.HubAudit(notifyActor, action, n.Owner, "ok", strings.TrimSpace(about+" · "+detail), now)
	}
	if n.Prefer == store.NotifyPage {
		finish(store.NoticeUndelivered, "", "asked for the page only")
		return
	}
	msg, ok, err := s.noticeMsg(n)
	if err != nil {
		s.retryNotice(n, now, about, []string{"the requests could not be read"})
		return
	}
	if !ok {
		finish(store.NoticeUndelivered, "", "nothing left to say")
		return
	}
	reach, err := s.noticeReach(n)
	if err != nil {
		s.retryNotice(n, now, about, []string{"where to reach them could not be read"})
		return
	}

	var tried []string
	down := false // a road that could not be reached: worth another try
	if n.Prefer != store.NotifyEmail && s.WxGW.ready() && reach.OpenID != "" && reach.Followed {
		chat := true
		if tpl := s.wxTemplate(n.Kind); tpl != "" {
			err := s.WxGW.templateSend(ctx, reach.OpenID, tpl, msg.Link, msg.Tpl)
			if err == nil {
				finish(store.NoticeSent, viaTemplate, viaTemplate)
				return
			}
			c := wxCode(err)
			tried = append(tried, viaTemplate+" "+wxWhy(c))
			switch c {
			case 0:
				down = true
			case wxUnfollowed:
				s.markUnfollowed(reach, now)
				chat = false
			}
		}
		if chat && now.Sub(reach.ChatAt) < notifyChat {
			err := s.WxGW.customSend(ctx, reach.OpenID, msg.Text)
			if err == nil {
				finish(store.NoticeSent, viaChat, strings.Join(append(tried, viaChat), " → "))
				return
			}
			c := wxCode(err)
			tried = append(tried, viaChat+" "+wxWhy(c))
			switch c {
			case 0:
				down = true
			case wxUnfollowed:
				s.markUnfollowed(reach, now)
			}
		}
	}
	if reach.Email != "" && s.Email.ready() {
		if err := s.Email.send(ctx, reach.Email, msg.Subject, msg.Body); err == nil {
			finish(store.NoticeSent, viaMail, strings.Join(append(tried, viaMail), " → "))
			return
		}
		tried = append(tried, viaMail+" refused")
		down = true
	}
	if down && n.Attempts < notifyRetries {
		s.retryNotice(n, now, about, tried)
		return
	}
	if len(tried) == 0 {
		tried = []string{"no way to reach them"}
	}
	finish(store.NoticeUndelivered, "", strings.Join(tried, " → "))
}

// retryNotice puts n back, due after the next backoff, or gives it up after
// the last retry.
func (s *Server) retryNotice(n store.Notice, now time.Time, about string, tried []string) {
	why := strings.Join(tried, " → ")
	if n.Attempts >= notifyRetries {
		if err := s.Store.FinishNotice(n.ID, store.NoticeUndelivered, "", now); err != nil {
			log.Printf("notify %s: %v", n.ID, err)
		}
		_ = s.Store.HubAudit(notifyActor, "notify.undelivered", n.Owner, "ok", about+" · "+why+" · gave up", now)
		return
	}
	wait := notifyBackoff << n.Attempts
	if err := s.Store.RetryNotice(n.ID, n.Attempts+1, now.Add(wait)); err != nil {
		log.Printf("notify %s: %v", n.ID, err)
	}
	_ = s.Store.HubAudit(notifyActor, "notify.retry", n.Owner, "error",
		fmt.Sprintf("%s · %s · try %d again in %s", about, why, n.Attempts+2, wait), now)
}

// wxWhy says a WeChat failure for the audit: its errcode, never its words.
func wxWhy(code int) string {
	if code == 0 {
		return "unreachable"
	}
	return fmt.Sprintf("errcode %d", code)
}

func (s *Server) wxTemplate(kind string) string {
	switch kind {
	case store.NotifyKindNewReq:
		return s.WxGW.TplNewReq
	case store.NotifyKindNotice:
		return s.WxGW.TplNotice
	}
	return s.WxGW.TplReview
}

// markUnfollowed records that the openid's person left the account.
func (s *Server) markUnfollowed(r reachOf, now time.Time) {
	if r.owner == "" {
		return
	}
	if err := s.Store.SetHubReach(store.HubReach{Owner: r.owner, Channel: store.ReachWeChatMP, Addr: r.OpenID,
		Followed: false, UpdatedAt: r.ChatAt}); err != nil {
		log.Printf("notify: unfollowed: %v", err)
	}
}

// noticeReach is where n's owner can be reached: the newest openid of the
// owner (and, for an applicant, of the person their sign-in names now), the
// address the request named, else their email sign-in, else a mail on record.
func (s *Server) noticeReach(n store.Notice) (reachOf, error) {
	var r reachOf
	owners := []string{n.Owner}
	var signinMail string
	if rest, ok := strings.CutPrefix(n.Owner, "applicant:"); ok {
		kind, subject, _ := strings.Cut(rest, ":")
		if kind == store.IdentityEmail {
			signinMail = subject
		}
		pid, err := s.Store.IdentityPrincipal(kind, subject)
		if err != nil {
			return r, err
		}
		if pid != "" {
			owners = append(owners, pid)
		}
	} else {
		ids, err := s.Store.HubIdentities(n.Owner)
		if err != nil {
			return r, err
		}
		for _, id := range ids {
			if id.Kind == store.IdentityEmail {
				signinMail = id.Subject
				break
			}
		}
	}
	var onRecord string
	for _, o := range owners {
		rows, err := s.Store.HubReachOf(o)
		if err != nil {
			return r, err
		}
		for _, x := range rows {
			switch x.Channel {
			case store.ReachWeChatMP:
				if r.OpenID == "" || x.UpdatedAt.After(r.ChatAt) {
					r.OpenID, r.Followed, r.ChatAt, r.owner = x.Addr, x.Followed, x.UpdatedAt, o
				}
			case store.ReachEmail:
				if onRecord == "" {
					onRecord = x.Addr
				}
			}
		}
	}
	r.Email = firstSet(n.Email, signinMail, onRecord)
	return r, nil
}

func firstSet(v ...string) string {
	for _, s := range v {
		if s = strings.TrimSpace(s); s != "" {
			return s
		}
	}
	return ""
}

// noticeMsg puts n into words; false when there is nothing left to say (the
// request was withdrawn, every gathered one decided already).
func (s *Server) noticeMsg(n store.Notice) (noticeMsg, bool, error) {
	en := i18n.Normalize(n.Lang) == i18n.EN && strings.TrimSpace(n.Lang) != ""
	base := strings.TrimRight(s.FleetPublicURL, "/")
	rq := s.Store.Requests()
	switch n.Kind {
	case store.NotifyKindReview:
		if len(n.Refs) == 0 {
			return noticeMsg{}, false, nil
		}
		req, err := rq.Get(n.Refs[0])
		if err != nil {
			return noticeMsg{}, false, err
		}
		if req == nil || (req.State != store.RequestApproved && req.State != store.RequestRejected) {
			return noticeMsg{}, false, nil
		}
		return reviewMsg(req, en, base), true, nil
	case store.NotifyKindNewReq:
		var waiting []store.AccessRequest
		for _, id := range n.Refs {
			req, err := rq.Get(id)
			if err != nil {
				return noticeMsg{}, false, err
			}
			if req != nil && req.State == store.RequestPending {
				waiting = append(waiting, *req)
			}
		}
		if len(waiting) == 0 {
			return noticeMsg{}, false, nil
		}
		return newReqMsg(waiting, en, base), true, nil
	case store.NotifyKindNotice:
		if len(n.Refs) == 0 {
			return noticeMsg{}, false, nil
		}
		sn, err := s.Store.ServiceNotice(n.Refs[0])
		if err != nil {
			return noticeMsg{}, false, err
		}
		if sn == nil {
			return noticeMsg{}, false, nil
		}
		return serviceNoticeMsg(sn, en, base, s.noticeTplFields()), true, nil
	}
	return noticeMsg{}, false, errors.New("no notice of kind " + n.Kind)
}

// beijing is the time the notices say (the service account's people are in
// China); an English notice says so.
var beijing = time.FixedZone("UTC+8", 8*3600)

func noticeTime(t time.Time, en bool) string {
	s := t.In(beijing).Format("2006-01-02 15:04")
	if en {
		s += " (UTC+8)"
	}
	return s
}

// reviewMsg: a request's result.
func reviewMsg(req *store.AccessRequest, en bool, base string) noticeMsg {
	m := noticeMsg{}
	if base != "" {
		m.Link = base + ApplyPath
	}
	when := noticeTime(req.DecidedAt, en)
	ok := req.State == store.RequestApproved
	var head, content, advice, why string
	switch {
	case ok && en:
		head, content, advice = "ClaudeFleet: your request is approved", "ClaudeFleet: your request to use it is approved", "Open ClaudeFleet and start"
	case ok:
		head, content, advice = "ClaudeFleet：申请已通过", "ClaudeFleet：你的使用申请已通过", "打开 ClaudeFleet 开始使用"
	case en:
		head = "ClaudeFleet: your request was not approved"
		content = "ClaudeFleet: your request was not approved: " + req.Reason
		advice = "You may ask again now"
		if !req.CooldownUntil.IsZero() {
			advice = "You may ask again from " + req.CooldownUntil.In(beijing).Format("2006-01-02")
		}
	default:
		head = "ClaudeFleet：申请未通过"
		content = "ClaudeFleet：你的使用申请未通过：" + req.Reason
		advice = "现在就可以再申请"
		if !req.CooldownUntil.IsZero() {
			advice = req.CooldownUntil.In(beijing).Format("2006-01-02") + " 起可以再申请"
		}
	}
	m.Tpl = map[string]string{
		"thing3":             ternary(en, "ClaudeFleet access", "ClaudeFleet 使用申请"),
		"character_string14": wxAccount(req),
		"thing5":             ternary(ok, ternary(en, "Approved", "已通过"), ternary(en, "Not approved", "未通过")),
		"time6":              noticeTime(req.DecidedAt, false),
	}
	m.Subject = head
	var b strings.Builder
	if en {
		b.WriteString(content + "\n\nDecided: " + when + "\n" + advice + ".\n")
		if m.Link != "" {
			b.WriteString("\nYour request: " + m.Link + "\n")
		}
		why = "You got this mail because you asked to use ClaudeFleet and chose to hear the result here."
	} else {
		b.WriteString(content + "\n\n审核时间：" + when + "\n" + advice + "。\n")
		if m.Link != "" {
			b.WriteString("\n你的申请：" + m.Link + "\n")
		}
		why = "你收到这封信，是因为你申请使用 ClaudeFleet 时选了用这个邮箱接收结果。"
	}
	b.WriteString("\n" + why + "\n")
	m.Body = b.String()
	m.Text = content + "\n" + advice
	if m.Link != "" {
		m.Text += "\n" + m.Link
	}
	return m
}

// newReqMsg: requests waiting for an admin, oldest first.
func newReqMsg(waiting []store.AccessRequest, en bool, base string) noticeMsg {
	first := waiting[0]
	m := noticeMsg{}
	if base != "" {
		m.Link = base + AdminPrefix + "/requests/" + first.ID
	}
	name := clipRunes(oneLine(firstSet(first.Display, first.Kind)), 20)
	n := len(waiting)
	var head, content, advice string
	if en {
		head = fmt.Sprintf("ClaudeFleet: %d new request(s) to review", n)
		content = fmt.Sprintf("ClaudeFleet: %d new request(s) to review (%s", n, name)
		if n > 1 {
			content += " and others"
		}
		content += ")"
		advice = "Tap to review it"
	} else {
		head = fmt.Sprintf("ClaudeFleet：%d 条新申请待审核", n)
		content = fmt.Sprintf("ClaudeFleet：%d 条新申请待审核（%s", n, name)
		if n > 1 {
			content += " 等"
		}
		content += "）"
		advice = "点开直接审核"
	}
	who := name
	if n > 1 {
		who = clipRunes(oneLine(firstSet(first.Display, first.Kind)), 12) + ternary(en, fmt.Sprintf(" +%d", n-1), fmt.Sprintf(" 等 %d 人", n))
	}
	m.Tpl = map[string]string{
		"thing1":             "ClaudeFleet",
		"thing2":             clipRunes(who, 20),
		"time6":              noticeTime(first.CreatedAt, false),
		"character_string10": fmt.Sprint(n),
	}
	m.Subject = head
	var b strings.Builder
	for _, r := range waiting {
		b.WriteString("· " + firstSet(r.Display, r.Kind) + " — " + clipRunes(oneLine(r.Use), 80) + "\n")
	}
	if en {
		m.Body = content + "\n\n" + b.String()
		if m.Link != "" {
			m.Body += "\nReview: " + m.Link + "\n"
		}
		m.Body += "\nYou got this mail because you are an admin of ClaudeFleet and someone asked to use it.\n"
	} else {
		m.Body = content + "\n\n" + b.String()
		if m.Link != "" {
			m.Body += "\n去审核：" + m.Link + "\n"
		}
		m.Body += "\n你收到这封信，是因为你是 ClaudeFleet 的管理员，有人提交了使用申请。\n"
	}
	m.Text = content + "\n" + advice
	if m.Link != "" {
		m.Text += "\n" + m.Link
	}
	return m
}

// wxAccount is a request's 申请账号 as a template's character_string can
// carry it: the first of its mail address, its name, its id that is all
// letters, digits and symbols, at most 32.
func wxAccount(req *store.AccessRequest) string {
	var mail string
	switch {
	case strings.Contains(req.NotifyAddr, "@"):
		mail = req.NotifyAddr
	case req.Kind == store.IdentityEmail:
		mail = req.Subject
	}
	for _, c := range []string{mail, req.Display, req.ID} {
		if c = strings.TrimSpace(c); c != "" && wxCharString(c) {
			if len(c) > 32 {
				c = c[:32]
			}
			return c
		}
	}
	return "-"
}

// wxCharString: s is printable ASCII with no space — what a character_string takes.
func wxCharString(s string) bool {
	for _, r := range s {
		if r <= ' ' || r > '~' {
			return false
		}
	}
	return true
}

func ternary(c bool, a, b string) string {
	if c {
		return a
	}
	return b
}

// noticeTplDefault is the service notice template's fields when
// CCQUOTA_WX_TPL_NOTICE_FIELDS is unset.
const noticeTplDefault = "thing1=title,thing2=body,time3=time"

// noticeTplFields reads CCQUOTA_WX_TPL_NOTICE_FIELDS: "<field>=<what>" pairs,
// comma-separated, <what> one of title · body · time · link. A pair it cannot
// read is skipped; none read = the default.
func (s *Server) noticeTplFields() [][2]string {
	var out [][2]string
	for _, src := range []string{s.WxGW.TplNoticeFields, noticeTplDefault} {
		for _, pair := range strings.Split(src, ",") {
			k, v, ok := strings.Cut(strings.TrimSpace(pair), "=")
			k, v = strings.TrimSpace(k), strings.TrimSpace(v)
			switch {
			case !ok || k == "":
			case v == "title" || v == "body" || v == "time" || v == "link":
				out = append(out, [2]string{k, v})
			}
		}
		if len(out) > 0 {
			return out
		}
	}
	return out
}

// serviceNoticeMsg: an admin's service notice, as the admin wrote it.
func serviceNoticeMsg(sn *store.ServiceNotice, en bool, base string, fields [][2]string) noticeMsg {
	m := noticeMsg{Link: sn.Link}
	if m.Link == "" && base != "" {
		m.Link = base + "/app"
	}
	title := ternary(en, "ClaudeFleet service notice", "ClaudeFleet 服务通知")
	when := noticeTime(sn.CreatedAt, en)
	m.Subject = title + ternary(en, ": ", "：") + clipRunes(oneLine(sn.Body), 40)
	m.Tpl = map[string]string{}
	for _, f := range fields {
		var v string
		switch f[1] {
		case "title":
			v = title
		case "body":
			v = oneLine(sn.Body)
		case "time":
			v = noticeTime(sn.CreatedAt, false)
		case "link":
			v = m.Link
		}
		switch {
		case strings.HasPrefix(f[0], "thing"):
			v = clipRunes(v, 20)
		case strings.HasPrefix(f[0], "character_string"):
			if !wxCharString(v) {
				v = "-"
			} else if len(v) > 32 {
				v = v[:32]
			}
		}
		m.Tpl[f[0]] = v
	}
	var b strings.Builder
	b.WriteString(title + "\n\n" + sn.Body + "\n")
	if sn.Link != "" {
		b.WriteString("\n" + sn.Link + "\n")
	}
	if en {
		b.WriteString("\nSent: " + when + "\n")
		b.WriteString("\nYou got this mail because you are a member of ClaudeFleet; it is a service notice about your account.\n")
	} else {
		b.WriteString("\n发送时间：" + when + "\n")
		b.WriteString("\n你收到这封信，是因为你是 ClaudeFleet 的成员；这是和你的账号有关的服务通知。\n")
	}
	m.Body = b.String()
	m.Text = title + "\n" + sn.Body
	if sn.Link != "" {
		m.Text += "\n" + sn.Link
	}
	return m
}
