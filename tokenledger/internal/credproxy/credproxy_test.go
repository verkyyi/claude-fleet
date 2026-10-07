package credproxy

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// The cluster credential proxy (claude-fleet#1973, EPIC #1967 C6) against a
// fake hub and a fake upstream: a pass in, the bound account's token out,
// nothing else touched.

// fakeHub answers resolves from a table the test edits; down = unreachable.
type fakeHub struct {
	mu    sync.Mutex
	down  bool
	calls int
	bind  map[string]string // pass → account
	bad   map[string]string // pass → reason
	over  map[string]string // pass → over-budget line (claude-fleet#1977)
}

func (h *fakeHub) Resolve(_ context.Context, pass, provider string) (Resolution, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls++
	if h.down {
		return Resolution{}, ErrHubUnavailable
	}
	if why, ok := h.over[pass]; ok {
		return Resolution{Valid: false, Error: PersonBudgetExceeded, Reason: why, ID: "sc_over", Principal: "p-over"}, nil
	}
	if why, ok := h.bad[pass]; ok {
		return Resolution{Valid: false, Reason: why, ID: "sc_bad"}, nil
	}
	acct, ok := h.bind[pass]
	if !ok {
		return Resolution{Valid: false, Reason: "signature does not verify (not issued by this hub)"}, nil
	}
	exp := time.Now().Add(time.Hour)
	who := strings.TrimPrefix(pass, PassPrefix)
	return Resolution{Valid: true, ID: "sc_" + who, Principal: "p-" + who, WorkerID: "fleet/" + who,
		Provider: provider, Owner: "p-" + who, Account: acct, BindRev: 1,
		AccessToken: "tok-" + acct, AccountID: "aid-" + acct, ExpiresAt: &exp, Exp: exp.Unix()}, nil
}

func (h *fakeHub) set(f func()) { h.mu.Lock(); f(); h.mu.Unlock() }

func (h *fakeHub) count() int { h.mu.Lock(); defer h.mu.Unlock(); return h.calls }

// seen is one request as the upstream received it.
type seen struct {
	path, query string
	hdr         http.Header
	body        string
}

type harness struct {
	hub   *fakeHub
	up    *httptest.Server
	proxy *httptest.Server
	p     *Proxy
	now   time.Time
	nowMu sync.Mutex
	mu    sync.Mutex
	got   []seen
	audit []string
}

func newHarness(t *testing.T, direct bool, upstream http.HandlerFunc) *harness {
	t.Helper()
	h := &harness{hub: &fakeHub{bind: map[string]string{}, bad: map[string]string{}}, now: time.Now()}
	if upstream == nil {
		upstream = func(w http.ResponseWriter, r *http.Request) {
			b, _ := io.ReadAll(r.Body)
			h.mu.Lock()
			h.got = append(h.got, seen{r.URL.Path, r.URL.RawQuery, r.Header.Clone(), string(b)})
			h.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"ok":"PONG"}`)
		}
	}
	h.up = httptest.NewServer(upstream)
	t.Cleanup(h.up.Close)
	cfg := Config{Resolver: h.hub, CacheTTL: 10 * time.Second, StaleFor: time.Minute,
		Audit: func(l string) { h.mu.Lock(); h.audit = append(h.audit, l); h.mu.Unlock() },
		Now:   func() time.Time { h.nowMu.Lock(); defer h.nowMu.Unlock(); return h.now }}
	if direct {
		cfg.Direct, cfg.AnthropicURL, cfg.CodexURL = true, h.up.URL, h.up.URL+"/backend-api/codex"
	} else {
		cfg.RelayURL = h.up.URL
	}
	p, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	h.p = p
	h.proxy = httptest.NewServer(p.Handler())
	t.Cleanup(h.proxy.Close)
	return h
}

func (h *harness) tick(d time.Duration) { h.nowMu.Lock(); h.now = h.now.Add(d); h.nowMu.Unlock() }

func (h *harness) do(t *testing.T, path, pass, body string, hdr map[string]string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+path, strings.NewReader(body))
	if pass != "" {
		req.Header.Set("Authorization", "Bearer "+pass)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(b)
}

func (h *harness) last(t *testing.T) seen {
	t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.got) == 0 {
		t.Fatal("the upstream saw nothing")
	}
	return h.got[len(h.got)-1]
}

func (h *harness) upstreamCount() int { h.mu.Lock(); defer h.mu.Unlock(); return len(h.got) }

// A forged, an expired and a revoked pass are all refused — 403, which no
// client retries — and nothing reaches the upstream. A credential that is
// not a hub pass at all (a real token, an fcp1. local one) is refused
// without asking the hub.
func TestRefusals(t *testing.T) {
	h := newHarness(t, false, nil)
	h.hub.set(func() { h.hub.bad[PassPrefix+"expired"] = "expired" })
	h.hub.set(func() { h.hub.bad[PassPrefix+"revoked"] = "revoked at 2026-10-06T00:00:00Z by operator" })
	for _, pass := range []string{PassPrefix + "forged", PassPrefix + "expired", PassPrefix + "revoked"} {
		st, body := h.do(t, "/v1/proxy/anthropic/v1/messages", pass, `{"x":1}`, nil)
		if st != http.StatusForbidden || !strings.Contains(body, "permission_error") {
			t.Fatalf("%s → %d %s; want 403 permission_error", pass, st, body)
		}
	}
	calls := h.hub.count()
	for _, pass := range []string{"", "sk-ant-oat01-real", "fcp1.local.sig"} {
		if st, _ := h.do(t, "/v1/proxy/codex/responses", pass, `{}`, nil); st != http.StatusForbidden {
			t.Fatalf("%q → %d; want 403", pass, st)
		}
	}
	if h.hub.count() != calls {
		t.Fatalf("a non-pass reached the hub")
	}
	if n := h.upstreamCount(); n != 0 {
		t.Fatalf("upstream saw %d requests; want none", n)
	}
	// Codex errors come in OpenAI's shape.
	_, body := h.do(t, "/v1/proxy/codex/responses", PassPrefix+"forged", `{}`, nil)
	var e struct {
		Error struct{ Code, Message string }
	}
	if json.Unmarshal([]byte(body), &e) != nil || e.Error.Code != "permission_error" {
		t.Fatalf("codex refusal body = %s", body)
	}
}

// Claude: only the authentication changes. The pass goes, the bound
// account's token comes in, x-api-key goes, the oauth beta joins the
// session's own betas; the body and the query pass byte for byte; the front
// door's X-Forwarded-* never reach the provider; the relay gets the pass in
// X-Fleet-Relay and the path under /anthropic.
func TestClaudeRewrite(t *testing.T) {
	h := newHarness(t, false, nil)
	h.hub.set(func() { h.hub.bind[PassPrefix+"a"] = "acct1" })
	body := `{"model":"claude","messages":[{"role":"user","content":"PING ü"}]}`
	st, out := h.do(t, "/v1/proxy/anthropic/v1/messages?beta=true", PassPrefix+"a", body, map[string]string{
		"X-Api-Key": "leak", "Anthropic-Beta": "foo-1,bar-2", "X-Forwarded-For": "10.0.0.9", "Anthropic-Version": "2023-06-01"})
	if st != 200 || !strings.Contains(out, "PONG") {
		t.Fatalf("→ %d %s", st, out)
	}
	g := h.last(t)
	if g.path != "/anthropic/v1/messages" || g.query != "beta=true" || g.body != body {
		t.Fatalf("upstream got %s?%s %q", g.path, g.query, g.body)
	}
	if a := g.hdr.Get("Authorization"); a != "Bearer tok-acct1" {
		t.Fatalf("Authorization = %q", a)
	}
	if g.hdr.Get("X-Api-Key") != "" || g.hdr.Get("X-Forwarded-For") != "" {
		t.Fatalf("leaked headers: %v", g.hdr)
	}
	if b := g.hdr.Get("Anthropic-Beta"); b != "foo-1,bar-2,"+oauthBeta {
		t.Fatalf("Anthropic-Beta = %q", b)
	}
	if g.hdr.Get("X-Fleet-Relay") != PassPrefix+"a" || g.hdr.Get("Anthropic-Version") != "2023-06-01" {
		t.Fatalf("relay pass / version header: %v", g.hdr)
	}
}

// Codex: the bound account's chatgpt-account-id, whatever the session sent;
// the path under /chatgpt/codex on the relay, /backend-api/codex direct.
func TestCodexRewrite(t *testing.T) {
	for _, direct := range []bool{false, true} {
		h := newHarness(t, direct, nil)
		h.hub.set(func() { h.hub.bind[PassPrefix+"c"] = "cx" })
		if st, _ := h.do(t, "/v1/proxy/codex/responses", PassPrefix+"c", `{"input":"PING"}`,
			map[string]string{"Chatgpt-Account-Id": "someone-else"}); st != 200 {
			t.Fatalf("direct=%v → %d", direct, st)
		}
		g := h.last(t)
		want := "/chatgpt/codex/responses"
		if direct {
			want = "/backend-api/codex/responses"
		}
		if g.path != want || g.hdr.Get("Chatgpt-Account-Id") != "aid-cx" || g.hdr.Get("Authorization") != "Bearer tok-cx" {
			t.Fatalf("direct=%v: %s %v", direct, g.path, g.hdr)
		}
		if direct && g.hdr.Get("X-Fleet-Relay") != "" {
			t.Fatalf("direct road carried the relay header")
		}
		if g.hdr.Get("Anthropic-Beta") != "" {
			t.Fatalf("codex got the anthropic beta")
		}
	}
}

// Two sessions bound to two accounts never cross: each request carries its
// own session's token, however they interleave.
func TestSessionsDoNotCross(t *testing.T) {
	var mu sync.Mutex
	got := map[string]map[string]bool{} // marker in body → tokens seen
	h := newHarness(t, false, func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		if got[string(b)] == nil {
			got[string(b)] = map[string]bool{}
		}
		got[string(b)][r.Header.Get("Authorization")] = true
		mu.Unlock()
		_, _ = io.WriteString(w, "ok")
	})
	h.hub.set(func() { h.hub.bind[PassPrefix+"one"] = "acctA" })
	h.hub.set(func() { h.hub.bind[PassPrefix+"two"] = "acctB" })
	var wg sync.WaitGroup
	for i := 0; i < 40; i++ {
		who := []string{"one", "two"}[i%2]
		wg.Add(1)
		go func() {
			defer wg.Done()
			if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+who, who, nil); st != 200 {
				t.Errorf("%s → %d", who, st)
			}
		}()
	}
	wg.Wait()
	if len(got["one"]) != 1 || !got["one"]["Bearer tok-acctA"] || len(got["two"]) != 1 || !got["two"]["Bearer tok-acctB"] {
		t.Fatalf("tokens per session: %v", got)
	}
}

// A stream is forwarded chunk by chunk — the first event reaches the
// session while the upstream is still writing — and arrives whole.
func TestStreamingNotTruncated(t *testing.T) {
	release := make(chan struct{})
	const n = 200
	h := newHarness(t, false, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		f := w.(http.Flusher)
		_, _ = io.WriteString(w, "event: first\ndata: {}\n\n")
		f.Flush()
		<-release
		for i := 0; i < n; i++ {
			_, _ = io.WriteString(w, "event: delta\ndata: "+strings.Repeat("x", 1000)+"\n\n")
			if i%10 == 0 {
				f.Flush()
			}
		}
		_, _ = io.WriteString(w, "event: message_stop\ndata: {}\n\n")
	})
	h.hub.set(func() { h.hub.bind[PassPrefix+"s"] = "acct" })
	req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+"/v1/proxy/anthropic/v1/messages", strings.NewReader(`{"stream":true}`))
	req.Header.Set("Authorization", "Bearer "+PassPrefix+"s")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	rd := bufio.NewReader(res.Body)
	first := make(chan string, 1)
	go func() { l, _ := rd.ReadString('\n'); first <- l }()
	select {
	case l := <-first:
		if l != "event: first\n" {
			t.Fatalf("first line %q", l)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the first event did not arrive while the upstream was still streaming")
	}
	close(release)
	rest, err := io.ReadAll(rd)
	if err != nil {
		t.Fatal(err)
	}
	if c := strings.Count(string(rest), "event: delta"); c != n || !strings.HasSuffix(string(rest), "event: message_stop\ndata: {}\n\n") {
		t.Fatalf("got %d deltas, tail %q", c, string(rest[max(0, len(rest)-40):]))
	}
}

// A rebind on the hub reaches the next request once the cached answer runs
// out (≤ CacheTTL); before that the old account stands.
func TestRebind(t *testing.T) {
	h := newHarness(t, false, nil)
	h.hub.set(func() { h.hub.bind[PassPrefix+"r"] = "old" })
	h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"r", "1", nil)
	h.hub.set(func() { h.hub.bind[PassPrefix+"r"] = "new" })
	h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"r", "2", nil)
	if a := h.last(t).hdr.Get("Authorization"); a != "Bearer tok-old" {
		t.Fatalf("within the cache: %q", a)
	}
	h.tick(11 * time.Second)
	h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"r", "3", nil)
	if a := h.last(t).hdr.Get("Authorization"); a != "Bearer tok-new" {
		t.Fatalf("after the cache: %q; want the rebound account", a)
	}
}

// A hub that cannot answer (a restart) does not stop a session the proxy
// already knows: its answer serves stale for StaleFor. A pass never seen gets
// a 503 (retry), never a 403. Past StaleFor, 503 too.
func TestHubDown(t *testing.T) {
	h := newHarness(t, false, nil)
	h.hub.set(func() { h.hub.bind[PassPrefix+"k"] = "acct" })
	h.hub.set(func() { h.hub.bind[PassPrefix+"u"] = "acct" })
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"k", "1", nil); st != 200 {
		t.Fatal(st)
	}
	h.hub.set(func() { h.hub.down = true })
	h.tick(20 * time.Second)
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"k", "2", nil); st != 200 {
		t.Fatalf("known session while the hub is down → %d; want 200 (stale)", st)
	}
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"u", "3", nil); st != http.StatusServiceUnavailable {
		t.Fatalf("unseen pass while the hub is down → %d; want 503", st)
	}
	h.tick(2 * time.Minute)
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"k", "4", nil); st != http.StatusServiceUnavailable {
		t.Fatalf("past StaleFor → %d; want 503", st)
	}
	h.hub.set(func() { h.hub.down = false })
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"k", "5", nil); st != 200 {
		t.Fatalf("hub back → %d", st)
	}
	stale := 0
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, l := range h.audit {
		if strings.Contains(l, `"stale":true`) {
			stale++
		}
	}
	if stale != 1 {
		t.Fatalf("stale audit lines = %d; want 1", stale)
	}
}

// The audit is one line per request — who, which account, status, bytes —
// and never a pass, a token or a body.
func TestAuditCarriesNoSecret(t *testing.T) {
	h := newHarness(t, false, nil)
	h.hub.set(func() { h.hub.bind[PassPrefix+"secretpass"] = "acct" })
	h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"secretpass", "private body", nil)
	h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"forged", "x", nil)
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.audit) != 2 {
		t.Fatalf("audit lines = %d", len(h.audit))
	}
	for _, l := range h.audit {
		for _, bad := range []string{"tok-acct", "private body", PassPrefix} {
			if strings.Contains(l, bad) {
				t.Fatalf("audit line carries %q: %s", bad, l)
			}
		}
	}
	var a map[string]any
	_ = json.Unmarshal([]byte(h.audit[0]), &a)
	if a["principal"] != "p-secretpass" || a["worker_id"] != "fleet/secretpass" || a["account"] != "acct" ||
		a["status"] != float64(200) || a["bytes_in"] != float64(12) || a["route"] != "relay" {
		t.Fatalf("audit = %v", a)
	}
}

// No relay and no explicit --direct: refuse to start.
func TestNeedsRelay(t *testing.T) {
	if _, err := New(Config{Resolver: &fakeHub{}}); err == nil {
		t.Fatal("started with no relay")
	}
}
