package api

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 名单外那一页 (claude-fleet#4050): GitHub, WeChat and a proven mail the list
// does not name all end the same way — 302 /apply with the applicant note,
// no hub_users row, no principal, no session — and /apply is the page that
// says where they stand, with 申请使用 as its first button (trial off).
func TestNotListedEveryWayLandsOnApply(t *testing.T) {
	h := newWaysHarness(t)
	people := func() int {
		u, err := h.srv.Store.HubUsers()
		if err != nil {
			t.Fatal(err)
		}
		return len(u)
	}
	before := people()

	type way struct {
		name, kind, subject, shown string
		signIn                     func(b *browser) *http.Response
	}
	ways := []way{
		{"github", store.IdentityGitHub, "300", "@mallory", func(b *browser) *http.Response {
			cb, _ := h.signIn(t, ghMallory)
			// The GitHub harness signs in with its own client: carry its cookies.
			b.c.Jar.SetCookies(mustURL(h.http.URL+ApplyPath), cb.Cookies())
			return cb
		}},
		{"wechat", store.IdentityWeChat, "union-lin", "林小满", func(b *browser) *http.Response {
			cb, _ := h.scan(t, b, "c-lin", "union-lin", "林小满")
			return cb
		}},
		{"email", store.IdentityEmail, "chen.ran@example.com", "chen.ran@example.com", func(b *browser) *http.Response {
			h.startMail(t, b, "Chen.Ran@Example.com")
			m := h.mail(t)
			code := mailCodeRE.FindStringSubmatch(m.body)[1]
			resp, _ := b.do(http.MethodPost, h.http.URL+"/auth/email/code", url.Values{"code": {code}})
			return resp
		}},
	}
	for _, w := range ways {
		t.Run(w.name, func(t *testing.T) {
			b := newBrowser(t, "")
			cb := w.signIn(b)
			if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != ApplyPath {
				t.Fatalf("sign-in = %d → %q; want 302 /apply", cb.StatusCode, cb.Header.Get("Location"))
			}
			c := cookieNamed(cb, applicantCookie)
			if c == nil || c.Path != ApplyPath || !c.HttpOnly {
				t.Fatalf("applicant note = %+v", c)
			}
			if cookieNamed(cb, authz.CookieName) != nil {
				t.Fatal("a not-listed sign-in set a session")
			}
			if pid, _ := h.srv.Store.IdentityPrincipal(w.kind, w.subject); pid != "" {
				t.Fatalf("the way now hangs on %s", pid)
			}
			if n := people(); n != before {
				t.Fatalf("hub_users %d → %d", before, n)
			}
			if !hasAudit(h.audit(t), "refused", notListedAudit) {
				t.Errorf("no refused audit row with applicant=1")
			}
			req, _ := http.NewRequest(http.MethodGet, h.http.URL+ApplyPath, nil)
			req.Header.Set("Accept", "text/html")
			req.Header.Set("Accept-Language", "zh-CN")
			req.AddCookie(&http.Cookie{Name: c.Name, Value: c.Value})
			resp, err := noFollow.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			body := readAll(t, resp)
			if resp.StatusCode != http.StatusOK || !strings.Contains(body, "你还不在名单上") ||
				!strings.Contains(body, "目前限定开放") || !strings.Contains(body, w.shown) {
				t.Fatalf("/apply = %d:\n%s", resp.StatusCode, body)
			}
			first := strings.Index(body, `class="btn primary"`)
			if first < 0 || !strings.HasPrefix(body[first:], `class="btn primary" href="/apply?new=1">申请使用`) {
				t.Fatalf("the first button is not 申请使用:\n%s", body)
			}
			if strings.Contains(body, "先试 15 分钟") || !strings.Contains(body, `href="/apply?invite=1"`) ||
				!strings.Contains(body, `href="/app/signin"`) {
				t.Fatalf("buttons:\n%s", body)
			}
		})
	}
}

// With the trial on and not yet tried, 先试 15 分钟 leads and 申请使用 follows;
// ?invite=1 explains the invite link; ?new=1 is the form.
func TestNotListedTrialInviteAndForm(t *testing.T) {
	h := newGitHubHarness(t)
	setHubSetting(t, h.srv, TrialKey, "on")
	ac := newApplyClient(t, h, store.IdentityGitHub, "300", "mallory", "203.0.113.40")
	_, body := ac.do(http.MethodGet, ApplyPath, nil)
	trial, apply := strings.Index(body, `class="btn primary" href="`+TryPagePath+`">先试 15 分钟`), strings.Index(body, `href="/apply?new=1">申请使用`)
	if trial < 0 || apply < trial || !strings.Contains(body, "试用一次 15 分钟或 20 条消息") {
		t.Fatalf("trial on: want 先试 15 分钟 then 申请使用:\n%s", body)
	}
	if _, body := ac.do(http.MethodGet, ApplyPath+"?invite=1", nil); !strings.Contains(body, "打开那条邀请链接就行") ||
		!strings.Contains(body, InvitePath) {
		t.Fatalf("?invite=1:\n%s", body)
	}
	if _, body := ac.do(http.MethodGet, ApplyPath+"?new=1", nil); !strings.Contains(body, `name="use"`) {
		t.Fatalf("?new=1 is not the form:\n%s", body)
	}
	// Asked once: /apply is the request's progress, not this page.
	if resp, _ := ac.do(http.MethodPost, ApplyPath, goodForm()); resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("submit = %d", resp.StatusCode)
	}
	if _, body := ac.do(http.MethodGet, ApplyPath, nil); strings.Contains(body, "你还不在名单上") || !strings.Contains(body, "申请审核中") {
		t.Fatalf("after asking /apply:\n%s", body)
	}
	// English too, for someone else who has not asked.
	en := newApplyClient(t, h, store.IdentityGitHub, "301", "mallory2", "203.0.113.41")
	if _, body := en.do(http.MethodGet, ApplyPath+"?lang=en", nil); !strings.Contains(body, "not on the list yet") ||
		!strings.Contains(body, "this GitHub account hasn") {
		t.Fatalf("English:\n%s", body)
	}
}

// BREAK-IT apply-reaches-app: the note a real not-listed sign-in leaves opens
// nothing but /apply — /app, /v1/me and /admin answer it exactly as they
// answer nobody.
func TestApplicantNoteReachesNothingElse(t *testing.T) {
	h := newGitHubHarness(t)
	cb, sess := h.signIn(t, ghMallory)
	if sess != nil && sess.MaxAge >= 0 {
		t.Fatalf("a session: %+v", sess)
	}
	note := cookieNamed(cb, applicantCookie)
	if note == nil {
		t.Fatal("no applicant note")
	}
	for _, p := range []string{AppPrefix, AppPrefix + "/", "/v1/me", "/admin", "/admin/", "/v1/fleet/sessions", "/v1/chat/conversation"} {
		ask := func(withNote bool) (int, string) {
			req, _ := http.NewRequest(http.MethodGet, h.http.URL+p, nil)
			req.Header.Set("Accept", "text/html")
			if withNote {
				// Sent as if its Path did not keep it to /apply.
				req.AddCookie(&http.Cookie{Name: note.Name, Value: note.Value})
			}
			resp, err := noFollow.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			resp.Body.Close()
			return resp.StatusCode, resp.Header.Get("Location")
		}
		gc, gl := ask(true)
		wc, wl := ask(false)
		if gc != wc || gl != wl {
			t.Errorf("%s with the note = %d → %q; signed out = %d → %q", p, gc, gl, wc, wl)
		}
	}
}

// The real refusals keep their page: a WeChat whose person was removed, an
// invite that cannot be used.
func TestRealRefusalsKeepTheDenyPage(t *testing.T) {
	h := newWaysHarness(t)
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: "union-gone", PrincipalID: pid})
	b := newBrowser(t, "")
	cb, _ := h.scan(t, b, "c-gone", "union-gone", "离开的人")
	if cb.StatusCode != http.StatusForbidden || cookieNamed(cb, applicantCookie) != nil {
		t.Fatalf("removed WeChat = %d, applicant %v; want 403 and no note", cb.StatusCode, cookieNamed(cb, applicantCookie))
	}
	resp, body := newBrowser(t, "").do(http.MethodGet, h.http.URL+InvitePath+"AAAAAAAAAAAAAAAAAAAAAAAAAA", nil)
	if resp.StatusCode != http.StatusForbidden || !strings.Contains(body, "never made this invite") {
		t.Fatalf("unknown invite = %d:\n%s", resp.StatusCode, body)
	}
}
