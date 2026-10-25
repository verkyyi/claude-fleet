package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A home whose link is reconnecting (task PNWW): a chat request waits for the
// link to come back instead of answering home_down at once — only for a login
// heard from lately, never past the bound, never for a login never connected.
func TestChatLinkWaitsForAReconnect(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "home")
	n := dialAdminCaps(t, h, tok, false, control.CapChat)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "mac-h", OSUser: "lee"})
	waitFor(t, 3*time.Second, "the link carries chat", func() bool {
		up, _ := h.srv.chatLinkUp(httptest.NewRequest(http.MethodGet, "/", nil), "mac-h", "lee")
		return up
	})
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if h.srv.awaitChatLink(req, "mac-h", "lee", time.Second) {
		t.Fatal("waited on a link that is up")
	}
	// the link drops (a hub copy replaced, a stalled path)
	n.c.Close(websocket.StatusNormalClosure, "")
	waitFor(t, 3*time.Second, "the link is gone", func() bool {
		up, offline := h.srv.chatLinkUp(req, "mac-h", "lee")
		return !up && offline
	})
	// back within the wait: the request goes on
	go func() {
		time.Sleep(400 * time.Millisecond)
		n2 := dialAdminCaps(t, h, tok, false, control.CapChat)
		beat(t, n2.c, control.Proto, control.Heartbeat{Hostname: "mac-h", OSUser: "lee"})
	}()
	start := time.Now()
	if !h.srv.awaitChatLink(req, "mac-h", "lee", 5*time.Second) {
		t.Fatal("did not wait for a reconnecting home")
	}
	if up, _ := h.srv.chatLinkUp(req, "mac-h", "lee"); !up || time.Since(start) > 4*time.Second {
		t.Fatalf("after the wait: up=%v in %s", up, time.Since(start))
	}
	// never past the bound
	start = time.Now()
	if !h.srv.awaitChatLink(httptest.NewRequest(http.MethodGet, "/", nil), "mac-x", "nobody", 300*time.Millisecond) && time.Since(start) > time.Second {
		t.Fatal("a never-connected login was waited on")
	}
	// a login never heard from: no wait at all
	start = time.Now()
	if h.srv.awaitChatLink(req, "nowhere", "nobody", 5*time.Second) || time.Since(start) > time.Second {
		t.Fatal("waited for a login that was never connected")
	}
	// switched off
	h.srv.ChatLinkWaitSecs = -1
	if h.srv.chatLinkWait() != 0 {
		t.Fatal("a negative wait is not off")
	}
}
