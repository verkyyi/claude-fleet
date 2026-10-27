package api

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// DeepSeek (task J7BN, P0): an API key in the vault, handed by resolve to the
// cluster credential proxy like a setup token, never to a node machine.

const dsKey = "fake-ds-pool-key"

// resolve asks the hub as the cluster proxy does.
func cpResolve(t *testing.T, r *cpRig, cred, provider string) map[string]any {
	t.Helper()
	st, out := sessDo(t, r.h, http.MethodPost, CredProxyResolvePath, cpToken, "", map[string]any{"cred": cred, "provider": provider})
	if st != http.StatusOK {
		t.Fatalf("resolve %s: %d %v", provider, st, out)
	}
	return out
}

func TestCredProxyResolveDeepSeek(t *testing.T) {
	r := newCPRig(t)
	cred, wid := r.issue(t, fidA)
	// none stored yet: refused, nothing leased
	if out := cpResolve(t, r, cred, credvault.DeepSeek); out["valid"] == true || out["error"] != "no_credential" {
		t.Fatalf("no key: %v", out)
	}
	if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.DeepSeek, "ds-pool", credvault.Secret{APIKey: dsKey}); err != nil {
		t.Fatal(err)
	}
	out := cpResolve(t, r, cred, credvault.DeepSeek)
	if out["valid"] != true || out["access_token"] != dsKey || out["owner"] != store.PoolPrincipal || out["account"] != "ds-pool" ||
		out["expires_at"] != nil || out["provider"] != credvault.DeepSeek || out["credential_id"] == "" {
		t.Fatalf("pool key: %v", out)
	}
	b, err := r.h.srv.Store.SessionBindFor(wid, credvault.DeepSeek)
	if err != nil || b.Owner != store.PoolPrincipal || b.Account != "ds-pool" {
		t.Fatalf("bind = %+v, %v", b, err)
	}
	// stable: the same binding, the same key, the row never written
	if again := cpResolve(t, r, cred, credvault.DeepSeek); again["access_token"] != dsKey || again["bind_rev"] != out["bind_rev"] {
		t.Fatalf("again: %v", again)
	}
	if row, _ := r.h.srv.Store.Credential(store.PoolPrincipal, credvault.DeepSeek, "ds-pool"); row.Version != 1 || len(row.AccessSealed) != 0 {
		t.Fatalf("the lease wrote the row: %+v", row)
	}
	// the Claude binding is its own
	if c := cpResolve(t, r, cred, credvault.Claude); c["access_token"] == dsKey {
		t.Fatalf("claude resolved to the deepseek key: %v", c)
	}

	// A person's own key: a new session binds it first.
	if err := r.h.srv.Vault.Put("gh:1005", credvault.DeepSeek, "ds-mine", credvault.Secret{APIKey: "sk-MINE"}); err != nil {
		t.Fatal(err)
	}
	credB, _ := r.issue(t, fidB)
	if mine := cpResolve(t, r, credB, credvault.DeepSeek); mine["access_token"] != "sk-MINE" || mine["owner"] != "gh:1005" {
		t.Fatalf("own key: %v", mine)
	}

	// A pass that does not cover deepseek resolves none.
	c := assertClaims(r.f5, time.Now())
	c.Fid, c.WorkerID, c.Key = fidA, fleetid.WorkerID(r.f5, fidA), "issue-"+fidA[:4]
	st, iss := sessDo(t, r.h, http.MethodPost, "/v1/fleet/session-cred", r.tok5, signWorkerAssertion(c, HashToken(r.tok5)),
		map[string]any{"providers": []string{credvault.Claude}})
	if st != 200 {
		t.Fatalf("issue claude-only: %d %v", st, iss)
	}
	if no := cpResolve(t, r, iss["cred"].(string), credvault.DeepSeek); no["valid"] == true || no["access_token"] != nil {
		t.Fatalf("claude-only pass resolved deepseek: %v", no)
	}

	// Its usage is filed under the person and counted in their budget.
	st, rep := sessDo(t, r.h, http.MethodPost, CredProxyUsagePath, cpToken, "", map[string]any{
		"cred": cred, "provider": credvault.DeepSeek, "account": "ds-pool", "owner": store.PoolPrincipal,
		"model": "deepseek-chat", "in": 100, "out": 50})
	if st != http.StatusOK {
		t.Fatalf("usage: %d %v", st, rep)
	}
	var ds []store.PoolUsage
	for _, u := range poolRows(t, r.h, "gh:1005") {
		if u.Provider == credvault.DeepSeek {
			ds = append(ds, u)
		}
	}
	if len(ds) != 1 || ds[0].In != 100 || ds[0].Out != 50 || ds[0].Model != "deepseek-chat" {
		t.Fatalf("deepseek usage rows = %+v", ds)
	}
	if got := personUsed(t, r.h, "gh:1005"); got < 150 {
		t.Fatalf("budget used %v, want the deepseek tokens counted", got)
	}
}

// Stored through the operator's route, listed without the key, never leased
// to a node, never read by the hub's quota reader.
func TestDeepSeekCredentialCentralOnly(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	relay := newFakeQuotaRelay(t, h)
	h.srv.HubQuota = &HubQuota{RelayURL: relay.srv.URL}
	log.SetOutput(io.Discard)

	putPool(t, h, credvault.DeepSeek, "ds-pool", credvault.Secret{APIKey: dsKey})
	putCred(t, h, credvault.DeepSeek, "ds-alice", credvault.Secret{APIKey: "sk-ALICEDSSECRET"})
	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "icloud", credvault.Secret{SetupToken: "sk-ant-oat01-ICLOUDSECRET", ExpiresAt: &exp, AccountUUID: icloudUUID})
	// bad shapes refused
	for name, s := range map[string]credvault.Secret{
		"empty":         {},
		"whitespace":    {APIKey: "sk bad"},
		"refresh_token": {APIKey: dsKey, RefreshToken: "rt"},
	} {
		if code, _ := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
			Provider: credvault.DeepSeek, Account: "bad", Secret: s}); code != http.StatusBadRequest {
			t.Errorf("%s: %d", name, code)
		}
	}

	res, body := h.get(t, "/v1/fleet/credentials")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("list: %d %s", res.StatusCode, body)
	}
	if strings.Contains(string(body), "DEEPSEEKSECRET") || strings.Contains(string(body), "ALICEDSSECRET") {
		t.Fatalf("the list carries a key: %s", body)
	}
	row, err := h.srv.Store.Credential(store.PoolPrincipal, credvault.DeepSeek, "ds-pool")
	if err != nil || row.Kind != credvault.KindAPIKey || row.Source() != store.SourceAPI {
		t.Fatalf("pool row = %+v, %v", row, err)
	}
	if own, _ := h.srv.Store.Credential(pAlice, credvault.DeepSeek, "ds-alice"); own.Source() != store.SourceBYO {
		t.Fatalf("own row source = %q", own.Source())
	}

	code, got, refusal := lease(t, h, tok)
	if code != http.StatusOK {
		t.Fatalf("lease: %d %v", code, refusal)
	}
	for _, c := range append(got.Credentials, got.Withdrawn...) {
		if c.Provider == credvault.DeepSeek {
			t.Fatalf("a node was handed a deepseek row: %+v", c)
		}
	}
	if len(got.Credentials) != 1 || got.Credentials[0].Account != "icloud" {
		t.Fatalf("lease = %+v", got.Credentials)
	}

	h.srv.ReadHubQuota(context.Background())
	relay.mu.Lock()
	auths := strings.Join(relay.auth, " ")
	relay.mu.Unlock()
	if strings.Contains(auths, "DEEPSEEKSECRET") || strings.Contains(auths, "ALICEDSSECRET") || !strings.Contains(auths, "ICLOUDSECRET") {
		t.Fatalf("quota reader saw auth=%q", auths)
	}
	for _, r := range h.srv.HubQuota.Reads() {
		if r.Provider == credvault.DeepSeek {
			t.Fatalf("a deepseek key was quota-read: %+v", r)
		}
	}
	if v, err := h.srv.credentialLimits(*row); err != nil || v.Available {
		t.Fatalf("limits = %+v, %v", v, err)
	}
}

func TestCredPodProvidersAcceptsDeepSeek(t *testing.T) {
	if got, why := checkCredPodProviders(nil, "codex,deepseek"); got != "codex,deepseek" || why != "" {
		t.Fatalf("%q %q", got, why)
	}
	for _, a := range nodeAgentNames {
		if a == credvault.DeepSeek {
			t.Fatal("deepseek listed as a node agent")
		}
	}
}
