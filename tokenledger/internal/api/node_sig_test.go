package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// A node's signed requests (claude-fleet#3699).

type sigNode struct {
	key ed25519.PrivateKey
	pub string
	id  string
}

func newSigNode(t *testing.T) sigNode {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return sigNode{key: priv, pub: base64.StdEncoding.EncodeToString(pub), id: NodeKeyID(pub)}
}

func (n sigNode) header(method, uri, nonce string, at time.Time) string {
	ts := strconv.FormatInt(at.Unix(), 10)
	sig := ed25519.Sign(n.key, NodeSigMessage(n.id, ts, nonce, method, uri))
	return "FleetSig keyid=" + n.id + ", ts=" + ts + ", nonce=" + nonce + ", sig=" + base64.RawURLEncoding.EncodeToString(sig)
}

func (n sigNode) proof() string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(n.key, []byte(nodeKeyProofLine+"\n"+n.pub)))
}

func sigCall(t *testing.T, h *harness, auth, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if out == nil {
		out = map[string]any{"raw": string(raw)}
	}
	return res.StatusCode, out
}

// nodeEndpointAnswer runs nodeEndpoint itself on a request carrying auth.
func nodeEndpointAnswer(h *harness, auth string) (int, string) {
	req := httptest.NewRequest(http.MethodGet, "/v1/node/self", nil)
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	ep, ok := h.srv.nodeEndpoint(w, req)
	if ok {
		return 200, ep.ID
	}
	return w.Code, strings.TrimSpace(w.Body.String())
}

// No key registered ⇒ the bearer is read exactly as before: the same
// endpoint, the same refusals, word for word.
func TestNodeSigOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m1")
	if code, id := nodeEndpointAnswer(h, "Bearer "+tok); code != 200 || id != "ep_m1" {
		t.Fatalf("bearer = %d %q", code, id)
	}
	if code, body := nodeEndpointAnswer(h, ""); code != 401 || !strings.Contains(body, "missing bearer token") {
		t.Fatalf("no header = %d %s", code, body)
	}
	if code, body := nodeEndpointAnswer(h, "Bearer nope"); code != 401 || !strings.Contains(body, "unrecognised enrollment token") {
		t.Fatalf("unknown token = %d %s", code, body)
	}
	if st, got := sigCall(t, h, "Bearer "+tok, http.MethodGet, NodeKeyPath, nil); st != 200 || got["key_id"] != "" {
		t.Fatalf("GET key with none = %d %v", st, got)
	}
}

// The completion criterion, hub side: a node registers its key (with a proof
// it holds it), then signs; a signature is good once, inside ±2 minutes, for
// the method and path it names; once the node says bearer_off a copied token
// is refused everywhere nodeEndpoint guards — and cannot turn it back on.
func TestNodeSigRegisterSignReplay(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m1")
	n := newSigNode(t)

	other := newSigNode(t)
	if st, _ := sigCall(t, h, "Bearer "+tok, http.MethodPost, NodeKeyPath,
		map[string]any{"public_key": n.pub, "proof": other.proof()}); st != 400 {
		t.Fatalf("a key registered without its own proof: HTTP %d", st)
	}
	st, got := sigCall(t, h, "Bearer "+tok, http.MethodPost, NodeKeyPath, map[string]any{"public_key": n.pub, "proof": n.proof()})
	if st != 200 || got["key_id"] != n.id || got["bearer_off"] != false {
		t.Fatalf("register = %d %v", st, got)
	}
	// Still compat: the token works beside the key until bearer_off.
	if code, _ := nodeEndpointAnswer(h, "Bearer "+tok); code != 200 {
		t.Fatalf("bearer beside a key = %d", code)
	}

	now := time.Now()
	good := n.header(http.MethodGet, "/v1/node/self", "nonce-aaaaaaaaaaaaaaaa", now)
	if code, id := nodeEndpointAnswer(h, good); code != 200 || id != "ep_m1" {
		t.Fatalf("signed = %d %q", code, id)
	}
	if code, body := nodeEndpointAnswer(h, good); code != 401 || !strings.Contains(body, "replayed") {
		t.Fatalf("the same signature again = %d %s", code, body)
	}
	for name, auth := range map[string]string{
		"stale":       n.header(http.MethodGet, "/v1/node/self", "nonce-bbbbbbbbbbbbbbbb", now.Add(-3*time.Minute)),
		"future":      n.header(http.MethodGet, "/v1/node/self", "nonce-cccccccccccccccc", now.Add(3*time.Minute)),
		"other path":  n.header(http.MethodGet, "/v1/node/peers", "nonce-dddddddddddddddd", now),
		"other verb":  n.header(http.MethodPost, "/v1/node/self", "nonce-eeeeeeeeeeeeeeee", now),
		"short nonce": n.header(http.MethodGet, "/v1/node/self", "short", now),
		"other key":   other.header(http.MethodGet, "/v1/node/self", "nonce-ffffffffffffffff", now),
	} {
		if code, _ := nodeEndpointAnswer(h, auth); code != 401 {
			t.Fatalf("%s: HTTP %d, want 401", name, code)
		}
	}

	// bearer_off: only a signed request may say it, the token is dead after.
	st, got = sigCall(t, h, n.header(http.MethodPost, NodeKeyPath, "nonce-gggggggggggggggg", time.Now()), http.MethodPost, NodeKeyPath,
		map[string]any{"public_key": n.pub, "proof": n.proof(), "bearer_off": true})
	if st != 200 || got["bearer_off"] != true {
		t.Fatalf("bearer_off = %d %v", st, got)
	}
	if code, body := nodeEndpointAnswer(h, "Bearer "+tok); code != 401 || !strings.Contains(body, "signs its requests") {
		t.Fatalf("a copied token after bearer_off = %d %s", code, body)
	}
	if st, _ := sigCall(t, h, "Bearer "+tok, http.MethodPost, NodeKeyPath,
		map[string]any{"public_key": other.pub, "proof": other.proof()}); st != 401 {
		t.Fatalf("a copied token registering its own key after bearer_off: HTTP %d", st)
	}
	st, got = sigCall(t, h, n.header(http.MethodPost, NodeKeyPath, "nonce-hhhhhhhhhhhhhhhh", time.Now()), http.MethodPost, NodeKeyPath,
		map[string]any{"public_key": n.pub, "proof": n.proof(), "bearer_off": false})
	if st != 200 || got["bearer_off"] != true {
		t.Fatalf("bearer_off turned back on = %d %v", st, got)
	}
	if code, _ := nodeEndpointAnswer(h, n.header(http.MethodGet, "/v1/node/self", "nonce-iiiiiiiiiiiiiiii", time.Now())); code != 200 {
		t.Fatalf("signed after bearer_off = %d", code)
	}

	// A retired endpoint's key dies with it.
	if _, err := h.srv.Store.RetireEndpoint("ep_m1"); err != nil {
		t.Fatal(err)
	}
	if code, _ := nodeEndpointAnswer(h, n.header(http.MethodGet, "/v1/node/self", "nonce-jjjjjjjjjjjjjjjj", time.Now())); code != 401 {
		t.Fatalf("a retired endpoint's signature = %d", code)
	}
}

// The session-pass road (sessionCredNode) proves its node the same way, and
// keys the worker assertion with the endpoint's token hash either way.
func TestNodeSigSessionCredNode(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m1")
	n := newSigNode(t)
	if st, got := sigCall(t, h, "Bearer "+tok, http.MethodPost, NodeKeyPath, map[string]any{"public_key": n.pub, "proof": n.proof()}); st != 200 {
		t.Fatalf("register = %d %v", st, got)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/fleet/session-cred", nil)
	req.Header.Set("Authorization", n.header(http.MethodPost, "/v1/fleet/session-cred", "nonce-kkkkkkkkkkkkkkkk", time.Now()))
	ep, hash := h.srv.sessionCredNode(req)
	if ep == nil || ep.ID != "ep_m1" || hash != HashToken(tok) {
		t.Fatalf("signed session-cred node = %v %q", ep, hash)
	}
	req = httptest.NewRequest(http.MethodPost, "/v1/fleet/session-cred", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	if ep, hash := h.srv.sessionCredNode(req); ep == nil || hash != HashToken(tok) {
		t.Fatalf("bearer session-cred node = %v %q", ep, hash)
	}
}

// bin/fleet_node_sig.py signs what this file verifies: a vector it printed for
// the seed 01..20 (the node's half and the hub's must agree byte for byte).
func TestNodeSigPythonVector(t *testing.T) {
	seed, _ := base64.StdEncoding.DecodeString("AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=")
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	if got := base64.StdEncoding.EncodeToString(pub); got != "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=" {
		t.Fatalf("public key = %s", got)
	}
	if NodeKeyID(pub) != "nk_65b60673d6ed884bf01c2c22" {
		t.Fatalf("key id = %s", NodeKeyID(pub))
	}
	f, ok := parseNodeSig("FleetSig keyid=nk_65b60673d6ed884bf01c2c22, ts=1791800000, nonce=vector-nonce-0001, " +
		"sig=16Ap00JDhipEs6cXPmqZJLzhwkABYws6mB7ZKweaGR2z2W8qTGcCG2RclLFtE4BpZIJsm_jF5K3iVL4KOaAEBg")
	if !ok {
		t.Fatal("header not parsed")
	}
	sig, err := base64.RawURLEncoding.DecodeString(f["sig"])
	if err != nil || !ed25519.Verify(pub, NodeSigMessage(f["keyid"], f["ts"], f["nonce"], "POST", "/v1/node/tasks?x=1"), sig) {
		t.Fatalf("python's signature does not verify: %v", err)
	}
	proof, _ := base64.RawURLEncoding.DecodeString("HIl0F1M6g1d6cnHTXZUwMcKR7DLKMXjtaMNBuUfwmOY4XDiNSvqMWlnDOIs43nIJ3bMbLFPE9DZkbb_q30BJCA")
	if !ed25519.Verify(pub, []byte(nodeKeyProofLine+"\nebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="), proof) {
		t.Fatal("python's register proof does not verify")
	}
}
