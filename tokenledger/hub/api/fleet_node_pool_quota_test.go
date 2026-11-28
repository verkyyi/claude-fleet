package api

import (
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
)

// A node's proxy reports its pool readings on the usage report: filed under
// the pool credential only once the hub leased that credential to the very
// endpoint, only when newer than the last reading, never refusing the usage.
func TestNodePoolQuotaFromUsageReport(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "gmail", credvault.Secret{SetupToken: "sk-ant-oat01-GMAILSECRET", ExpiresAt: &exp, AccountUUID: gmailUUID})
	putPool(t, h, credvault.Codex, "heidi", credvault.Secret{RefreshToken: "rt-CODEXSECRET", AccountID: "acct-1", IDToken: quotaIDToken("acct-1", "user-1")})
	eps, err := h.srv.Store.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	var ep string
	for _, e := range eps {
		if e.Hostname == "mac-c" {
			ep = e.ID
		}
	}
	if ep == "" {
		t.Fatalf("no endpoint for mac-c in %+v", eps)
	}
	now := time.Now()
	week := strconv.FormatInt(now.Add(20*time.Hour).Unix(), 10)
	five := strconv.FormatInt(now.Add(2*time.Hour).Unix(), 10)
	report := func(at time.Time, pct string, extra ...map[string]any) {
		t.Helper()
		q := []map[string]any{
			{"provider": "claude", "account": "gmail", "at": at.Unix(), "rl5h": "-", "rl7d": pct, "rl_reset5": "-", "rl_reset7": week},
			{"provider": "codex", "account": "heidi", "at": at.Unix(), "rl5h": "3", "rl7d": pct, "rl_reset5": five, "rl_reset7": week, "win5": "300", "win7": "10080"},
		}
		q = append(q, extra...)
		st, out := sessDo(t, h, http.MethodPost, "/v1/node/usage", tok, "", map[string]any{
			"usage": []map[string]any{{"provider": "claude", "tokens": 10, "requests": 1}}, "quota": q})
		if st != http.StatusOK {
			t.Fatalf("usage report refused: %d %v", st, out)
		}
	}
	seven := func(uuid string) (float64, bool) {
		t.Helper()
		v, err := h.srv.LimitsFor(uuid)
		if err != nil {
			t.Fatal(err)
		}
		if !v.Available {
			return 0, false
		}
		if uuid == gmailUUID {
			if v.ReadVia == HubQuotaVia {
				t.Fatalf("read via %q", v.ReadVia)
			}
			return v.SevenDay.Utilization, true
		}
		for _, w := range v.Windows {
			if w.Minutes == 10080 {
				return w.Utilization, true
			}
		}
		return 0, false
	}
	cu := codex.AccountUUID("acct-1", "user-1")

	// Never leased to this endpoint: nothing filed.
	report(now.Add(-time.Minute), "40")
	if _, ok := seven(gmailUUID); ok {
		t.Fatal("a reading of a credential never leased to the endpoint was filed")
	}
	for _, acct := range []struct{ p, a string }{{credvault.Claude, "gmail"}, {credvault.Codex, "heidi"}} {
		if err := h.srv.Store.AddCredAudit(store.CredAudit{Action: store.CredIssue, PrincipalID: pAlice,
			Provider: acct.p, Account: acct.a, Hostname: "mac-c", OSUser: "alice", EndpointID: ep}); err != nil {
			t.Fatal(err)
		}
	}
	// Leased: filed, with an unknown account and a stale one dropped quietly.
	report(now.Add(-30*time.Second), "68",
		map[string]any{"provider": "claude", "account": "nobody", "at": now.Unix(), "rl5h": "1", "rl7d": "1"},
		map[string]any{"provider": "claude", "account": "gmail", "at": now.Add(-2 * time.Hour).Unix(), "rl5h": "1", "rl7d": "99"})
	if v, ok := seven(gmailUUID); !ok || v != 68 {
		t.Fatalf("claude: %v %v", v, ok)
	}
	if v, ok := seven(cu); !ok || v != 68 {
		t.Fatalf("codex: %v %v", v, ok)
	}
	q, err := h.srv.Store.LatestQuota(h.srv.Vault.CredentialID(mustCred(t, h, credvault.Codex, "heidi")))
	if err != nil || q == nil || q.Observation != ObservationProxyHeaders || len(q.Windows) != 2 || q.Windows[0].Minutes != 300 {
		t.Fatalf("codex snapshot under the credential: %+v %v", q, err)
	}
	// An older reading (another machine's, late) does not displace the newer.
	report(now.Add(-10*time.Minute), "12")
	if v, _ := seven(gmailUUID); v != 68 {
		t.Fatalf("an older reading displaced the newer: %v", v)
	}
	report(now, "71")
	if v, _ := seven(gmailUUID); v != 71 {
		t.Fatalf("a newer reading was not filed: %v", v)
	}
}

func mustCred(t *testing.T, h *harness, provider, account string) store.Credential {
	t.Helper()
	c, err := h.srv.Store.Credential(store.PoolPrincipal, provider, account)
	if err != nil || c == nil {
		t.Fatalf("credential %s/%s: %v", provider, account, err)
	}
	return *c
}
