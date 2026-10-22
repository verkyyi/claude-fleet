package api

import (
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

func TestCodexSelection429Contract(t *testing.T) {
	for _, quota := range []bool{false, true} {
		t.Run(fmt.Sprint("quota=", quota), func(t *testing.T) {
			r := newCPRig(t)
			s := r.h.srv
			if err := s.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2", credvault.Secret{RefreshToken: "fixture-second", AccountID: "second"}); err != nil {
				t.Fatal(err)
			}
			pass, wid := r.issue(t, fidA)
			now := time.Now()
			reset := now.Add(time.Hour).Unix()
			failure := `{"error":{"type":"rate_limit_error","message":"per-minute rate limit"}}`
			if quota {
				failure = fmt.Sprintf(`{"error":{"type":"usage_limit_reached","resets_at":%d}}`, reset)
			}
			var mu sync.Mutex
			var seen []string
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				body, _ := io.ReadAll(req.Body)
				account := req.Header.Get("Chatgpt-Account-Id")
				mu.Lock()
				seen = append(seen, account+" "+string(body))
				n := len(seen)
				mu.Unlock()
				if n == 1 {
					w.Header().Set("Retry-After", "60")
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(429)
					io.WriteString(w, failure)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				io.WriteString(w, `{"output":[]}`)
			}))
			defer up.Close()
			p, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}, Direct: true, CodexURL: up.URL, Audit: func(string) {}})
			if err != nil {
				t.Fatal(err)
			}
			proxy := httptest.NewServer(p.Handler())
			defer proxy.Close()
			codexSelectionQuota(t, r, "poolcx", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
			codexSelectionQuota(t, r, "poolcx2", now, 10, 10, 4*time.Hour, 6*24*time.Hour)
			call := func(body string) (int, string, string) {
				t.Helper()
				req, _ := http.NewRequest(http.MethodPost, proxy.URL+"/v1/proxy/codex/responses", strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer "+pass)
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				raw, err := io.ReadAll(resp.Body)
				resp.Body.Close()
				if err != nil {
					t.Fatal(err)
				}
				return resp.StatusCode, string(raw), resp.Header.Get("Retry-After")
			}
			status, body, retry := call(`{"input":"first"}`)
			if status != 429 || body != failure || retry != "60" {
				t.Fatalf("original response lost: %d %q %q", status, body, retry)
			}
			mu.Lock()
			count := len(seen)
			mu.Unlock()
			if count != 1 {
				t.Fatalf("429 replayed %d times", count)
			}
			wantAccount, wantRev := "poolcx", int64(1)
			if quota {
				wantAccount, wantRev = "poolcx2", 2
			}
			bind, err := s.Store.SessionBindFor(wid, credvault.Codex)
			if err != nil || bind.Account != wantAccount || bind.Rev != wantRev {
				t.Fatalf("binding: %+v %v", bind, err)
			}
			first, err := s.Store.Credential(store.PoolPrincipal, credvault.Codex, "poolcx")
			if err != nil || first == nil {
				t.Fatal("missing credential", err)
			}
			limited := s.limits.limited(credvault.Codex, store.PoolPrincipal, s.Vault.CredentialID(*first), now)
			if limited != quota {
				t.Fatalf("cooldown=%v quota=%v", limited, quota)
			}
			if status, body, _ := call(`{"input":"next independent request"}`); status != 200 {
				t.Fatalf("next: %d %s", status, body)
			}
			mu.Lock()
			defer mu.Unlock()
			wantID := "aid-pool"
			if quota {
				wantID = "second"
			}
			if len(seen) != 2 || seen[0] != `aid-pool {"input":"first"}` || seen[1] != wantID+` {"input":"next independent request"}` {
				t.Fatalf("replay/wrong next account: %v", seen)
			}
			if quota && s.limits.limited(credvault.Codex, store.PoolPrincipal, s.Vault.CredentialID(*first), time.Unix(reset, 0)) {
				t.Fatal("cooldown survived reset boundary")
			}
		})
	}
}
