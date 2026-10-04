package agent

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// refreshHub is a hub that sends one TypeOAuthRefresh after the hello and
// keeps every answer.
type refreshHub struct {
	srv     *httptest.Server
	req     control.Message
	mu      sync.Mutex
	hellos  []control.Hello
	results []control.Message
	errors  []control.Message
}

func newRefreshHub(t *testing.T, req control.OAuthRefresh) *refreshHub {
	t.Helper()
	m, _ := control.New(control.TypeOAuthRefresh, req)
	h := &refreshHub{req: m}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != control.Path {
			w.Write([]byte(`{}`))
			return
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx := r.Context()
		var hello control.Message
		if wsjson.Read(ctx, c, &hello) != nil {
			return
		}
		var hp control.Hello
		json.Unmarshal(hello.Payload, &hp)
		h.mu.Lock()
		first := len(h.hellos) == 0
		h.hellos = append(h.hellos, hp)
		h.mu.Unlock()
		reply, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true, HubProto: control.Proto, MinProto: control.MinProto})
		reply.OpID = hello.OpID
		if wsjson.Write(ctx, c, reply) != nil {
			return
		}
		if first {
			if wsjson.Write(ctx, c, h.req) != nil {
				return
			}
		}
		for {
			var m control.Message
			if wsjson.Read(ctx, c, &m) != nil {
				return
			}
			h.mu.Lock()
			switch m.Type {
			case control.TypeOAuthRefreshResult:
				h.results = append(h.results, m)
			case control.TypeError:
				h.errors = append(h.errors, m)
			}
			h.mu.Unlock()
		}
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *refreshHub) snapshot() (hellos []control.Hello, results, errs []control.Message) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]control.Hello(nil), h.hellos...), append([]control.Message(nil), h.results...), append([]control.Message(nil), h.errors...)
}

func refreshTestAgent(t *testing.T, hub, provider string, admin bool) *Agent {
	t.Helper()
	home := t.TempDir()
	a, err := New(Config{
		HubURL: hub, Token: "tok", Home: home, Sources: "claude",
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		LiveInterval: 50 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Version: "test", Fleet: true, FleetAdmin: admin, FleetOAuthRefresh: true,
		OAuthTokenURLs: map[string]string{"codex": provider},
	})
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	buf := &bytes.Buffer{}
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	return buf
}

const theSecret = "rt-SECRET-never-logged"

func TestOAuthRefreshPostsOnceAndLogsNoToken(t *testing.T) {
	shrinkBackoff(t)
	var hits atomic.Int64
	var gotForm atomic.Value
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		var form map[string]string
		json.NewDecoder(r.Body).Decode(&form)
		gotForm.Store(form)
		if r.Header.Get("Content-Type") != "application/json" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"access_token":"at-SECRET-1","refresh_token":"rt-SECRET-2","id_token":"id-SECRET"}`))
	}))
	t.Cleanup(provider.Close)
	hub := newRefreshHub(t, control.OAuthRefresh{Provider: "codex", Form: map[string]string{
		"grant_type": "refresh_token", "refresh_token": theSecret, "client_id": "app_x", "scope": "openid profile email"}})
	logs := captureLog(t)
	runFor(t, refreshTestAgent(t, hub.srv.URL, provider.URL, true), 800*time.Millisecond)

	hellos, results, errs := hub.snapshot()
	if len(hellos) == 0 || !hellos[0].HasCap(control.CapOAuthRefresh) || !hellos[0].Admin {
		t.Fatalf("hello = %+v, want admin + oauth_refresh capability", hellos)
	}
	if len(errs) != 0 || len(results) != 1 {
		t.Fatalf("results %d errors %+v, want one result", len(results), errs)
	}
	var res control.OAuthRefreshResult
	if err := json.Unmarshal(results[0].Payload, &res); err != nil || results[0].OpID != hub.req.OpID {
		t.Fatalf("result %+v: %v", results[0], err)
	}
	if res.Status != http.StatusOK || res.Error != "" || !strings.Contains(res.Body, `"refresh_token":"rt-SECRET-2"`) {
		t.Fatalf("result = %+v, want the provider's answer verbatim", res)
	}
	if hits.Load() != 1 {
		t.Fatalf("provider hit %d times, want 1", hits.Load())
	}
	form, _ := gotForm.Load().(map[string]string)
	if form["refresh_token"] != theSecret || form["client_id"] != "app_x" {
		t.Fatalf("provider got form %v, want the hub's", form)
	}
	l := logs.String()
	for _, s := range []string{theSecret, "at-SECRET-1", "rt-SECRET-2", "id-SECRET"} {
		if strings.Contains(l, s) {
			t.Fatalf("a token reached the agent log:\n%s", l)
		}
	}
	if !strings.Contains(l, "relayed a codex refresh for the hub: HTTP 200") {
		t.Fatalf("no status line in the log:\n%s", l)
	}
}

func TestOAuthRefreshRefusedByNonAdmin(t *testing.T) {
	shrinkBackoff(t)
	var hits atomic.Int64
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
	t.Cleanup(provider.Close)
	hub := newRefreshHub(t, control.OAuthRefresh{Provider: "codex", Form: map[string]string{"refresh_token": theSecret}})
	logs := captureLog(t)
	runFor(t, refreshTestAgent(t, hub.srv.URL, provider.URL, false), 600*time.Millisecond)

	hellos, results, errs := hub.snapshot()
	if len(hellos) == 0 || hellos[0].HasCap(control.CapOAuthRefresh) {
		t.Fatalf("a non-admin agent offered the relay: %+v", hellos)
	}
	if len(results) != 0 || len(errs) != 1 || errs[0].Error == nil || errs[0].Error.Code != control.CodeNotAdmin || errs[0].OpID != hub.req.OpID {
		t.Fatalf("results %+v errors %+v, want one NOT_ADMIN refusal", results, errs)
	}
	if hits.Load() != 0 {
		t.Fatal("a non-admin agent posted to the provider")
	}
	if strings.Contains(logs.String(), theSecret) {
		t.Fatalf("token in log:\n%s", logs.String())
	}
}

func TestOAuthRefreshRefusesUnknownProviderAndReportsTransportError(t *testing.T) {
	shrinkBackoff(t)
	// Unknown provider: BAD_ARGS, nothing posted.
	hub := newRefreshHub(t, control.OAuthRefresh{Provider: "github", Form: map[string]string{"refresh_token": theSecret}})
	runFor(t, refreshTestAgent(t, hub.srv.URL, "http://127.0.0.1:9/never", true), 600*time.Millisecond)
	_, results, errs := hub.snapshot()
	if len(results) != 0 || len(errs) != 1 || errs[0].Error == nil || errs[0].Error.Code != control.CodeBadArgs {
		t.Fatalf("unknown provider: results %+v errors %+v", results, errs)
	}

	// Provider unreachable: a result with Error set and no status, so the hub
	// reports refresh_unavailable rather than waiting out its timeout.
	hub2 := newRefreshHub(t, control.OAuthRefresh{Provider: "codex", Form: map[string]string{"refresh_token": theSecret}})
	logs := captureLog(t)
	runFor(t, refreshTestAgent(t, hub2.srv.URL, "http://127.0.0.1:9/closed", true), 800*time.Millisecond)
	_, results, errs = hub2.snapshot()
	if len(errs) != 0 || len(results) != 1 {
		t.Fatalf("unreachable provider: results %+v errors %+v", results, errs)
	}
	var res control.OAuthRefreshResult
	json.Unmarshal(results[0].Payload, &res)
	if res.Status != 0 || res.Error == "" || res.Body != "" {
		t.Fatalf("result = %+v, want status 0 + transport error", res)
	}
	if strings.Contains(res.Error, theSecret) || strings.Contains(logs.String(), theSecret) {
		t.Fatal("the transport error or the log carried the token")
	}
}
