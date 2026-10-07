package codex

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// claude-fleet#1920: a hub lease the upstream answered token_revoked with a
// week left on its exp read login.state=valid. The upstream's refusal of this
// exact credential now makes it access_rejected, with the code as the reason;
// a new auth.json (renewed lease, re-login) outdates the record by itself.
func TestUpstreamRejectionMakesALoginInvalid(t *testing.T) {
	useRPCFixture(t)
	t.Setenv("CCQUOTA_RPC_FIXTURE_LIMITS", "revoked")
	for _, refresh := range []string{HubManagedRefreshToken, "fixture-refresh-secret"} {
		home := t.TempDir()
		writeTestLoginRefresh(t, home, "member", time.Now().Add(183*time.Hour), refresh)
		a, err := ReadAuth(home)
		if err != nil {
			t.Fatal(err)
		}
		if h := LoginHealth(home, a, true); h.State != "valid" {
			t.Fatalf("%s: before any upstream verdict state = %s, want valid", refresh, h.State)
		}
		r, err := Query(context.Background(), "codex", a)
		if err != nil || r.Quota != nil || !NeedsRefresh(r, err) {
			t.Fatalf("%s: fixture 401 not seen as an auth refusal: quota=%v err=%v", refresh, r.Quota, err)
		}
		if err := RecordUpstream(home, a, r, err); err != nil {
			t.Fatal(err)
		}
		b, _ := os.ReadFile(filepath.Join(home, upstreamFile))
		if strings.Contains(string(b), "fixture-refresh-secret") || strings.Contains(string(b), "invalidated.") {
			t.Fatalf("%s: verdict file carries a credential or the upstream message: %s", refresh, b)
		}
		h := LoginHealth(home, a, true)
		if h.State != "access_rejected" || h.UpstreamError != "token_revoked" || h.UpstreamRejectedAt == nil || !strings.Contains(h.Reason, "token_revoked") {
			t.Fatalf("%s: revoked login health = %+v, want access_rejected · token_revoked", refresh, h)
		}
		if refresh == HubManagedRefreshToken && (h.Source != "hub" || !strings.Contains(h.Reason, "hub must issue")) {
			t.Fatalf("hub lease rejection does not name the hub as the fix: %+v", h)
		}
		// A new credential in the same home: the record is about the old one.
		writeTestLoginRefresh(t, home, "member", time.Now().Add(100*time.Hour), refresh)
		b2, _ := ReadAuth(home)
		if h := LoginHealth(home, b2, true); h.State != "valid" || h.UpstreamError != "" {
			t.Fatalf("%s: a renewed credential inherited the old refusal: %+v", refresh, h)
		}
	}
}

// The clock's more specific words win, and an accepted read clears a refusal.
func TestUpstreamVerdictPrecedenceAndClearing(t *testing.T) {
	home := t.TempDir()
	writeTestLogin(t, home, "member", time.Now().Add(-time.Hour))
	a, _ := ReadAuth(home)
	revoked := classifyRPC(-32000, "unexpected status 401 Unauthorized: token_revoked")
	if err := RecordUpstream(home, a, Result{}, revoked); err != nil {
		t.Fatal(err)
	}
	if h := LoginHealth(home, a, true); h.State != "access_expired" {
		t.Fatalf("expired + rejected = %s, want access_expired", h.State)
	}
	writeTestLogin(t, home, "member", time.Now().Add(48*time.Hour))
	a, _ = ReadAuth(home)
	if err := RecordUpstream(home, a, Result{}, revoked); err != nil {
		t.Fatal(err)
	}
	if h := LoginHealth(home, a, true); h.State != "access_rejected" {
		t.Fatalf("live + rejected = %s, want access_rejected", h.State)
	}
	if err := RecordUpstream(home, a, Result{Quota: &model.QuotaSnapshot{}}, nil); err != nil {
		t.Fatal(err)
	}
	if h := LoginHealth(home, a, true); h.State != "refresh_due" && h.State != "valid" || h.UpstreamError != "" {
		t.Fatalf("accepted read did not clear the refusal: %+v", h)
	}
	// Nothing on record + accepted = no write; a network error = no verdict.
	other := t.TempDir()
	writeTestLogin(t, other, "member", time.Now().Add(48*time.Hour))
	o, _ := ReadAuth(other)
	_ = RecordUpstream(other, o, Result{Quota: &model.QuotaSnapshot{}}, nil)
	_ = RecordUpstream(other, o, Result{}, classifyRPC(-32000, "temporary connection failure"))
	if _, err := os.Stat(filepath.Join(other, upstreamFile)); !os.IsNotExist(err) {
		t.Fatalf("a verdict was written with nothing to say: %v", err)
	}
}

func TestAccessRejectCodes(t *testing.T) {
	for msg, want := range map[string]string{
		`unexpected status 401 Unauthorized: {"error":{"code":"token_revoked"}}`: "token_revoked",
		"401 unauthorized":                      "",
		"refresh_token_expired":                 "",
		"invalid_token: the token is malformed": "invalid_token",
	} {
		e := classifyRPC(-32000, msg)
		if e.authCode != want || (want != "" && !e.unauthorized) {
			t.Errorf("classifyRPC(%q) = code %q unauthorized %v, want %q", msg, e.authCode, e.unauthorized, want)
		}
	}
}

// The fleet credential proxy (bin/fleet-cred-proxy.py codex_verdict) writes
// the same file from Python: its exact shape must read as a refusal here.
func TestProxyWrittenVerdictIsRead(t *testing.T) {
	home := t.TempDir()
	writeTestLoginRefresh(t, home, "member", time.Now().Add(183*time.Hour), HubManagedRefreshToken)
	a, _ := ReadAuth(home)
	b, _ := os.ReadFile(filepath.Join(home, "auth.json"))
	var doc struct {
		Tokens struct {
			Access  string `json:"access_token"`
			Refresh string `json:"refresh_token"`
		} `json:"tokens"`
	}
	_ = json.Unmarshal(b, &doc)
	// what codex_tokens computes: sha256(access NUL refresh), lower hex
	fp := fmt.Sprintf("%x", sha256.Sum256([]byte(doc.Tokens.Access+"\x00"+doc.Tokens.Refresh)))
	rec := `{"credential_version": "` + fp + `", "state": "rejected", "error": "token_revoked", "at": "2026-10-06T14:40:00Z", "by": "proxy"}`
	if err := os.WriteFile(filepath.Join(home, upstreamFile), []byte(rec), 0600); err != nil {
		t.Fatal(err)
	}
	if h := LoginHealth(home, a, true); h.State != "access_rejected" || h.UpstreamError != "token_revoked" {
		t.Fatalf("proxy-written verdict not read: %+v", h)
	}
}
