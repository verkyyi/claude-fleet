package api

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A key rotation does not break the sessions already running
// (claude-fleet#4138): with the retiring key named *_PREV, what it signed
// still verifies and renews — re-signed with the new key, the same id and
// kind; with no PREV the old passes are refused, as before.

// fcp-h1 under the HMAC key.
func TestKeyRotationSessionPassH1(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, nil)
	cred, id := out["cred"].(string), out["id"].(string)
	hubPass, _ := h.srv.HubRelayPass()
	quotaPass := ""
	if h.srv.HubQuota != nil {
		quotaPass, _ = h.srv.HubQuotaPass()
	}
	oldKey := h.srv.SessionCredKey
	h.srv.SessionCredKey = bytes.Repeat([]byte{4}, 32)
	h.srv.sessCred.drop("")

	// No PREV: the rotation strands it — the break this issue is about.
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] == true {
		t.Fatalf("old-key pass verified with no PREV: %v", v)
	}
	if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": cred}); st != http.StatusForbidden {
		t.Fatalf("renew with no PREV: %d; want 403", st)
	}
	if v := h.srv.verifyHubRelayPass(hubPass, "/openai-auth/oauth/token", time.Now()); v.ok {
		t.Fatal("old-key frh1 verified with no PREV")
	}

	// PREV: verify and renew take it; the renewal is the new key's.
	h.srv.SessionCredKeyPrev = oldKey
	if v := sessVerify(t, h, map[string]any{"cred": cred, "provider": "claude"}); v["valid"] != true || v["id"] != id {
		t.Fatalf("old-key pass under PREV: %v", v)
	}
	if v := h.srv.verifyHubRelayPass(hubPass, "/openai-auth/oauth/token", time.Now()); !v.ok {
		t.Fatalf("old-key frh1 under PREV: %s", v.why)
	}
	if quotaPass != "" {
		if v := h.srv.verifyHubQuotaPass(quotaPass, hubQuotaRoutes[0], time.Now()); !v.ok {
			t.Fatalf("old-key frq1 under PREV: %s", v.why)
		}
	}
	st, r := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": cred})
	renewed, _ := r["cred"].(string)
	if st != 200 || r["id"] != id || !strings.HasPrefix(renewed, "fcp-h1.") {
		t.Fatalf("renew under PREV: %d %v; want the same fcp-h1 pass", st, r)
	}
	if _, why := parseSessionCred(renewed, h.srv.SessionCredKey, time.Now()); why != "" {
		t.Fatalf("renewal is not the new key's: %s", why)
	}
	// The wait's count: the renewal is the newest signature on record.
	st, cnt := sessDo(t, h, http.MethodGet, "/v1/fleet/session-cred?signed_before="+time.Now().Add(-time.Hour).UTC().Format(time.RFC3339), viewerToken, "", nil)
	if st != 200 || cnt["count"] != float64(0) {
		t.Fatalf("signed_before an hour ago: %d %v; want 0", st, cnt)
	}
	st, cnt = sessDo(t, h, http.MethodGet, "/v1/fleet/session-cred?signed_before="+time.Now().Add(time.Hour).UTC().Format(time.RFC3339), viewerToken, "", nil)
	if st != 200 || cnt["count"] != float64(1) {
		t.Fatalf("signed_before an hour on: %d %v; want 1", st, cnt)
	}
	if st, _ := sessDo(t, h, http.MethodGet, "/v1/fleet/session-cred?signed_before=yesterday", viewerToken, "", nil); st != http.StatusBadRequest {
		t.Fatalf("bad signed_before: %d; want 400", st)
	}
	// PREV dropped: the renewed pass lives on, the old string does not.
	h.srv.SessionCredKeyPrev = nil
	h.srv.sessCred.drop("")
	if v := sessVerify(t, h, map[string]any{"cred": renewed}); v["valid"] != true {
		t.Fatalf("renewed pass after PREV dropped: %v", v)
	}
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] == true {
		t.Fatalf("old string after PREV dropped: %v", v)
	}
}

// fcp-h2 and frl2 under the relay signing key; the list and the resolve
// answer name both public halves during the overlap.
func TestKeyRotationRelayKey(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	oldPub := withRelayKey(h)
	h.srv.RevocationsToken = "rev-token"
	cred := sessIssue(t, h, tok5, f5, map[string]any{"kind": "fcp-h2"})["cred"].(string)
	id := h2Claims(t, cred).ID

	h.srv.RelaySignKey = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{5}, ed25519.SeedSize))
	newPub := h.srv.RelaySignKey.Public().(ed25519.PublicKey)
	h.srv.sessCred.drop("")
	if h.srv.SessionPubPrev() != "" || h.srv.RelayPubPrev() != "" {
		t.Fatal("no PREV, yet a previous key is named")
	}
	if code, _ := relayCheck(t, h, cred, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("old-key fcp-h2, no PREV: %d; want 403", code)
	}
	if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": cred}); st != http.StatusForbidden {
		t.Fatalf("renew with no PREV: %d; want 403", st)
	}

	h.srv.RelaySignPubPrev = oldPub
	if v := sessVerify(t, h, map[string]any{"cred": cred, "provider": "claude"}); v["valid"] != true {
		t.Fatalf("old-key fcp-h2 under PREV: %v", v)
	}
	if code, _ := relayCheck(t, h, cred, "/anthropic/v1/messages"); code != 200 {
		t.Fatalf("relay check, old-key fcp-h2 under PREV: %d", code)
	}
	b64 := base64.StdEncoding.EncodeToString
	if h.srv.SessionPub() != b64(newPub) || h.srv.SessionPubPrev() != b64(oldPub) {
		t.Fatalf("resolve keys = %q / %q", h.srv.SessionPub(), h.srv.SessionPubPrev())
	}
	if _, l := revGet(t, h, RelayRevocationsPath, "rev-token", -1, 0); l.RelayPub != b64(newPub) || l.RelayPubPrev != b64(oldPub) {
		t.Fatalf("list keys = %q / %q", l.RelayPub, l.RelayPubPrev)
	}
	st, r := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": cred})
	renewed, _ := r["cred"].(string)
	if st != 200 || r["id"] != id || !strings.HasPrefix(renewed, "fcp-h2.") {
		t.Fatalf("renew under PREV: %d %v; want the same fcp-h2 pass", st, r)
	}
	if c, why := parseSessionCred2(renewed, newPub, time.Now()); c == nil || why != "" {
		t.Fatalf("renewal is not the new key's: %s", why)
	}
	// A key that is neither is still refused.
	if _, ok := h2Forged(t, h, cred); ok {
		t.Fatal("a third key verified")
	}
}

func TestKeyRotationFrl2(t *testing.T) {
	h, nodeTok, _ := newVaultHarness(t)
	oldPub := withRelayKey(h)
	tok := mustMintRelay2(t, h, nodeTok)
	h.srv.RelaySignKey = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{5}, ed25519.SeedSize))
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("old-key frl2, no PREV: %d; want 403", code)
	}
	h.srv.RelaySignPubPrev = oldPub
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != 200 {
		t.Fatalf("old-key frl2 under PREV: %d", code)
	}
	// A new mint is the new key's alone.
	fresh := mustMintRelay2(t, h, nodeTok)
	if _, why := parseRelayPass2(fresh, h.srv.RelaySignKey.Public().(ed25519.PublicKey), time.Now()); why != "" {
		t.Fatalf("new mint under the new key: %s", why)
	}
}

func TestLoadKeysPrev(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if _, ok, err := LoadSessionCredKeyPrev(env(nil)); ok || err != nil {
		t.Fatalf("session prev unset: ok=%v err=%v", ok, err)
	}
	if _, ok, err := LoadRelaySignKeyPrev(env(nil)); ok || err != nil {
		t.Fatalf("relay prev unset: ok=%v err=%v", ok, err)
	}
	dir := t.TempDir()
	k := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32))
	path := filepath.Join(dir, "k")
	if err := os.WriteFile(path, []byte(k+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, ok, err := LoadSessionCredKeyPrev(env(map[string]string{"CCQUOTA_FLEET_SESSION_CRED_KEY_PREV_FILE": path})); !ok || err != nil || len(got) != 32 {
		t.Fatalf("session prev file: %v %v", ok, err)
	}
	seed := bytes.Repeat([]byte{2}, ed25519.SeedSize)
	pub, ok, err := LoadRelaySignKeyPrev(env(map[string]string{"CCQUOTA_FLEET_RELAY_SIGN_KEY_PREV": k}))
	if !ok || err != nil || !bytes.Equal(pub, ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)) {
		t.Fatalf("relay prev: %v %v", ok, err)
	}
	if _, ok, err := LoadRelaySignKeyPrev(env(map[string]string{"CCQUOTA_FLEET_RELAY_SIGN_KEY_PREV": "short"})); !ok || err == nil {
		t.Fatalf("bad relay prev: ok=%v err=%v; want an error", ok, err)
	}
}
