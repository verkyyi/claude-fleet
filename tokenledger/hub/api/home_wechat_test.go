package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// T794: the website's front page inside WeChat — the silent authorisation
// comes back to the page, which asks /apply/me who the applicant is and
// offers one tap to apply; the apply form is the page when there is nothing
// to choose.

// A silent start from the front page lands back on it: a member signed in,
// anyone else with the applicant note — never the console or /apply.
func TestWxRelayNextFrontPage(t *testing.T) {
	h := newRelayHarness(t)
	pid := h.addPerson(t, store.IdentityWeChat, "union-lx")
	h.wb.users["open-lx-0123456789abc"] = wxUser{OpenID: "open-lx-0123456789abc", UnionID: "union-lx", Followed: true}
	h.wb.users["open-new-0123456789ab"] = wxUser{OpenID: "open-new-0123456789ab", UnionID: "union-new", Followed: true}

	start := func(b *browser, next string) string {
		t.Helper()
		resp, _ := b.do(http.MethodGet, h.http.URL+"/auth/wechat/start?next="+url.QueryEscape(next), nil)
		u, _ := url.Parse(resp.Header.Get("Location"))
		return strings.Split(u.Query().Get("state"), ".")[1]
	}
	b := newBrowser(t, wechatUA)
	if resp := h.relayBack(t, b, start(b, "/en/"), "open-lx-0123456789abc", "gate-secret", time.Now()); resp.Header.Get("Location") != "/en/" {
		t.Fatalf("member from /en/ → %q", resp.Header.Get("Location"))
	}
	if got, _ := b.session(h.waysHarness); got != pid {
		t.Fatalf("member not signed in (%q)", got)
	}
	b2 := newBrowser(t, wechatUA)
	if resp := h.relayBack(t, b2, start(b2, "/"), "open-new-0123456789ab", "gate-secret", time.Now()); resp.Header.Get("Location") != "/" {
		t.Fatalf("applicant from / → %q", resp.Header.Get("Location"))
	}
	resp, body := b2.do(http.MethodGet, h.http.URL+ApplicantPath, nil)
	var a applicantInfo
	if resp.StatusCode != http.StatusOK || json.Unmarshal([]byte(body), &a) != nil || a.Name != "" || !a.Followed || a.Applied {
		t.Fatalf("/apply/me = %d %s", resp.StatusCode, body)
	}
	// Anywhere else is not a front page: the old landing.
	b3 := newBrowser(t, wechatUA)
	if resp := h.relayBack(t, b3, start(b3, "https://evil.example/"), "open-new-0123456789ab", "gate-secret", time.Now()); resp.Header.Get("Location") != applicantPath {
		t.Fatalf("a foreign next → %q", resp.Header.Get("Location"))
	}
}

func TestHomeReturnOnlyLandings(t *testing.T) {
	for loc, want := range map[string]string{AppPrefix: "/", ApplyPath: "/", AppPrefix + "/signin?e=wechat": AppPrefix + "/signin?e=wechat", TryPagePath: TryPagePath} {
		rec := httptest.NewRecorder()
		w := &homeReturn{ResponseWriter: rec, next: "/"}
		http.Redirect(w, httptest.NewRequest(http.MethodGet, "/", nil), loc, http.StatusFound)
		if got := rec.Header().Get("Location"); got != want {
			t.Fatalf("%s → %s; want %s", loc, got, want)
		}
	}
	if homeNext("//evil") != "" || homeNext("/app") != "" || homeNext("/en/") != "/en/" {
		t.Fatal("homeNext lets a non-front page through")
	}
}

// The form is the page with nothing to choose; one tap with no words
// applies; /apply/me says so after.
func TestApplyOneTap(t *testing.T) {
	h := newGitHubHarness(t)
	ac := newApplyClient(t, h, store.IdentityWeChat, "union-1", "林小满", "")
	_, body := ac.do(http.MethodGet, ApplyPath, nil)
	if !strings.Contains(body, `action="/apply"`) || !strings.Contains(body, "补充团队、推荐人") ||
		!strings.Contains(body, "改用邮箱") || !strings.Contains(body, `value="wechat" checked`) || !strings.Contains(body, "/apply?invite=1") {
		t.Fatalf("/apply for a fresh WeChat applicant is not the form:\n%s", body)
	}
	if _, body := ac.do(http.MethodGet, ApplyPath+"?invite=1", nil); strings.Contains(body, `action="/apply"`) {
		t.Fatal("?invite=1 lost its page")
	}
	if resp, _ := ac.do(http.MethodPost, ApplyPath, url.Values{"use": {"看板"}, "notify": {"wechat"}}); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("two words applied: %d", resp.StatusCode)
	}
	resp, _ := ac.do(http.MethodPost, ApplyPath, url.Values{"notify": {"wechat"}})
	if resp.StatusCode != http.StatusSeeOther {
		t.Fatalf("one tap = %d", resp.StatusCode)
	}
	_, body = ac.do(http.MethodGet, ApplyPath, nil)
	if !strings.Contains(body, "apply?edit=1") || strings.Contains(body, "<p class=\"pre\"></p>") {
		t.Fatalf("after one tap:\n%s", body)
	}
	_, body = ac.do(http.MethodGet, ApplicantPath, nil)
	if !strings.Contains(body, `"applied":true`) || !strings.Contains(body, `"name":"林小满"`) {
		t.Fatalf("/apply/me after = %s", body)
	}
	// No note: nobody.
	if resp, _ := newApplyClient(t, h, "", "", "", "").do(http.MethodGet, ApplicantPath, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no note = %d", resp.StatusCode)
	}
	if applicantName("微信用户·1a2b") != "" || applicantName("WeChat user·1a2b") != "" || applicantName("林小满") != "林小满" {
		t.Fatal("applicantName")
	}
}
