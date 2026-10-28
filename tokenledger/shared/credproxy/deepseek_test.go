package credproxy

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// The deepseek route (P0 domestic models): /v1/proxy/deepseek/<path> goes
// straight to DeepSeekURL — never the relay — with the hub's token as
// x-api-key, no Authorization, no oauth beta; the body byte for byte; usage
// reported as provider deepseek; no rebind, no Bedrock.

type dsHub struct {
	*fakeHub
	mu       sync.Mutex
	usage    []Usage
	asked    int // Fallback
	rebinds  int
	provider []string
}

func (h *dsHub) Resolve(ctx context.Context, pass, provider string) (Resolution, error) {
	h.mu.Lock()
	h.provider = append(h.provider, provider)
	h.mu.Unlock()
	r, err := h.fakeHub.Resolve(ctx, pass, provider)
	r.ExpiresAt = nil // an API key does not run out
	return r, err
}

func (h *dsHub) ReportUsage(_ context.Context, u Usage) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.usage = append(h.usage, u)
	return false, nil
}

func (h *dsHub) Fallback(context.Context, string, string, string) (Fallback, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.asked++
	return Fallback{}, nil
}

func (h *dsHub) Rebind(context.Context, string, string, string, string, int64, ...string) (Resolution, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.rebinds++
	return Resolution{}, nil
}

type dsRig struct {
	hub       *dsHub
	px        *httptest.Server
	mu        sync.Mutex
	ds, relay []seen
	status    int
	audit     []string
}

func newDSRig(t *testing.T, direct bool) *dsRig {
	t.Helper()
	g := &dsRig{hub: &dsHub{fakeHub: &fakeHub{bind: map[string]string{PassPrefix + "a": "dskey"}, bad: map[string]string{}}}, status: 200}
	ds := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		g.mu.Lock()
		g.ds = append(g.ds, seen{r.URL.Path, r.URL.RawQuery, r.Header.Clone(), string(b)})
		st := g.status
		g.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(st)
		if st != 200 {
			_, _ = io.WriteString(w, `{"type":"error","error":{"type":"rate_limit_error","message":"usage limit"}}`)
			return
		}
		_, _ = io.WriteString(w, `{"id":"m","type":"message","model":"deepseek-chat","content":[{"type":"text","text":"PONG"}],"usage":{"input_tokens":11,"output_tokens":4}}`)
	}))
	t.Cleanup(ds.Close)
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		g.mu.Lock()
		g.relay = append(g.relay, seen{r.URL.Path, r.URL.RawQuery, r.Header.Clone(), string(b)})
		g.mu.Unlock()
		_, _ = io.WriteString(w, `{}`)
	}))
	t.Cleanup(relay.Close)
	cfg := Config{Resolver: g.hub, DeepSeekURL: ds.URL + "/anthropic/", BedrockURL: relay.URL,
		CacheTTL: 10 * time.Second, Audit: func(l string) { g.mu.Lock(); g.audit = append(g.audit, l); g.mu.Unlock() }}
	if direct {
		cfg.Direct, cfg.AnthropicURL, cfg.CodexURL = true, relay.URL, relay.URL
	} else {
		cfg.RelayURL = relay.URL
	}
	p, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	g.px = httptest.NewServer(p.Handler())
	t.Cleanup(g.px.Close)
	return g
}

func TestDeepSeekRouteDirectWithAPIKey(t *testing.T) {
	for _, direct := range []bool{false, true} {
		g := newDSRig(t, direct)
		body := `{"model":"deepseek-chat","max_tokens":8,"messages":[{"role":"user","content":"PING"}]}`
		code, _, out := post(t, g.px.URL+"/v1/proxy/deepseek/v1/messages?beta=1", PassPrefix+"a", body,
			map[string]string{"X-Api-Key": "inbound", "Anthropic-Beta": "foo-2025", "Anthropic-Version": "2023-06-01"})
		if code != 200 || !strings.Contains(out, "PONG") {
			t.Fatalf("direct=%v: %d %s", direct, code, out)
		}
		g.mu.Lock()
		relayed, dsn := len(g.relay), len(g.ds)
		var s seen
		if dsn > 0 {
			s = g.ds[0]
		}
		g.mu.Unlock()
		if relayed != 0 {
			t.Fatalf("direct=%v: the relay / another upstream was used %d time(s)", direct, relayed)
		}
		if dsn != 1 {
			t.Fatalf("direct=%v: deepseek saw %d", direct, dsn)
		}
		if s.path != "/anthropic/v1/messages" || s.query != "beta=1" {
			t.Fatalf("path %q query %q", s.path, s.query)
		}
		if s.hdr.Get("X-Api-Key") != "tok-dskey" || s.hdr.Get("Authorization") != "" {
			t.Fatalf("auth: x-api-key %q authorization %q", s.hdr.Get("X-Api-Key"), s.hdr.Get("Authorization"))
		}
		if b := s.hdr.Get("Anthropic-Beta"); b != "foo-2025" || strings.Contains(b, oauthBeta) {
			t.Fatalf("anthropic-beta %q", b)
		}
		if s.hdr.Get("X-Fleet-Relay") != "" || s.hdr.Get("Anthropic-Version") != "2023-06-01" {
			t.Fatalf("headers %v", s.hdr)
		}
		if s.body != body {
			t.Fatalf("body changed: %q", s.body)
		}
		waitUntil(t, func() bool { g.hub.mu.Lock(); defer g.hub.mu.Unlock(); return len(g.hub.usage) == 1 })
		g.hub.mu.Lock()
		u := g.hub.usage[0]
		prov := g.hub.provider
		g.hub.mu.Unlock()
		if u.Provider != DeepSeek || u.Source != "" || u.In != 11 || u.Out != 4 || u.Cred != PassPrefix+"a" {
			t.Fatalf("usage %+v", u)
		}
		if len(prov) == 0 || prov[0] != DeepSeek {
			t.Fatalf("resolved as %v", prov)
		}
		// the audit line is written after the answer has gone out: wait for it,
		// never Fatal while holding g.mu (the handler's Audit would block Close)
		waitUntil(t, func() bool {
			g.mu.Lock()
			defer g.mu.Unlock()
			for _, l := range g.audit {
				if strings.Contains(l, `"provider":"deepseek"`) && strings.Contains(l, `"route":"direct"`) {
					return true
				}
			}
			return false
		})
	}
}

// A DeepSeek 429 is its own answer: no rebind, no Bedrock, nothing replayed.
func TestDeepSeek429PassesThrough(t *testing.T) {
	g := newDSRig(t, false)
	g.status = http.StatusTooManyRequests
	code, _, out := post(t, g.px.URL+"/v1/proxy/deepseek/v1/messages", PassPrefix+"a", streamBody,
		map[string]string{"Anthropic-Ratelimit-Unified-Status": "rejected"})
	if code != http.StatusTooManyRequests || !strings.Contains(out, "usage limit") {
		t.Fatalf("%d %s", code, out)
	}
	g.hub.mu.Lock()
	defer g.hub.mu.Unlock()
	if g.hub.asked != 0 || g.hub.rebinds != 0 {
		t.Fatalf("fallback asked %d, rebinds %d", g.hub.asked, g.hub.rebinds)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.ds) != 1 || len(g.relay) != 0 {
		t.Fatalf("deepseek %d, relay/bedrock %d", len(g.ds), len(g.relay))
	}
}

// A 401 from DeepSeek goes back as DeepSeek said it; an unknown provider stays refused.
func TestDeepSeek401AndUnknownRoute(t *testing.T) {
	g := newDSRig(t, false)
	g.status = http.StatusUnauthorized
	if code, _, _ := post(t, g.px.URL+"/v1/proxy/deepseek/v1/messages", PassPrefix+"a", `{}`, nil); code != http.StatusUnauthorized {
		t.Fatalf("401 → %d", code)
	}
	if code, _, _ := post(t, g.px.URL+"/v1/proxy/qwen/v1/messages", PassPrefix+"a", `{}`, nil); code != http.StatusNotFound {
		t.Fatalf("unknown route → %d", code)
	}
	if code, _, _ := post(t, g.px.URL+"/v1/proxy/deepseek/v1/messages", "sk-raw", `{}`, nil); code != http.StatusForbidden {
		t.Fatalf("no pass → %d", code)
	}
}

func TestDeepSeekDefaultURL(t *testing.T) {
	p, err := New(Config{Resolver: &fakeHub{}, RelayURL: "https://relay.example"})
	if err != nil {
		t.Fatal(err)
	}
	u, _ := http.NewRequest("POST", "http://x/v1/proxy/deepseek/v1/messages", nil)
	if got, route := p.target(DeepSeek, u.URL); got != "https://api.deepseek.com/anthropic/v1/messages" || route != "direct" {
		t.Fatalf("%s %s", got, route)
	}
}
