package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet#4053 (EPIC #4048 C5): one way out for a notice — a template
// message, else a customer-service message, else a mail, else the page.

// fakeWxNotify stands in for workbench's /internal/wx/token and the two
// sends a notice uses.
type fakeWxNotify struct {
	mu     sync.Mutex
	srv    *httptest.Server
	down   bool // workbench answers 502
	tplErr int  // errcode template/send answers (0 = sent)
	subErr int
	sub    []map[string]any
	kfErr  int  // errcode custom/send answers
	echo   bool // a refusal's errmsg echoes the request, token and all
	tpl    []map[string]any
	kf     []map[string]any
	tokens int
}

func newFakeWxNotify(t *testing.T) *fakeWxNotify {
	f := &fakeWxNotify{}
	mux := http.NewServeMux()
	mux.HandleFunc("/internal/wx/token", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.down {
			http.Error(w, "upstream says: bad gate "+r.Header.Get("x-internal-token"), http.StatusBadGateway)
			return
		}
		if r.Header.Get("x-internal-token") != "gate-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		f.tokens++
		writeJSON(w, http.StatusOK, map[string]any{"access_token": "wxtok-" + strconv.Itoa(f.tokens),
			"expires_at": time.Now().Add(2 * time.Hour).Unix()})
	})
	send := func(list *[]map[string]any, code *int) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			f.mu.Lock()
			defer f.mu.Unlock()
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			if *code != 0 {
				msg := "refused"
				if f.echo {
					msg = "refused, access_token " + r.URL.Query().Get("access_token") + " rid: x"
				}
				writeJSON(w, http.StatusOK, map[string]any{"errcode": *code, "errmsg": msg})
				return
			}
			*list = append(*list, body)
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 0, "errmsg": "ok"})
		}
	}
	mux.HandleFunc("/cgi-bin/message/template/send", send(&f.tpl, &f.tplErr))
	mux.HandleFunc("/cgi-bin/message/subscribe/bizsend", send(&f.sub, &f.subErr))
	mux.HandleFunc("/cgi-bin/ticket/getticket", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"errcode": 0, "ticket": "test-js-ticket", "expires_in": 7200})
	})
	mux.HandleFunc("/cgi-bin/message/custom/send", send(&f.kf, &f.kfErr))
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeWxNotify) set(fn func(f *fakeWxNotify)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *fakeWxNotify) sent() (tpl, kf int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.tpl), len(f.kf)
}

type notifyHarness struct {
	*waysHarness
	wb *fakeWxNotify
}

// newNotifyHarness: a hub with mail on, the service account's road with
// both templates, and a public address.
func newNotifyHarness(t *testing.T) *notifyHarness {
	h := newWaysHarness(t)
	wb := newFakeWxNotify(t)
	h.srv.WxGW = &WxGateway{URL: wb.srv.URL + "/internal/wx", Token: "gate-secret", APIBase: wb.srv.URL,
		TplReview: "tpl-review", TplNewReq: "tpl-newreq"}
	h.srv.FleetPublicURL = "https://fleet.example"
	return &notifyHarness{waysHarness: h, wb: wb}
}

// applicant files a request as someone not on the list, reachable on the
// service account as openid (followed, last seen at seen) — "" for none.
func (h *notifyHarness) applicant(t *testing.T, id, kind, subject, channel, addr, openid string, followed bool, seen time.Time) *store.AccessRequest {
	t.Helper()
	req, err := h.srv.Store.Requests().Create(store.AccessRequest{ID: id, Kind: kind, Subject: subject, Display: "林晓",
		Use: "给五个人的运营小组做每周销售看板。", NotifyChannel: channel, NotifyAddr: addr, CreatedAt: time.Now().Add(-time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	if openid != "" {
		if err := h.srv.Store.SetHubReach(store.HubReach{Owner: store.ApplicantReachOwner(kind, subject),
			Channel: store.ReachWeChatMP, Addr: openid, Followed: followed, UpdatedAt: seen}); err != nil {
			t.Fatal(err)
		}
	}
	return req
}

// decide decides req as an admin would, and tells them.
func (h *notifyHarness) decide(t *testing.T, id, state, reason string) {
	t.Helper()
	got, err := h.srv.Store.Requests().Decide(id, state, reason, time.Time{}, "gh:100", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	h.srv.notifyResult(got)
}

func (h *notifyHarness) notice(t *testing.T, id string) *store.Notice {
	t.Helper()
	n, err := h.srv.Store.Notice(id)
	if err != nil || n == nil {
		t.Fatalf("notice %s: %v %v", id, n, err)
	}
	return n
}

func auditDetails(t *testing.T, h *notifyHarness, action string) []string {
	t.Helper()
	rows, err := h.srv.Store.DB().Query(`SELECT detail FROM hub_audit WHERE action = ? ORDER BY id`, action)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var d string
		_ = rows.Scan(&d)
		out = append(out, d)
	}
	return out
}

// The roads in order: a template to a follower; with no template, a chat
// message to one seen in the last 48 hours; else a mail; else the page.
func TestNotifyRoadsInOrder(t *testing.T) {
	h := newNotifyHarness(t)
	ctx := context.Background()
	now := time.Now()

	// 1 · a follower, a template ⇒ the template, with the result in it
	h.applicant(t, "rq-1", store.IdentityWeChat, "union-1", store.NotifyWeChat, "", "o-1", true, now)
	h.decide(t, "rq-1", store.RequestApproved, "")
	h.srv.notifyPass(ctx, time.Now())
	if n := h.notice(t, "nt-review-rq-1"); n.State != store.NoticeSent || n.Channel != viaTemplate {
		t.Fatalf("follower: %+v", n)
	}
	h.wb.mu.Lock()
	got := h.wb.tpl[0]
	h.wb.mu.Unlock()
	data, _ := json.Marshal(got)
	if got["touser"] != "o-1" || got["template_id"] != "tpl-review" || got["url"] != "https://fleet.example/apply" ||
		!strings.Contains(string(data), `"thing5":{"value":"已通过"}`) {
		t.Fatalf("template = %s", data)
	}

	// 2 · no template, seen an hour ago ⇒ a customer-service message
	h.srv.WxGW.TplReview = ""
	h.applicant(t, "rq-2", store.IdentityWeChat, "union-2", store.NotifyWeChat, "", "o-2", true, now.Add(-time.Hour))
	h.decide(t, "rq-2", store.RequestRejected, "我们这期只开放给团队用户")
	h.srv.notifyPass(ctx, time.Now())
	if n := h.notice(t, "nt-review-rq-2"); n.State != store.NoticeSent || n.Channel != viaChat {
		t.Fatalf("recent: %+v", n)
	}
	if tpl, kf := h.wb.sent(); tpl != 1 || kf != 1 {
		t.Fatalf("sends = %d template %d chat", tpl, kf)
	}

	// 3 · no template, last seen three days ago, a mail sign-in ⇒ a mail
	h.applicant(t, "rq-3", store.IdentityEmail, "dana@example.com", store.NotifyWeChat, "", "o-3", true, now.Add(-72*time.Hour))
	h.decide(t, "rq-3", store.RequestRejected, "用途和 ClaudeFleet 不太相关")
	h.srv.notifyPass(ctx, time.Now())
	m := h.mail(t)
	if n := h.notice(t, "nt-review-rq-3"); n.State != store.NoticeSent || n.Channel != viaMail ||
		m.to != "dana@example.com" || !strings.Contains(m.body, "用途和 ClaudeFleet 不太相关") ||
		!strings.Contains(m.body, "为什么收到这封信") && !strings.Contains(m.body, "你收到这封信") {
		t.Fatalf("mail road: %+v %+v", n, m)
	}

	// 4 · they chose a mail ⇒ a mail, even though they follow
	h.srv.WxGW.TplReview = "tpl-review"
	h.applicant(t, "rq-4", store.IdentityWeChat, "union-4", store.NotifyEmail, "ops@example.com", "o-4", true, now)
	h.decide(t, "rq-4", store.RequestApproved, "")
	h.srv.notifyPass(ctx, time.Now())
	if m := h.mail(t); m.to != "ops@example.com" || !strings.Contains(m.subject, "通过") {
		t.Fatalf("chose mail: %+v", m)
	}
	if tpl, _ := h.wb.sent(); tpl != 1 {
		t.Fatalf("a mail chooser got a template too (%d)", tpl)
	}

	// 5 · not following, no mail ⇒ the page only, audited
	h.applicant(t, "rq-5", store.IdentityWeChat, "union-5", store.NotifyWeChat, "", "o-5", false, now)
	h.decide(t, "rq-5", store.RequestApproved, "")
	h.srv.notifyPass(ctx, time.Now())
	if n := h.notice(t, "nt-review-rq-5"); n.State != store.NoticeUndelivered {
		t.Fatalf("nowhere: %+v", n)
	}
	// 6 · they asked for the page only ⇒ nothing sent
	h.applicant(t, "rq-6", store.IdentityEmail, "page@example.com", store.NotifyPage, "", "", false, now)
	h.decide(t, "rq-6", store.RequestApproved, "")
	h.srv.notifyPass(ctx, time.Now())
	if n := h.notice(t, "nt-review-rq-6"); n.State != store.NoticeUndelivered {
		t.Fatalf("page only: %+v", n)
	}
	h.noMail(t)
	if got := auditDetails(t, h, "notify.undelivered"); len(got) != 2 {
		t.Fatalf("notify.undelivered = %q", got)
	}
	if got := auditDetails(t, h, "notify.sent"); len(got) != 4 {
		t.Fatalf("notify.sent = %q", got)
	}
}

// 43004: they left the account — the openid is marked, no chat message is
// tried, the mail goes.
func TestNotifyUnfollowedGoesToMail(t *testing.T) {
	h := newNotifyHarness(t)
	h.wb.set(func(f *fakeWxNotify) { f.tplErr = wxUnfollowed })
	h.applicant(t, "rq-u", store.IdentityEmail, "left@example.com", store.NotifyWeChat, "", "o-u", true, time.Now())
	h.decide(t, "rq-u", store.RequestApproved, "")
	h.srv.notifyPass(context.Background(), time.Now())
	if m := h.mail(t); m.to != "left@example.com" {
		t.Fatalf("mail = %+v", m)
	}
	if n := h.notice(t, "nt-review-rq-u"); n.State != store.NoticeSent || n.Channel != viaMail {
		t.Fatalf("notice = %+v", n)
	}
	if _, kf := h.wb.sent(); kf != 0 {
		t.Fatal("a chat message went to someone who left")
	}
	rs, _ := h.srv.Store.HubReachOf(store.ApplicantReachOwner(store.IdentityEmail, "left@example.com"))
	if len(rs) != 1 || rs[0].Followed {
		t.Fatalf("reach after 43004 = %+v", rs)
	}
	if d := auditDetails(t, h, "notify.sent"); len(d) != 1 || !strings.Contains(d[0], "errcode 43004") {
		t.Fatalf("notify.sent = %q", d)
	}
}

// A decision is told once, however often it is pressed.
func TestNotifyResultOnce(t *testing.T) {
	h := newNotifyHarness(t)
	h.applicant(t, "rq-o", store.IdentityWeChat, "union-o", store.NotifyWeChat, "", "o-o", true, time.Now())
	h.decide(t, "rq-o", store.RequestApproved, "")
	got, _ := h.srv.Store.Requests().Get("rq-o")
	h.srv.notifyResult(got)
	h.srv.notifyResult(got)
	h.srv.notifyPass(context.Background(), time.Now())
	h.srv.notifyPass(context.Background(), time.Now())
	if tpl, _ := h.wb.sent(); tpl != 1 {
		t.Fatalf("templates = %d; want 1", tpl)
	}
}

// An admin hears of the first request at once; the next ones in ten minutes
// come as one notice when the window ends.
func TestNotifyGatherWindow(t *testing.T) {
	h := newNotifyHarness(t)
	ctx := context.Background()
	pid, _ := newPersonPrincipal()
	if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "admin", Role: store.RoleAdmin, AddedBy: "test", AddedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.SetHubReach(store.HubReach{Owner: pid, Channel: store.ReachWeChatMP, Addr: "o-admin", Followed: true, UpdatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	file := func(id, who string) {
		req, err := h.srv.Store.Requests().Create(store.AccessRequest{ID: id, Kind: store.IdentityEmail, Subject: who + "@example.com",
			Display: who, Use: "做每周销售看板，周一自动发出来。", CreatedAt: time.Now()})
		if err != nil {
			t.Fatal(err)
		}
		h.srv.notifyAdmins(req)
	}
	file("rq-a", "alpha")
	h.srv.notifyPass(ctx, time.Now())
	if tpl, _ := h.wb.sent(); tpl != 1 {
		t.Fatalf("first request: %d templates", tpl)
	}
	file("rq-b", "bravo")
	file("rq-c", "charlie")
	ns, _ := h.srv.Store.NoticesOf(pid, store.NotifyKindNewReq)
	var waiting []store.Notice
	for _, n := range ns {
		if n.State == store.NoticePending {
			waiting = append(waiting, n)
		}
	}
	if len(ns) != 2 || len(waiting) != 1 || strings.Join(waiting[0].Refs, ",") != "rq-b,rq-c" {
		t.Fatalf("gathered = %+v", ns)
	}
	if wait := time.Until(waiting[0].DueAt); wait < 9*time.Minute || wait > 10*time.Minute {
		t.Fatalf("the gathered notice is due in %s; want the window's end", wait)
	}
	h.srv.notifyPass(ctx, time.Now())
	if tpl, _ := h.wb.sent(); tpl != 1 {
		t.Fatal("the window's notice went before the window ended")
	}
	h.srv.notifyPass(ctx, time.Now().Add(notifyGather))
	h.wb.mu.Lock()
	defer h.wb.mu.Unlock()
	if len(h.wb.tpl) != 2 {
		t.Fatalf("after the window: %d templates", len(h.wb.tpl))
	}
	b, _ := json.Marshal(h.wb.tpl[1])
	if h.wb.tpl[1]["template_id"] != "tpl-newreq" || !strings.Contains(string(b), `"thing2":{"value":"bravo 等 2 人"}`) ||
		!strings.Contains(string(b), `"character_string10":{"value":"2"}`) ||
		h.wb.tpl[1]["url"] != "https://fleet.example/admin/requests/rq-b" {
		t.Fatalf("gathered template = %s", b)
	}
}

// A road that cannot be reached is tried three more times, backing off, each
// try audited; then the notice is given up.
func TestNotifyRetryThenUndelivered(t *testing.T) {
	h := newNotifyHarness(t)
	h.wb.set(func(f *fakeWxNotify) { f.down = true })
	h.applicant(t, "rq-r", store.IdentityWeChat, "union-r", store.NotifyWeChat, "", "o-r", true, time.Now())
	h.decide(t, "rq-r", store.RequestApproved, "")
	at := time.Now().Truncate(time.Second) // the outbox keeps seconds
	for i := 0; i < notifyRetries; i++ {
		h.srv.notifyPass(context.Background(), at)
		n := h.notice(t, "nt-review-rq-r")
		want := notifyBackoff << i
		if n.State != store.NoticePending || n.Attempts != i+1 || n.DueAt.Sub(at) != want {
			t.Fatalf("try %d: %+v (want due in %s)", i+1, n, want)
		}
		at = n.DueAt
	}
	h.srv.notifyPass(context.Background(), at)
	if n := h.notice(t, "nt-review-rq-r"); n.State != store.NoticeUndelivered {
		t.Fatalf("after the retries: %+v", n)
	}
	if r, u := auditDetails(t, h, "notify.retry"), auditDetails(t, h, "notify.undelivered"); len(r) != notifyRetries || len(u) != 1 {
		t.Fatalf("audit: retry %q undelivered %q", r, u)
	}
	// workbench is back: a new decision goes at once
	h.wb.set(func(f *fakeWxNotify) { f.down = false })
	h.applicant(t, "rq-r2", store.IdentityWeChat, "union-r2", store.NotifyWeChat, "", "o-r2", true, time.Now())
	h.decide(t, "rq-r2", store.RequestApproved, "")
	h.srv.notifyPass(context.Background(), time.Now())
	if n := h.notice(t, "nt-review-rq-r2"); n.State != store.NoticeSent {
		t.Fatalf("after recovery: %+v", n)
	}
}

// BREAK-IT notify-leaks-secret: every failure on the way — workbench refusing
// with the gate in its words, WeChat echoing the token, the token going stale,
// the mail server refusing — and neither the gate nor an access token reaches
// a log line, an audit row, the outbox or anything sent.
func TestNotifyLeaksNoSecret(t *testing.T) {
	h := newNotifyHarness(t)
	var logs bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(prev) })
	var mails []sentMail
	var mu sync.Mutex
	failMail := true
	h.srv.Email = &EmailAuth{Send: func(_ context.Context, to, subject, body string) error {
		mu.Lock()
		defer mu.Unlock()
		mails = append(mails, sentMail{to, subject, body})
		if failMail {
			return errors.New("smtp: 554 refused for gate-secret wxtok-1") // a sender that says too much
		}
		return nil
	}}
	ctx := context.Background()
	at := time.Now()
	pass := func() {
		h.srv.notifyPass(ctx, at)
		at = at.Add(5 * time.Minute)
	}
	steps := []func(*fakeWxNotify){
		func(f *fakeWxNotify) { f.down = true },                                                 // 502 with the gate in its body
		func(f *fakeWxNotify) { f.down, f.tplErr, f.kfErr, f.echo = false, 40037, 45015, true }, // refusals echoing the token
		func(f *fakeWxNotify) { f.tplErr, f.kfErr = wxUnfollowed, wxUnfollowed },                // left the account
		func(f *fakeWxNotify) { f.tplErr = 40001 },                                              // a stale token, twice
	}
	for i, step := range steps {
		h.wb.set(step)
		id := "rq-s" + strconv.Itoa(i)
		h.applicant(t, id, store.IdentityEmail, "s"+strconv.Itoa(i)+"@example.com", store.NotifyWeChat, "", "o-s"+strconv.Itoa(i), true, time.Now())
		h.decide(t, id, store.RequestRejected, "这期只开放给团队用户")
		for j := 0; j <= notifyRetries; j++ {
			pass()
		}
	}
	// and a gateway with no workbench at all: the dial error carries the URL
	h.srv.WxGW.URL = "http://127.0.0.1:1/internal/wx"
	h.applicant(t, "rq-s9", store.IdentityEmail, "s9@example.com", store.NotifyWeChat, "", "o-s9", true, time.Now())
	h.decide(t, "rq-s9", store.RequestApproved, "")
	failMail = false
	pass()

	var seen strings.Builder
	seen.WriteString(logs.String())
	rows, err := h.srv.Store.DB().Query(`SELECT actor, action, target, outcome, detail FROM hub_audit`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var a, b, c, d, e string
		_ = rows.Scan(&a, &b, &c, &d, &e)
		seen.WriteString(strings.Join([]string{a, b, c, d, e}, "|") + "\n")
	}
	rows.Close()
	ob, err := h.srv.Store.DB().Query(`SELECT id, kind, owner, email, prefer, lang, refs, state, channel FROM hub_notify_outbox`)
	if err != nil {
		t.Fatal(err)
	}
	for ob.Next() {
		var v [9]string
		_ = ob.Scan(&v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8])
		seen.WriteString(strings.Join(v[:], "|") + "\n")
	}
	ob.Close()
	mu.Lock()
	for _, m := range mails {
		seen.WriteString(m.subject + "\n" + m.body + "\n")
	}
	mu.Unlock()
	h.wb.mu.Lock()
	for _, x := range append(h.wb.tpl, h.wb.kf...) {
		b, _ := json.Marshal(x)
		seen.Write(b)
	}
	h.wb.mu.Unlock()
	all := seen.String()
	if !strings.Contains(all, "notify.retry") || !strings.Contains(all, "errcode 43004") || len(mails) == 0 {
		t.Fatalf("the failures were not exercised:\n%s", all)
	}
	for _, secret := range []string{"gate-secret", "wxtok-"} {
		if strings.Contains(all, secret) {
			i := strings.Index(all, secret)
			t.Fatalf("%q leaked: …%s…", secret, all[max(0, i-200):min(len(all), i+60)])
		}
	}
}

// Through the real doors: /apply tells the admins, approve and reject tell
// the person — once, in the language they asked in.
func TestNotifyFromTheDoors(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	mails := make(chan sentMail, 8)
	h.srv.Email = &EmailAuth{Send: func(_ context.Context, to, subject, body string) error {
		mails <- sentMail{to, subject, body}
		return nil
	}}
	ac := newApplyClient(t, h, store.IdentityGitHub, "4242", "zhouyu-dev", "203.0.113.7")
	if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("submit = %d", resp.StatusCode)
	}
	rs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityGitHub, "4242")
	if len(rs) != 1 {
		t.Fatalf("requests = %d", len(rs))
	}
	id := rs[0].ID
	if l, _ := h.srv.Store.Requests().Lang(id); l != "zh-CN" {
		t.Fatalf("lang = %q", l)
	}
	ns, _ := h.srv.Store.NoticesOf(githubPrincipal(ghAdmin.ID), store.NotifyKindNewReq)
	if len(ns) != 1 || strings.Join(ns[0].Refs, ",") != id {
		t.Fatalf("the admin's notice = %+v", ns)
	}
	for i := 0; i < 2; i++ {
		if st, b := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/"+id+"/approve", map[string]any{}); st != http.StatusOK {
			t.Fatalf("approve = %d %s", st, b)
		}
	}
	n, _ := h.srv.Store.Notice("nt-review-" + id)
	if n == nil || n.Email != "ops@example.com" || n.Prefer != store.NotifyEmail || n.Lang != "zh-CN" {
		t.Fatalf("the result's notice = %+v", n)
	}
	h.srv.notifyPass(context.Background(), time.Now())
	select {
	case m := <-mails:
		if m.to != "ops@example.com" || !strings.Contains(m.body, "你的使用申请已通过") {
			t.Fatalf("mail = %+v", m)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no mail")
	}
	select {
	case m := <-mails:
		t.Fatalf("a second mail: %+v", m)
	default:
	}
}

// claude-fleet#4214: the two category templates' fields, each within what
// WeChat takes — a thing ≤ 20 runes, a character_string ≤ 32 with no
// Chinese, a time with no zone note.
func TestNotifyTemplateFields(t *testing.T) {
	at := time.Date(2026, 10, 14, 1, 2, 0, 0, time.UTC)
	check := func(t *testing.T, tpl map[string]string, want map[string]string) {
		t.Helper()
		if len(tpl) != len(want) {
			t.Fatalf("fields = %v; want %v", tpl, want)
		}
		for k, v := range want {
			if tpl[k] != v {
				t.Fatalf("%s = %q; want %q (all: %v)", k, tpl[k], v, tpl)
			}
		}
		for k, v := range tpl {
			switch {
			case strings.HasPrefix(k, "thing") && utf8.RuneCountInString(v) > 20,
				strings.HasPrefix(k, "character_string") && (len(v) > 32 || !wxCharString(v)):
				t.Fatalf("%s = %q is not what WeChat takes", k, v)
			}
		}
	}
	ok := &store.AccessRequest{ID: "rq-1", Kind: store.IdentityWeChat, Subject: "union-1", Display: "林晓",
		State: store.RequestApproved, DecidedAt: at}
	check(t, reviewMsg(ok, false, "").Tpl, map[string]string{"thing3": "tokenman 使用申请",
		"character_string14": "rq-1", "thing5": "已通过", "time6": "2026-10-14 09:02"})
	no := &store.AccessRequest{ID: "rq-2", Kind: store.IdentityEmail, Subject: "a-very-long-mail-address-for-a-test@example.com",
		Display: "lin", State: store.RequestRejected, Reason: "说明再具体一点", DecidedAt: at}
	check(t, reviewMsg(no, true, "").Tpl, map[string]string{"thing3": "tokenman access",
		"character_string14": "a-very-long-mail-address-for-a-t", "thing5": "Not approved", "time6": "2026-10-14 09:02"})
	mail := &store.AccessRequest{ID: "rq-3", Kind: store.IdentityWeChat, Display: "林晓", NotifyAddr: "lx@example.com",
		State: store.RequestApproved, DecidedAt: at}
	if got := reviewMsg(mail, false, "").Tpl["character_string14"]; got != "lx@example.com" {
		t.Fatalf("account = %q; want the mail address", got)
	}

	one := []store.AccessRequest{{ID: "rq-a", Display: "一个名字特别特别特别特别长的申请人啊啊啊啊", CreatedAt: at}}
	check(t, newReqMsg(one, false, "").Tpl, map[string]string{"thing1": "tokenman",
		"thing2": "一个名字特别特别特别特别长的申请人啊啊…", "time6": "2026-10-14 09:02", "character_string10": "1"})
	three := append(one, store.AccessRequest{ID: "rq-b", Display: "b"}, store.AccessRequest{ID: "rq-c", Display: "c"})
	check(t, newReqMsg(three, false, "").Tpl, map[string]string{"thing1": "tokenman",
		"thing2": "一个名字特别特别特别特… 等 3 人", "time6": "2026-10-14 09:02", "character_string10": "3"})
	check(t, newReqMsg(three, true, "").Tpl, map[string]string{"thing1": "tokenman",
		"thing2": "一个名字特别特别特别特… +2", "time6": "2026-10-14 09:02", "character_string10": "3"})
}

// claude-fleet T805: a trial member's 申请转正 reaches every admin once, on the
// new-request template, tapping through to that person's drawer in 成员; a
// second ask — or one after the ask was cleared — pushes nothing more, and a
// person made a member before it went out is told to nobody.
func TestNotifyTrialUpgrade(t *testing.T) {
	h := newNotifyHarness(t)
	ctx := context.Background()
	now := time.Now()
	admin, _ := newPersonPrincipal()
	for _, u := range []store.HubUser{
		{PrincipalID: admin, Login: "admin", Role: store.RoleAdmin, AddedBy: "test", AddedAt: now},
		{PrincipalID: "gh:42", Login: "bob", Role: store.RoleUser, AddedBy: "test", AddedAt: now},
		{PrincipalID: "gh:43", Login: "carol", Role: store.RoleUser, AddedBy: "test", AddedAt: now},
	} {
		if err := h.srv.Store.UpsertHubUser(u); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.SetHubReach(store.HubReach{Owner: admin, Channel: store.ReachWeChatMP, Addr: "o-admin", Followed: true, UpdatedAt: now}); err != nil {
		t.Fatal(err)
	}
	asked := now.Add(-time.Minute).UTC().Format(time.RFC3339)
	for _, pid := range []string{"gh:42", "gh:43"} {
		setHubSetting(t, h.srv, MemberLimitsPrefix+pid, MemberLimits{Until: now.Add(48 * time.Hour), Tokens: 3_000_000}.String())
		setHubSetting(t, h.srv, MemberUpgradePrefix+pid, asked)
	}
	h.srv.notifyUpgrade("gh:42")
	h.srv.notifyUpgrade("gh:42")
	h.srv.notifyPass(ctx, time.Now())
	setHubSetting(t, h.srv, MemberUpgradePrefix+"gh:42", "")
	h.srv.notifyUpgrade("gh:42")
	h.srv.notifyPass(ctx, time.Now())
	if ns, _ := h.srv.Store.NoticesOf(admin, store.NotifyKindUpgrade); len(ns) != 1 {
		t.Fatalf("the admin's 转正 notices = %+v; want one", ns)
	}
	h.wb.mu.Lock()
	if len(h.wb.tpl) != 1 {
		h.wb.mu.Unlock()
		t.Fatalf("templates sent = %d; want 1", len(h.wb.tpl))
	}
	b, _ := json.Marshal(h.wb.tpl[0])
	if h.wb.tpl[0]["template_id"] != "tpl-newreq" || h.wb.tpl[0]["touser"] != "o-admin" ||
		h.wb.tpl[0]["url"] != "https://fleet.example/admin/people/gh:42" ||
		!strings.Contains(string(b), `"thing2":{"value":"bob · 转正"}`) || !strings.Contains(string(b), `"character_string10":{"value":"1"}`) {
		h.wb.mu.Unlock()
		t.Fatalf("template = %s", b)
	}
	h.wb.mu.Unlock()

	// carol is made a member before her notice goes out: nothing to say
	h.srv.notifyUpgrade("gh:43")
	setHubSetting(t, h.srv, MemberLimitsPrefix+"gh:43", "")
	h.srv.notifyPass(ctx, time.Now())
	if tpl, _ := h.wb.sent(); tpl != 1 {
		t.Fatalf("a member's stale ask was pushed: %d templates", tpl)
	}
	if n := h.notice(t, "nt-upgrade-gh:43-"+admin); n.State != store.NoticeUndelivered {
		t.Fatalf("carol's notice = %+v", n)
	}

	en := upgradeMsg("gh:42", "bob", now, true, "https://fleet.example")
	if en.Subject != "tokenman: bob asks to become a member" || !strings.Contains(en.Text, "https://fleet.example/admin/people/gh:42") {
		t.Fatalf("english = %+v", en)
	}
	for k, v := range en.Tpl {
		if strings.HasPrefix(k, "thing") && utf8.RuneCountInString(v) > 20 {
			t.Fatalf("%s = %q over 20 runes", k, v)
		}
	}
}
