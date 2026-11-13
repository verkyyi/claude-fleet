package credproxy

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// A request is read only once it has shown it is worth reading: a refusal
// before then reads at most refusedDrain of its body and closes the
// connection; an accepted one keeps the whole maxBody.

// zeros is a body of n bytes that is never held in memory; read counts what
// was taken from it.
type zeros struct {
	n    int64
	read atomic.Int64
}

func (z *zeros) Read(b []byte) (int, error) {
	left := z.n - z.read.Load()
	if left <= 0 {
		return 0, io.EOF
	}
	if int64(len(b)) > left {
		b = b[:left]
	}
	clear(b)
	z.read.Add(int64(len(b)))
	return len(b), nil
}

func TestRefusalDoesNotReadTheBody(t *testing.T) {
	key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, ed25519.SeedSize))
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{3}, ed25519.SeedSize))
	h := newHarness(t, false, nil)
	h.p.mu.Lock()
	h.p.pub = key.Public().(ed25519.PublicKey)
	h.p.mu.Unlock()
	h.hub.set(func() { h.hub.bad[PassPrefix+"revoked"] = "revoked" })
	enforced, _ := New(Config{Resolver: h.hub, RelayURL: h.up.URL, AnthropicAllow: AnthropicAllowEnforce, Audit: func(string) {}})
	for _, c := range []struct {
		name, path, pass string
		px               *Proxy
		want             int
	}{
		{"no pass", "/v1/proxy/anthropic/v1/messages", "", h.p, 403},
		{"not a hub pass", "/v1/proxy/anthropic/v1/messages", "sk-ant-oat01-x", h.p, 403},
		{"forged fcp-h2", "/v1/proxy/anthropic/v1/messages", signPass2(other, "f", time.Now().Add(time.Hour)), h.p, 403},
		{"expired fcp-h2", "/v1/proxy/anthropic/v1/messages", signPass2(key, "e", time.Now().Add(-time.Minute)), h.p, 403},
		{"fcp-h1 the hub refuses", "/v1/proxy/anthropic/v1/messages", PassPrefix + "revoked", h.p, 403},
		{"fcp-h1 the hub does not know", "/v1/proxy/deepseek/v1/messages", PassPrefix + "nobody", h.p, 403},
		{"codex path off the list", "/v1/proxy/codex/tasks/list", PassPrefix + "revoked", h.p, 403},
		{"anthropic path off the list, enforced", "/v1/proxy/anthropic/v1/files", PassPrefix + "revoked", enforced, 403},
	} {
		z := &zeros{n: maxBody}
		r := httptest.NewRequest(http.MethodPost, c.path, z)
		if c.pass != "" {
			r.Header.Set("Authorization", "Bearer "+c.pass)
		}
		w := httptest.NewRecorder()
		c.px.Handler().ServeHTTP(w, r)
		if w.Code != c.want {
			t.Fatalf("%s: %d %s; want %d", c.name, w.Code, w.Body, c.want)
		}
		if got := w.Header().Get("Connection"); got != "close" {
			t.Fatalf("%s: Connection %q; want close", c.name, got)
		}
		if n := z.read.Load(); n > refusedDrain {
			t.Fatalf("%s: read %d bytes of the body; want at most %d", c.name, n, refusedDrain)
		}
	}
	if n := h.upstreamCount(); n != 0 {
		t.Fatalf("upstream saw %d requests", n)
	}
}

// Over a real connection: the answer comes while most of the body is still
// unsent, says Connection: close, and nothing after it is read as a request.
func TestRefusalClosesTheConnection(t *testing.T) {
	h := newHarness(t, false, nil)
	c, err := net.Dial("tcp", strings.TrimPrefix(h.proxy.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(10 * time.Second))
	fmt.Fprintf(c, "POST /v1/proxy/anthropic/v1/messages HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer nope\r\nContent-Length: %d\r\n\r\n", maxBody)
	go func() {
		// a part of the body, then what would be a second request if it were parsed
		_, _ = c.Write(make([]byte, 1<<20))
		_, _ = io.WriteString(c, "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
	}()
	rd := bufio.NewReader(c)
	res, err := http.ReadResponse(rd, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusForbidden || !res.Close {
		t.Fatalf("status %d close %v; want 403, closed", res.StatusCode, res.Close)
	}
	if next, err := http.ReadResponse(rd, nil); err == nil {
		t.Fatalf("a second answer came on the refused connection: %d", next.StatusCode)
	}
}

// A good pass still sends the whole maxBody on, byte for byte.
func TestAcceptedPassKeepsTheFullBody(t *testing.T) {
	var got atomic.Int64
	h := newHarness(t, false, func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		got.Store(n)
		_, _ = io.WriteString(w, `{}`)
	})
	h.hub.set(func() { h.hub.bind[PassPrefix+"big"] = "acct" })
	for _, path := range []string{"/v1/proxy/anthropic/v1/messages", "/v1/proxy/anthropic/v1/messages/count_tokens"} {
		got.Store(0)
		req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+path, &zeros{n: maxBody})
		req.ContentLength = maxBody
		req.Header.Set("Authorization", "Bearer "+PassPrefix+"big")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, res.Body)
		res.Body.Close()
		if res.StatusCode != 200 || got.Load() != maxBody {
			t.Fatalf("%s: %d, upstream got %d bytes; want 200 and %d", path, res.StatusCode, got.Load(), maxBody)
		}
	}
	req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+"/v1/proxy/anthropic/v1/messages", &zeros{n: maxBody + 1})
	req.ContentLength = maxBody + 1
	req.Header.Set("Authorization", "Bearer "+PassPrefix+"big")
	res, err := http.DefaultClient.Do(req)
	if err == nil {
		res.Body.Close()
		if res.StatusCode != http.StatusRequestEntityTooLarge {
			t.Fatalf("over maxBody: %d; want 413", res.StatusCode)
		}
	}
}

func TestAnthropicAllowList(t *testing.T) {
	for _, c := range []struct {
		m, target string
		ok        bool
	}{
		{"POST", "/v1/proxy/anthropic/v1/messages", true},
		{"POST", "/v1/proxy/anthropic/v1/messages?beta=true", true},
		{"POST", "/v1/proxy/anthropic/v1/messages/count_tokens", true},
		{"GET", "/v1/proxy/anthropic/api/hello", true},
		{"GET", "/v1/proxy/anthropic/v1/messages", false},
		{"POST", "/v1/proxy/anthropic/v1/messages/batches", false},
		{"POST", "/v1/proxy/anthropic/v1/complete", false},
		{"GET", "/v1/proxy/anthropic/v1/files", false},
		{"POST", "/v1/proxy/anthropic/v1/messages/", false},
		{"POST", "/v1/proxy/anthropic/v1/../v1/messages", false},
		{"POST", "/v1/proxy/anthropic/v1%2Fmessages", false},
		{"POST", "http://api.anthropic.com/v1/proxy/anthropic/v1/messages", false},
	} {
		r := httptest.NewRequest(c.m, c.target, nil)
		if why := anthropicRefused(r); (why == "") != c.ok {
			t.Fatalf("%s %s: refused %q; want allowed=%v", c.m, c.target, why, c.ok)
		}
	}

	// Log only (the default): an off-list request goes on, marked on its audit line.
	h := newHarness(t, false, nil)
	h.hub.set(func() { h.hub.bind[PassPrefix+"a"] = "acct" })
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages/batches", PassPrefix+"a", `{}`, nil); st != 200 {
		t.Fatalf("log only: %d; want 200", st)
	}
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"a", `{}`, nil); st != 200 {
		t.Fatalf("on the list: %d", st)
	}
	h.mu.Lock()
	lines := append([]string(nil), h.audit...)
	h.mu.Unlock()
	var off, on map[string]any
	_ = json.Unmarshal([]byte(lines[len(lines)-2]), &off)
	_ = json.Unmarshal([]byte(lines[len(lines)-1]), &on)
	if off["would_refuse"] == nil || on["would_refuse"] != nil {
		t.Fatalf("audit: off %v / on %v", off["would_refuse"], on["would_refuse"])
	}

	// Enforced: a 403 that neither asks the hub nor reaches the upstream.
	h.p.cfg.AnthropicAllow = AnthropicAllowEnforce
	before, calls := h.upstreamCount(), h.hub.count()
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages/batches", PassPrefix+"a", `{}`, nil); st != http.StatusForbidden {
		t.Fatalf("enforced: %d; want 403", st)
	}
	if h.upstreamCount() != before || h.hub.count() != calls {
		t.Fatal("an enforced refusal reached the hub or the upstream")
	}
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages/count_tokens", PassPrefix+"a", `{}`, nil); st != 200 {
		t.Fatalf("enforced, on the list: %d", st)
	}
}
