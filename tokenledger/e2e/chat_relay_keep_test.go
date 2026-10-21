package e2e

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
)

// A kept relay (task V9DJ B): one person's requests to their home ride one
// relay the agent dialled once; still only theirs, and a running stream is
// cut once their home moves.
func TestChatRelayKept(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	h.Srv.ChatRelayKeepSecs = 60
	setChatHome(t, h, pAlice, host, login)
	alice := personCookie(pAlice, "alice")
	get := func() string {
		req, _ := http.NewRequest("GET", h.HTTP.URL+"/v1/chat/conversation", nil)
		req.AddCookie(alice)
		resp, err := h.HTTP.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("conversation: %d %s", resp.StatusCode, b)
		}
		return string(b)
	}
	for i := 0; i < 5; i++ {
		if b := get(); !strings.Contains(b, `"session":"s1"`) {
			t.Fatalf("read %d: %s", i, b)
		}
	}
	if n := chatAudits(t, h, "chat_relay"); n != 1 {
		t.Errorf("5 reads opened %d relays; want 1 kept", n)
	}
	for _, hit := range svc.seen() {
		if hit != "GET /api/conversation person="+pAlice+" cookie=" {
			t.Errorf("the service saw %q; want each read as %s", hit, pAlice)
		}
	}
	if n := h.Srv.ChatRelaysOpenForTest(); n != 1 {
		t.Errorf("%d relays open between reads; want the kept one", n)
	}

	// Bob's request never rides Alice's relay.
	setChatHome(t, h, pBob, host, login)
	req, _ := http.NewRequest("GET", h.HTTP.URL+"/v1/chat/conversation", nil)
	req.AddCookie(personCookie(pBob, "bob"))
	resp, err := h.HTTP.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.ReadAll(resp.Body)
	resp.Body.Close()
	hits := svc.seen()
	if last := hits[len(hits)-1]; last != "GET /api/conversation person="+pBob+" cookie=" {
		t.Errorf("bob's read reached the service as %q", last)
	}
	if n := chatAudits(t, h, "chat_relay"); n != 2 {
		t.Errorf("%d relays audited after bob's read; want his own (2)", n)
	}

	// A turn still streaming is cut once alice's home moves.
	old := SetChatRecheckForTest(100 * time.Millisecond)
	defer old()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	treq, _ := http.NewRequestWithContext(ctx, "POST", h.HTTP.URL+"/v1/chat/turn", strings.NewReader(`{"text":"hi"}`))
	treq.AddCookie(alice)
	treq.Header.Set("X-Fleet-Webchat", "1")
	treq.Header.Set("Content-Type", "application/json")
	tresp, err := h.HTTP.Client().Do(treq)
	if err != nil {
		t.Fatal(err)
	}
	defer tresp.Body.Close()
	line, err := bufio.NewReader(tresp.Body).ReadString('\n')
	if err != nil || !strings.Contains(line, `"start"`) {
		t.Fatalf("turn's first line: %q %v", line, err)
	}
	started := time.Now()
	setChatHome(t, h, pAlice, "elsewhere", login)
	rest, _ := io.ReadAll(tresp.Body)
	if strings.Contains(string(rest), `"done"`) || time.Since(started) > 5*time.Second {
		t.Errorf("the stream went on after the home moved (%s): %q", time.Since(started), rest)
	}
	if n := chatAudits(t, h, "chat_relay"); n < 3 {
		t.Errorf("%d chat_relay rows; want the REVOKED one too", n)
	}
	h.Srv.CloseKeptChatRelaysForTest()
	waitFor(t, 5*time.Second, "kept relays released", func() bool { return h.Srv.ChatRelaysOpenForTest() == 0 })
}
