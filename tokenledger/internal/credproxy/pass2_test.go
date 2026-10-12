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
