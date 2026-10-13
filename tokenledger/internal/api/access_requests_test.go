package api

import (
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4051 (EPIC #4048 C3): /apply is the form until something is
// waiting, then where it stands; one pending request per sign-in.

// applyClient is one browser holding an applicant note, coming from ip.
type applyClient struct {
	t  *testing.T
	h  *ghHarness
	c  *http.Client
	ip string
}

func newApplyClient(t *testing.T, h *ghHarness, kind, subject, display, ip string) *applyClient {
	t.Helper()
	jar, _ := cookiejar.New(nil)
	ac := &applyClient{t: t, h: h, ip: ip, c: &http.Client{Jar: jar,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	if kind != "" {
		rec := httptest.NewRecorder()
		h.srv.issueApplicant(rec, httptest.NewRequest(http.MethodGet, "/", nil), kind, subject, display)
		u, _ := url.Parse(h.http.URL + ApplyPath)
		jar.SetCookies(u, rec.Result().Cookies())
	}
	return ac
}

func (ac *applyClient) do(method, p string, form url.Values) (*http.Response, string) {
	ac.t.Helper()
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, _ := http.NewRequest(method, ac.h.http.URL+p, body)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	req.Header.Set("Accept", "text/html")
	req.Header.Set("Accept-Language", "zh-CN")
	if ac.ip != "" {
		req.Header.Set("X-Forwarded-For", ac.ip)
	}
	resp, err := ac.c.Do(req)
	if err != nil {
		ac.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func goodForm() url.Values {
	return url.Values{"use": {"给五个人的运营小组做每周销售看板，周一自动发出来。"}, "team": {"杭州一家电商公司"},
		"notify": {"email"}, "email": {"ops@example.com"}}
}

// Nobody signed in and no applicant note ⇒ sign in first; a member ⇒ /app.
func TestApplyWhoMayOpen(t *testing.T) {
	h := newGitHubHarness(t)
	anon := newApplyClient(t, h, "", "", "", "")
	for _, p := range []string{ApplyPath, ApplyPath + "?edit=1"} {
		resp, _ := anon.do(http.MethodGet, p, nil)
		if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/app/signin?next=/apply" {
			t.Fatalf("GET %s signed out = %d → %q; want 302 /app/signin?next=/apply", p, resp.StatusCode, resp.Header.Get("Location"))
		}
	}
	if resp, _ := anon.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther ||
		!strings.HasPrefix(resp.Header.Get("Location"), "/app/signin") {
		t.Fatalf("POST signed out = %d → %q", resp.StatusCode, resp.Header.Get("Location"))
	}

	// A forged / other-key note is no note.
	jar, _ := cookiejar.New(nil)
	u, _ := url.Parse(h.http.URL + ApplyPath)
	jar.SetCookies(u, []*http.Cookie{{Name: applicantCookie, Value: "eyJrIjoiZ2l0aHViIn0.AAAA", Path: ApplyPath}})
	forged := &applyClient{t: t, h: h, c: &http.Client{Jar: jar, CheckRedirect: anon.c.CheckRedirect}}
	if resp, _ := forged.do(http.MethodGet, ApplyPath, nil); resp.StatusCode != http.StatusFound {
		t.Fatalf("a forged note opened /apply: %d", resp.StatusCode)
	}

	member := fakeGHUser{ID: 501, Login: "mia"}
	h.addUser(t, member)
	_, sess := h.signIn(t, member)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+ApplyPath, nil)
	req.AddCookie(sess)
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != AppPrefix {
		t.Fatalf("a member at /apply = %d → %q; want 302 /app", resp.StatusCode, resp.Header.Get("Location"))
	}
}

// The applicant note is read at /apply only: its cookie path keeps it off
// every other route, and holding it opens nothing there.
func TestApplicantNoteOpensNothingElse(t *testing.T) {
	h := newGitHubHarness(t)
	rec := httptest.NewRecorder()
	h.srv.issueApplicant(rec, httptest.NewRequest(http.MethodGet, "/", nil), store.IdentityGitHub, "777", "zoe")
	c := cookieNamed(rec.Result(), applicantCookie)
	if c == nil || c.Path != ApplyPath || !c.HttpOnly || c.MaxAge != int(applicantTTL.Seconds()) {
		t.Fatalf("applicant cookie = %+v", c)
	}
	for _, p := range []string{"/v1/me", AppPrefix, "/v1/fleet/users"} {
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+p, nil)
		req.Header.Set("Accept", "application/json")
		req.AddCookie(&http.Cookie{Name: c.Name, Value: c.Value})
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			t.Errorf("GET %s with only the applicant note = 200", p)
		}
	}
}

// Submit → the status page; a second submit is 409 and shows the first;
// edit changes it; withdraw frees the way for a new one.
func TestApplySubmitEditWithdraw(t *testing.T) {
	h := newGitHubHarness(t)
	ac := newApplyClient(t, h, store.IdentityGitHub, "4242", "zhouyu-dev", "203.0.113.7")

	resp, body := ac.do(http.MethodGet, ApplyPath, nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `action="/apply"`) || !strings.Contains(body, "zhouyu-dev") ||
		!strings.Contains(body, `name="use"`) || !strings.Contains(body, `value="email" checked`) {
		t.Fatalf("empty /apply = %d, want the form for zhouyu-dev with email first:\n%s", resp.StatusCode, body)
	}
	if csp := resp.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "script-src 'none'") {
		t.Errorf("CSP = %q", csp)
	}

	// Too short, a bad address: the form again, 400, nothing stored.
	bad := goodForm()
	bad.Set("use", "试试")
	if resp, body := ac.do(http.MethodPost, ApplyPath, bad); resp.StatusCode != http.StatusBadRequest ||
		!strings.Contains(body, "至少 10 个字") || !strings.Contains(body, "2/500") {
		t.Fatalf("short use = %d:\n%s", resp.StatusCode, body)
	}
	bad = goodForm()
	bad.Set("email", "not-an-address")
	if resp, _ := ac.do(http.MethodPost, ApplyPath, bad); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad address = %d", resp.StatusCode)
	}
	bad = goodForm()
	bad.Set("team", strings.Repeat("团", 81))
	if resp, _ := ac.do(http.MethodPost, ApplyPath, bad); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("81-character team = %d", resp.StatusCode)
	}
	if rs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityGitHub, "4242"); len(rs) != 0 {
		t.Fatalf("a refused form stored %d requests", len(rs))
	}

	if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther || resp.Header.Get("Location") != ApplyPath {
		t.Fatalf("submit = %d → %q; want 303 /apply", resp.StatusCode, resp.Header.Get("Location"))
	}
	resp, body = ac.do(http.MethodGet, ApplyPath, nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "申请审核中") || !strings.Contains(body, "运营小组") ||
		!strings.Contains(body, "ops@example.com") || strings.Contains(body, `name="use"`) {
		t.Fatalf("after submit /apply = %d, want the status page:\n%s", resp.StatusCode, body)
	}

	// The same person again: 409 and the existing one, still one pending.
	again := goodForm()
	again.Set("use", "另一件完全不同的事情，想再交一条申请看看")
	resp, body = ac.do(http.MethodPost, ApplyPath, again)
	if resp.StatusCode != http.StatusConflict || !strings.Contains(body, "运营小组") || !strings.Contains(body, "已经有一条申请在审核中") {
		t.Fatalf("second submit = %d, want 409 with the first shown:\n%s", resp.StatusCode, body)
	}
	rs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityGitHub, "4242")
	if len(rs) != 1 || rs[0].State != store.RequestPending {
		t.Fatalf("requests = %+v; want one pending", rs)
	}
	id := rs[0].ID

	// Edit: the form carries the request, the change lands.
	if _, body := ac.do(http.MethodGet, ApplyPath+"?edit=1", nil); !strings.Contains(body, `action="/apply/edit"`) ||
		!strings.Contains(body, `value="`+id+`"`) || !strings.Contains(body, "运营小组") {
		t.Fatalf("?edit=1 is not the filled form:\n%s", body)
	}
	ed := goodForm()
	ed.Set("id", id)
	ed.Set("use", "改一下：给运营小组做每天的销售看板，早上九点自动发出来。")
	ed.Set("notify", "page")
	if resp, _ := ac.do(http.MethodPost, ApplyEditPath, ed); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("edit = %d", resp.StatusCode)
	}
	got, _ := h.srv.Store.Requests().Get(id)
	if got.Use != ed.Get("use") || got.NotifyChannel != store.NotifyPage || got.NotifyAddr != "" || got.State != store.RequestPending {
		t.Fatalf("edited = %+v", got)
	}
	// Someone else's id is not theirs to edit.
	other := newApplyClient(t, h, store.IdentityEmail, "x@example.com", "x@example.com", "203.0.113.8")
	if resp, _ := other.do(http.MethodPost, ApplyEditPath, ed); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("editing another's request = %d; want 404", resp.StatusCode)
	}
	if resp, _ := other.do(http.MethodPost, ApplyWithdrawPath, url.Values{"id": {id}}); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("withdrawing another's request = %d; want 404", resp.StatusCode)
	}

	// Withdraw: the confirmation, then gone, then a new one goes in.
	if _, body := ac.do(http.MethodGet, ApplyPath+"?withdraw=1", nil); !strings.Contains(body, `action="/apply/withdraw"`) ||
		!strings.Contains(body, "撤回这条申请") {
		t.Fatalf("?withdraw=1 has no confirmation:\n%s", body)
	}
	if resp, _ := ac.do(http.MethodPost, ApplyWithdrawPath, url.Values{"id": {id}}); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("withdraw = %d", resp.StatusCode)
	}
	if _, body := ac.do(http.MethodGet, ApplyPath, nil); !strings.Contains(body, `action="/apply"`) {
		t.Fatalf("after withdrawing /apply is not the form:\n%s", body)
	}
	if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("a new request after withdrawing = %d", resp.StatusCode)
	}
	log := h.audit(t)
	for _, act := range []string{"request.submit", "request.edit", "request.withdraw"} {
		found := false
		for _, e := range log {
			found = found || (e.Action == act && e.Outcome == "ok")
		}
		if !found {
			t.Errorf("no %s ok in the audit", act)
		}
	}
}

// A refusal shows the admin's words and the date a new request may go in;
// inside it nothing can be submitted, after it the form comes back with the
// last words carried.
func TestApplyCooldown(t *testing.T) {
	h := newGitHubHarness(t)
	ac := newApplyClient(t, h, store.IdentityEmail, "chen.ran@qq.com", "chen.ran@qq.com", "198.51.100.4")
	if _, body := ac.do(http.MethodGet, ApplyPath, nil); !strings.Contains(body, "chen.ran@qq.com") ||
		!strings.Contains(body, `value="email" checked`) || strings.Contains(body, `name="email"`) {
		t.Fatalf("a mail sign-in's form should default to their own address:\n%s", body)
	}
	if resp, _ := ac.do(http.MethodPost, ApplyPath, url.Values{"use": {"给运营小组做每周销售看板，周一自动发出来"}}); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("submit = %d", resp.StatusCode)
	}
	rs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityEmail, "chen.ran@qq.com")
	if len(rs) != 1 || rs[0].NotifyChannel != store.NotifyEmail || rs[0].NotifyAddr != "chen.ran@qq.com" {
		t.Fatalf("stored = %+v", rs)
	}
	now := time.Now()
	if _, err := h.srv.Store.Requests().Decide(rs[0].ID, store.RequestRejected, "目前只对团队开放。",
		now.Add(h.srv.applyCooldown()), "gh:1", now); err != nil {
		t.Fatal(err)
	}
	resp, body := ac.do(http.MethodGet, ApplyPath+"?again=1", nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "这次没有通过") || !strings.Contains(body, "目前只对团队开放") ||
		!strings.Contains(body, "30 天") || strings.Contains(body, `name="use"`) {
		t.Fatalf("refused /apply = %d:\n%s", resp.StatusCode, body)
	}
	if resp, _ := ac.do(http.MethodPost, ApplyPath, url.Values{"use": {"再交一次，这次写得更清楚一些"}}); resp.StatusCode != http.StatusConflict {
		t.Fatalf("submit inside the cooldown = %d; want 409", resp.StatusCode)
	}
	// The cooldown over: the form, carrying the last words.
	if _, err := h.srv.Store.Requests().Create(store.AccessRequest{ID: "probe", Kind: store.IdentityEmail,
		Subject: "chen.ran@qq.com", CreatedAt: now.Add(31 * 24 * time.Hour)}); err != nil {
		t.Fatalf("after the cooldown the store still refuses: %v", err)
	}
}

// One address may send applyPerIPHour requests an hour, whoever they are.
func TestApplyPerAddressLimit(t *testing.T) {
	h := newGitHubHarness(t)
	for i := 0; i < applyPerIPHour; i++ {
		ac := newApplyClient(t, h, store.IdentityGitHub, "9"+strings.Repeat("0", i), "p", "192.0.2.10")
		if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther {
			t.Fatalf("request %d = %d", i+1, resp.StatusCode)
		}
	}
	ac := newApplyClient(t, h, store.IdentityGitHub, "9999999", "p", "192.0.2.10")
	if resp, body := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusTooManyRequests ||
		!strings.Contains(body, "过一小时再试") {
		t.Fatalf("request %d from one address = %d", applyPerIPHour+1, resp.StatusCode)
	}
	ac = newApplyClient(t, h, store.IdentityGitHub, "9999999", "p", "192.0.2.11")
	if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("another address = %d", resp.StatusCode)
	}
}

// A WeChat sign-in defaults to WeChat; the English page is English.
func TestApplyWeChatDefaultAndEnglish(t *testing.T) {
	h := newGitHubHarness(t)
	ac := newApplyClient(t, h, store.IdentityWeChat, "union-1", "林小满", "")
	_, body := ac.do(http.MethodGet, ApplyPath+"?lang=en", nil)
	if !strings.Contains(body, `value="wechat" checked`) || !strings.Contains(body, "Apply to use it") ||
		!strings.Contains(body, `<span class="av" aria-hidden="true">林</span>`) {
		t.Fatalf("WeChat applicant, English:\n%s", body)
	}
}

// The approved person sees it, and the way back in.
func TestApplyApprovedPage(t *testing.T) {
	h := newGitHubHarness(t)
	ac := newApplyClient(t, h, store.IdentityGitHub, "31337", "amy", "203.0.113.20")
	if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("submit = %d", resp.StatusCode)
	}
	rs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityGitHub, "31337")
	if _, err := h.srv.Store.Requests().Decide(rs[0].ID, store.RequestApproved, "", time.Time{}, "gh:1", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, body := ac.do(http.MethodGet, ApplyPath, nil); !strings.Contains(body, "申请通过了") || !strings.Contains(body, `href="/app/signin"`) {
		t.Fatalf("approved /apply:\n%s", body)
	}
	if resp, _ := ac.do(http.MethodPost, ApplyWithdrawPath, url.Values{"id": {rs[0].ID}}); resp.StatusCode != http.StatusConflict {
		t.Fatalf("withdrawing a decided request = %d; want 409", resp.StatusCode)
	}
}
