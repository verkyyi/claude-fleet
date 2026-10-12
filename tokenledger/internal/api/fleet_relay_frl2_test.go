package api

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// frl2 (claude-fleet#3561, EPIC #3500 C19): with a relay signing key the hub
// mints a four-hour, signed relay pass the relay verifies by itself.

func withRelayKey(h *harness) ed25519.PublicKey {
	h.srv.RelaySignKey = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, ed25519.SeedSize))
	return h.srv.RelaySignKey.Public().(ed25519.PublicKey)
}

func frl2Claims(t *testing.T, tok string) relayPass2Claims {
	t.Helper()
	parts := strings.Split(tok, ".")
	if len(parts) != 3 || parts[0] != "frl2" {
		t.Fatalf("not an frl2 pass: %q", tok)
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var c relayPass2Claims
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestRelayFrl2OffAddsNothing(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	code, out := mintRelay(t, h, m4)
	if tok, _ := out["token"].(string); code != 200 || !strings.HasPrefix(tok, relayTokenPrefix) {
		t.Fatalf("no key: %d %v; want frl1 as before", code, out)
	}
	if _, has := out["expires_at"]; has {
		t.Fatalf("no key, the answer grew expires_at: %v", out)
	}
	h.srv.RevocationsToken = revTok
	if code, l := revGet(t, h, RelayRevocationsPath, revTok, -1, 0); code != 200 || l.RelayPub != "" {
		t.Fatalf("no key, the list names a relay key: %d %+v", code, l)
	}
	if ok, why := gateHubJudge["cred-ttl"](h.srv, nil, true); ok || !strings.Contains(why, "frl1") {
		t.Fatalf("gate, no key: %v %s", ok, why)
	}
}

func mintRelay2(t *testing.T, h *harness, nodeTok string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/relay-credential", strings.NewReader(`{"kind":"frl2"}`))
	req.Header.Set("Authorization", "Bearer "+nodeTok)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func TestRelayFrl2IssueCheckRevoke(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	pub := withRelayKey(h)
	host := revMachine(revHost(t, h, m4))
	// an older node asks with no kind: it still gets the frl1 it can keep
	if code, out := mintRelay(t, h, m4); code != 200 || !strings.HasPrefix(out["token"].(string), relayTokenPrefix) {
		t.Fatalf("a caller that does not ask for frl2: %d %v", code, out)
	}
	code, out := mintRelay2(t, h, m4)
	tok, _ := out["token"].(string)
	if code != 200 || !strings.HasPrefix(tok, relayPass2Prefix) {
		t.Fatalf("mint with a key: %d %v", code, out)
	}
	c := frl2Claims(t, tok)
	if c.Login != "alice" || c.Machine != host || c.Principal == "" || c.Exp-c.Iat != int64(RelayPassTTL.Seconds()) {
		t.Fatalf("claims = %+v; want alice@%s, a principal, %v", c, host, RelayPassTTL)
	}
	if exp, _ := time.Parse(time.RFC3339, out["expires_at"].(string)); exp.Unix() != c.Exp {
		t.Fatalf("expires_at %v ≠ exp %d", out["expires_at"], c.Exp)
	}
	if code, who := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != 200 || who != "alice@"+host {
		t.Fatalf("live frl2: %d who=%q", code, who)
	}
	s, _ := h.srv.Store.FleetSettings()
	if v := s[relayKey(host)]; v != "alice:frl2@"+c.JTI {
		t.Fatalf("setting = %q; want the jti, never the pass", v)
	}

	// Anything not signed by this hub, or past its end, is refused.
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{3}, ed25519.SeedSize))
	bob := c
	bob.Login = "bob"
	past := c
	past.Iat, past.Exp = time.Now().Add(-5*time.Hour).Unix(), time.Now().Add(-time.Hour).Unix()
	for name, pass := range map[string]string{
		"another key":    signRelayPass2(c, other),
		"another login":  signRelayPass2(bob, other),
		"claims swapped": relayPass2Prefix + base64.RawURLEncoding.EncodeToString(mustJSON(bob)) + tok[strings.LastIndexByte(tok, '.'):],
		"expired":        signRelayPass2(past, h.srv.RelaySignKey),
		"no signature":   tok[:strings.LastIndexByte(tok, '.')],
		"frl1 spelling":  "frl1." + tok[len(relayPass2Prefix):],
	} {
		if code, _ := relayCheck(t, h, pass, "/anthropic/v1/messages"); code != http.StatusForbidden {
			t.Fatalf("%s: %d, want 403", name, code)
		}
	}

	// The relay verifies it with the key the list hands it.
	h.srv.RevocationsToken = revTok
	_, l := revGet(t, h, RelayRevocationsPath, revTok, -1, 0)
	rp, err := base64.StdEncoding.DecodeString(l.RelayPub)
	if err != nil || !bytes.Equal(rp, pub) {
		t.Fatalf("relay_pub = %q; want the signing key's public half", l.RelayPub)
	}
	i := strings.LastIndexByte(tok, '.')
	sig, _ := base64.RawURLEncoding.DecodeString(tok[i+1:])
	if !ed25519.Verify(rp, []byte(tok[:i]), sig) {
		t.Fatal("the pass does not verify under relay_pub")
	}

	// A re-mint supersedes the old pass on the hub's road.
	tok2 := mustMintRelay2(t, h, m4)
	if code, _ := relayCheck(t, h, tok, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("superseded pass: %d, want 403", code)
	}
	if code, _ := relayCheck(t, h, tok2, "/anthropic/v1/messages"); code != 200 {
		t.Fatalf("new pass: %d", code)
	}
	// A revoke refuses it and lists its jti for the relay.
	putSetting(t, h, NodeRelayPrefix+host, "", 200)
	if code, _ := relayCheck(t, h, tok2, "/anthropic/v1/messages"); code != http.StatusForbidden {
		t.Fatalf("revoked frl2: %d, want 403", code)
	}
	_, l = revGet(t, h, RelayRevocationsPath, revTok, -1, 0)
	if !revHas(l, "frl2:"+frl2Claims(t, tok2).JTI) {
		t.Fatalf("list after the revoke: %+v", l)
	}
	for _, e := range l.Entries {
		if strings.HasPrefix(e.JTI, "frl1:frl2") {
			t.Fatalf("an frl2 jti listed as an frl1 hash: %+v", e)
		}
	}

	// The gate: a four-hour relay pass is short enough.
	if _, why := gateHubJudge["cred-ttl"](h.srv, nil, true); strings.Contains(why, "中转") {
		t.Fatalf("gate with frl2: %s", why)
	}
}

func mustMintRelay2(t *testing.T, h *harness, nodeTok string) string {
	t.Helper()
	code, out := mintRelay2(t, h, nodeTok)
	tok, _ := out["token"].(string)
	if code != http.StatusOK || !strings.HasPrefix(tok, relayPass2Prefix) {
		t.Fatalf("mint: %d %v", code, out)
	}
	return tok
}

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

func TestLoadRelaySignKey(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if _, ok, err := LoadRelaySignKey(env(nil)); ok || err != nil {
		t.Fatalf("unset: ok=%v err=%v", ok, err)
	}
	seed := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	k, ok, err := LoadRelaySignKey(env(map[string]string{"CCQUOTA_FLEET_RELAY_SIGN_KEY": seed}))
	if !ok || err != nil || len(k) != ed25519.PrivateKeySize {
		t.Fatalf("seed: %v %v", ok, err)
	}
	if _, ok, err := LoadRelaySignKey(env(map[string]string{"CCQUOTA_FLEET_RELAY_SIGN_KEY": "short"})); !ok || err == nil {
		t.Fatalf("bad key: ok=%v err=%v; want an error", ok, err)
	}
}
