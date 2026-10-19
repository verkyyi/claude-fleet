package e2e

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// startSignedChatAgent runs a real chat agent that signs its requests (a
// FleetSig key, claude-fleet#3710), dials hubURL, and whose link holder is
// holder; it returns the machine and the login.
func startSignedChatAgent(t *testing.T, holder *harness, hubURL, label, conf string) (string, string) {
	t.Helper()
	t.Setenv("FLEET_CONF_DIR", conf)
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	a, err := agent.New(agent.Config{
		HubURL: hubURL, Token: holder.Enroll(t, label), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		KeyFile: filepath.Join(home, "node.key"),
		Sources: "claude", LiveInterval: 200 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetChat: true, Version: "it-" + label,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	host, _ := os.Hostname()
	waitFor(t, 5*time.Second, "agent connected as its login", func() bool {
		c := holder.Srv.NodeForTest("ep_" + label)
		return c != nil && c.HostnameForTest() == host && c.UserForTest() == me.Username
	})
	waitFor(t, 5*time.Second, "its link recorded", func() bool { return holderOf(holder, "ep_"+label) })
	if _, err := holder.Srv.Store.NodeKeyOf("ep_" + label); err != nil {
		t.Fatalf("the agent registered no signing key: %v", err)
	}
	return host, me.Username
}

// spentNonce counts how often the hubs' shared store has seen one signature's
// nonce.
func spentNonce(t *testing.T, h *harness, nonce string) int {
	t.Helper()
	var n int
	if err := h.Srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_sig_nonces WHERE nonce = ?`, nonce).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestChatRelayReplicaHop(t *testing.T) {
	ha, hb := newReplicaPair(t)
	for _, h := range []*harness{ha, hb} {
		enablePeople(t, h, pAlice)
	}
	ua, _ := url.Parse(ha.HTTP.URL)
	ub, _ := url.Parse(hb.HTTP.URL)
	pa, pb := httputil.NewSingleHostReverseProxy(ua), httputil.NewSingleHostReverseProxy(ub)
	var dataOnA atomic.Int64
	var dataAuth atomic.Value
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == control.ChatRelayDataPath {
			dataOnA.Add(1)
			dataAuth.Store(r.Header.Get("Authorization"))
			pa.ServeHTTP(w, r)
			return
		}
		pb.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)

	conf := shortTemp(t)
	svc := serveFakeChat(t, conf)
	host, login := startSignedChatAgent(t, hb, front.URL, "chat-hop", conf)
	setChatHome(t, ha, pAlice, host, login)
	alice := personCookie(pAlice, "alice")

	// A holds no link: its home read is B's, and says ok.
	resp := chatDo(t, ha, "GET", "/v1/chat/home", alice, nil, "")
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `"state":"ok"`) {
		t.Fatalf("home asked of A: %d %s; want ok", resp.StatusCode, b)
	}

	// The page asks A; B opens the relay; the agent's data half lands on A.
	resp = chatDo(t, ha, "GET", "/v1/chat/conversation", alice, nil, "")
	b, _ = io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `"session":"s1"`) {
		t.Fatalf("conversation asked of A: %d %s (the page's «连不上»)", resp.StatusCode, b)
	}
	if hits := svc.seen(); len(hits) != 1 || !strings.HasPrefix(hits[0], "GET /api/conversation person="+pAlice) {
		t.Fatalf("the service saw %q; want one GET as %s", hits, pAlice)
	}
	if n := dataOnA.Load(); n != 1 {
		t.Fatalf("data halves through A = %d, want 1", n)
	}
	// Two hand-overs by A (the home read, the page's request, the data half),
	// none by B — and the data half's signature spent exactly once.
	if n := ha.Srv.ForwardedForTest(); n != 3 {
		t.Fatalf("A proxied %d request(s), want 3", n)
	}
	if n := hb.Srv.ForwardedForTest(); n != 0 {
		t.Fatalf("B proxied %d request(s) it was handed (a bounce)", n)
	}
	// Counted by the data half's own nonce, not the table's growth: the agent
	// signs its other requests too, and one landing in this window read as a
	// second spend (claude-fleet#4679: "2 signatures spent").
	auth, _ := dataAuth.Load().(string)
	nonce := regexp.MustCompile(`nonce=([^,\s]+)`).FindStringSubmatch(auth)
	if nonce == nil {
		t.Fatalf("the data half was not signed: Authorization %q", auth)
	}
	if n := spentNonce(t, ha, nonce[1]); n != 1 {
		t.Fatalf("the data half's signature spent %d time(s), want 1", n)
	}
	if n := chatAudits(t, ha, "chat_relay"); n != 1 {
		t.Errorf("%d relays audited; want 1 (by B, which carried it)", n)
	}
	waitFor(t, 5*time.Second, "relay released", func() bool { return hb.Srv.ChatRelaysOpenForTest() == 0 })

	// Asked of B, the holder, nothing is proxied.
	before := ha.Srv.ForwardedForTest()
	resp = chatDo(t, hb, "GET", "/v1/chat/conversation", alice, nil, "")
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("conversation asked of B: %d", resp.StatusCode)
	}
	if hb.Srv.ForwardedForTest() != 0 || ha.Srv.ForwardedForTest() != before+1 {
		// +1: the data half still lands on A, which hands it to B.
		t.Fatalf("a request asked of the holder was proxied: A %d→%d, B %d", before, ha.Srv.ForwardedForTest(), hb.Srv.ForwardedForTest())
	}
}

// A single hub never proxies a chat request.
func TestChatRelayReplicaSingleNeverProxies(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setChatHome(t, h, pAlice, host, login)
	resp := chatDo(t, h, "GET", "/v1/chat/conversation", personCookie(pAlice, "alice"), nil, "")
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK || len(svc.seen()) != 1 {
		t.Fatalf("conversation on a single hub: %d, service saw %v", resp.StatusCode, svc.seen())
	}
	if n := h.Srv.ForwardedForTest(); n != 0 {
		t.Fatalf("a single hub proxied %d request(s)", n)
	}
}
