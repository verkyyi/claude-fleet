package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

func TestCodexContinuationAcrossReplicas(t *testing.T) {
	r := newCPRig(t)
	s := r.h.srv
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	pass, wid := r.issue(t, fidA)
	var mu sync.Mutex
	var seen []string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		account := req.Header.Get("Chatgpt-Account-Id")
		mu.Lock()
		seen = append(seen, account+" "+string(body))
		mu.Unlock()
		// Account scoped state: the fixture refuses any wrong-account continuation.
		if strings.Contains(string(body), "old-ref") && account != "aid-pool" {
			t.Error("crossed subscription")
			http.Error(w, "wrong account", 409)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Codex-Turn-State", account+"-state")
		fmt.Fprintf(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":%q,\"output\":[{\"type\":\"compaction\",\"encrypted_content\":%q}]}}\n\n", account+"-response", account+"-encrypted")
	}))
	defer upstream.Close()
	makeProxy := func() *httptest.Server {
		p, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}, Direct: true, CodexURL: upstream.URL, Audit: func(string) {}})
		if err != nil {
			t.Fatal(err)
		}
		pserver := httptest.NewServer(p.Handler())
		t.Cleanup(pserver.Close)
		return pserver
	}
	p1, p2 := makeProxy(), makeProxy()
	call := func(proxy *httptest.Server, body string, want int, state ...string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, proxy.URL+"/v1/proxy/codex/responses", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+pass)
		if len(state) > 0 {
			req.Header.Set("X-Codex-Turn-State", state[0])
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("status %d want %d: %s", resp.StatusCode, want, raw)
		}
	}
	now := time.Now()
	codexSelectionQuota(t, r, "poolcx", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
	call(p1, `{"input":"first"}`, 200)
	first, _ := s.Store.Credential(store.PoolPrincipal, credvault.Codex, "poolcx")
	// Seed the reference used by the account-checking fixture via the real record protocol.
	router := &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}
	if err := router.RecordCodexAffinity(t.Context(), pass, credproxy.Resolution{Owner: store.PoolPrincipal, Account: "poolcx", AccountID: "aid-pool", CredentialID: s.Vault.CredentialID(*first)}, []string{credproxy.CodexReference("id", "old-ref")}); err != nil {
		t.Fatal(err)
	}
	b, _ := s.Store.SessionBindFor(wid, credvault.Codex)
	if _, err := s.Store.SetSessionBind(b, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	codexSelectionQuota(t, r, "poolcx2", time.Now(), 10, 10, 15*time.Minute, 6*24*time.Hour)
	call(p2, `{"input":"independent"}`, 200)
	b, _ = s.Store.SessionBindFor(wid, credvault.Codex)
	if b.Account != "poolcx2" {
		t.Fatalf("existing sticky did not reselect: %+v", b)
	}
	call(p2, `{"previous_response_id":"old-ref","input":"continue"}`, 200)
	call(p2, `{"input":[{"type":"compaction","encrypted_content":"aid-pool-encrypted"}]}`, 200)
	// The first proxy must also ignore its old pass cache for the new lineage.
	call(p1, `{"previous_response_id":"second-response","input":"continue"}`, 200)
	// A newly started replica has no local resolution or reference cache.
	call(makeProxy(), `{"previous_response_id":"old-ref","input":"cold replica"}`, 200)
	call(p2, `{"input":"same turn"}`, 200, "aid-pool-state")
	mu.Lock()
	if len(seen) != 7 || !strings.HasPrefix(seen[2], "aid-pool ") || !strings.HasPrefix(seen[3], "aid-pool ") || !strings.HasPrefix(seen[4], "second ") {
		t.Errorf("wrong provenance: %v", seen)
	}
	before := len(seen)
	mu.Unlock()
	for _, body := range []string{
		`{"previous_response_id":"never-observed","input":"continue"}`,
		`{"previous_response_id":"old-ref","input":[{"type":"compaction","encrypted_content":"second-encrypted"}]}`,
		`{"future_state":"opaque","input":"continue"}`,
	} {
		call(p2, body, 409)
	}
	// A quota cooldown refuses a pinned source; it cannot redirect the continuation.
	s.limits.mark(credvault.Codex, store.PoolPrincipal, s.Vault.CredentialID(*first), time.Now().Add(time.Hour))
	call(p2, `{"previous_response_id":"old-ref","input":"continue"}`, 409)
	// Reauth and allowlist are checked again even with a durable reference.
	if err := s.Store.MarkReauthRequired(store.PoolPrincipal, credvault.Codex, "poolcx2", "fixture", true, time.Now()); err != nil {
		t.Fatal(err)
	}
	call(p2, `{"previous_response_id":"second-response","input":"continue"}`, 409)
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "replacement", AccountID: "replacement"}); err != nil {
		t.Fatal(err)
	}
	call(p2, `{"previous_response_id":"second-response","input":"continue"}`, 409)
	setPolicy(t, r.h, "user", "gh:1005", []string{})
	call(p1, `{"previous_response_id":"old-ref","input":"continue"}`, 409)
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != before {
		t.Fatalf("refusal reached upstream or replayed: %v", seen)
	}
}

func TestCodexContinuationLegacyBoundaryCannotReselect(t *testing.T) {
	r := newCPRig(t)
	s := r.h.srv
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "second"}); err != nil {
		t.Fatal(err)
	}
	pass, wid := r.issue(t, fidA)
	now := time.Now()
	_, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: wid, Provider: credvault.Codex, Owner: store.PoolPrincipal, Account: "poolcx", SetBy: "auto"}, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	codexSelectionQuota(t, r, "poolcx", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
	codexSelectionQuota(t, r, "poolcx2", now, 10, 10, 15*time.Minute, 6*24*time.Hour)
	raw, _ := json.Marshal(credproxy.ResolveRequest{Cred: pass, Provider: credvault.Codex, RequestBoundary: true})
	req, _ := http.NewRequest(http.MethodPost, r.h.http.URL+CredProxyResolvePath, strings.NewReader(string(raw)))
	req.Header.Set("Authorization", "Bearer "+cpToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var result credproxy.Resolution
	json.NewDecoder(resp.Body).Decode(&result)
	if !result.Valid || result.Account != "poolcx" {
		t.Fatalf("legacy boolean selected new account: %+v", result)
	}
}

func TestCodexContinuationWorkspaceIdentity(t *testing.T) {
	r := newCPRig(t)
	s := r.h.srv
	pass, _ := r.issue(t, fidA)
	router := &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}
	original, err := router.ResolveCodex(t.Context(), pass, credproxy.CodexRoute{Independent: true})
	if err != nil || !original.Valid {
		t.Fatalf("initial %+v %v", original, err)
	}
	ref := credproxy.CodexReference("id", "workspace-ref")
	if err := router.RecordCodexAffinity(t.Context(), pass, original, []string{ref}); err != nil {
		t.Fatal(err)
	}
	// A workspace/account ID can change without changing the OAuth grant used
	// by the stable metering identity. Neither labels nor that identity suffice.
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx", credvault.Secret{RefreshToken: "rt-cx", AccountID: "another-workspace"}); err != nil {
		t.Fatal(err)
	}
	row, _ := s.Store.Credential(store.PoolPrincipal, credvault.Codex, "poolcx")
	if s.Vault.CredentialID(*row) != original.CredentialID {
		t.Fatal("fixture changed grant, not just workspace")
	}
	next, err := router.ResolveCodex(t.Context(), pass, credproxy.CodexRoute{References: []string{ref}})
	if err != nil || next.Valid || next.Error != credproxy.CodexContinuationUnavailable {
		t.Fatalf("workspace change accepted: %+v %v", next, err)
	}
}
