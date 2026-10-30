package api

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

// task GXR5: a member who goes straight to the conversation gets their first
// home there, as 我的连接 gives it — never 「你还没有家」 on a login that is
// ready. A person with no live fleet still has none.
func TestChatHomeSetsTheFirstHome(t *testing.T) {
	h := entryHarness(t)
	if _, ok, err := h.srv.Store.EntryHomeOf(pAlice); err != nil || ok {
		t.Fatalf("Alice has a home before anything: %v %v", ok, err)
	}
	resp := chatDo(t, h, http.MethodGet, ChatPathPrefix+chatHomeRoute, personCookie(pAlice, "alice"), nil, "")
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || strings.Contains(string(raw), `"no_home"`) {
		t.Fatalf("Alice's first chat read: HTTP %d %s", resp.StatusCode, raw)
	}
	home, ok, err := h.srv.Store.EntryHomeOf(pAlice)
	if err != nil || !ok || home.SetBy != "auto" || home.Machine == "" {
		t.Fatalf("Alice's home after the chat read = %+v %v %v; want one set by auto", home, ok, err)
	}
}
