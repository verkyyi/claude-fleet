package api

import (
	"encoding/base64"
	"encoding/json"
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

// The Bedrock fallback, end to end (task PNWW): hub + cluster proxy + a fake
// subscription upstream + a fake Bedrock. Off by default; on, a request the
// pool cannot take is replayed on Bedrock and metered as source bedrock;
// never for a trial person, never past the monthly cap.

type bedrockRig struct {
	*cpRig
	mu    sync.Mutex
	calls []string // the Bedrock paths called
}

func (b *bedrockRig) bedrockCalls() int { b.mu.Lock(); defer b.mu.Unlock(); return len(b.calls) }

func bedrockChunk(ev string) []byte {
	p, _ := json.Marshal(map[string]string{"bytes": base64.StdEncoding.EncodeToString([]byte(ev))})
	return credproxy.EncodeFrame(map[string]string{":message-type": "event", ":event-type": "chunk"}, p)
}

func newBedrockHubRig(t *testing.T) *bedrockRig {
	t.Helper()
	b := &bedrockRig{}
	br := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		b.mu.Lock()
		b.calls = append(b.calls, r.URL.EscapedPath()+" "+strings.SplitN(r.Header.Get("Authorization"), "/", 2)[0])
		b.mu.Unlock()
		w.Header().Set("Content-Type", "application/vnd.amazon.eventstream")
		for _, ev := range []string{
			`{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":1}}}`,
			`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"FROM BEDROCK"}}`,
			`{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":500}}`,
			`{"type":"message_stop"}`,
		} {
			_, _ = w.Write(bedrockChunk(ev))
		}
	}))
	t.Cleanup(br.Close)
	b.cpRig = newCPRigWith(t, func(c *credproxy.Config) { c.BedrockURL = br.URL })
	// the pool's Bedrock key, through the admin's credentials API
	if code, out := b.h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "bedrock1", Secret: credvault.Secret{AWSAccessKeyID: "AKIDTEST", AWSSecretAccessKey: "sekrit"}}); code != http.StatusOK {
		t.Fatalf("put bedrock key: %d %v", code, out)
	}
	return b
}

// both of the person's accounts answer a quota 429
func (b *bedrockRig) fillPool(t *testing.T) {
	t.Helper()
	a1, a2 := b.leased(t, "gh:1005", credvault.Claude, "acct1"), b.leased(t, "gh:1005", credvault.Claude, "acct2")
	b.cpRig.mu.Lock()
	b.full = map[string]string{a1: weekly429, a2: weekly429}
	b.cpRig.mu.Unlock()
}

func (b *bedrockRig) stream(t *testing.T, cred string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, b.proxy.URL+"/v1/proxy/anthropic/v1/messages",
		strings.NewReader(`{"model":"claude-opus-5-5","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"PING"}]}`))
	req.Header.Set("Authorization", "Bearer "+cred)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(body)
}

func (b *bedrockRig) set(t *testing.T, key, value string) {
	t.Helper()
	if err := b.h.srv.Store.SetFleetSetting(key, value, time.Now()); err != nil {
		t.Fatal(err)
	}
	b.pastCache()
}

func TestBedrockFallbackOffByDefault(t *testing.T) {
	b := newBedrockHubRig(t)
	cred, _ := b.issue(t, fidA)
	b.fillPool(t)
	if st, body := b.stream(t, cred); st != http.StatusTooManyRequests || strings.Contains(body, "FROM BEDROCK") {
		t.Fatalf("off → %d %s", st, body)
	}
	if b.bedrockCalls() != 0 {
		t.Fatal("Bedrock was called with the fallback off")
	}
	// the key is no subscription: never listed, never bound, never leased
	if rows, _ := b.h.srv.Store.Credentials(store.PoolPrincipal); len(rows) != 1 || rows[0].Provider != credvault.Codex {
		t.Fatalf("pool subscriptions = %+v", rows)
	}
	if _, err := b.h.srv.Vault.Lease(t.Context(), store.PoolPrincipal, credvault.Claude, "bedrock1"); err == nil {
		t.Fatal("a Bedrock key was leased")
	}
	if rows, _ := b.h.srv.Store.BedrockCredentials(); len(rows) != 1 || rows[0].Source() != store.SourceAPI {
		t.Fatalf("bedrock rows = %+v", rows)
	}
}

func TestBedrockFallbackOnReplays429(t *testing.T) {
	b := newBedrockHubRig(t)
	cred, wid := b.issue(t, fidA)
	b.fillPool(t)
	b.set(t, BedrockFallbackKey, "on")
	st, body := b.stream(t, cred)
	if st != http.StatusOK || !strings.Contains(body, "event: message_start") || !strings.Contains(body, "FROM BEDROCK") {
		t.Fatalf("on + 429 → %d %s", st, body)
	}
	if b.bedrockCalls() != 1 || !strings.HasPrefix(b.calls[0], "/model/global.anthropic.claude-opus-5-5/invoke-with-response-stream AWS4-HMAC-SHA256 Credential=AKIDTEST") {
		t.Fatalf("bedrock calls %v", b.calls)
	}
	var row store.PoolUsage
	waitFor(t, 3*time.Second, "the bedrock row", func() bool {
		for _, u := range poolRows(t, b.h, "gh:1005") {
			if u.Source == store.UsageSourceBedrock {
				row = u
				return true
			}
		}
		return false
	})
	if row.WorkerID != wid || row.Account != "pool/bedrock1" || row.In != 1000 || row.Out != 500 || row.Model != "claude-opus-5-5" {
		t.Fatalf("row = %+v", row)
	}
	// the admin sees the split and the month's spend
	var au AdminUsage
	b.h.getJSON(t, AdminUsagePath, &au)
	found := false
	for _, s := range au.Sources {
		found = found || (s.Source == store.UsageSourceBedrock && s.Tokens == 1500)
	}
	if !found || au.Bedrock == nil || !au.Bedrock.On || au.Bedrock.MonthUSD <= 0 || au.Bedrock.CapUSD != 200 {
		t.Fatalf("admin usage sources=%+v bedrock=%+v", au.Sources, au.Bedrock)
	}
}

func TestBedrockFallbackNotForTrial(t *testing.T) {
	b := newBedrockHubRig(t)
	cred, _ := b.issue(t, fidA)
	b.fillPool(t)
	b.set(t, BedrockFallbackKey, "on")
	b.set(t, MemberLimitsPrefix+"gh:1005", "until="+time.Now().Add(30*24*time.Hour).UTC().Format(time.RFC3339))
	if st, body := b.stream(t, cred); st == http.StatusOK || strings.Contains(body, "FROM BEDROCK") || b.bedrockCalls() != 0 {
		t.Fatalf("trial → %d %s (bedrock calls %d)", st, body, b.bedrockCalls())
	}
	b.cpRig.mu.Lock()
	audit := strings.Join(b.audit, "\n")
	b.cpRig.mu.Unlock()
	if !strings.Contains(audit, `"fallback":"bedrock: trial"`) {
		t.Fatalf("the hub did not refuse as trial:\n%s", audit)
	}
}

func TestBedrockFallbackCap(t *testing.T) {
	b := newBedrockHubRig(t)
	cred, _ := b.issue(t, fidA)
	b.fillPool(t)
	b.set(t, BedrockFallbackKey, "on")
	// this month's Bedrock spend already at the cap: $5 a million input on opus
	if err := b.h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: "gh:1005", Provider: credvault.Claude, Model: "claude-opus-5",
		In: 2_000_000, Source: store.UsageSourceBedrock, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	b.set(t, BedrockFallbackCapKey, "10")
	if st, body := b.stream(t, cred); st != http.StatusTooManyRequests || b.bedrockCalls() != 0 {
		t.Fatalf("cap reached → %d %s (bedrock calls %d)", st, body, b.bedrockCalls())
	}
	b.set(t, BedrockFallbackCapKey, "11")
	if st, body := b.stream(t, cred); st != http.StatusOK || b.bedrockCalls() != 1 {
		t.Fatalf("under the cap → %d %s", st, body)
	}
}

// The credentials API keeps a Bedrock key the pool's, and never lets it
// replace a subscription.
func TestBedrockKeyPutRules(t *testing.T) {
	b := newBedrockHubRig(t)
	for name, req := range map[string]FleetCredentialRequest{
		"a person's": {Action: "put", PrincipalID: "gh:1005", Provider: credvault.Claude, Account: "x",
			Secret: credvault.Secret{AWSAccessKeyID: "A", AWSSecretAccessKey: "S"}},
		"over a subscription": {Action: "put", PrincipalID: "gh:1005", Provider: credvault.Claude, Account: "acct1",
			Secret: credvault.Secret{AWSAccessKeyID: "A", AWSSecretAccessKey: "S"}},
		"half a key": {Action: "put", PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "y",
			Secret: credvault.Secret{AWSAccessKeyID: "A"}},
		"a subscription over it": {Action: "put", PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "bedrock1",
			Secret: credvault.Secret{RefreshToken: "rt"}},
	} {
		if code, out := b.h.post(t, "/v1/fleet/credentials", req); code == http.StatusOK {
			t.Errorf("%s: accepted %v", name, out)
		}
	}
}
