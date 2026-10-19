package api

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

// The web chat with two hub replicas (claude-fleet#3847; BREAK-IT
// chat-relay-replica-hop): the person's page lands on the replica that does not
// hold their login's link, and the agent's data half lands on the one that did
// not ask for it — a front splits them — and the turn still goes through, with
// a SIGNING node, whose nonce is spent once, by the replica that serves it.

// A home no replica holds is still offline / home_down, and nothing is proxied.
func TestChatRelayReplicaNobodyHolds(t *testing.T) {
	ha, _ := newReplicaPair(t)
	enablePeople(t, ha, pAlice)
	setChatHome(t, ha, pAlice, "nowhere", "nobody")
	alice := personCookie(pAlice, "alice")
	resp := chatDo(t, ha, "GET", "/v1/chat/conversation", alice, nil, "")
	if resp.StatusCode != http.StatusServiceUnavailable || chatCode(t, resp) != "home_down" {
		t.Fatalf("home nobody holds: %d; want 503 home_down", resp.StatusCode)
	}
	resp = chatDo(t, ha, "GET", "/v1/chat/home", alice, nil, "")
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), `"state":"offline"`) {
		t.Fatalf("home nobody holds: %s; want offline", b)
	}
	if n := ha.srv.forwarded.Load(); n != 0 {
		t.Fatalf("A proxied %d request(s) with no holder anywhere", n)
	}
}
