package api

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// The GitHub sign-in's token exchange through the Singapore relay
// (claude-fleet#3392): github.com is unreliable from the hub's cluster, so
// with CCQUOTA_GITHUB_OAUTH_VIA=relay the one POST goes to the relay's
// /github-oauth/ route with the hub's own pass, and github.com directly only
// when the relay cannot be asked.

// Only the hub's own pass opens the route, and only its one path.
func TestGitHubRelayRouteCheck(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	pass, err := h.srv.HubRelayPass()
	if err != nil {
		t.Fatal(err)
	}
	if code, who := relayCheck(t, h, pass, relayGitHubTokenPath); code != http.StatusOK || who != "hub" {
		t.Fatalf("hub pass on %s: %d who=%q", relayGitHubTokenPath, code, who)
	}
	for _, uri := range []string{"/github-oauth/", "/github-oauth/login/oauth/authorize",
		"/github-oauth/login/oauth/access_token/x", "/github-oauth/user"} {
		if code, _ := relayCheck(t, h, pass, uri); code != http.StatusForbidden {
			t.Fatalf("hub pass on %q: %d, want 403", uri, code)
		}
	}
	// A machine's relay credential opens the vendors' routes, never github.com.
	tok := mustMintRelay(t, h, m4)
	if code, _ := relayCheck(t, h, tok, relayGitHubTokenPath); code != http.StatusForbidden {
		t.Fatalf("machine pass on %s: %d, want 403", relayGitHubTokenPath, code)
	}
	if code, _ := relayCheck(t, h, tok, "/openai-auth/oauth/token"); code != http.StatusOK {
		t.Fatalf("machine pass on /openai-auth/ after a github refusal: %d", code)
	}
}

// fakeGitHubRelay does what extras/cred-relay/Caddyfile does for the route:
// forward_auth against the hub's real relay check (its handler, called
// directly: the sign-in harness mounts no fleet module), strip the pass and the
// prefix, forward to the (fake) github.com.
type fakeGitHubRelay struct {
	srv  *httptest.Server
	hits atomic.Int32
}

func newFakeGitHubRelay(t *testing.T, hub *Server, github string) *fakeGitHubRelay {
	f := &fakeGitHubRelay{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits.Add(1)
		chk := httptest.NewRequest(http.MethodGet, RelayCheckPath, nil)
		chk.Header.Set(RelayHeader, r.Header.Get(RelayHeader))
		chk.Header.Set("X-Forwarded-Uri", r.URL.RequestURI())
		chk.Header.Set("X-Forwarded-Method", r.Method)
		rec := httptest.NewRecorder()
		hub.handleRelayCheck(rec, chk)
		if rec.Code != http.StatusOK {
			w.WriteHeader(rec.Code)
			_, _ = w.Write(rec.Body.Bytes())
			return
		}
		up, _ := http.NewRequest(r.Method, github+strings.TrimPrefix(r.URL.Path, "/github-oauth"), r.Body)
		for k, v := range r.Header {
			if k != RelayHeader {
				up.Header[k] = v
			}
		}
		ur, err := http.DefaultClient.Do(up)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer ur.Body.Close()
		w.WriteHeader(ur.StatusCode)
		_, _ = io.Copy(w, ur.Body)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

// hangServer never answers until the caller gives up: github.com as the
// cluster sees it.
func hangServer(t *testing.T) (*httptest.Server, *atomic.Int32) {
	var hits atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		select {
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
	}))
	t.Cleanup(s.Close)
	return s, &hits
}

// captureLog collects the hub's log lines for the test.
func captureLog(t *testing.T) *syncBuf {
	b := &syncBuf{}
	prev := log.Writer()
	log.SetOutput(b)
	t.Cleanup(func() { log.SetOutput(prev) })
	return b
}

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newRelayGitHubHarness(t *testing.T) *ghHarness {
	h := newGitHubHarnessWith(t, func(s *Server) { s.SessionCredKey = bytes.Repeat([]byte{9}, 32) }, ghAdmin.Login)
	h.addUser(t, ghAlice)
	h.srv.GitHub.RelayPass = h.srv.HubRelayPass
	return h
}

// github.com unreachable, the switch on: the exchange goes through the relay,
// succeeds, and says so in the log; github.com is never tried.
func TestGitHubSignIn_ThroughRelay(t *testing.T) {
	h := newRelayGitHubHarness(t)
	gh := h.gh.srv.URL
	dead, direct := hangServer(t)
	h.srv.GitHub.TokenURL = dead.URL + "/login/oauth/access_token"
	relay := newFakeGitHubRelay(t, h.srv, gh)
	h.srv.GitHub.RelayURL = relay.srv.URL + "/"
	h.srv.GitHub.DirectTimeout = time.Second
	logs := captureLog(t)

	cb, sess := h.signIn(t, ghAlice)
	if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != "/" || sess == nil {
		t.Fatalf("callback = %d → %q (session %v)", cb.StatusCode, cb.Header.Get("Location"), sess)
	}
	if relay.hits.Load() != 1 || direct.Load() != 0 || h.gh.exchanged != 1 {
		t.Fatalf("relay %d, direct %d, github exchanges %d; want 1, 0, 1", relay.hits.Load(), direct.Load(), h.gh.exchanged)
	}
	if !strings.Contains(logs.String(), "token exchanged through the relay "+relay.srv.URL) {
		t.Fatalf("no relay line in the log:\n%s", logs)
	}
	// GitHub's own answer through the relay — a bad code — ends it: no
	// second try against github.com.
	form := url.Values{"client_id": {"Iv1.test"}, "client_secret": {"shh"}, "code": {"nope"}}
	if _, err := h.srv.githubExchange(context.Background(), form); err == nil || !strings.Contains(err.Error(), "bad_verification_code") {
		t.Fatalf("bad code: %v", err)
	}
	if direct.Load() != 0 {
		t.Fatal("GitHub's own refusal through the relay was retried directly")
	}
}

// The relay down, or refusing: github.com directly, once.
func TestGitHubSignIn_RelayDownFallsBackDirect(t *testing.T) {
	for name, set := range map[string]func(h *ghHarness){
		"relay unreachable": func(h *ghHarness) {
			gone := httptest.NewServer(http.NotFoundHandler())
			gone.Close()
			h.srv.GitHub.RelayURL = gone.URL
		},
		"relay refuses the pass": func(h *ghHarness) {
			h.srv.GitHub.RelayURL = newFakeGitHubRelay(t, h.srv, h.gh.srv.URL).srv.URL
			h.srv.GitHub.RelayPass = func() (string, error) { return hubRelayPassPrefix + "1.forged", nil }
		},
		"relay hangs": func(h *ghHarness) {
			s, _ := hangServer(t)
			h.srv.GitHub.RelayURL = s.URL
			h.srv.GitHub.RelayTimeout = 200 * time.Millisecond
		},
	} {
		t.Run(name, func(t *testing.T) {
			h := newRelayGitHubHarness(t)
			set(h)
			logs := captureLog(t)
			cb, sess := h.signIn(t, ghAlice)
			if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != "/" || sess == nil {
				t.Fatalf("callback = %d → %q", cb.StatusCode, cb.Header.Get("Location"))
			}
			if h.gh.exchanged != 1 {
				t.Fatalf("github exchanges %d, want 1 (direct)", h.gh.exchanged)
			}
			if !strings.Contains(logs.String(), "trying github.com directly") {
				t.Fatalf("no fallback line in the log:\n%s", logs)
			}
		})
	}
}

// Both roads dead: the person gets the usual "could not reach GitHub" page,
// bounded by the two timeouts — and the defaults stay under the 15 s a person
// waited before.
func TestGitHubSignIn_RelayAndGitHubDownIsBounded(t *testing.T) {
	if githubRelayTimeout+githubDirectTimeout >= 15*time.Second {
		t.Fatalf("relay %v + direct %v ≥ 15s", githubRelayTimeout, githubDirectTimeout)
	}
	h := newRelayGitHubHarness(t)
	relay, rhits := hangServer(t)
	dead, dhits := hangServer(t)
	h.srv.GitHub.RelayURL = relay.URL
	h.srv.GitHub.TokenURL = dead.URL + "/login/oauth/access_token"
	h.srv.GitHub.RelayTimeout = 300 * time.Millisecond
	h.srv.GitHub.DirectTimeout = 300 * time.Millisecond
	start := time.Now()
	cb, sess := h.signIn(t, ghAlice)
	took := time.Since(start)
	if cb.Header.Get("Location") != "/signin?e=github" || sess != nil {
		t.Fatalf("callback → %q (session %v), want /signin?e=github", cb.Header.Get("Location"), sess)
	}
	if rhits.Load() != 1 || dhits.Load() != 1 {
		t.Fatalf("relay %d, direct %d; want one try each", rhits.Load(), dhits.Load())
	}
	if took > 3*time.Second {
		t.Fatalf("took %v", took)
	}
}
