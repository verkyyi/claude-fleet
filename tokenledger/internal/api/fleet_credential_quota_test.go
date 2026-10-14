package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// BREAK-IT credential-quota-unbound: a valid setup token needs no profile scope.
func TestCredentialQuotaUnbound(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = []byte("test-quota-pass-key")
	relay := newFakeQuotaRelay(t, h)
	h.srv.HubQuota = &HubQuota{RelayURL: relay.srv.URL}
	exp := time.Now().Add(24 * time.Hour)
	putPool(t, h, credvault.Claude, "unbound", credvault.Secret{SetupToken: "sk-ant-oat01-fixture-unbound", ExpiresAt: &exp})
	c, _ := h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "unbound")
	r := h.srv.readHubQuotaOne(context.Background(), *c)
	if !r.OK {
		t.Fatalf("valid unbound credential was not measured: %s", r.Error)
	}
}

// Same labels and identical resets never establish identity. This exercises the
// real periodic round, vault API, persistent readings, policy and picker.
func TestCredentialQuotaIsolation(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = []byte("fixture-key")
	var fraction atomic.Int64
	fraction.Store(4)
	var failed atomic.Bool
	var calls atomic.Int64
	reset := time.Now().Add(time.Hour)
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if failed.Load() {
			w.WriteHeader(503)
			return
		}
		n := fraction.Load()
		if strings.Contains(r.Header.Get("Authorization"), "fixture-b") {
			n = 100
		}
		w.Header().Set("anthropic-ratelimit-unified-5h-utilization", fmt.Sprintf("%.2f", float64(n)/100))
		w.Header().Set("anthropic-ratelimit-unified-7d-utilization", "0.01")
		w.Header().Set("anthropic-ratelimit-unified-5h-reset", strconv.FormatInt(reset.Unix(), 10))
		w.Header().Set("anthropic-ratelimit-unified-7d-reset", strconv.FormatInt(reset.Unix(), 10))
		w.Write([]byte(`{}`))
	}))
	defer relay.Close()
	h.srv.HubQuota = &HubQuota{RelayURL: relay.URL}
	exp := time.Now().Add(24 * time.Hour)
	put := func(owner, name, token, uuid string) store.Credential {
		t.Helper()
		if err := h.srv.Vault.Put(owner, credvault.Claude, name, credvault.Secret{SetupToken: token, ExpiresAt: &exp, AccountUUID: uuid}); err != nil {
			t.Fatal(err)
		}
		c, err := h.srv.Store.Credential(owner, credvault.Claude, name)
		if err != nil || c == nil {
			t.Fatal("missing credential", err)
		}
		return *c
	}
	a := put(store.PoolPrincipal, "same", "sk-ant-oat01-fixture-a", "")
	alias := put(store.PoolPrincipal, "alias", "sk-ant-oat01-fixture-a", "")
	b := put(store.PoolPrincipal, "second", "sk-ant-oat01-fixture-b", "")
	own := put(pAlice, "same", "sk-ant-oat01-fixture-a", "")
	bound := put(store.PoolPrincipal, "bound", "sk-ant-oat01-fixture-bound", icloudUUID)
	id := h.srv.Vault.CredentialID
	if id(a) != id(alias) || id(a) == id(b) || id(a) == id(own) {
		t.Fatal("identity collision or alias split")
	}
	// A pre-existing account with the SAME label and resets is unrelated.
	if err := h.srv.Store.UpsertAccount(model.Identity{AccountUUID: gmailUUID, DisplayName: "same"}, "", ""); err != nil {
		t.Fatal(err)
	}
	h.srv.ReadHubQuota(context.Background())
	if calls.Load() != 4 {
		t.Fatalf("round probed %d credentials, want 4 unique identities", calls.Load())
	}
	for _, c := range []store.Credential{a, alias, b, own, bound} {
		v, err := h.srv.credentialLimits(c)
		want := float64(4)
		if c.Account == b.Account {
			want = 100
		}
		if err != nil || !v.Available || v.FiveHour.Utilization != want || v.SevenDay.Utilization != 1 || v.ReadStatus != "ok" || v.ObservedAt == nil || v.FiveHour.ResetsAt == nil {
			t.Fatalf("%s reading: %+v %v", c.Account, v, err)
		}
	}
	if s, _ := h.srv.Store.LatestLimits(gmailUUID); s != nil {
		t.Fatal("label collision contaminated existing account")
	}
	if v, _ := h.srv.LimitsFor(icloudUUID); !v.Available {
		t.Fatal("verified legacy account lost its reading")
	}
	if h.srv.credAtLimit(a, time.Now()) != "" || h.srv.credAtLimit(b, time.Now()) != "5h" {
		t.Fatal("picker did not use credential readings")
	}
	choices := h.srv.dedupCredentials([]store.Credential{a, alias, b, own})
	if len(choices) != 3 || h.srv.byHeadroom(choices, time.Now())[2].Account != b.Account {
		t.Fatal("aliases inflated capacity or picker ignored limits")
	}
	p := credPolicy{User: credAllow{Set: true, IDs: map[string]bool{id(a): true}}}
	if _, why := h.srv.credVerdict(a, p); why != "" {
		t.Fatal(why)
	}
	if _, why := h.srv.credVerdict(b, p); why == "" {
		t.Fatal("policy crossed identities")
	}
	// Restarting the reader does not erase a failed attempt or the last good value.
	failed.Store(true)
	h.srv.ReadHubQuota(context.Background())
	h.srv.HubQuota = &HubQuota{RelayURL: relay.URL}
	v, err := h.srv.credentialLimits(a)
	if err != nil || v.ReadStatus != "failed" || !v.Available || v.ReadAttemptAt == nil || v.ReadNote == "" {
		t.Fatalf("failure not persisted: %+v %v", v, err)
	}
	failed.Store(false)
	fraction.Store(8)
	h.srv.ReadHubQuota(context.Background())
	v, _ = h.srv.credentialLimits(a)
	if v.FiveHour.Utilization != 8 || v.ReadStatus != "ok" {
		t.Fatalf("later round did not update: %+v", v)
	}
	h.srv.limits.mark(a.Provider, a.PrincipalID, id(a), time.Now().Add(time.Hour))
	if h.srv.credAtLimit(alias, time.Now()) != "429" {
		t.Fatal("alias escaped 429")
	}
	replaced := put(store.PoolPrincipal, "same", "sk-ant-oat01-fixture-replacement", "")
	v, _ = h.srv.credentialLimits(replaced)
	if id(replaced) == id(a) || v.Available || v.ReadStatus != "unknown" || h.srv.credAtLimit(replaced, time.Now()) != "" {
		t.Fatalf("replacement inherited old reading or scheduler state: %+v", v)
	}
	if old, _ := h.srv.Store.LatestLimits(id(a)); old == nil || old.FiveHour.Utilization != 8 {
		t.Fatal("replacement erased old identity's history")
	}
	var response struct {
		Credentials []struct {
			store.Credential
			ID     string      `json:"credential_id"`
			UUID   string      `json:"account_uuid"`
			Limits *LimitsView `json:"limits"`
		} `json:"credentials"`
	}
	h.getJSON(t, "/v1/fleet/credentials", &response)
	found := false
	for _, row := range response.Credentials {
		if row.PrincipalID == store.PoolPrincipal && row.Account == "same" {
			found = true
			if row.ID != id(replaced) || row.UUID != "" || row.Limits.Available {
				t.Fatalf("wire join carries stale identity: %+v", row)
			}
		}
	}
	if !found {
		t.Fatal("new credential absent from subscription API")
	}
	raw, _ := json.Marshal(response)
	if strings.Contains(string(raw), "sk-ant-oat01-") || strings.Contains(string(raw), "meter_id") {
		t.Fatal("secret leaked in metadata")
	}
}
