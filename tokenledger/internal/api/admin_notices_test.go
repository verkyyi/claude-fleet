package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4063 (EPIC #4048 R1): an admin tells every member, or a few,
// one plain sentence — at most three a day, each audited, each copy down the
// notice desk's roads.

type noticeHarness struct {
	*ghHarness
	wb    *fakeWxNotify
	mails chan sentMail
	admin *http.Cookie
}

// newNoticeHarness: ivan the deploy admin signed in; mail on; the service
// account's road with a notice template; three members — one who follows the
// account, one who signs in by mail, one reachable nowhere.
func newNoticeHarness(t *testing.T) *noticeHarness {
	t.Helper()
	wb := newFakeWxNotify(t)
	mails := make(chan sentMail, 16)
	h := newGitHubHarnessWith(t, func(s *Server) {
		fullServer(s)
		s.Email = &EmailAuth{Send: func(_ context.Context, to, subject, body string) error {
			mails <- sentMail{to, subject, body}
			return nil
		}}
		s.WxGW = &WxGateway{URL: wb.srv.URL + "/internal/wx", Token: "gate-secret", APIBase: wb.srv.URL,
			TplNotice: "tpl-notice"}
	}, "ivan")
	_, admin := h.signIn(t, ghAdmin)
	if admin == nil {
		t.Fatal("admin sign-in failed")
	}
	h.srv.FleetPublicURL = "https://fleet.example" // after the sign-in, whose callback it would name
	st := h.srv.Store
	for _, u := range []store.HubUser{
		{PrincipalID: "p:wx", Login: "林晓", Role: store.RoleUser},
		{PrincipalID: "p:mail", Login: "dana", Role: store.RoleUser},
		{PrincipalID: "p:none", Login: "zed", Role: store.RoleUser},
	} {
		if err := st.UpsertHubUser(u); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.SetHubReach(store.HubReach{Owner: "p:wx", Channel: store.ReachWeChatMP, Addr: "o-wx",
		Followed: true, UpdatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := st.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "dana@example.com",
		PrincipalID: "p:mail", VerifiedAt: time.Now(), AddedBy: "test"}); err != nil {
		t.Fatal(err)
	}
	return &noticeHarness{ghHarness: h, wb: wb, mails: mails, admin: admin}
}

func (h *noticeHarness) send(t *testing.T, body map[string]any) (int, []byte) {
	t.Helper()
	return requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminNoticesPath, body)
}

func (h *noticeHarness) list(t *testing.T) adminNoticesView {
	t.Helper()
	st, b := requestsDo(t, h.ghHarness, h.admin, http.MethodGet, AdminNoticesPath, nil)
	if st != http.StatusOK {
		t.Fatalf("GET = %d %s", st, b)
	}
	var v adminNoticesView
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// A member is answered as if there were nothing there, reads and writes.
func TestAdminNotices_MemberGets404(t *testing.T) {
	h, _, user := rolesHarness(t)
	if st, b := requestsDo(t, h, user, http.MethodGet, AdminNoticesPath, nil); st != http.StatusNotFound {
		t.Fatalf("member GET = %d %s", st, b)
	}
	if st, b := requestsDo(t, h, user, http.MethodPost, AdminNoticesPath, map[string]any{"body": "x", "to": "all"}); st != http.StatusNotFound {
		t.Fatalf("member POST = %d %s", st, b)
	}
	if n, _ := h.srv.Store.ServiceNotices(0); len(n) != 0 {
		t.Fatalf("a member's POST wrote %d notices", len(n))
	}
}

// 「全部成员」 expands to everyone on the list (the admin who signed in
// too); a follower gets the template, a mail sign-in the mail, the rest only
// the record — and it is audited.
func TestAdminNotices_AllMembersEachByTheirRoad(t *testing.T) {
	h := newNoticeHarness(t)
	v := h.list(t)
	reach := map[string]string{}
	for _, m := range v.Members {
		reach[m.PrincipalID] = m.Reach
	}
	if reach["p:wx"] != "wechat" || reach["p:mail"] != "email" || reach["p:none"] != "none" {
		t.Fatalf("members = %+v", v.Members)
	}
	st, b := h.send(t, map[string]any{"body": "周六 2 点维护 30 分钟", "link": "https://fleet.example/status", "to": "all"})
	if st != http.StatusCreated {
		t.Fatalf("POST = %d %s", st, b)
	}
	var made noticeRow
	_ = json.Unmarshal(b, &made)
	if made.Audience != store.NoticeAll || len(made.Recipients) != 4 {
		t.Fatalf("made = %+v", made)
	}
	h.srv.notifyPass(context.Background(), time.Now())

	h.wb.mu.Lock()
	if len(h.wb.tpl) != 1 {
		h.wb.mu.Unlock()
		t.Fatalf("templates sent = %d", len(h.wb.tpl))
	}
	got, _ := json.Marshal(h.wb.tpl[0])
	h.wb.mu.Unlock()
	if !strings.Contains(string(got), `"touser":"o-wx"`) || !strings.Contains(string(got), `"template_id":"tpl-notice"`) ||
		!strings.Contains(string(got), `"url":"https://fleet.example/status"`) || !strings.Contains(string(got), `"thing2":{"value":"周六 2 点维护 30 分钟"}`) {
		t.Fatalf("template = %s", got)
	}
	select {
	case m := <-h.mails:
		if m.to != "dana@example.com" || !strings.Contains(m.body, "周六 2 点维护 30 分钟") ||
			!strings.Contains(m.body, "https://fleet.example/status") || !strings.Contains(m.subject, "服务通知") {
			t.Fatalf("mail = %+v", m)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no mail")
	}
	v = h.list(t)
	if len(v.Notices) != 1 || v.Today != 1 || v.Limit != noticeDayMax {
		t.Fatalf("list = %+v", v)
	}
	if d := v.Notices[0].Delivery; d.Sent != 2 || d.Undelivered != 2 || d.Pending != 0 || d.Via[viaTemplate] != 1 || d.Via[viaMail] != 1 {
		t.Fatalf("delivery = %+v", d)
	}
	if n := hubAuditCount(t, h.ghHarness, "notice.send", "ok"); n != 1 {
		t.Fatalf("notice.send audits = %d", n)
	}
}

// A few named members only; one not on the list is refused.
func TestAdminNotices_SomeMembers(t *testing.T) {
	h := newNoticeHarness(t)
	if st, b := h.send(t, map[string]any{"body": "你的额度明天重置", "to": []string{"p:mail", "p:mail"}}); st != http.StatusCreated {
		t.Fatalf("POST = %d %s", st, b)
	}
	if st, _ := h.send(t, map[string]any{"body": "x", "to": []string{"p:stranger"}}); st != http.StatusBadRequest {
		t.Fatalf("a stranger = %d; want 400", st)
	}
	ns, _ := h.srv.Store.ServiceNotices(0)
	if len(ns) != 1 || ns[0].Audience != "some" || strings.Join(ns[0].Recipients, ",") != "p:mail" {
		t.Fatalf("notices = %+v", ns)
	}
	h.srv.notifyPass(context.Background(), time.Now())
	if tpl, _ := h.wb.sent(); tpl != 0 {
		t.Fatalf("a member not named got a template")
	}
}

// Three a day: the fourth is refused, nothing written, the refusal audited.
func TestAdminNotices_DayLimit(t *testing.T) {
	h := newNoticeHarness(t)
	for i := 0; i < noticeDayMax; i++ {
		if st, b := h.send(t, map[string]any{"body": "维护通知", "to": "all"}); st != http.StatusCreated {
			t.Fatalf("notice %d = %d %s", i+1, st, b)
		}
	}
	if st, b := h.send(t, map[string]any{"body": "再来一条", "to": "all"}); st != http.StatusTooManyRequests {
		t.Fatalf("over the limit = %d %s; want 429", st, b)
	}
	if ns, _ := h.srv.Store.ServiceNotices(0); len(ns) != noticeDayMax {
		t.Fatalf("notices = %d", len(ns))
	}
	if n := hubAuditCount(t, h.ghHarness, "notice.send", "denied"); n != 1 {
		t.Fatalf("refusals audited = %d", n)
	}
	// a day later the window has moved
	if _, err := h.srv.Store.DB().Exec(`UPDATE hub_notices SET created_at = created_at - 90000`); err != nil {
		t.Fatal(err)
	}
	if st, b := h.send(t, map[string]any{"body": "第二天", "to": "all"}); st != http.StatusCreated {
		t.Fatalf("next day = %d %s", st, b)
	}
}

// Plain text with at most one https link in its own field.
func TestAdminNotices_PlainTextOnly(t *testing.T) {
	h := newNoticeHarness(t)
	for _, c := range []map[string]any{
		{"body": "", "to": "all"},
		{"body": "看这里 https://evil.example", "to": "all"},
		{"body": "维护", "link": "http://fleet.example", "to": "all"},
		{"body": "维护", "link": "javascript:alert(1)", "to": "all"},
		{"body": strings.Repeat("长", noticeBodyMax+1), "to": "all"},
		{"body": "维护", "to": "everyone"},
		{"body": "维护", "to": []string{}},
	} {
		if st, b := h.send(t, c); st != http.StatusBadRequest {
			t.Errorf("%v = %d %s; want 400", c, st, b)
		}
	}
	if ns, _ := h.srv.Store.ServiceNotices(0); len(ns) != 0 {
		t.Fatalf("a refused notice was written: %+v", ns)
	}
}

// The template's fields follow CCQUOTA_WX_TPL_NOTICE_FIELDS, each within
// what WeChat takes.
func TestAdminNotices_TemplateFields(t *testing.T) {
	sn := &store.ServiceNotice{Body: "本周六下午两点到两点半系统维护，期间会话暂停", CreatedAt: time.Date(2026, 10, 17, 6, 0, 0, 0, time.UTC)}
	s := &Server{WxGW: &WxGateway{TplNoticeFields: "thing5=body, time9=time, bogus, character_string2=link"}}
	m := serviceNoticeMsg(sn, false, "https://fleet.example", s.noticeTplFields())
	if m.Tpl["time9"] != "2026-10-17 14:00" || m.Tpl["character_string2"] != "https://fleet.example/app" ||
		len([]rune(m.Tpl["thing5"])) != 20 || len(m.Tpl) != 3 {
		t.Fatalf("tpl = %+v", m.Tpl)
	}
	s.WxGW.TplNoticeFields = ""
	m = serviceNoticeMsg(sn, true, "", s.noticeTplFields())
	if m.Tpl["thing1"] != clipRunes("ClaudeFleet service notice", 20) {
		t.Fatalf("default tpl = %+v", m.Tpl)
	}
	if _, ok := m.Tpl["thing2"]; !ok || m.Link != "" || !strings.Contains(m.Body, "member of ClaudeFleet") {
		t.Fatalf("english = %+v", m)
	}
}
