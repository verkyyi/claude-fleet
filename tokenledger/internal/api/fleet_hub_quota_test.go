package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

const (
	icloudUUID = "7a7e6173-f07c-490f-844e-00c27c3f0844"
	gmailUUID  = "e58c27f3-22fe-4939-b6ff-f7d9ad65275b"
)

// The quota pass (claude-fleet#2169) opens the two quota routes and nothing
// else, only while the hub reads quota itself, and is keyed apart from the
// refresh pass.
func TestHubQuotaPassCheck(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	pass, err := h.srv.HubQuotaPass()
	if err != nil || !strings.HasPrefix(pass, hubQuotaPassPrefix) {
		t.Fatalf("mint: %q %v", pass, err)
	}
	// Off: refused everywhere.
	if code, _ := relayCheck(t, h, pass, hubQuotaClaudePath); code != http.StatusForbidden {
		t.Fatalf("feature off, quota pass passed: %d", code)
	}
	h.srv.HubQuota = &HubQuota{RelayURL: "https://relay.example"}
	for _, uri := range []string{hubQuotaClaudePath, hubQuotaCodexPath, hubQuotaCodexPath + "?x=1"} {
		if code, who := relayCheck(t, h, pass, uri); code != http.StatusOK || who != "hub" {
			t.Fatalf("quota pass on %q: %d who=%q", uri, code, who)
		}
	}
	for _, uri := range []string{"/anthropic/v1/messages/batches", "/anthropic/v1/complete", "/chatgpt/codex/responses",
		"/openai-auth/oauth/token", "/v1/fleet/settings", ""} {
		if code, _ := relayCheck(t, h, pass, uri); code != http.StatusForbidden {
			t.Fatalf("quota pass on %q: %d, want 403", uri, code)
		}
	}
	// The refresh pass still opens only /openai-auth/.
	rp, _ := h.srv.HubRelayPass()
	if code, _ := relayCheck(t, h, rp, hubQuotaClaudePath); code != http.StatusForbidden {
		t.Fatalf("refresh pass opened the quota route: %d", code)
	}
	i := strings.LastIndexByte(pass, '.')
	for name, forged := range map[string]string{
		"refresh pass relabeled": hubQuotaPassPrefix + rp[len(hubRelayPassPrefix):],
		"bad mac":                pass[:i] + ".AAAA",
		"longer life":            hubQuotaPassPrefix + strconv.FormatInt(time.Now().Add(24*time.Hour).Unix(), 10) + pass[i:],
	} {
		if code, _ := relayCheck(t, h, forged, hubQuotaClaudePath); code != http.StatusForbidden {
			t.Fatalf("%s: %d, want 403", name, code)
		}
	}
	old := hubQuotaPassPrefix + strconv.FormatInt(time.Now().Add(-time.Minute).Unix(), 10)
	old += "." + base64.RawURLEncoding.EncodeToString(h.srv.hubQuotaPassMAC(old))
	if code, _ := relayCheck(t, h, old, hubQuotaClaudePath); code != http.StatusForbidden {
		t.Fatalf("expired: %d", code)
	}
}

// fakeQuotaRelay does what extras/cred-relay/Caddyfile does: forward_auth
// against the hub's real /v1/relay/check, strip the pass, forward
// /anthropic/* to a fake api.anthropic.com and /chatgpt/* to a fake
// chatgpt.com/backend-api.
type fakeQuotaRelay struct {
	srv  *httptest.Server
	mu   sync.Mutex
	auth []string // Authorization headers upstream saw
	acct []string // ChatGPT-Account-Id headers upstream saw
}

func newFakeQuotaRelay(t *testing.T, h *harness) *fakeQuotaRelay {
	f := &fakeQuotaRelay{}
	reset := time.Now().Add(3 * time.Hour).Unix()
	week := time.Now().Add(4 * 24 * time.Hour).Unix()
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chk, _ := http.NewRequest(http.MethodGet, h.http.URL+RelayCheckPath, nil)
		chk.Header.Set(RelayHeader, r.Header.Get(RelayHeader))
		chk.Header.Set("X-Forwarded-Uri", r.URL.RequestURI())
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
		f.mu.Lock()
		f.auth = append(f.auth, r.Header.Get("Authorization"))
		f.acct = append(f.acct, r.Header.Get("ChatGPT-Account-Id"))
		f.mu.Unlock()
		switch {
		case r.URL.Path == "/anthropic/v1/messages":
			w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "0.42")
			w.Header().Set("anthropic-ratelimit-unified-5h-reset", strconv.FormatInt(reset, 10))
			w.Header().Set("anthropic-ratelimit-unified-7d-utilization", "0.17")
			w.Header().Set("anthropic-ratelimit-unified-7d-reset", strconv.FormatInt(week, 10))
			w.Write([]byte(`{}`))
		case r.URL.Path == "/chatgpt/wham/usage":
			writeJSON(w, http.StatusOK, map[string]any{"plan_type": "plus",
				"rate_limit": map[string]any{"allowed": true, "limit_reached": false,
					"primary_window":   map[string]any{"used_percent": 12, "limit_window_seconds": 18000, "reset_at": reset},
					"secondary_window": map[string]any{"used_percent": 34, "limit_window_seconds": 604800, "reset_at": week}},
				"credits": map[string]any{"has_credits": false, "unlimited": false, "balance": "0"}})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func putPool(t *testing.T, h *harness, provider, account string, s credvault.Secret) {
	t.Helper()
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put",
		PrincipalID: store.PoolPrincipal, Provider: provider, Account: account, Secret: s})
	if code != http.StatusOK {
		t.Fatalf("put %s/%s: %d %v", provider, account, code, out)
	}
}

func quotaIDToken(account, user string) string {
	claims, _ := json.Marshal(map[string]any{"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": account, "chatgpt_user_id": user}})
	return "e30." + base64.RawURLEncoding.EncodeToString(claims) + ".IDSIG"
}

// End to end: every pool credential is read through the relay and filed
// under its OWN account; a fresh hub reading wins on the page over a newer
// node reading; a credential that names no account is not written; nothing
// secret reaches a log.
func TestHubQuotaReadsThroughRelay(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	relay := newFakeQuotaRelay(t, h)
	h.srv.HubQuota = &HubQuota{RelayURL: relay.srv.URL}

	var logs bytes.Buffer
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(io.Discard) })

	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "icloud", credvault.Secret{SetupToken: "sk-ant-oat01-ICLOUDSECRET", ExpiresAt: &exp, AccountUUID: icloudUUID})
	putPool(t, h, credvault.Claude, "gmail", credvault.Secret{SetupToken: "sk-ant-oat01-GMAILSECRET", ExpiresAt: &exp})
	putPool(t, h, credvault.Claude, "nobody", credvault.Secret{SetupToken: "sk-ant-oat01-NOBODYSECRET", ExpiresAt: &exp})
	putPool(t, h, credvault.Claude, "paused", credvault.Secret{SetupToken: "sk-ant-oat01-PAUSEDSECRET", ExpiresAt: &exp, AccountUUID: gmailUUID})
	putPool(t, h, credvault.Codex, "verky", credvault.Secret{RefreshToken: "rt-CODEXSECRET", AccountID: "acct-1", IDToken: quotaIDToken("acct-1", "user-1")})
	if err := h.srv.Store.SetFleetSetting(PoolPausedPrefix+"paused", "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	// The gmail label names exactly one account; nobody names none.
	if err := h.srv.Store.UpsertAccount(model.Identity{AccountUUID: gmailUUID, Email: "verky.yi@gmail.com"}, "max", ""); err != nil {
		t.Fatal(err)
	}
	// An older node reading of icloud, the 95% of October 5.
	oct5 := time.Now().Add(-48 * time.Hour)
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: icloudUUID, EndpointID: "ep_node", ObservedAt: oct5,
		FiveHour: model.Window{Utilization: 95}, SevenDay: model.Window{Utilization: 95}}); err != nil {
		t.Fatal(err)
	}
	accountsBefore, _ := h.srv.Store.ListAccounts()

	h.srv.ReadHubQuota(context.Background())

	// The upstream saw each credential's own token, and the codex account id.
	relay.mu.Lock()
	auths, accts := strings.Join(relay.auth, " "), strings.Join(relay.acct, " ")
	relay.mu.Unlock()
	if !strings.Contains(auths, "ICLOUDSECRET") || !strings.Contains(auths, "GMAILSECRET") || strings.Contains(auths, "PAUSEDSECRET") ||
		strings.Contains(auths, "NOBODYSECRET") || !strings.Contains(auths, "codex-access-") || !strings.Contains(accts, "acct-1") {
		t.Fatalf("upstream saw auth=%q acct=%q", auths, accts)
	}

	for _, uuid := range []string{icloudUUID, gmailUUID} {
		v, err := h.srv.LimitsFor(uuid)
		if err != nil {
			t.Fatal(err)
		}
		if !v.Available || v.ReadVia != HubQuotaVia || v.FiveHour.Utilization != 42 || v.SevenDay.Utilization != 17 || v.StaleSeconds > 60 {
			t.Fatalf("%s: %+v", uuid, v)
		}
	}
	// A newer node reading does not displace a fresh hub reading.
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: icloudUUID, EndpointID: "ep_node", ObservedAt: time.Now().Add(time.Second),
		FiveHour: model.Window{Utilization: 95}, SevenDay: model.Window{Utilization: 95}}); err != nil {
		t.Fatal(err)
	}
	if v, _ := h.srv.LimitsFor(icloudUUID); v.ReadVia != HubQuotaVia || v.FiveHour.Utilization != 42 {
		t.Fatalf("node reading displaced the hub's: %+v", v)
	}

	// Codex: filed under the id_token's account, read via the hub.
	cu := codex.AccountUUID("acct-1", "user-1")
	v, err := h.srv.LimitsFor(cu)
	if err != nil {
		t.Fatal(err)
	}
	if v.Source != model.SourceCodex || v.ReadVia != HubQuotaVia || len(v.Windows) != 2 || v.Windows[0].Utilization != 12 || v.Plan != "plus" {
		t.Fatalf("codex view: %+v", v)
	}

	// "nobody" names no account: not written, no win_ minted, the reason kept.
	accountsAfter, _ := h.srv.Store.ListAccounts()
	// +2: icloud's and the Codex account's own rows — known identities, not
	// guesses — and nothing for "nobody".
	if len(accountsAfter) != len(accountsBefore)+2 {
		t.Fatalf("accounts %d → %d", len(accountsBefore), len(accountsAfter))
	}
	for _, a := range accountsAfter {
		if strings.HasPrefix(a.AccountUUID, "win_") {
			t.Fatalf("a fingerprint account was minted: %s", a.AccountUUID)
		}
	}
	var nobody *HubQuotaRead
	for _, r := range h.srv.HubQuota.Reads() {
		if r.Account == "nobody" {
			r := r
			nobody = &r
		}
		if r.Account == "paused" {
			t.Fatal("a paused account was read")
		}
	}
	if nobody == nil || nobody.OK || !strings.Contains(nobody.Error, "not written") {
		t.Fatalf("nobody: %+v", nobody)
	}
	if out := logs.String(); strings.Contains(out, "SECRET") || strings.Contains(out, "codex-access-") || strings.Contains(out, "frq1.") {
		t.Fatalf("a secret reached the log: %s", out)
	}
}

// The relay down: the page falls back to the node's reading and says why.
func TestHubQuotaRelayDownFallsBackToNode(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	h.srv.HubQuota = &HubQuota{RelayURL: dead.URL}
	log.SetOutput(io.Discard)
	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "icloud", credvault.Secret{SetupToken: "sk-ant-oat01-X", ExpiresAt: &exp, AccountUUID: icloudUUID})
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: icloudUUID, EndpointID: "ep_node", ObservedAt: time.Now().Add(-time.Minute),
		FiveHour: model.Window{Utilization: 30}, SevenDay: model.Window{Utilization: 20}}); err != nil {
		t.Fatal(err)
	}
	h.srv.ReadHubQuota(context.Background())
	v, err := h.srv.LimitsFor(icloudUUID)
	if err != nil {
		t.Fatal(err)
	}
	if !v.Available || v.ReadVia != NodeQuotaVia || v.FiveHour.Utilization != 30 || !strings.Contains(v.ReadNote, "hub reading failed") {
		t.Fatalf("fallback: %+v", v)
	}
	// And a stale hub reading yields to the node's too.
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: icloudUUID, EndpointID: HubQuotaEndpoint, ObservedAt: time.Now().Add(-time.Hour),
		FiveHour: model.Window{Utilization: 1}}); err != nil {
		t.Fatal(err)
	}
	if v, _ := h.srv.LimitsFor(icloudUUID); v.ReadVia != NodeQuotaVia || v.FiveHour.Utilization != 30 {
		t.Fatalf("stale hub reading shown: %+v", v)
	}
}

// Off (no CCQUOTA_FLEET_HUB_QUOTA): nothing is read, no read_via / read_note
// appears, and the newest reading is shown — byte for byte as before.
func TestHubQuotaOffChangesNothing(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	done := make(chan struct{})
	go func() { h.srv.RunHubQuota(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunHubQuota ran with the feature off")
	}
	h.srv.ReadHubQuota(context.Background())
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: icloudUUID, EndpointID: "ep_node", ObservedAt: time.Now().Add(-time.Minute),
		FiveHour: model.Window{Utilization: 30}}); err != nil {
		t.Fatal(err)
	}
	// Even a hub-endpoint row is just the newest row when the feature is off.
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: icloudUUID, EndpointID: HubQuotaEndpoint, ObservedAt: time.Now().Add(-2 * time.Minute),
		FiveHour: model.Window{Utilization: 1}}); err != nil {
		t.Fatal(err)
	}
	v, err := h.srv.LimitsFor(icloudUUID)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(v)
	if v.FiveHour.Utilization != 30 || strings.Contains(string(b), "read_via") || strings.Contains(string(b), "read_note") {
		t.Fatalf("off: %s", b)
	}
	pass, _ := h.srv.HubQuotaPass()
	if code, _ := relayCheck(t, h, pass, hubQuotaClaudePath); code != http.StatusForbidden {
		t.Fatalf("off: quota pass accepted: %d", code)
	}
}

// bind records an existing credential's account without its secret.
func TestCredentialBindAccountUUID(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "icloud", credvault.Secret{SetupToken: "sk-ant-oat01-KEEPME", ExpiresAt: &exp})
	before, _ := h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "icloud")

	bind := func(provider, account, uuid string) int {
		code, _ := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "bind", PrincipalID: store.PoolPrincipal,
			Provider: provider, Account: account, AccountUUID: uuid})
		return code
	}
	for _, bad := range []string{"", "win_abc", "not a uuid", "codex:account:00000000000000000000000000000000"} {
		if code := bind(credvault.Claude, "icloud", bad); code != http.StatusBadRequest {
			t.Fatalf("bind %q: %d, want 400", bad, code)
		}
	}
	if code := bind(credvault.Claude, "nosuch", icloudUUID); code != http.StatusNotFound {
		t.Fatalf("bind of a missing credential: %d", code)
	}
	if code := bind(credvault.GitHub, "icloud", icloudUUID); code != http.StatusBadRequest {
		t.Fatalf("bind on github: %d", code)
	}
	if code := bind(credvault.Claude, "icloud", icloudUUID); code != http.StatusOK {
		t.Fatalf("bind: %d", code)
	}
	after, _ := h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "icloud")
	if got := h.srv.Vault.AccountUUID(*after); got != icloudUUID {
		t.Fatalf("account_uuid after bind = %q", got)
	}
	if after.Version != before.Version {
		t.Fatalf("bind bumped the version %d → %d", before.Version, after.Version)
	}
	acc, err := h.srv.Vault.Lease(context.Background(), store.PoolPrincipal, credvault.Claude, "icloud")
	if err != nil || acc.AccessToken != "sk-ant-oat01-KEEPME" {
		t.Fatalf("token after bind: %v", err)
	}
	audit, _ := h.srv.Store.CredAuditLog(store.PoolPrincipal, 10)
	found := false
	for _, a := range audit {
		if strings.Contains(a.Detail, "KEEPME") {
			t.Fatalf("a secret in the audit: %+v", a)
		}
		if a.Action == store.CredBind && strings.Contains(a.Detail, icloudUUID) && strings.Contains(a.Detail, "by ") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no bind audit row: %+v", audit)
	}
}

// A collector that keeps failing does not keep the Codex quota lease, and
// another online collector takes the account over (claude-fleet#2169).
func TestQuotaLeaseNotRenewedToFailingCollector(t *testing.T) {
	s := &Server{}
	const acct = "codex:account:aaaa"
	now := time.Now()
	if !s.quotaLeaseGrant(acct, "ep_a/p", 300, 0, now) {
		t.Fatal("first grant")
	}
	if s.quotaLeaseGrant(acct, "ep_b/p", 300, 0, now) {
		t.Fatal("a second collector took a held lease")
	}
	// A working holder keeps it.
	s.quotaLeaseDelivered(acct, "ep_a", now.Add(4*time.Minute))
	if !s.quotaLeaseGrant(acct, "ep_a/p", 300, 0, now.Add(5*time.Minute)) {
		t.Fatal("a working holder lost its lease")
	}
	// It reports three failures in a row: dropped, benched, b takes over.
	if s.quotaLeaseGrant(acct, "ep_a/p", 300, 3, now.Add(9*time.Minute)) {
		t.Fatal("a failing holder was renewed")
	}
	if !s.quotaLeaseGrant(acct, "ep_b/p", 300, 0, now.Add(9*time.Minute)) {
		t.Fatal("another collector could not take the account over")
	}
	if s.quotaLeaseGrant(acct, "ep_a/p", 300, 3, now.Add(30*time.Minute)) {
		t.Fatal("a benched collector got the lease back")
	}

	// An older agent cannot report failures: delivering nothing for the
	// fail window loses the lease all the same.
	const acct2 = "codex:account:bbbb"
	// An agent polling every 5m asks for 450s and renews every ~5m.
	for _, m := range []time.Duration{0, 5, 10} {
		if !s.quotaLeaseGrant(acct2, "ep_c/p", 450, 0, now.Add(m*time.Minute)) {
			t.Fatalf("renewal at +%dm within the window", m)
		}
	}
	late := now.Add(15*time.Minute + 30*time.Second)
	if s.quotaLeaseGrant(acct2, "ep_c/p", 450, 0, late) {
		t.Fatal("a holder that delivered nothing for 15m30s was renewed")
	}
	if !s.quotaLeaseGrant(acct2, "ep_d/p", 450, 0, late) {
		t.Fatal("d could not take over")
	}
	// After its bench a collector may try again (it may be the only one).
	if !s.quotaLeaseGrant("codex:account:cccc", "ep_c/p", 300, 5, late) {
		t.Fatal("a failure count alone refused a fresh lease")
	}
	if !s.quotaLeaseGrant(acct2, "ep_c/p", 300, 0, late.Add(quotaLeaseBench+time.Minute)) {
		t.Fatal("bench never ended") // d's lease (7.5m) has lapsed by then
	}
}
