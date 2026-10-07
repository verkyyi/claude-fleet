package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// The Singapore relay's door (claude-fleet#1974, EPIC #1967 C7): a trusted
// machine mints a relay credential with its node token; the forwarder's
// forward_auth asks GET /v1/relay/check, which lets a live one through and
// refuses a forged, revoked or untrusted one.

func mintRelay(t *testing.T, h *harness, nodeTok string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/relay-credential", nil)
	req.Header.Set("Authorization", "Bearer "+nodeTok)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func mustMintRelay(t *testing.T, h *harness, nodeTok string) string {
	t.Helper()
	code, out := mintRelay(t, h, nodeTok)
	tok, _ := out["token"].(string)
	if code != http.StatusOK || !strings.HasPrefix(tok, relayTokenPrefix) {
		t.Fatalf("mint: %d %v", code, out)
	}
	return tok
}

// relayCheck asks the check the way Caddy's forward_auth does; uri "" sends
// no X-Forwarded-Uri.
func relayCheck(t *testing.T, h *harness, pass, uri string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+RelayCheckPath, nil)
	if pass != "" {
		req.Header.Set(RelayHeader, pass)
	}
	if uri != "" {
		req.Header.Set("X-Forwarded-Uri", uri)
		req.Header.Set("X-Forwarded-Method", http.MethodPost)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	return res.StatusCode, res.Header.Get("X-Fleet-Relay-Who")
}

func TestRelayCredIssueAndCheck(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	tok := mustMintRelay(t, h, m4)
	for _, uri := range []string{"/anthropic/v1/messages", "/chatgpt/codex/responses", "/openai-auth/oauth/token", ""} {
		if code, who := relayCheck(t, h, tok, uri); code != http.StatusOK || who != "m4" {
			t.Fatalf("live pass on %q: %d who=%q", uri, code, who)
		}
	}
	// Only the hash is kept, and not even that leaves through the settings.
	s, _ := h.srv.Store.FleetSettings()
	if v := s[NodeRelayPrefix+"m4"]; v != "alice:"+HashToken(tok) {
		t.Fatalf("stored relay setting = %q", v)
	}
	res, body := h.get(t, "/v1/fleet/settings")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("settings: %d", res.StatusCode)
	}
	if strings.Contains(string(body), HashToken(tok)) || strings.Contains(string(body), tok) {
		t.Fatalf("settings carry the relay credential: %s", body)
	}
	if !strings.Contains(string(body), `"`+NodeRelayPrefix+`m4":"alice"`) {
		t.Fatalf("settings do not show who holds one: %s", body)
	}
	var issued int
	_ = h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'relay_cred' AND outcome LIKE 'ISSUE%'`).Scan(&issued)
	if issued != 1 {
		t.Fatalf("issue audit rows = %d, want 1", issued)
	}
}

func TestRelayCheckRefusesForged(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	tok := mustMintRelay(t, h, m4)
	for name, pass := range map[string]string{
		"none":          "",
		"forged":        relayTokenPrefix + strings.Repeat("A", 43),
		"tampered":      tok[:len(tok)-1] + map[bool]string{true: "B", false: "A"}[tok[len(tok)-1] == 'A'],
		"node token":    m4,
		"viewer token":  viewerToken,
		"session pass":  hubPassPrefix + "anything", // passes off here, and forged
		"no prefix":     strings.TrimPrefix(tok, relayTokenPrefix),
		"bearer spoken": "Bearer " + tok,
	} {
		if code, _ := relayCheck(t, h, pass, "/anthropic/v1/messages"); code != http.StatusForbidden {
			t.Fatalf("%s: HTTP %d, want 403", name, code)
		}
	}
	// A live pass opens nothing but the relay's routes.
	for _, uri := range []string{"/v1/fleet/settings", "/", "/anthropicx/v1"} {
		if code, _ := relayCheck(t, h, tok, uri); code != http.StatusForbidden {
			t.Fatalf("live pass on %q: %d, want 403", uri, code)
		}
	}
	// The pass travels in its own header; an Authorization header is not one.
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+RelayCheckPath, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("pass in Authorization: %d, want 403", res.StatusCode)
	}
	// Not a POST route.
	req, _ = http.NewRequest(http.MethodPost, h.http.URL+RelayCheckPath, nil)
	req.Header.Set(RelayHeader, tok)
	res, _ = http.DefaultClient.Do(req)
	res.Body.Close()
	if res.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST check: %d", res.StatusCode)
	}
}

func TestRelayCredRevoked(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	tok := mustMintRelay(t, h, m4)
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusOK {
		t.Fatalf("before: %d", code)
	}
	// The operator can only drop it, never write a hash by hand.
	putSetting(t, h, NodeRelayPrefix+"m4", "alice:"+HashToken("frl1.mine"), 400)
	// Dropped: refused at once, even with a verdict cached a moment ago.
	putSetting(t, h, NodeRelayPrefix+"m4.local", "", 200)
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("revoked pass: %d, want 403", code)
	}
	var revoked int
	_ = h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'relay_cred' AND outcome = 'REVOKE 1'`).Scan(&revoked)
	if revoked != 1 {
		t.Fatalf("revoke audit rows = %d", revoked)
	}
	// A new one works; the old one stays dead.
	tok2 := mustMintRelay(t, h, m4)
	if code, _ := relayCheck(t, h, tok2, "/chatgpt/codex/responses"); code != http.StatusOK {
		t.Fatalf("re-minted: %d", code)
	}
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("old pass after re-mint: %d", code)
	}
	// A credential revocation of the machine stops the pass too.
	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4", Reason: "lost"}); code != http.StatusOK {
		t.Fatalf("revoke m4: %d %v", code, out)
	}
	if code, _ := relayCheck(t, h, tok2, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("pass of a revoked machine: %d, want 403", code)
	}
	if code, out := mintRelay(t, h, m4); code != http.StatusForbidden || out["error"] != LeaseRevoked {
		t.Fatalf("mint on a revoked machine: %d %v", code, out)
	}
}

func TestRelayCredUntrusted(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	tok := mustMintRelay(t, h, m4)
	putSetting(t, h, NodeTrustPrefix+"m4", TrustUntrusted, 200)
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("pass of an untrusted machine: %d, want 403", code)
	}
	if code, out := mintRelay(t, h, m4); code != http.StatusForbidden || out["error"] != LeaseUntrusted {
		t.Fatalf("mint on an untrusted machine: %d %v", code, out)
	}
	putSetting(t, h, NodeTrustPrefix+"m4", TrustTrusted, 200)
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusOK {
		t.Fatalf("trusted again: %d", code)
	}

	// A machine that joined after the migration mints nothing.
	p, _ := h.srv.Store.Principal("wecom-alice")
	if err := h.srv.Store.AdoptAccount(p, "m9", time.Now()); err != nil {
		t.Fatal(err)
	}
	m9 := enrollAs(t, h, "alice-m9", "m9", "alice")
	if code, out := mintRelay(t, h, m9); code != http.StatusForbidden || out["error"] != LeaseUntrusted {
		t.Fatalf("mint on new m9: %d %v", code, out)
	}
	// A node with no fleet account mints nothing either.
	m7 := enrollAs(t, h, "carol-m7", "m7", "carol")
	if code, out := mintRelay(t, h, m7); code != http.StatusForbidden || out["error"] != LeaseNoPrincipal {
		t.Fatalf("mint with no account: %d %v", code, out)
	}
	if code, _ := mintRelay(t, h, "ccq_not-a-token"); code != http.StatusUnauthorized {
		t.Fatalf("mint with a bad node token: %d", code)
	}
}

// Two logins on one machine each hold their own; re-minting one replaces only
// that login's.
func TestRelayCredPerLogin(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	p, err := h.srv.Store.AdoptPrincipal("wecom-bob", "bob", "Bob", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	bob := enrollAs(t, h, "bob-m4", "m4", "bob")
	a1 := mustMintRelay(t, h, m4)
	b1 := mustMintRelay(t, h, bob)
	a2 := mustMintRelay(t, h, m4)
	for name, want := range map[string]int{"alice old": 403, "bob": 200, "alice new": 200} {
		tok := map[string]string{"alice old": a1, "bob": b1, "alice new": a2}[name]
		if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != want {
			t.Fatalf("%s: %d, want %d", name, code, want)
		}
	}
	// Revoking the machine drops both.
	putSetting(t, h, NodeRelayPrefix+"m4", "", 200)
	for _, tok := range []string{a2, b1} {
		if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusForbidden {
			t.Fatalf("after machine revoke: %d", code)
		}
	}
}

// Nothing minted, nothing changes: a check writes no setting, and the
// settings answer is what it was (the degenerate case). The first check runs
// C1's one trust migration, as any trust read does; after it, nothing moves.
func TestRelayOffAddsNothing(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	relayCheck(t, h, relayTokenPrefix+"warm", "/anthropic/v1/messages")
	_, before := h.get(t, "/v1/fleet/settings")
	relayCheck(t, h, relayTokenPrefix+"x", "/anthropic/v1/messages")
	relayCheck(t, h, "", "")
	_, after := h.get(t, "/v1/fleet/settings")
	if string(before) != string(after) {
		t.Fatalf("a check changed the settings:\n%s\n%s", before, after)
	}
	s, _ := h.srv.Store.FleetSettings()
	for k := range s {
		if strings.HasPrefix(k, NodeRelayPrefix) {
			t.Fatalf("a relay setting appeared with nothing minted: %v", s)
		}
	}
}

// An ingress session pass (C2) passes the check for the provider it covers,
// and stops the moment it is revoked — the central proxy's way out.
func TestRelayCheckSessionPass(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, map[string]any{"providers": []string{"claude"}})
	cred, id := out["cred"].(string), out["id"].(string)
	if code, who := relayCheck(t, h, cred, "/anthropic/v1/messages"); code != http.StatusOK || who != "wecom-verk@m5" {
		t.Fatalf("session pass on /anthropic/: %d who=%q", code, who)
	}
	for _, uri := range []string{"/chatgpt/codex/responses", "/openai-auth/oauth/token", "/v1/fleet/settings"} {
		if code, _ := relayCheck(t, h, cred, uri); code != http.StatusForbidden {
			t.Fatalf("claude-only pass on %q: %d, want 403", uri, code)
		}
	}
	if code, _ := relayCheck(t, h, reclaim(t, cred, func(c *sessionCredClaims) { c.Principal = "wecom-evil" }), "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("re-signed claims: %d, want 403", code)
	}
	if st, _ := sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok5, "", nil); st != 200 {
		t.Fatalf("revoke: %d", st)
	}
	if code, _ := relayCheck(t, h, cred, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("revoked session pass: %d, want 403", code)
	}
}
