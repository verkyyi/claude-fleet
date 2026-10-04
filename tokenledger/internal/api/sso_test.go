package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

const (
	ssoTicketKey  = "dev-only-set-ccquota-ticket"
	ssoSessionKey = "dev-only-set-ccquota-session"
	ssoGate       = "https://ai.24haowan.com/kf/authz/enter"
)

func enableSSO(h *harness) {
	h.srv.SSO = &SSO{
		AppID:         "ccquota",
		Slug:          "24haowan",
		TicketSecret:  ssoTicketKey,
		SessionSecret: ssoSessionKey,
		EnterURL:      ssoGate,
		TTL:           8 * time.Hour,
	}
}

// mintTicket signs what the authorization service would sign. It lives in the
// test only: a downstream that can sign is a second issuer.
func mintTicket(t *testing.T, aud, sub string, exp int64) string {
	t.Helper()
	payload := fmt.Sprintf(`{"iss":"kf-context","aud":%q,"sub":%q,"ten":"24haowan","iat":%d,"exp":%d}`,
		aud, sub, exp-90, exp)
	body := base64.RawURLEncoding.EncodeToString([]byte(payload))
	m := hmac.New(sha256.New, []byte(ssoTicketKey))
	m.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// raw makes a request that does NOT follow redirects and carries no cookie jar,
// so each test says exactly which credential it is presenting.
func (h *harness) raw(t *testing.T, path string, hdr map[string]string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
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

func sessionCookie(t *testing.T, resp *http.Response) *http.Cookie {
	t.Helper()
	for _, c := range resp.Cookies() {
		if c.Name == "ccq_sess" {
			return c
		}
	}
	return nil
}

// 一张票换一个会话，会话开得了面板 —— 这就是接进公司企微 SSO 的全部可见效果。
func TestSSO_TicketBecomesASessionThatOpensTheDashboard(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	resp := h.raw(t, "/enter?ticket="+mintTicket(t, "ccquota", "lee", time.Now().Add(time.Minute).Unix()), nil)
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("验票回了 %d，want 302", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != "/" {
		t.Fatalf("落地到 %q，want /", loc)
	}
	c := sessionCookie(t, resp)
	if c == nil {
		t.Fatal("没有种下会话 cookie")
	}
	// host-only：**不写 Domain**。写了就等于把它交给 *.24haowan.com 上的每个 preview
	// 环境和每个别的 app。
	if c.Domain != "" {
		t.Errorf("cookie 带了 Domain=%q，必须是 host-only", c.Domain)
	}
	if !c.HttpOnly {
		t.Error("cookie 不是 HttpOnly")
	}

	// 拿着它、不带任何 token，面板该开。
	resp = h.raw(t, "/v1/accounts", map[string]string{"Cookie": c.Name + "=" + c.Value})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("带会话 cookie 访问回了 %d，want 200", resp.StatusCode)
	}
}

// 签给别的下游站的票，在这里必须是拒绝 —— 一把 HMAC 密钥服务 N 个站，分开它们的只有 aud。
func TestSSO_TicketForAnotherAudienceIsRejected(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	resp := h.raw(t, "/enter?ticket="+mintTicket(t, "aicall", "lee", time.Now().Add(time.Minute).Unix()), nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("别家的票回了 %d，want 401", resp.StatusCode)
	}
	if c := sessionCookie(t, resp); c != nil {
		t.Fatal("拒绝了却还是种了 cookie")
	}
}

func TestSSO_ExpiredTicketIsRejected(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	// 票活 90 秒、验票给 30 秒时钟余量，所以要过期得退得比这更远。
	resp := h.raw(t, "/enter?ticket="+mintTicket(t, "ccquota", "lee", time.Now().Add(-time.Hour).Unix()), nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("过期票回了 %d，want 401", resp.StatusCode)
	}
}

// 没配 SSO 时这个口要**看起来不存在**（404），不是 401 —— 401 会告诉试探的人
// 「这里有个登录口，只是你没带凭据」，而事实是这台 hub 根本没接。
func TestSSO_DisabledLooksAbsentNotUnauthorized(t *testing.T) {
	h := newHarness(t)
	resp := h.raw(t, "/enter?ticket=whatever", nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("未配置时回了 %d，want 404", resp.StatusCode)
	}
}

// 浏览器该被送去登录，API / MCP 客户端该拿到 401 —— 它们做不了跳转，
// 给它们 302 只会换来一页它读不懂的 HTML，而真正的原因（没带凭据）被藏住了。
func TestSSO_BrowserGoesToTheGateWhileApiClientsGet401(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	resp := h.raw(t, "/v1/accounts", map[string]string{"Accept": "text/html,application/xhtml+xml"})
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("浏览器回了 %d，want 302", resp.StatusCode)
	}
	loc := resp.Header.Get("Location")
	if !strings.HasPrefix(loc, ssoGate) || !strings.Contains(loc, "app=ccquota") || !strings.Contains(loc, "to=24haowan") {
		t.Fatalf("跳去了 %q，want 带 app/to 的授权端点", loc)
	}

	resp = h.raw(t, "/v1/accounts", map[string]string{"Accept": "application/json"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("API 客户端回了 %d，want 401", resp.StatusCode)
	}
}

// 票只在 /enter 换得动会话。把它当成万能凭据挂在任何别的口上都必须不认 ——
// 票会出现在 Referer、浏览器历史和日志里，它的短命只在「换完就作废」时才有意义。
func TestSSO_TicketIsNotACredentialAnywhereElse(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	tok := mintTicket(t, "ccquota", "lee", time.Now().Add(time.Minute).Unix())
	resp := h.raw(t, "/v1/accounts?ticket="+tok, map[string]string{"Accept": "application/json"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("票在别的口上被当成凭据了：%d", resp.StatusCode)
	}
	resp = h.raw(t, "/v1/accounts", map[string]string{"Accept": "application/json", "Authorization": "Bearer " + tok})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("票当 Bearer 用被收下了：%d", resp.StatusCode)
	}
}

// viewer token 是接了 SSO 之后**人的应急通道**（企微不可用时）与机器路径（MCP / agent）
// 唯一的凭据，接 SSO 不能把它关掉。
func TestSSO_ViewerTokenKeepsWorkingAsTheFallback(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	resp := h.raw(t, "/v1/accounts", map[string]string{"Authorization": "Bearer " + viewerToken})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("带 viewer token 回了 %d，want 200", resp.StatusCode)
	}
}

// 会话 cookie 是本站签的，换一把密钥就该验不过 —— 否则「谁签的」这件事没有意义。
func TestSSO_SessionCookieFromAnotherKeyIsRejected(t *testing.T) {
	h := newHarness(t)
	enableSSO(h)

	resp := h.raw(t, "/enter?ticket="+mintTicket(t, "ccquota", "lee", time.Now().Add(time.Minute).Unix()), nil)
	c := sessionCookie(t, resp)
	if c == nil {
		t.Fatal("没有种下会话 cookie")
	}
	h.srv.SSO.SessionSecret = "dev-only-set-rotated-session-key"
	resp = h.raw(t, "/v1/accounts", map[string]string{
		"Accept": "application/json",
		"Cookie": c.Name + "=" + c.Value,
	})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("换密钥后旧 cookie 仍被放行：%d", resp.StatusCode)
	}
}
