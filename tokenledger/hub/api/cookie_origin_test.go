package api

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The rule a write authenticated by the session cookie is held to.
func TestCookieWriteOK(t *testing.T) {
	const self = "hub.example.com"
	for _, c := range []struct {
		name, method, origin, referer, fetchSite, ctype string
		ok                                              bool
	}{
		{"a read from anywhere", "GET", "https://other.example.com", "", "cross-site", "", true},
		{"the console's fetch", "POST", "https://" + self, "", "same-origin", "application/json", true},
		{"a form on the hub's page", "POST", "https://" + self, "", "same-origin", "application/x-www-form-urlencoded", true},
		{"the no-referrer sign-out form", "POST", "null", "", "same-origin", "application/x-www-form-urlencoded", true},
		{"a CLI holding the cookie", "PUT", "", "", "", "application/json", true},
		{"a CLI form post", "POST", "", "", "", "application/x-www-form-urlencoded", true},
		{"JSON behind a proxy that changes Host", "POST", "https://public.example.com", "", "same-origin", "application/json", true},
		{"an older browser, same host by Origin", "DELETE", "https://" + self, "", "", "", true},
		{"a sibling host's form", "POST", "https://sib." + self, "", "same-site", "application/x-www-form-urlencoded", false},
		{"a sibling host's text/plain", "POST", "https://sib.example.com", "", "same-site", "text/plain", false},
		{"a sibling host claiming JSON", "POST", "https://sib.example.com", "", "same-site", "application/json", false},
		{"another site", "POST", "https://other.test", "", "cross-site", "application/x-www-form-urlencoded", false},
		{"an older browser, another host", "POST", "https://sib.example.com", "", "", "text/plain", false},
		{"an opaque origin, no word from the browser", "POST", "null", "", "", "text/plain", false},
		{"a Referer naming another host", "POST", "", "https://sib.example.com/x", "", "application/json", false},
		{"cross-site with no Origin at all", "POST", "", "", "cross-site", "", false},
	} {
		r := httptest.NewRequest(c.method, "https://"+self+"/v1/fleet/cert", strings.NewReader("{}"))
		for k, v := range map[string]string{"Origin": c.origin, "Referer": c.referer, "Sec-Fetch-Site": c.fetchSite, "Content-Type": c.ctype} {
			if v != "" {
				r.Header.Set(k, v)
			}
		}
		if got := cookieWriteOK(r); got != c.ok {
			t.Errorf("%s: cookieWriteOK = %v; want %v", c.name, got, c.ok)
		}
	}
}

// End to end, in front of every route: a sibling host's form POST that the
// browser sent the session cookie with is refused on the ways that change
// what a person holds (an entry key, a device certificate, the people list);
// the console's own fetch, a CLI holding the cookie, a bearer and a request
// with no session go on to the route.
func TestCookieWriteGuard(t *testing.T) {
	h, admin, user := rolesHarness(t)
	do := func(method, path string, c *http.Cookie, hdr map[string]string, body string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(method, h.http.URL+path, strings.NewReader(body))
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		if c != nil {
			req.AddCookie(c)
		}
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	const key = `{"public_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl x"}`
	sibling := map[string]string{"Origin": "https://sib.example.com", "Sec-Fetch-Site": "same-site",
		"Content-Type": "text/plain"}
	refused := func(code int, b string) bool {
		return code == http.StatusForbidden && strings.Contains(b, "cross-site request refused")
	}
	for _, c := range []struct {
		method, path string
		cookie       *http.Cookie
	}{
		{http.MethodPost, "/v1/fleet/entry/keys", user},
		{http.MethodPost, "/v1/fleet/cert", user},
		{http.MethodPost, "/v1/fleet/users", admin},
		{http.MethodDelete, "/v1/fleet/users?login=alice", admin},
		{http.MethodPost, "/mcp", user},
	} {
		if code, b := do(c.method, c.path, c.cookie, sibling, key); !refused(code, b) {
			t.Errorf("sibling %s %s with the cookie = %d %s; want the cross-site 403", c.method, c.path, code, b)
		}
		// an older browser that sends no Sec-Fetch-Site: the Origin decides
		if code, b := do(c.method, c.path, c.cookie, map[string]string{"Origin": "https://sib.example.com"}, key); !refused(code, b) {
			t.Errorf("older-browser sibling %s %s = %d %s; want the cross-site 403", c.method, c.path, code, b)
		}
	}
	// the console's own fetch, and a CLI holding the cookie (no Origin, no
	// Sec-Fetch-*): past the guard to the route's own answer
	console := map[string]string{"Origin": h.http.URL, "Sec-Fetch-Site": "same-origin", "Content-Type": "application/json"}
	cli := map[string]string{"Content-Type": "application/json"}
	for _, hdr := range []map[string]string{console, cli} {
		for _, p := range []string{"/v1/fleet/entry/keys", "/v1/fleet/cert", "/v1/fleet/users"} {
			c := user
			if p == "/v1/fleet/users" {
				c = admin
			}
			if code, b := do(http.MethodPost, p, c, hdr, key); refused(code, b) || code == http.StatusForbidden {
				t.Errorf("%v POST %s = %d %s; want past the guard", hdr, p, code, b)
			}
		}
	}
	// a read from a sibling is not a write
	if code, b := do(http.MethodGet, "/v1/me", user, sibling, ""); code != http.StatusOK {
		t.Errorf("sibling GET /v1/me = %d %s; want 200", code, b)
	}
	// a bearer, with no session cookie, from wherever: the guard does not look
	if h.srv.ViewerToken != "" {
		hdr := map[string]string{"Origin": "https://sib.example.com", "Sec-Fetch-Site": "same-site",
			"Content-Type": "application/json", "Authorization": "Bearer " + h.srv.ViewerToken}
		if code, b := do(http.MethodPost, "/v1/fleet/users", nil, hdr, `{"login":"nobody-here"}`); refused(code, b) {
			t.Errorf("bearer POST /v1/fleet/users = %d %s; want past the guard", code, b)
		}
	}
	// no session at all: the route's own answer (the sign-in), not this guard's
	if code, b := do(http.MethodPost, "/v1/fleet/cert", nil, sibling, key); refused(code, b) {
		t.Errorf("signed-out sibling POST = %d %s; want the gate's answer", code, b)
	}
	// a session cookie that does not verify authenticates nothing
	junk := &http.Cookie{Name: user.Name, Value: "not-a-session"}
	if code, b := do(http.MethodPost, "/v1/fleet/cert", junk, sibling, key); refused(code, b) {
		t.Errorf("junk-cookie sibling POST = %d %s; want the gate's answer", code, b)
	}
}
