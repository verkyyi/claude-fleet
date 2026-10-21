package e2e

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

// A person's two conversations (task R9A2): ?provider=codex reaches the home as
// that one query (nothing else of the page's goes on), 新对话 is a route, an
// unknown provider never leaves the entry, and the copy beside the entry is kept
// per assistant — the Codex conversation's read never replaces Claude's copy.
func TestChatProvider(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.Srv.Vault = &credvault.Vault{Store: h.Srv.Store, Sealer: sealer}
	setChatHome(t, h, pAlice, host, login)
	alice := personCookie(pAlice, "alice")
	page := map[string]string{"X-Fleet-Webchat": "1", "Content-Type": "application/json"}
	lastQuery := func() string {
		svc.mu.Lock()
		defer svc.mu.Unlock()
		return svc.queries[len(svc.queries)-1]
	}
	answer := func(session string) {
		svc.mu.Lock()
		svc.conversation = func(w http.ResponseWriter) {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"session":"`+session+`","items":[{"t":"text","d":"`+session+` says hi"}]}`)
		}
		svc.mu.Unlock()
	}

	answer("claude-s1")
	if r := chatDo(t, h, "GET", "/v1/chat/conversation", alice, nil, ""); r.StatusCode != http.StatusOK || lastQuery() != "" {
		t.Fatalf("the Claude side: %d query %q; want 200 and no query", r.StatusCode, lastQuery())
	}
	answer("thr-1")
	if r := chatDo(t, h, "GET", "/v1/chat/conversation?provider=codex&person=x", alice, nil, ""); r.StatusCode != http.StatusForbidden {
		t.Fatalf("another person named beside the provider: %d; want 403", r.StatusCode)
	}
	if r := chatDo(t, h, "GET", "/v1/chat/conversation?provider=codex&evil=1", alice, nil, ""); r.StatusCode != http.StatusOK || lastQuery() != "provider=codex" {
		t.Fatalf("the Codex side: %d query %q; want 200 and provider=codex only", r.StatusCode, lastQuery())
	}
	n := len(svc.seen())
	if r := chatDo(t, h, "GET", "/v1/chat/conversation?provider=gemini", alice, nil, ""); r.StatusCode != http.StatusBadRequest || len(svc.seen()) != n {
		t.Fatalf("an unknown provider: %d, reached the home %v; want 400 and not", r.StatusCode, len(svc.seen()) != n)
	}
	if r := chatDo(t, h, "POST", "/v1/chat/new?provider=codex", alice, page, "{}"); r.StatusCode != http.StatusOK {
		t.Fatalf("新对话: %d", r.StatusCode)
	}
	if hits := svc.seen(); !strings.HasPrefix(hits[len(hits)-1], "POST /api/new ") || lastQuery() != "provider=codex" {
		t.Fatalf("新对话 reached %q with %q", hits[len(hits)-1], lastQuery())
	}
	// one copy per assistant
	cached := func(q string) string {
		r := chatDo(t, h, "GET", "/v1/chat/conversation?cached=1"+q, alice, nil, "")
		b, _ := io.ReadAll(r.Body)
		return string(b)
	}
	waitFor(t, 5e9, "both copies kept", func() bool {
		return strings.Contains(cached(""), "claude-s1 says hi") && strings.Contains(cached("&provider=codex"), "thr-1 says hi")
	})
	if c := cached(""); strings.Contains(c, "thr-1") {
		t.Errorf("the Claude copy holds the Codex conversation: %s", c)
	}
}
