package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
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

// A service pass (standing, or a run's) carries no node: its first Codex
// response must still record its continuation source, and the next request
// carrying that response's ids must go to the same account.
func TestSvcPassCodexContinuationRecorded(t *testing.T) {
	r := newCPRig(t)
	s := r.h.srv
	s.RelaySignKey = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{5}, ed25519.SeedSize)) // prod mints fcp-h2
	if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "rt-second", AccountID: "aid-second"}); err != nil {
		t.Fatal(err)
	}
	tok := svcStandingSetup(t, r.h, "xiaoerge", "pass:issue")
	standing := svcPassMint(t, r.h, tok, nil)["cred"].(string)
	run := svcCodexRunPass(t, r.h, "space:ws:1", "R31")
	var mu sync.Mutex
	var seen []string
	n := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		account := req.Header.Get("Chatgpt-Account-Id")
		mu.Lock()
		n++
		k := n
		seen = append(seen, account+" "+string(body))
		mu.Unlock()
		// the Agents SDK's shape: store:false, stream:true, a function call and
		// reasoning in the output, ids the next turn sends back
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_%d\"}}\n\n", k)
		fmt.Fprintf(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_%d\",\"output\":["+
			"{\"type\":\"reasoning\",\"id\":\"rs_%d\",\"encrypted_content\":\"enc-%s-%d\",\"summary\":[]},"+
			"{\"type\":\"function_call\",\"id\":\"fc_%d\",\"call_id\":\"call_%d\",\"name\":\"lookup\",\"arguments\":\"{}\"}],"+
			"\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\n\n", k, k, account, k, k, k)
	}))
	defer upstream.Close()
	p, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}, Direct: true, CodexURL: upstream.URL, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	proxy := httptest.NewServer(p.Handler())
	defer proxy.Close()
	call := func(pass, body string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, proxy.URL+"/v1/proxy/codex/responses", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+pass)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp.StatusCode, string(raw)
	}
	for name, pass := range map[string]string{"standing": standing, "run": run} {
		first := `{"model":"gpt-5-codex","store":false,"stream":true,"tools":[{"type":"function","name":"lookup"}],"input":[{"role":"user","content":"hi"}]}`
		if st, body := call(pass, first); st != 200 {
			t.Fatalf("%s: first turn → %d %s", name, st, body)
		}
		mu.Lock()
		k := n
		acct := strings.Fields(seen[len(seen)-1])[0]
		mu.Unlock()
		next := fmt.Sprintf(`{"model":"gpt-5-codex","store":false,"stream":true,"input":[{"role":"user","content":"hi"},`+
			`{"type":"reasoning","id":"rs_%d","encrypted_content":"enc-%s-%d","summary":[]},`+
			`{"type":"function_call","id":"fc_%d","call_id":"call_%d","name":"lookup","arguments":"{}"},`+
			`{"type":"function_call_output","call_id":"call_%d","output":"42"}]}`, k, acct, k, k, k, k)
		if st, body := call(pass, next); st != 200 {
			t.Fatalf("%s: the follow-up carrying the first response's ids → %d %s", name, st, body)
		}
		mu.Lock()
		got := strings.Fields(seen[len(seen)-1])[0]
		mu.Unlock()
		if got != acct {
			t.Fatalf("%s: the follow-up went to %s, the first turn ran on %s", name, got, acct)
		}
	}

	// A response that already went out is recorded whatever the account's
	// availability now: a failed background refresh (the cached access token
	// still serving) or a limit reached since must not refuse the record — that
	// refusal is the client's 502 affinity_record_unavailable.
	b, err := s.Store.SessionBindFor("svc-standing/xiaoerge", credvault.Codex)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := s.Store.Credential(b.Owner, credvault.Codex, b.Account)
	sec := map[string]string{"poolcx": "aid-pool", "poolcx2": "aid-second"}[b.Account]
	if err := s.Store.NoteRefreshError(b.Owner, credvault.Codex, b.Account, "refresh: HTTP 500 (fixture)", time.Now()); err != nil {
		t.Fatal(err)
	}
	s.limits.mark(credvault.Codex, b.Owner, s.Vault.CredentialID(*c), time.Now().Add(time.Hour))
	router := &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}
	if err := router.RecordCodexAffinity(t.Context(), standing, credproxy.Resolution{Owner: b.Owner, Account: b.Account, AccountID: sec,
		CredentialID: s.Vault.CredentialID(*c)}, []string{credproxy.CodexReference("id", "resp_after_refresh_failed")}); err != nil {
		t.Fatalf("recording a response that already went out, account now unhealthy: %v", err)
	}
	// an account the service may not use is still refused, with its reason
	other, _ := s.Store.Credential(store.PoolPrincipal, credvault.Codex, map[string]string{"poolcx": "poolcx2", "poolcx2": "poolcx"}[b.Account])
	if err := s.Store.SetFleetSetting(credUserKey("svc:xiaoerge"), `["`+s.Vault.CredentialID(*c)+`"]`, time.Now()); err != nil {
		t.Fatal(err)
	}
	err = router.RecordCodexAffinity(t.Context(), standing, credproxy.Resolution{Owner: store.PoolPrincipal, Account: other.Account, AccountID: "aid-x",
		CredentialID: s.Vault.CredentialID(*other)}, []string{credproxy.CodexReference("id", "resp_foreign")})
	if err == nil || !strings.Contains(err.Error(), "source_account_not_authorized") {
		t.Fatalf("a record naming an account off the allowlist: %v", err)
	}
}

// svcCodexRunPass mints a run's Codex pass as svcRunSpec does for engine codex.
func svcCodexRunPass(t *testing.T, h *harness, tenant, run string) string {
	t.Helper()
	var rnd [16]byte
	_, _ = rand.Read(rnd[:])
	now := time.Now().Truncate(time.Second)
	worker := "svc/" + run + "/a1"
	if err := h.srv.Store.SetFleetSetting(credUserKey("svc:livepage"), `"*"`, now); err != nil {
		t.Fatal(err)
	}
	c := sessionCredClaims{V: 2, ID: "sc_" + hex.EncodeToString(rnd[:]), Principal: "svc:livepage", WorkerID: worker,
		Machine: "svc-run", Providers: []string{credvault.Codex}, Iat: now.Unix(), Exp: now.Add(time.Hour).Unix(),
		Svc: "livepage", Tenant: tenant, Run: run}
	if err := h.srv.Store.AddSessionCred(store.SessionCred{ID: c.ID, PrincipalID: c.Principal, WorkerID: worker,
		WorkerKey: worker, Machine: "svc-run", Providers: c.Providers, IssuedAt: now, ExpiresAt: time.Unix(c.Exp, 0)}); err != nil {
		t.Fatal(err)
	}
	return h.srv.signSessionPass(c)
}
