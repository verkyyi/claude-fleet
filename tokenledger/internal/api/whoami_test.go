package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"testing/fstest"
)

// 页头显示当前登录用户 + 退出登录（claude-fleet#1467）。页头从 /v1/me 一个答案画出来：
// 门口放行时记下走的是哪扇门；GitHub 会话带人名；退出只清入口自己的 cookie。

// GitHub 进来的人：/v1/me 报 github、gh:<id>、用户名，并且有得退。
func TestMe_GitHubSessionNamesThePerson(t *testing.T) {
	h := newHarness(t)
	enablePeople(t, h, pAlice)
	c := personCookie(pAlice, "alice-gh")
	var me Me
	h.rawJSON(t, "/v1/me", map[string]string{"Cookie": c.Name + "=" + c.Value}, &me)
	if me.Via != doorGitHub || me.Person != pAlice || me.Name != "alice-gh" || !me.CanLogout {
		t.Fatalf("/v1/me = %+v; want github / %s / alice-gh / can_logout", me, pAlice)
	}
}

// 运营者的门：令牌不是人，报的是门；只有存成 cookie 的令牌才有得退（bearer 没有 cookie 可清）。
// 没有 fleet 模块的 hub 也要答得了 —— 页头在每台 hub 的首页上。
func TestMe_OperatorDoorsNameTheDoorNotAPerson(t *testing.T) {
	h := newHarness(t)
	var me Me
	h.rawJSON(t, "/v1/me", map[string]string{"Authorization": "Bearer " + viewerToken}, &me)
	if me.Via != doorToken || me.Person != "" || me.Name != "" || me.CanLogout {
		t.Fatalf("bearer 的 /v1/me = %+v; want token，无人，不可退", me)
	}
	h.rawJSON(t, "/v1/me", map[string]string{"Cookie": viewerCookie + "=" + viewerToken}, &me)
	if me.Via != doorToken || !me.CanLogout {
		t.Fatalf("令牌 cookie 的 /v1/me = %+v; want token，可退", me)
	}
	if code := h.raw(t, "/v1/me", map[string]string{"Accept": "application/json"}).StatusCode; code != http.StatusUnauthorized {
		t.Fatalf("没凭据的 /v1/me 回了 %d，want 401", code)
	}
}

// 退出：同源 POST 清掉入口自己的 cookie（会话 + 存着的令牌），303 到退出页；
// 退出页有「重新登录」指向 /signin；之后再访问 /connect 要重新登录。
func TestLogout_ClearsTheHubsCookiesAndShowsTheSignedOutPage(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.UI = fstest.MapFS{
		"connect.html": &fstest.MapFile{Data: []byte("<!doctype html><title>连接</title>")},
		"index.html":   &fstest.MapFile{Data: []byte("<!doctype html><title>dashboard</title>")},
	}
	c := personCookie(pAlice, "alice-gh")

	resp := h.postForm(t, "/logout", map[string]string{"Cookie": c.Name + "=" + c.Value, "Origin": h.http.URL})
	if resp.StatusCode != http.StatusSeeOther || resp.Header.Get("Location") != "/logout" {
		t.Fatalf("POST /logout = %d → %q; want 303 → /logout", resp.StatusCode, resp.Header.Get("Location"))
	}
	cleared := map[string]bool{}
	for _, ck := range resp.Cookies() {
		if ck.Value == "" && ck.MaxAge < 0 {
			cleared[ck.Name] = true
		}
	}
	for _, want := range []string{"ccq_sess", viewerCookie} {
		if !cleared[want] {
			t.Errorf("退出没有清掉 %s（清掉的：%v）", want, cleared)
		}
	}

	resp = h.raw(t, "/logout", nil)
	body := readBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "已退出登录") {
		t.Fatalf("GET /logout = %d %q; want 退出页", resp.StatusCode, body)
	}
	if !strings.Contains(body, `href="/signin"`) {
		t.Errorf("退出页没有指向 /signin 的「重新登录」：%q", body)
	}

	// 没了 cookie 的浏览器再开 /connect：被送去登录，不是页面。
	resp = h.raw(t, "/connect", map[string]string{"Accept": "text/html"})
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/signin" {
		t.Fatalf("退出后 /connect = %d → %q; want 302 → /signin", resp.StatusCode, resp.Header.Get("Location"))
	}
}

// 跨站的 POST 不认：不清 cookie、不跳转。
func TestLogout_RefusesACrossOriginPost(t *testing.T) {
	h := newHarness(t)
	enablePeople(t, h)
	resp := h.postForm(t, "/logout", map[string]string{"Origin": "https://evil.example"})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("跨站 POST /logout = %d; want 403", resp.StatusCode)
	}
	if len(resp.Cookies()) != 0 {
		t.Errorf("拒绝了却还动了 cookie：%v", resp.Cookies())
	}
}

// 不接任何「退出后去哪」参数：不存在开放重定向。
func TestLogout_TakesNoDestination(t *testing.T) {
	h := newHarness(t)
	enablePeople(t, h)
	resp := h.postForm(t, "/logout?next=https://evil.example&rd=https://evil.example", map[string]string{"Origin": h.http.URL})
	if loc := resp.Header.Get("Location"); loc != "/logout" {
		t.Fatalf("带 next 的 POST 跳去了 %q; want /logout", loc)
	}
	resp = h.raw(t, "/logout?next=https://evil.example&return="+url.QueryEscape("https://evil.example"), nil)
	if body := readBody(t, resp); strings.Contains(body, "evil.example") {
		t.Fatalf("退出页把请求里的地址画出来了：%q", body)
	}
}

// 没接 GitHub 登录的 hub：退出页照样有（令牌 cookie 也是入口自己的），「重新登录」回首页。
func TestLogout_WithoutGitHubLinksHome(t *testing.T) {
	h := newHarness(t)
	resp := h.raw(t, "/logout", nil)
	body := readBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `href="/"`) || strings.Contains(body, "/signin") {
		t.Fatalf("无 GitHub 登录的 GET /logout = %d %q; want 200 且 重新登录→/", resp.StatusCode, body)
	}
	if code := h.raw(t, "/logout", map[string]string{"X-Method": "PUT"}).StatusCode; code != http.StatusOK {
		t.Fatalf("GET /logout = %d", code)
	}
}

// postForm sends a form POST that does not follow redirects, so the test reads the
// 303 and its Set-Cookie headers itself.
func (h *harness) postForm(t *testing.T, path string, hdr map[string]string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, strings.NewReader(""))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	c := *h.http.Client()
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// rawJSON reads a JSON route with exactly the headers given, into `into`.
func (h *harness) rawJSON(t *testing.T, path string, hdr map[string]string, into any) {
	t.Helper()
	resp := h.raw(t, path, hdr)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s = %d", path, resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(into); err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
}

func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
