package e2e

import (
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"

	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// A turn that gets no reply keeps the trial's line (claude-fleet#4248): the
// service never answered (the relay broke), it refused the turn, or its stream
// ended on an error frame (no session credential) — the msgs stay as they were.
// A turn that got a reply is counted, even one that later says error.
func TestTrialFailedTurnKeepsTheLine(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setHubSetting(t, h.Srv, TrialKey, "on")
	setHubSetting(t, h.Srv, TrialMaxMsgsKey, "5")
	const pid = "p:00000000-0000-4000-8000-000000004248"
	c := trialSession(t, h, pid)
	if err := h.Srv.Store.PlaceTrial(pid, host, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pid, host, login)
	msgs := func() int {
		tr, err := h.Srv.Store.Trial(pid)
		if err != nil || tr == nil {
			t.Fatalf("trial: %v", err)
		}
		return tr.Msgs
	}
	turn := func(answer func(w http.ResponseWriter)) (int, string) {
		svc.mu.Lock()
		svc.turn = answer
		svc.mu.Unlock()
		resp := chatDo(t, h, "POST", "/v1/chat/turn", c, map[string]string{"X-Fleet-Webchat": "1"}, `{"text":"hi"}`)
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		waitFor(t, 5*time.Second, "relay released", func() bool { return h.Srv.ChatRelaysOpenForTest() == 0 })
		return resp.StatusCode, string(b)
	}
	ndjson := func(lines ...string) func(w http.ResponseWriter) {
		return func(w http.ResponseWriter) {
			w.Header().Set("Content-Type", "application/x-ndjson")
			for _, l := range lines {
				io.WriteString(w, l+"\n")
				w.(http.Flusher).Flush()
			}
		}
	}

	// No session credential: the stream ends on an error frame, nothing said.
	code, body := turn(ndjson(`{"t":"turn","id":"x","model":"m"}`,
		`{"t":"error","msg":"no session credential from the proxy (rc 1) — fleet-cred-proxy.sh status"}`))
	if code != http.StatusOK || !strings.Contains(body, "no session credential") {
		t.Fatalf("credential turn = %d %q", code, body)
	}
	if n := msgs(); n != 0 {
		t.Fatalf("msgs after a no-credential turn = %d; want 0", n)
	}

	// The service did not answer: the connection dies before any response.
	code, body = turn(func(w http.ResponseWriter) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
	})
	if code != http.StatusBadGateway || !strings.Contains(body, "did not answer") {
		t.Fatalf("broken turn = %d %q; want 502 relay", code, body)
	}
	if n := msgs(); n != 0 {
		t.Fatalf("msgs after a turn the service did not answer = %d; want 0", n)
	}

	// The service refused the turn outright (its SDK did not load).
	if code, _ = turn(func(w http.ResponseWriter) {
		w.WriteHeader(http.StatusServiceUnavailable)
		io.WriteString(w, `{"error":"no sdk"}`)
	}); code != http.StatusServiceUnavailable {
		t.Fatalf("refused turn = %d; want 503 passed on", code)
	}
	if n := msgs(); n != 0 {
		t.Fatalf("msgs after a refused turn = %d; want 0", n)
	}

	// A reply is a line, and so is a reply that ends on an error.
	turn(ndjson(`{"t":"turn","id":"y","model":"m"}`, `{"t":"text","d":"hello"}`, `{"t":"done","subtype":"success"}`))
	if n := msgs(); n != 1 {
		t.Fatalf("msgs after a replied turn = %d; want 1", n)
	}
	turn(ndjson(`{"t":"text","d":"half"}`, `{"t":"error","msg":"boom"}`))
	if n := msgs(); n != 2 {
		t.Fatalf("msgs after a half-replied turn = %d; want 2", n)
	}
}

// trialSession is a trial person's session cookie: their own role, not on
// the list.
func trialSession(t *testing.T, h *harness, pid string) *http.Cookie {
	t.Helper()
	if err := h.Srv.Store.StartTrialAs(pid, store.IdentityEmail, pid+"@example.com", time.Now()); err != nil {
		t.Fatal(err)
	}
	return &http.Cookie{Name: authz.CookieName, Value: authz.SignRole(store.IdentityEmail, pid, "trier", RoleTrialForTest,
		(&GitHubAuth{ClientSecret: testGitHubSecret}).SessionKeyForTest(), time.Now(), time.Hour)}
}
