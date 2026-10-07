package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
)

// The hub's own pass through the relay (claude-fleet#1976): it opens
// /openai-auth/ and nothing else, and only this hub's key signs one.
func TestHubRelayPassCheck(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	if _, err := h.srv.HubRelayPass(); err == nil {
		t.Fatal("no session pass key: a hub pass was minted")
	}
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	pass, err := h.srv.HubRelayPass()
	if err != nil || !strings.HasPrefix(pass, hubRelayPassPrefix) {
		t.Fatalf("mint: %q %v", pass, err)
	}
	if code, who := relayCheck(t, h, pass, "/openai-auth/oauth/token"); code != http.StatusOK || who != "hub" {
		t.Fatalf("hub pass on /openai-auth/: %d who=%q", code, who)
	}
	for _, uri := range []string{"/anthropic/v1/messages", "/chatgpt/codex/responses", "/v1/fleet/settings", ""} {
		if code, _ := relayCheck(t, h, pass, uri); code != http.StatusForbidden {
			t.Fatalf("hub pass on %q: %d, want 403", uri, code)
		}
	}
	i := strings.LastIndexByte(pass, '.')
	exp, _ := strconv.ParseInt(pass[len(hubRelayPassPrefix):i], 10, 64)
	for name, forged := range map[string]string{
		"longer life":  hubRelayPassPrefix + strconv.FormatInt(exp+86400, 10) + pass[i:],
		"bad mac":      pass[:i] + ".AAAA",
		"no mac":       pass[:i],
		"another key":  otherHubPass(t),
		"session kind": "fcp-h1." + pass[len(hubRelayPassPrefix):],
	} {
		if code, _ := relayCheck(t, h, forged, "/openai-auth/oauth/token"); code != http.StatusForbidden {
			t.Fatalf("%s: %d, want 403", name, code)
		}
	}
	// A pass past its life is refused.
	old := hubRelayPassPrefix + strconv.FormatInt(time.Now().Add(-time.Minute).Unix(), 10)
	old += "." + base64.RawURLEncoding.EncodeToString(h.srv.hubRelayPassMAC(old))
	if code, _ := relayCheck(t, h, old, "/openai-auth/oauth/token"); code != http.StatusForbidden {
		t.Fatalf("expired: %d, want 403", code)
	}
	// Nor one checked after its life.
	if v := h.srv.verifyHubRelayPass(pass, "/openai-auth/oauth/token", time.Now().Add(hubRelayPassTTL+time.Second)); v.ok {
		t.Fatal("a pass outlived its TTL")
	}
}

// End to end with a fake relay that does what extras/cred-relay/Caddyfile
// does — forward_auth against this hub's real /v1/relay/check, strip the pass,
// forward to a fake auth.openai.com: the vault refreshes through it, saves the
// rotated refresh token before it issues, and the audit says refresh_via=relay.
func TestRelayRefreshEndToEnd(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var seen []map[string]string
	openai := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/token" || r.Header.Get(RelayHeader) != "" {
			t.Errorf("upstream got path %q, relay header %q", r.URL.Path, r.Header.Get(RelayHeader))
		}
		var f map[string]string
		_ = json.NewDecoder(r.Body).Decode(&f)
		mu.Lock()
		seen = append(seen, f)
		n := len(seen)
		mu.Unlock()
		writeJSON(w, http.StatusOK, map[string]any{"access_token": "at-" + strconv.Itoa(n),
			"refresh_token": "rt-" + strconv.Itoa(n), "expires_in": 60})
	}))
	defer openai.Close()
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/openai-auth/") {
			http.NotFound(w, r)
			return
		}
		chk, _ := http.NewRequest(http.MethodGet, h.http.URL+RelayCheckPath, nil)
		chk.Header.Set(RelayHeader, r.Header.Get(RelayHeader))
		chk.Header.Set("X-Forwarded-Uri", r.URL.Path)
		res, err := http.DefaultClient.Do(chk)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusOK {
			w.WriteHeader(res.StatusCode)
			w.Write(body)
			return
		}
		up, _ := http.NewRequest(r.Method, openai.URL+strings.TrimPrefix(r.URL.Path, "/openai-auth"), r.Body)
		up.Header.Set("Content-Type", r.Header.Get("Content-Type"))
		ur, err := http.DefaultClient.Do(up)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer ur.Body.Close()
		w.WriteHeader(ur.StatusCode)
		io.Copy(w, ur.Body)
	}))
	defer relay.Close()

	nodeCalled := false
	node := &credvault.ProxyRefresher{Via: func(context.Context, string, map[string]string) (credvault.ProxyAnswer, error) {
		nodeCalled = true
		return credvault.ProxyAnswer{}, credvault.ErrRefreshUnavailable
	}}
	v := &credvault.Vault{Store: h.srv.Store, Sealer: sealer,
		Refresher: &credvault.RelayRefresher{URL: relay.URL, Pass: h.srv.HubRelayPass, Fallback: node}}
	if err := v.Put("pool", credvault.Codex, "default", credvault.Secret{RefreshToken: "rt-0", AccountID: "acct"}); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 2; i++ { // expires_in 60 < MinTTL: every lease refreshes
		acc, err := v.Lease(context.Background(), "pool", credvault.Codex, "default")
		if err != nil || acc.AccessToken != "at-"+strconv.Itoa(i) {
			t.Fatalf("lease %d: %+v %v", i, acc, err)
		}
	}
	if nodeCalled {
		t.Fatal("the node path ran while the relay was up")
	}
	// The second refresh carried rt-1: the rotated token was saved before
	// at-1 was issued.
	if len(seen) != 2 || seen[0]["refresh_token"] != "rt-0" || seen[1]["refresh_token"] != "rt-1" || seen[1]["client_id"] != credvault.CodexClientID {
		t.Fatalf("upstream saw %v", seen)
	}
	rows, _ := h.srv.Store.CredAuditLog("pool", 10)
	n := 0
	for _, r := range rows {
		if r.Action == "refresh" && r.Detail == "ok · refresh_via=relay" {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("audit = %+v", rows)
	}

	// The hub's key changed (another hub): the relay refuses the pass and
	// the vault falls back to the node path, saying why.
	v.Refresher.(*credvault.RelayRefresher).Pass = func() (string, error) { return otherHubPass(t), nil }
	// The cached at-2 is still valid (just under MinTTL), so the lease
	// itself is served either way; what matters is which path ran.
	_, _ = v.Lease(context.Background(), "pool", credvault.Codex, "default")
	if !nodeCalled {
		t.Fatal("a refused relay pass did not fall back to the node path")
	}
	rows, _ = h.srv.Store.CredAuditLog("pool", 10)
	if !strings.Contains(rows[0].Detail, "relay unavailable: relay refused the hub's pass") {
		t.Fatalf("fallback audit = %q", rows[0].Detail)
	}
}

// otherHubPass is a well-formed pass signed by another hub's key.
func otherHubPass(t *testing.T) string {
	t.Helper()
	p, err := (&Server{SessionCredKey: bytes.Repeat([]byte{1}, 32)}).HubRelayPass()
	if err != nil {
		t.Fatal(err)
	}
	return p
}
