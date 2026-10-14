package credproxy

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// fcp-h2 (claude-fleet#3698): once the proxy knows the hub's key, a forged or
// expired pass is refused here and the hub is not asked; a good one is still
// resolved for its account.

func signPass2(key ed25519.PrivateKey, id string, exp time.Time) string {
	raw, _ := json.Marshal(map[string]any{"v": 2, "id": id, "principal": "p-" + id, "exp": exp.Unix()})
	body := Pass2Prefix + base64.RawURLEncoding.EncodeToString(raw)
	return body + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, []byte(body)))
}

func TestPass2LocalVerify(t *testing.T) {
	key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, ed25519.SeedSize))
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{3}, ed25519.SeedSize))
	h := newHarness(t, false, nil)
	good := signPass2(key, "a", time.Now().Add(time.Hour))
	forged := signPass2(other, "b", time.Now().Add(time.Hour))
	expired := signPass2(key, "c", time.Now().Add(-time.Minute))
	h.hub.set(func() {
		h.hub.pub = base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
		h.hub.bind[good] = "acct-1"
	})
	// No key yet: a forged fcp-h2 goes to the hub (which refuses it).
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", forged, `{}`, nil); st != http.StatusForbidden || h.hub.count() != 1 {
		t.Fatalf("forged, no key: %d, hub calls %d; want 403 after asking", st, h.hub.count())
	}
	// A good one is served — and its answer hands over the key.
	if st, body := h.do(t, "/v1/proxy/anthropic/v1/messages", good, `{}`, nil); st != http.StatusOK {
		t.Fatalf("good fcp-h2: %d %s", st, body)
	}
	if got := h.last(t).hdr.Get("Authorization"); got != "Bearer tok-acct-1" {
		t.Fatalf("upstream Authorization = %q", got)
	}
	calls := h.hub.count()
	for name, pass := range map[string]string{"forged": forged, "expired": expired, "relabelled fcp-h1": PassPrefix + good[len(Pass2Prefix):]} {
		if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", pass, `{}`, nil); st != http.StatusForbidden {
			t.Fatalf("%s: %d; want 403", name, st)
		}
	}
	if n := h.hub.count(); n != calls+1 { // only the relabelled fcp-h1 is the hub's to judge
		t.Fatalf("hub calls %d → %d; a forged / expired fcp-h2 reached the hub", calls, n)
	}
}

// A key given at start is used before any answer.
func TestPass2ConfiguredKey(t *testing.T) {
	key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, ed25519.SeedSize))
	pub, err := ParseSessionPub(base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)))
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatalf("ParseSessionPub: %v", err)
	}
	if _, err := ParseSessionPub("not-a-key"); err == nil {
		t.Fatal("ParseSessionPub took a bad key")
	}
	h := newHarness(t, false, nil)
	h.p.mu.Lock()
	h.p.pub = pub
	h.p.mu.Unlock()
	if st, _ := h.do(t, "/v1/proxy/codex/responses", signPass2(key, "x", time.Now().Add(-time.Second)), `{}`, nil); st != http.StatusForbidden || h.hub.count() != 0 {
		t.Fatalf("expired fcp-h2 with a configured key: %d, hub calls %d; want 403, none", st, h.hub.count())
	}
}

// A key rotated while the proxy runs (claude-fleet#4138): a pass under the
// new key is let through to the hub once (its answer teaches the new key and
// the retiring one), then both verify here; another unknown key inside the
// minute is refused without asking.
func TestPass2KeyRotation(t *testing.T) {
	old := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, ed25519.SeedSize))
	cur := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{7}, ed25519.SeedSize))
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{3}, ed25519.SeedSize))
	b64 := func(k ed25519.PrivateKey) string {
		return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
	}
	h := newHarness(t, false, nil)
	before := signPass2(old, "o", time.Now().Add(time.Hour))
	h.hub.set(func() { h.hub.pub = b64(old); h.hub.bind[before] = "acct-o" })
	if st, body := h.do(t, "/v1/proxy/anthropic/v1/messages", before, `{}`, nil); st != http.StatusOK {
		t.Fatalf("before the rotation: %d %s", st, body)
	}
	// The hub rotates: new key current, the old one retiring.
	after := signPass2(cur, "n", time.Now().Add(time.Hour))
	h.hub.set(func() { h.hub.pub, h.hub.prev = b64(cur), b64(old); h.hub.bind[after] = "acct-n" })
	calls := h.hub.count()
	if st, body := h.do(t, "/v1/proxy/anthropic/v1/messages", after, `{}`, nil); st != http.StatusOK || h.hub.count() != calls+1 {
		t.Fatalf("new-key pass after a rotation: %d %s (hub calls %d → %d)", st, body, calls, h.hub.count())
	}
	if got := h.p.checkPass2(after, time.Now()); got != "" {
		t.Fatalf("new key not learned: %q", got)
	}
	if got := h.p.checkPass2(signPass2(old, "o2", time.Now().Add(time.Hour)), time.Now()); got != "" {
		t.Fatalf("retiring key refused during the overlap: %q", got)
	}
	calls = h.hub.count()
	forged := signPass2(other, "f", time.Now().Add(time.Hour))
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", forged, `{}`, nil); st != http.StatusForbidden {
		t.Fatalf("forged: %d; want 403", st)
	}
	if st, _ := h.do(t, "/v1/proxy/anthropic/v1/messages", signPass2(other, "g", time.Now().Add(time.Hour)), `{}`, nil); st != http.StatusForbidden || h.hub.count() > calls+1 {
		t.Fatalf("second forgery inside the minute: %d, hub calls %d → %d; want at most one ask", st, calls, h.hub.count())
	}
	// The overlap ends: prev dropped. A rolling deploy's replicas answer by
	// turns, so the key stays good keySeen after it was last named, then not.
	h.p.learnPub(Resolution{SessionPub: b64(cur)})
	oldPass := signPass2(old, "o3", time.Now().Add(time.Hour))
	if got := h.p.checkPass2(oldPass, time.Now().Add(time.Minute)); got != "" {
		t.Fatalf("retired key a minute after it was last named: %q; want still good", got)
	}
	if got := h.p.checkPass2(oldPass, time.Now().Add(keySeen+2*time.Minute)); got != "-" {
		t.Fatalf("retired key past keySeen: %q; want the hub's to judge (once a minute)", got)
	}
}
