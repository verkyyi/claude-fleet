package api

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

// With previews on, the hub still answers its in-cluster Service names
// (previewClusterHost): the cluster credential proxy dials http://ccquota-hub,
// other pods …svc.cluster.local. Public-looking and preview hosts are as before.

func TestPreviewClusterHost(t *testing.T) {
	for h, want := range map[string]bool{
		"ccquota-hub": true, "ccquota-hub:80": true, "CCQUOTA-HUB": true,
		"ccquota-hub.new-deploy": true, "ccquota-hub.new-deploy:80": true,
		"ccquota-hub.new-deploy.svc": true, "ccquota-hub.new-deploy.svc.cluster.local": true,
		"ccquota-hub.new-deploy.svc.cluster.local:80": true,
		"evil.example.com":                            false, "example.com": false, "hub.co.uk": false, "foo.dev": false, "foo.app": false,
		"192.0.2.3": false, "192.0.2.3:8787": false, "[::1]:80": false, "localhost.": false,
		"a.svc": false, "x.y.z.svc": false, "a.b.svc.cluster.local.evil.com": false,
		"x.preview.example.net": false, "": false, "bad_name": false, "-x": false, "a..b": false,
	} {
		if got := previewClusterHost(h); got != want {
			t.Errorf("previewClusterHost(%q) = %v, want %v", h, got, want)
		}
	}
}

func TestPreviewOnServesClusterNames(t *testing.T) {
	s := &Server{PreviewDomain: "preview.example.net", FleetPublicURL: "https://hub.example.com", PreviewHubAliases: []string{"ccquota.example.com"}}
	if e := s.ValidatePreviewConfig(); e != nil {
		t.Fatal(e)
	}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	for host, want := range map[string]int{
		"ccquota-hub": 204, "ccquota-hub:80": 204, "ccquota-hub.new-deploy.svc.cluster.local": 204,
		"ccquota-hub.new-deploy.svc": 204, "ccquota-hub.new-deploy": 204,
		"hub.example.com": 204, "ccquota.example.com": 204,
		"evil.example.com": 421, "192.0.2.3:8787": 421,
		"x.preview.example.net": 421, "preview.example.net": 421,
	} {
		r := httptest.NewRequest("POST", "http://"+host+CredProxyResolvePath, nil)
		w := httptest.NewRecorder()
		s.previewHosts(next).ServeHTTP(w, r)
		if w.Code != want {
			t.Errorf("%s: %d want %d", host, w.Code, want)
		}
	}
}

// End to end: the real credential proxy resolves through a previews-on hub
// dialled as http://ccquota-hub (its CCQUOTA_CREDPROXY_HUB_URL in prod), and a
// codex call goes through; dialled by a public-looking name it stays 421.
func TestCredProxyResolvesThroughPreviewsOnHub(t *testing.T) {
	r := newCPRig(t)
	cred, _ := r.issue(t, fidA) // the node's issue rides 127.0.0.1, before previews go on
	r.h.srv.PreviewDomain, r.h.srv.FleetPublicURL = "preview.example.net", "https://hub.example.com"
	if !r.h.srv.previewOn() {
		t.Fatal("previews are not on")
	}
	hubAddr := strings.TrimPrefix(r.h.http.URL, "http://")
	toHub := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, hubAddr)
	}}}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.Copy(io.Discard, req.Body)
		_, _ = io.WriteString(w, `{"usage":{"input_tokens":1,"output_tokens":1}}`)
	}))
	t.Cleanup(up.Close)
	call := func(hubURL, cred string) (int, string) {
		p, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: hubURL, Token: cpToken, Client: toHub},
			Direct: true, AnthropicURL: up.URL, CodexURL: up.URL, CacheTTL: time.Second, StaleFor: time.Minute,
			Now: time.Now, Audit: func(string) {}})
		if err != nil {
			t.Fatal(err)
		}
		srv := httptest.NewServer(p.Handler())
		defer srv.Close()
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/proxy/codex/responses", strings.NewReader(`{"input":"PING"}`))
		req.Header.Set("Authorization", "Bearer "+cred)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(res.Body)
		return res.StatusCode, string(b)
	}
	for _, hub := range []string{"http://ccquota-hub", "http://ccquota-hub.new-deploy.svc.cluster.local"} {
		if st, body := call(hub, cred); st != 200 {
			t.Fatalf("via %s → %d %s", hub, st, body)
		}
	}
	if st, body := call("http://evil.example.com", cred); st == 200 || !strings.Contains(body, "misconfigured") {
		t.Fatalf("via a public-looking host → %d %s; want the 421 refusal", st, body)
	}
}
