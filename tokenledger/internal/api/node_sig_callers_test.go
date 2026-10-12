package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/nodesig"
)

// The second slice (claude-fleet#3710): every caller signs, every door that
// reads a node token goes through nodeAuth, and a copied token is dead on all
// of them once its node says bearer_off.

// signedDo sends one request to the harness, signed by s or shown tok.
func signedDo(t *testing.T, h *harness, s *nodesig.Signer, tok, method, path, body string) int {
	t.Helper()
	req, _ := http.NewRequest(method, h.http.URL+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	nodesig.Set(req, s, tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	return res.StatusCode
}

// The node's half end to end: Ensure makes and registers the key, it signs
// every door, bearer_off kills a copied token everywhere — and a node that
// joined again (a new endpoint) gets a new key, the old one set aside.
func TestNodeSigEnsureAndEveryDoor(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m1")
	path := filepath.Join(t.TempDir(), "node.key")

	s, note := nodesig.Ensure(context.Background(), h.http.Client(), h.http.URL+"/", tok, path)
	if s == nil || !strings.Contains(note, "made and registered") {
		t.Fatalf("Ensure = %v %q", s, note)
	}
	if c := nodesig.Confirmed(path, h.http.URL); c == nil || c.ID() != s.ID() {
		t.Fatalf("Confirmed after Ensure = %v", c)
	}
	if again, note := nodesig.Ensure(context.Background(), h.http.Client(), h.http.URL, tok, path); again == nil || again.ID() != s.ID() || note != "" {
		t.Fatalf("Ensure again = %v %q", again, note)
	}

	doors := []struct{ method, path, body string }{
		{http.MethodPost, "/v1/ingest", `{}`},
		{http.MethodPost, "/v1/live/report", `{"sessions":[],"complete":true}`},
		{http.MethodPost, "/v1/node/lease", `{}`},
		{http.MethodPost, "/v1/node/place", `{}`},
		{http.MethodPost, "/v1/collectors/quota-lease", `{}`},
		{http.MethodPost, "/v1/node/credentials", `{}`},
		{http.MethodGet, NodeKeyPath, ``},
	}
	for _, d := range doors {
		if st := signedDo(t, h, s, tok, d.method, d.path, d.body); st == http.StatusUnauthorized {
			t.Fatalf("signed %s %s = 401", d.method, d.path)
		}
		if st := signedDo(t, h, nil, tok, d.method, d.path, d.body); st == http.StatusUnauthorized {
			t.Fatalf("bearer %s %s before bearer_off = 401", d.method, d.path)
		}
	}

	req, _ := http.NewRequest(http.MethodPost, h.http.URL+NodeKeyPath,
		strings.NewReader(`{"public_key":"`+mustPub(t, path)+`","proof":"`+mustProof(t, path)+`","bearer_off":true}`))
	nodesig.Set(req, s, tok)
	if res, err := h.http.Client().Do(req); err != nil || res.StatusCode != 200 {
		t.Fatalf("bearer_off = %v %v", res, err)
	}
	for _, d := range doors {
		if st := signedDo(t, h, nil, tok, d.method, d.path, d.body); st != http.StatusUnauthorized {
			t.Fatalf("a copied token on %s %s after bearer_off = %d", d.method, d.path, st)
		}
		if st := signedDo(t, h, s, tok, d.method, d.path, d.body); st == http.StatusUnauthorized {
			t.Fatalf("signed %s %s after bearer_off = 401", d.method, d.path)
		}
	}

	// joined again: a new endpoint, the key still bound to the old one ⇒ set
	// aside, a new key registered
	tok2 := h.enroll(t, "m1b")
	s2, note := nodesig.Ensure(context.Background(), h.http.Client(), h.http.URL, tok2, path)
	if s2 == nil || s2.ID() == s.ID() || !strings.Contains(note, "registered") {
		t.Fatalf("Ensure after a re-join = %v %q", s2, note)
	}
	if old, _ := filepath.Glob(path + ".old-*"); len(old) != 1 {
		t.Fatalf("the old key was not set aside: %v", old)
	}
}

func mustPub(t *testing.T, path string) string {
	t.Helper()
	body := registerBodyOf(t, path)
	return body["public_key"]
}

func mustProof(t *testing.T, path string) string {
	t.Helper()
	return registerBodyOf(t, path)["proof"]
}

// registerBodyOf reads the key file's seed and builds the register body the
// way bin/fleet_node_sig.py does.
func registerBodyOf(t *testing.T, path string) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	n := sigNodeFromSeed(t, strings.TrimSpace(string(raw)))
	return map[string]string{"public_key": n.pub, "proof": n.proof()}
}

// A hub that does not take keys gets none made: no file, the bearer stays.
func TestNodeSigEnsureOldHubMakesNothing(t *testing.T) {
	old := httptest.NewServer(http.NotFoundHandler())
	defer old.Close()
	path := filepath.Join(t.TempDir(), "node.key")
	if s, note := nodesig.Ensure(context.Background(), old.Client(), old.URL, "tok", path); s != nil || note != "" {
		t.Fatalf("Ensure on an old hub = %v %q", s, note)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("a key was made for a hub that takes none: %v", err)
	}
	if c := nodesig.Confirmed(path, old.URL); c != nil {
		t.Fatal("Confirmed with no key")
	}
}

// One signed request may be asked about twice (an identity tried, then
// another): its nonce is spent once and both answers agree.
func TestNodeSigOneRequestTwoAsks(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m1")
	n := newSigNode(t)
	if st, got := sigCall(t, h, "Bearer "+tok, http.MethodPost, NodeKeyPath, map[string]any{"public_key": n.pub, "proof": n.proof()}); st != 200 {
		t.Fatalf("register = %d %v", st, got)
	}
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/v1/node/self", nil).WithContext(ctx)
	req.Header.Set("Authorization", n.header(http.MethodGet, "/v1/node/self", "nonce-twice-aaaaaaaaaa", time.Now()))
	for i := 0; i < 2; i++ {
		if ep, _, code, msg := h.srv.nodeAuth(req); ep == nil || ep.ID != "ep_m1" {
			t.Fatalf("ask %d = %d %s", i+1, code, msg)
		}
	}
	cancel()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, held := h.srv.nodeSigSeen.Load(req); !held {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the answer outlived its request")
		}
		time.Sleep(5 * time.Millisecond)
	}
	// a second request with the same header is the replay it always was
	req2 := httptest.NewRequest(http.MethodGet, "/v1/node/self", nil)
	req2.Header.Set("Authorization", req.Header.Get("Authorization"))
	if ep, _, code, msg := h.srv.nodeAuth(req2); ep != nil || !strings.Contains(msg, "replayed") {
		t.Fatalf("the same header on another request = %d %s", code, msg)
	}
}
