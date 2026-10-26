package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

// One hub, two audiences (task PNWW, edge.go): a listed X-Forwarded-Host is
// the request's host, over https, from the leftmost X-Forwarded-For; per-host
// public URL and site edition; nothing set ⇒ as before.

var testForwarded = []string{"hub.example.com", "ccquota.example.com", "*.preview.example.net"}

// seen is what the handler under forwardedTrust was handed.
type seen struct {
	host, remote, xff, proto, xfh string
	https                         bool
	ip                            string
}

// edgeRun sends one request as traefik hands it on: Host core.tokenman.io,
// traefik as the peer, X-Forwarded-For "<client>, <edge>".
func edgeRun(s *Server, mod func(*http.Request)) seen {
	var got seen
	h := s.forwardedTrust(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = seen{host: r.Host, remote: r.RemoteAddr, xff: r.Header.Get("X-Forwarded-For"),
			proto: r.Header.Get("X-Forwarded-Proto"), xfh: r.Header.Get("X-Forwarded-Host"),
			https: isHTTPS(r), ip: chatClientIP(r).String()}
	}))
	r := httptest.NewRequest(http.MethodGet, "http://core.tokenman.io/x", nil)
	r.RemoteAddr = "192.0.2.7:4444" // traefik
	r.Header.Set("X-Forwarded-For", "198.51.100.1, 203.0.113.9")
	mod(r)
	h.ServeHTTP(httptest.NewRecorder(), r)
	return got
}

func fwdHost(h string) func(*http.Request) {
	return func(r *http.Request) { r.Header.Set("X-Forwarded-Host", h) }
}

func TestForwardedTrust(t *testing.T) {
	s := &Server{ForwardedHosts: testForwarded}
	const pv = "0123456789abcdef0123456789abcdef.preview.example.net"

	// a listed host: host, client (leftmost) and scheme are the edge's
	for in, want := range map[string]string{
		"Hub.example.com":                   "hub.example.com",
		"ccquota.example.com:443":           "ccquota.example.com:443",
		pv:                                  pv,
		"hub.example.com, core.tokenman.io": "hub.example.com",
	} {
		got := edgeRun(s, fwdHost(in))
		if got.host != want || got.xfh != want || got.remote != "198.51.100.1:0" || got.xff != "198.51.100.1" ||
			got.ip != "198.51.100.1" || !got.https || got.proto != "https" {
			t.Errorf("forwarded %q: %+v", in, got)
		}
	}

	// an unlisted host, no header, or nothing configured: as it came
	untouched := func(name string, got seen, xfh string) {
		t.Helper()
		if got.host != "core.tokenman.io" || got.remote != "192.0.2.7:4444" || got.xff != "198.51.100.1, 203.0.113.9" ||
			got.https || got.xfh != xfh || got.ip != "203.0.113.9" {
			t.Errorf("%s: %+v; want the request as it came", name, got)
		}
	}
	untouched("own host", edgeRun(s, fwdHost("core.tokenman.io")), "core.tokenman.io")
	untouched("stranger", edgeRun(s, fwdHost("evil.example.com")), "evil.example.com")
	untouched("preview apex", edgeRun(s, fwdHost("preview.example.net")), "preview.example.net")
	untouched("lookalike", edgeRun(s, fwdHost("x.evilpreview.example.net")), "x.evilpreview.example.net")
	untouched("bad host", edgeRun(s, fwdHost("hub.example.com/x")), "hub.example.com/x")
	untouched("no header", edgeRun(s, func(*http.Request) {}), "")
	untouched("off", edgeRun(&Server{}, fwdHost("hub.example.com")), "hub.example.com")

	// a listed host with no readable client keeps the peer
	got := edgeRun(s, func(r *http.Request) {
		fwdHost("hub.example.com")(r)
		r.Header.Set("X-Forwarded-For", "junk")
	})
	if got.host != "hub.example.com" || got.remote != "192.0.2.7:4444" || !got.https {
		t.Errorf("forwarded, bad X-Forwarded-For: %+v", got)
	}

	if _, err := ParseForwardedHosts("ok.example.com bad_host"); err == nil {
		t.Error("ParseForwardedHosts accepted bad_host")
	}
	if l, err := ParseForwardedHosts("A.example.com,*.p.example.net"); err != nil || len(l) != 2 || l[0] != "a.example.com" || l[1] != "*.p.example.net" {
		t.Errorf("ParseForwardedHosts = %v %v", l, err)
	}
	if l, err := ParseForwardedHosts(""); err != nil || l != nil {
		t.Errorf("ParseForwardedHosts(empty) = %v %v", l, err)
	}
}

// A WebSocket upgrade through the edge: the upgrade still hijacks, and the
// terminal's same-origin rule sees the host the browser asked for.
func TestForwardedTrustUpgrade(t *testing.T) {
	s := &Server{ForwardedHosts: testForwarded}
	var originOK bool
	srv := httptest.NewServer(s.forwardedTrust(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		originOK = s.termOriginOK(r)
		c, bw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		defer c.Close()
		_, _ = bw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
		_ = bw.Flush()
	})))
	defer srv.Close()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/term/ws", nil)
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Origin", "https://hub.example.com")
	req.Header.Set("X-Forwarded-Host", "hub.example.com")
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusSwitchingProtocols || !originOK {
		t.Errorf("upgrade via edge = %d, origin ok %v; want 101 and the edge host as the origin", resp.StatusCode, originOK)
	}
}

func TestPublicHosts(t *testing.T) {
	m, err := ParseHostMap("tokenman.io=https://tokenman.io www.tokenman.io=https://tokenman.io/ Core.Tokenman.io=https://tokenman.io", PublicHostOrigin)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{FleetPublicURL: "https://hub.example.com/", PublicHosts: m}
	at := func(host string) *http.Request { return httptest.NewRequest(http.MethodGet, "http://"+host+"/", nil) }
	for host, want := range map[string]string{
		"tokenman.io": "https://tokenman.io", "www.tokenman.io": "https://tokenman.io", "core.tokenman.io:443": "https://tokenman.io",
		"hub.example.com": "https://hub.example.com", "ccquota.example.com": "https://hub.example.com",
	} {
		r := at(host)
		if got := s.hubURL(r); got != want {
			t.Errorf("hubURL(%s) = %q, want %q", host, got, want)
		}
		if got := s.nodeHubURL(r); got != "https://hub.example.com" {
			t.Errorf("nodeHubURL(%s) = %q; want the configured address", host, got)
		}
		if got := s.wechatCallbackURL(r); got != "https://hub.example.com/auth/wechat/callback" {
			t.Errorf("wechatCallbackURL(%s) = %q; want claudefleet's", host, got)
		}
	}
	if got := s.githubCallbackURL(at("tokenman.io")); got != "https://tokenman.io/auth/github/callback" {
		t.Errorf("githubCallbackURL(tokenman.io) = %q", got)
	}

	// through the edge the host is claudefleet's again
	var got string
	s.ForwardedHosts = testForwarded
	h := s.forwardedTrust(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { got = s.hubURL(r) }))
	r := at("core.tokenman.io")
	fwdHost("hub.example.com")(r)
	h.ServeHTTP(httptest.NewRecorder(), r)
	if got != "https://hub.example.com" {
		t.Errorf("hubURL via edge = %q", got)
	}

	// nothing set: as before
	plain := &Server{FleetPublicURL: "https://hub.example.com"}
	if got := plain.hubURL(at("tokenman.io")); got != "https://hub.example.com" {
		t.Errorf("no PublicHosts: hubURL = %q", got)
	}
	if got := (&Server{}).hubURL(at("x.example.com")); got != "http://x.example.com" {
		t.Errorf("no public URL: hubURL = %q", got)
	}

	for _, bad := range []string{"tokenman.io", "tokenman.io=ftp://x", "tokenman.io=https://x/path", "bad_host=https://x", "tokenman.io=https://u@x"} {
		if _, err := ParseHostMap(bad, PublicHostOrigin); err == nil {
			t.Errorf("ParseHostMap(%q) accepted", bad)
		}
	}
	if m, err := ParseHostMap("  ", PublicHostOrigin); err != nil || m != nil {
		t.Errorf("empty: %v %v", m, err)
	}
}

// Previews on: a per-host public address is the hub, not a 421; a public host
// on the preview's own site is refused at start; a preview host the edge
// forwards is served as the preview.
func TestPublicHostsWithPreview(t *testing.T) {
	s := &Server{PreviewDomain: "preview.example.net", FleetPublicURL: "https://hub.example.com",
		PreviewHubAliases: []string{"ccquota.example.com"}, PublicHosts: map[string]string{"tokenman.io": "https://tokenman.io"}}
	if e := s.ValidatePreviewConfig(); e != nil {
		t.Fatal(e)
	}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	for host, want := range map[string]int{"tokenman.io": 204, "hub.example.com": 204, "evil.tokenman.io": 421} {
		w := httptest.NewRecorder()
		s.previewHosts(next).ServeHTTP(w, httptest.NewRequest("GET", "http://"+host+"/v1/x", nil))
		if w.Code != want {
			t.Errorf("%s: %d want %d", host, w.Code, want)
		}
	}
	// a forwarded hub host passes; a forwarded bad preview name is the preview's 421
	s.ForwardedHosts = testForwarded
	for fh, want := range map[string]int{"ccquota.example.com": 204, "nope.preview.example.net": 421} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "http://core.tokenman.io/v1/x", nil)
		fwdHost(fh)(r)
		s.forwardedTrust(s.previewHosts(next)).ServeHTTP(w, r)
		if w.Code != want {
			t.Errorf("forwarded %s: %d want %d", fh, w.Code, want)
		}
	}
	s.PublicHosts["x.example.net"] = "https://x.example.net"
	if e := s.ValidatePreviewConfig(); e == nil {
		t.Errorf("a public host on the preview's site was accepted")
	}
}

// CCQUOTA_SITE_HOSTS: the sandbox page on tokenman.io, the 中文 page on
// claudefleet (as the edge says), each with its own address filled in.
func TestSiteHosts(t *testing.T) {
	h, _, _ := rolesHarness(t)
	h.srv.Site = true
	site, docs := siteFixture()
	site["sandbox/index.html"] = &fstest.MapFile{Data: []byte(`<html lang="en"><link rel="canonical" href="__ORIGIN__/"><b>SANDBOX-EN</b></html>`)}
	site["sandbox/zh/index.html"] = &fstest.MapFile{Data: []byte(`<html lang="zh-CN"><b>SANDBOX-ZH</b></html>`)}
	h.srv.SiteFS, h.srv.DocsFS = site, docs
	h.srv.FleetPublicURL = "https://hub.example.com"
	h.srv.ForwardedHosts = testForwarded
	var err error
	if h.srv.SiteHosts, err = ParseHostMap("tokenman.io=sandbox core.tokenman.io=sandbox", SiteHostEdition); err != nil {
		t.Fatal(err)
	}
	h.srv.PublicHosts = map[string]string{"tokenman.io": "https://tokenman.io", "core.tokenman.io": "https://tokenman.io"}
	do := func(host, p string, edge bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "http://"+host+p, nil)
		if edge {
			fwdHost("hub.example.com")(req)
		}
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, req)
		return rec
	}
	if rec := do("tokenman.io", "/", false); rec.Code != 200 || !strings.Contains(rec.Body.String(), "SANDBOX-EN") ||
		!strings.Contains(rec.Body.String(), `href="https://tokenman.io/"`) {
		t.Errorf("tokenman.io / = %d %q; want the sandbox page with its address", rec.Code, rec.Body.String())
	}
	if rec := do("tokenman.io", "/en/", false); rec.Code != http.StatusMovedPermanently {
		t.Errorf("tokenman.io /en/ = %d; want the sandbox's 301", rec.Code)
	}
	for _, c := range []struct {
		host string
		edge bool
	}{{"hub.example.com", false}, {"core.tokenman.io", true}} {
		rec := do(c.host, "/", c.edge)
		if b := rec.Body.String(); rec.Code != 200 || !strings.HasPrefix(b, `<html lang="zh-CN">`) || strings.Contains(b, "SANDBOX") ||
			!strings.Contains(b, "https://hub.example.com/x") {
			t.Errorf("%s (edge %v) / = %d %q; want the 中文 page at claudefleet", c.host, c.edge, rec.Code, b)
		}
		if rec := do(c.host, "/en/", c.edge); rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), `<html lang="en">`) {
			t.Errorf("%s /en/ = %d; want the default English page", c.host, rec.Code)
		}
	}
	for _, bad := range []string{"tokenman.io=off", "tokenman.io=", "tokenman.io"} {
		if _, err := ParseHostMap(bad, SiteHostEdition); err == nil {
			t.Errorf("ParseHostMap(%q) accepted", bad)
		}
	}
}
