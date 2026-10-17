package credproxy

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
)

// raw sends one request line exactly as written — no client cleans or encodes it.
func raw(t *testing.T, h *harness, method, target, pass string) int {
	t.Helper()
	c, err := net.Dial("tcp", strings.TrimPrefix(h.proxy.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprintf(c, "%s %s HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}", method, target, pass)
	res, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	return res.StatusCode
}

// Only the paths Codex CLI uses reach the upstream; every other spelling, path
// or method is a 403 that never asks the hub (claude-fleet#4611).
func TestCodexPathAllowList(t *testing.T) {
	for _, direct := range []bool{false, true} {
		h := newHarness(t, direct, nil)
		pass := PassPrefix + "c"
		h.hub.set(func() { h.hub.bind[pass] = "cx" })
		for _, c := range []struct{ m, target string }{
			{"POST", "/v1/proxy/codex/responses"},
			{"POST", "/v1/proxy/codex/responses/compact"},
			{"GET", "/v1/proxy/codex/models?client_version=0.162.1"},
		} {
			if st := raw(t, h, c.m, c.target, pass); st != 200 {
				t.Fatalf("direct=%v %s %s → %d, want 200", direct, c.m, c.target, st)
			}
		}
		if g := h.last(t); g.query != "client_version=0.162.1" {
			t.Fatalf("query not carried: %q", g.query)
		}
		before, calls := len(h.got), h.hub.count()
		for _, c := range []struct{ m, target string }{
			{"POST", "/v1/proxy/codex/../anthropic/v1/messages"},
			{"POST", "/v1/proxy/codex/%2e%2e/%2e%2e/admin"},
			{"POST", "/v1/proxy/codex/responses%2Fcompact"},
			{"POST", "/v1/proxy/codex//responses"},
			{"POST", "/v1/proxy/codex/./responses"},
			{"POST", "/v1/proxy/codex/responses/"},
			{"POST", `/v1/proxy/codex/responses\..\x`},
			{"GET", "/v1/proxy/codex/wham/usage"},
			{"POST", "/v1/proxy/codex/tasks/list"},
			{"GET", "/v1/proxy/codex/responses"},
			{"DELETE", "/v1/proxy/codex/responses"},
			{"POST", "http://chatgpt.com/v1/proxy/codex/responses"},
		} {
			if st := raw(t, h, c.m, c.target, pass); st != http.StatusForbidden {
				t.Fatalf("direct=%v %s %s → %d, want 403", direct, c.m, c.target, st)
			}
		}
		if len(h.got) != before || h.hub.count() != calls {
			t.Fatalf("a refused path reached the upstream (%d→%d) or the hub (%d→%d)", before, len(h.got), calls, h.hub.count())
		}
		// the Claude half is untouched: any path still goes on
		if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages/count_tokens", PassPrefix+"c", `{}`, nil); st != 200 {
			t.Fatalf("claude path → %d", st)
		}
	}
}

// The list is ONE list: the node proxy's line is this package's line.
func TestCodexAllowMatchesPython(t *testing.T) {
	b, err := os.ReadFile("../../../bin/fleet-cred-proxy.py")
	if err != nil {
		t.Skip("no bin/fleet-cred-proxy.py beside this tree:", err)
	}
	m := regexp.MustCompile(`(?m)^CODEX_ALLOW_SPEC = "([^"]*)"$`).FindSubmatch(b)
	if m == nil {
		t.Fatal("bin/fleet-cred-proxy.py has no CODEX_ALLOW_SPEC line")
	}
	if string(m[1]) != CodexAllowSpec {
		t.Fatalf("node proxy %q ≠ central proxy %q", m[1], CodexAllowSpec)
	}
}
