package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func portalServer(t *testing.T) *Server {
	t.Helper()
	s := &Server{FleetPublicURL: "https://core.example.com"}
	if err := s.ConfigurePortal("portal.example.com", "old.example.com quota.example.com", "https://old.example.com"); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestPortalRedirect(t *testing.T) {
	s := portalServer(t)
	end := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	for _, tc := range []struct {
		host, path, method, ua, upgrade string
		code                            int
	}{
		{"old.example.com", "/app/s/a?x=%2F&x=2", "GET", "Mozilla", "", 301},
		{"old.example.com", "/sessions?q=abc", "GET", "Mozilla", "", 301},
		{"quota.example.com", "/zh/?lang=zh", "HEAD", "Mozilla", "", 301},
		{"old.example.com", "/", "GET", "MicroMessenger/8", "", 204},
		{"old.example.com", "/app", "GET", "micromessenger", "", 204},
		{"old.example.com", "/apply", "POST", "Mozilla", "", 204},
		{"old.example.com", "/app", "GET", "Mozilla", "websocket", 204},
		{"x.preview.example.com", "/app", "GET", "Mozilla", "", 204},
		{"portal.example.com", "/app", "GET", "Mozilla", "", 204},
		{"unknown.example.com", "/app", "GET", "Mozilla", "", 204},
	} {
		r := httptest.NewRequest(tc.method, "https://"+tc.host+tc.path, nil)
		r.Header.Set("User-Agent", tc.ua)
		r.Header.Set("Upgrade", tc.upgrade)
		w := httptest.NewRecorder()
		s.portal(end).ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Errorf("%+v: %d", tc, w.Code)
		}
		if tc.code == 301 && w.Header().Get("Location") != s.PortalURL+tc.path {
			t.Error("lost path/query", w.Header())
		}
		if tc.path == "/" && !strings.Contains(w.Header().Get("Vary"), "User-Agent") {
			t.Error("WeChat cache not isolated")
		}
	}
	for _, p := range []string{"/auth/wechat/qr", "/auth/wechat/poll?s=12", "/auth/wechat/relay-cb?n=x", "/auth/github/callback", "/auth/email/link", "/v1/node/hello", "/v1/fleet/login/start", "/v1/ingest", "/install", "/install.sh", "/install/client", "/fleet/login", "/fleet/login/refused", "/mcp", "/healthz", "/version", "/internal/wx", "/unknown"} {
		r := httptest.NewRequest("GET", "https://old.example.com"+p, nil)
		w := httptest.NewRecorder()
		s.portal(end).ServeHTTP(w, r)
		if w.Code != 204 {
			t.Errorf("client/auth path %s redirected", p)
		}
	}
	s.ForwardedHosts = []string{"old.example.com"}
	r := httptest.NewRequest("GET", "https://core.example.com/app?a=1", nil)
	r.Header.Set("X-Forwarded-Host", "old.example.com")
	w := httptest.NewRecorder()
	s.forwardedTrust(s.portal(end)).ServeHTTP(w, r)
	if w.Header().Get("Location") != s.PortalURL+"/app?a=1" {
		t.Fatal(w.Header())
	}
	off := &Server{}
	if err := off.ConfigurePortal("", "*.example.com", "bad"); err != nil {
		t.Fatal(err)
	}
	w = httptest.NewRecorder()
	off.portal(end).ServeHTTP(w, r)
	if w.Code != 204 || len(w.Header()) != 0 {
		t.Fatal("off changed response")
	}
}

func TestPortalLanguageAndLinks(t *testing.T) {
	s := portalServer(t)
	s.Site = true
	s.SiteFS = fstest.MapFS{
		"portal/sandbox/index.html":    {Data: []byte("PORTAL EN")},
		"portal/sandbox/zh/index.html": {Data: []byte("PORTAL ZH")},
		"sandbox/zh/index.html":        {Data: []byte("OLD ZH SB")},
		"sandbox/index.html":           {Data: []byte("OLD EN")},
		"index.html":                   {Data: []byte("OLD ZH")},
	}
	for _, tc := range []struct{ path, accept, cookie, want string }{
		{"/", "zh-CN,zh;q=0.9", "", "PORTAL ZH"}, {"/", "en-US,en;q=0.9", "", "PORTAL EN"},
		{"/", "zh", "en", "PORTAL EN"}, {"/?lang=zh", "en", "en", "PORTAL ZH"},
		{"/?lang=en", "zh", "zh-CN", "PORTAL EN"}, {"/zh/", "en", "en", "PORTAL ZH"},
	} {
		r := httptest.NewRequest("GET", s.PortalURL+tc.path, nil)
		r.Header.Set("Accept-Language", tc.accept)
		if tc.cookie != "" {
			r.AddCookie(&http.Cookie{Name: langCookie, Value: tc.cookie})
		}
		w := httptest.NewRecorder()
		s.withPageLang(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" {
				s.serveSite(w, r)
			} else {
				s.serveSitePath(w, r)
			}
		})).ServeHTTP(w, r)
		if w.Body.String() != tc.want {
			t.Errorf("%+v: %q", tc, w.Body.String())
		}
		if !strings.Contains(w.Header().Get("Cache-Control"), "private") {
			t.Error("language publicly cached")
		}
		if strings.Contains(tc.path, "lang=") && len(w.Result().Cookies()) == 0 {
			t.Error("choice not remembered")
		}
	}
	r := httptest.NewRequest("GET", "https://old.example.com/", nil)
	if s.humanURL(r) != s.PortalURL || s.wechatURL(r) != "https://old.example.com" || s.nodeHubURL(r) != s.FleetPublicURL {
		t.Fatal("URL purposes mixed")
	}
	if got := s.wechatNotice("open " + s.PortalURL + "/app"); got != "open https://old.example.com/app" {
		t.Fatal(got)
	}
	w := httptest.NewRecorder()
	s.serveSite(w, r)
	if w.Body.String() != "OLD ZH" {
		t.Fatal("legacy site changed")
	}
	r = httptest.NewRequest("GET", s.PortalURL+"/auth/wechat/start?next=%2Fapply", nil)
	r.Header.Set("User-Agent", "MicroMessenger")
	w = httptest.NewRecorder()
	s.portal(http.NotFoundHandler()).ServeHTTP(w, r)
	if w.Code != 302 || w.Header().Get("Location") != "https://old.example.com/auth/wechat/start?next=%2Fapply" {
		t.Fatal("relay cookie wrong host", w.Header())
	}
}

func TestPortalConfig(t *testing.T) {
	for _, tc := range []struct{ o, a, w string }{{"http://example.com", "", ""}, {"https://example.com/path", "", ""}, {"example.com", "*.example.com", ""}, {"example.com", "", "http://old.example.com"}} {
		if err := (&Server{}).ConfigurePortal(tc.o, tc.a, tc.w); err == nil {
			t.Errorf("accepted %+v", tc)
		}
	}
}

// Traefik uses the trusted GA PROXY source to build XFF before forwarding.
func TestPortalGAClientIP(t *testing.T) {
	s := portalServer(t)
	for _, xff := range []string{"198.51.100.42", "198.51.100.42, 10.42.0.7"} { // oss-ok: synthetic private replica hop for IP selection test
		r := httptest.NewRequest("GET", s.PortalURL+"/", nil)
		r.RemoteAddr = "10.42.0.8:443" // oss-ok: synthetic private ingress peer for IP selection test
		r.Header.Set("X-Forwarded-For", xff)
		s.forwardedTrust(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if got := chatClientIP(r).String(); got != "198.51.100.42" {
				t.Fatal(got)
			}
			if got, _ := entryReportSource(r); got.String() != "198.51.100.42" {
				t.Fatal(got)
			}
		})).ServeHTTP(httptest.NewRecorder(), r)
	}
}

// A service-account scan finishes on the portal even when the machine and
// WeChat message origins are different: no OAuth callback/domain registration.
func TestPortalWechatScan(t *testing.T) {
	h := newWxHarness(t)
	h.srv.PortalURL = h.http.URL
	h.srv.FleetPublicURL = "https://core.example.com"
	h.srv.WeChatPublicURL = "https://old.example.com"
	h.http.Config.Handler = h.srv.Handler()
	pid := h.addPerson(t, "wechat", "union-portal")
	b := newBrowser(t, "Mozilla/5.0 (Macintosh)")
	scene, body := h.signinScene(t, b)
	if !strings.Contains(body, `action="/auth/email/start"`) || !strings.Contains(body, `href="/auth/github/start"`) {
		t.Fatal("missing portal login methods")
	}
	if state := h.pollJSON(t, b, scene); state != wxWait {
		t.Fatal(state)
	}
	h.wb.scan(scene, "open-portal", "union-portal")
	if state := h.pollJSON(t, b, scene); state != wxReady {
		t.Fatal(state)
	}
	if resp := h.finish(t, b, scene); resp.StatusCode != 302 {
		t.Fatal(resp.StatusCode)
	}
	if got, _ := b.session(h.waysHarness); got != pid {
		t.Fatalf("scan logged in %q, want %q", got, pid)
	}
}
