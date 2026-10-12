package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// fcp-h2 (claude-fleet#3698, EPIC #3500 C19): with the relay signing key, a
// node that asks gets a session pass the relay and the cluster credential
// proxy verify themselves.

func h2Claims(t *testing.T, tok string) sessionCredClaims {
	t.Helper()
	parts := strings.Split(tok, ".")
	if len(parts) != 3 || parts[0] != "fcp-h2" {
		t.Fatalf("not an fcp-h2 pass: %q", tok)
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var c sessionCredClaims
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

// No relay key: asking for fcp-h2 gets fcp-h1, and no answer names a key.
func TestSessionCredH2OffAddsNothing(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, map[string]any{"kind": "fcp-h2"})
	if cred, _ := out["cred"].(string); !strings.HasPrefix(cred, "fcp-h1.") {
		t.Fatalf("no relay key: issued %q; want fcp-h1", cred)
	}
	if h.srv.SessionPub() != "" {
		t.Fatalf("SessionPub with no relay key = %q", h.srv.SessionPub())
	}
}

// With the key: a node that asks gets fcp-h2 (one that does not, fcp-h1);
// its signature is the relay key's over the prefixed claims; verify, the
// relay check and renew take it, and renew keeps its kind.
func TestSessionCredH2IssueVerifyRenew(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	pub := withRelayKey(h)
	h.srv.RevocationsToken = "rev-token"
	if h.srv.SessionPub() != base64.StdEncoding.EncodeToString(pub) {
		t.Fatalf("SessionPub = %q", h.srv.SessionPub())
	}
	if old := sessIssue(t, h, tok5, f5, nil); !strings.HasPrefix(old["cred"].(string), "fcp-h1.") {
		t.Fatalf("a node that does not ask: %v; want fcp-h1", old["cred"])
	}
	out := sessIssue(t, h, tok5, f5, map[string]any{"kind": "fcp-h2", "providers": []string{"claude"}})
	cred, id := out["cred"].(string), out["id"].(string)
	host, _ := out["machine"].(string) // the harness's node
	c := h2Claims(t, cred)
	if c.V != 2 || c.ID != id || c.Principal != "gh:1005" || host == "" || c.Machine != host {
		t.Fatalf("claims = %+v", c)
	}
	i := strings.LastIndexByte(cred, '.')
	sig, _ := base64.RawURLEncoding.DecodeString(cred[i+1:])
	if !ed25519.Verify(pub, []byte(cred[:i]), sig) {
		t.Fatal("fcp-h2 does not verify with the relay key's public half")
	}
	if v := sessVerify(t, h, map[string]any{"cred": cred, "provider": "claude"}); v["valid"] != true || v["id"] != id {
		t.Fatalf("verify: %v", v)
	}
	if code, who := relayCheck(t, h, cred, "/anthropic/v1/messages"); code != http.StatusOK || who != "gh:1005@"+host {
		t.Fatalf("relay check: %d who=%q", code, who)
	}
	if code, _ := relayCheck(t, h, cred, "/chatgpt/codex/responses"); code != http.StatusForbidden {
		t.Fatalf("claude-only fcp-h2 on /chatgpt/: %d, want 403", code)
	}
	st, r := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": cred})
	if st != 200 || r["id"] != id || !strings.HasPrefix(r["cred"].(string), "fcp-h2.") {
		t.Fatalf("renew: %d %v; want the same fcp-h2 pass", st, r)
	}
	if _, st := h2Forged(t, h, cred); st {
		t.Fatal("an fcp-h2 re-signed with another key verified")
	}
	if st, _ := sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok5, "", nil); st != 200 {
		t.Fatalf("revoke: %d", st)
	}
	if code, _ := relayCheck(t, h, cred, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("revoked fcp-h2: %d, want 403", code)
	}
	// The revocation is on the list a relay verifies by, as fcp:<id>.
	_, entries, err := h.srv.Store.RevocationList(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, e := range entries {
		found = found || e.JTI == "fcp:"+id
	}
	if !found {
		t.Fatalf("list: no fcp:%s in %+v", id, entries)
	}
}

// h2Forged re-signs cred's claims with another key and asks verify.
func h2Forged(t *testing.T, h *harness, cred string) (string, bool) {
	t.Helper()
	other := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))
	forged := signSessionCred2(h2Claims(t, cred), other)
	v := sessVerify(t, h, map[string]any{"cred": forged})
	return forged, v["valid"] == true
}

// An fcp-h1 body cannot pass as fcp-h2, nor an frl2 as either.
func TestSessionCredH2KindsDoNotCross(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	withRelayKey(h)
	cred := sessIssue(t, h, tok5, f5, map[string]any{"kind": "fcp-h2"})["cred"].(string)
	parts := strings.Split(cred, ".")
	for name, tok := range map[string]string{
		"relabelled fcp-h1": "fcp-h1." + parts[1] + "." + parts[2],
		"relabelled frl2":   "frl2." + parts[1] + "." + parts[2],
	} {
		if v := sessVerify(t, h, map[string]any{"cred": tok}); v["valid"] == true {
			t.Fatalf("%s verified: %v", name, v)
		}
	}
}
