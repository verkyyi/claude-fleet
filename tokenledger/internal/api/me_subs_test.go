package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

const aliceSubUUID = "8e3f0c2a-4444-4d5e-8f60-3456789abcde"

// fakeExchange is the provider's token endpoint for a sign-in: it keeps every
// form and answers Claude with a refresh token + account, Codex with an
// id_token naming a workspace.
type fakeExchange struct {
	mu    sync.Mutex
	forms []map[string]string
	encs  []string
	fail  bool
}

func (f *fakeExchange) fn(_ context.Context, provider string, form map[string]string, enc string) (int, []byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.forms, f.encs = append(f.forms, form), append(f.encs, enc)
	if f.fail {
		return http.StatusBadRequest, []byte(`{"error":"invalid_grant"}`), nil
	}
	if provider == "claude" {
		return 200, []byte(`{"access_token":"at","refresh_token":"rt-claude","expires_in":28800,"scope":"user:inference user:profile","account":{"uuid":"` + aliceSubUUID + `"}}`), nil
	}
	claims, _ := json.Marshal(map[string]any{"https://api.openai.com/auth": map[string]any{
		"chatgpt_account_id": "ws-1", "chatgpt_user_id": "user-1", "chatgpt_plan_type": "plus"}})
	idt := "h." + base64.RawURLEncoding.EncodeToString(claims) + ".s"
	return 200, []byte(`{"access_token":"at","refresh_token":"rt-codex","id_token":"` + idt + `"}`), nil
}

func meSubsCall(t *testing.T, h *harness, who, path string, body any) (int, map[string]any) {
	t.Helper()
	var b []byte
	method := http.MethodGet
	if body != nil {
		b, _ = json.Marshal(body)
		method = http.MethodPost
	}
	code, raw := asPerson(t, h, method, path, who, b)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return code, out
}

// meSubsConnect runs one sign-in for who and returns the finish answer.
func meSubsConnect(t *testing.T, h *harness, who, provider, account string, paste func(state string) string) (int, map[string]any) {
	t.Helper()
	code, start := meSubsCall(t, h, who, MeSubsLoginPath, map[string]any{"provider": provider, "account": account})
	if code != 200 {
		t.Fatalf("%s login %s/%s: HTTP %d %v", who, provider, account, code, start)
	}
	u, err := url.Parse(start["authorize_url"].(string))
	if err != nil {
		t.Fatal(err)
	}
	return meSubsCall(t, h, who, MeSubsFinishPath, map[string]any{"flow": start["flow"], "paste": paste(u.Query().Get("state"))})
}

// 我自己的订阅 (claude-fleet#4035): alice connects her own Claude in her own
// browser (the hub only mints the PKCE sign-in and exchanges the pasted code),
// it is stored under her, joins her strict-mode allowlist and her machine's,
// and her node leases it; bob sees none of it — not in his list, and every
// write that names it answers 404 exactly as for a name nobody has; her flow
// does not finish for him. She pauses it (the lease says paused), and
// disconnecting takes it out of the vault and the lists again.
func TestMeSubs_ConnectOwnOnlyAndScoped(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	enablePeople(t, h, pAlice, pBob)
	credsepBeat(t, h, tok, "alice", control.CredsepSeparated) // a member's login leases only once separated
	ex := &fakeExchange{}
	h.srv.OAuthExchange = ex.fn
	now := time.Now()
	// strict, mac-c's list naming some other subscription, alice with none
	for k, v := range map[string]string{CredPolicyModeKey: "strict", credNodeKey("mac-c"): `["11111111-2222-4333-8444-555555555555"]`} {
		if err := h.srv.Store.SetFleetSetting(k, v, now); err != nil {
			t.Fatal(err)
		}
	}

	if code, out := meSubsCall(t, h, pAlice, MeSubsPath, nil); code != 200 || len(out["subscriptions"].([]any)) != 0 || out["login"] != true {
		t.Fatalf("empty list: HTTP %d %v", code, out)
	}
	// the sign-in page is the provider's own, with a PKCE challenge
	code, start := meSubsCall(t, h, pAlice, MeSubsLoginPath, map[string]any{"provider": "claude", "account": "my-max"})
	au, _ := url.Parse(start["authorize_url"].(string))
	if code != 200 || au.Host != "claude.ai" || au.Query().Get("code_challenge_method") != "S256" || au.Query().Get("code_challenge") == "" ||
		start["paste"] != "code" {
		t.Fatalf("login: HTTP %d %v", code, start)
	}
	// a code from another sign-in (its state differs) is refused before any exchange
	if code, out := meSubsCall(t, h, pAlice, MeSubsFinishPath, map[string]any{"flow": start["flow"], "paste": "c1#other-state"}); code != http.StatusUnprocessableEntity || len(ex.forms) != 0 {
		t.Fatalf("wrong state: HTTP %d %v (exchanges %d)", code, out, len(ex.forms))
	}
	// bob cannot finish alice's sign-in
	if code, _ := meSubsCall(t, h, pBob, MeSubsFinishPath, map[string]any{"flow": start["flow"], "paste": "c1#" + au.Query().Get("state")}); code != http.StatusGone {
		t.Fatalf("bob finishing alice's flow: HTTP %d, want 410", code)
	}
	code, row := meSubsCall(t, h, pAlice, MeSubsFinishPath, map[string]any{"flow": start["flow"], "paste": "c1#" + au.Query().Get("state")})
	if code != 200 || row["account"] != "my-max" || row["account_uuid"] != aliceSubUUID {
		t.Fatalf("finish: HTTP %d %v", code, row)
	}
	f := ex.forms[0]
	if f["grant_type"] != "authorization_code" || f["code"] != "c1" || f["code_verifier"] == "" || f["client_id"] == "" || ex.encs[0] != "" {
		t.Fatalf("exchange form = %v enc %q", f, ex.encs[0])
	}
	if c, err := h.srv.Store.Credential(pAlice, "claude", "my-max"); err != nil || c.PrincipalID != pAlice {
		t.Fatalf("stored row: %+v %v", c, err)
	}
	settings, _ := h.srv.Store.FleetSettings()
	if !strings.Contains(settings[credUserKey(pAlice)], aliceSubUUID) || !strings.Contains(settings[credNodeKey("mac-c")], aliceSubUUID) ||
		strings.Contains(settings[credUserKey(pBob)], aliceSubUUID) {
		t.Fatalf("allowlists after connect: %v", settings)
	}
	if code, _ := meSubsCall(t, h, pAlice, MeSubsLoginPath, map[string]any{"provider": "claude", "account": "my-max"}); code != http.StatusConflict {
		t.Fatalf("a second my-max: HTTP %d, want 409", code)
	}

	// alice's node leases it, not paused
	findLease := func() *NodeCredential {
		code, resp, refusal := lease(t, h, tok)
		if code != 200 {
			t.Fatalf("lease: HTTP %d %v", code, refusal)
		}
		for i := range resp.Credentials {
			if resp.Credentials[i].Account == "my-max" {
				return &resp.Credentials[i]
			}
		}
		return nil
	}
	if nc := findLease(); nc == nil || nc.Pool || nc.Paused {
		t.Fatalf("alice's lease: %+v", nc)
	}

	// bob: nothing listed; pause / delete of it, and of a name nobody has, are the same 404
	if code, out := meSubsCall(t, h, pBob, MeSubsPath, nil); code != 200 || len(out["subscriptions"].([]any)) != 0 {
		t.Fatalf("bob's list: HTTP %d %v", code, out)
	}
	for _, target := range []map[string]any{{"provider": "claude", "account": "my-max"}, {"provider": "claude", "account": "nobody-has"}} {
		for _, path := range []string{MeSubsPausePath, MeSubsDeletePath} {
			body := map[string]any{"paused": true}
			for k, v := range target {
				body[k] = v
			}
			code, out := meSubsCall(t, h, pBob, path, body)
			if code != http.StatusNotFound || out["error"] == nil {
				t.Fatalf("bob %s %v: HTTP %d %v, want 404", path, target, code, out)
			}
		}
	}
	if _, err := h.srv.Store.Credential(pAlice, "claude", "my-max"); err != nil {
		t.Fatalf("bob's delete reached alice's row: %v", err)
	}
	if s, _ := h.srv.Store.FleetSettings(); s[ownPausedKey(pAlice, "claude", "my-max")] != "" {
		t.Fatal("bob's pause reached alice's row")
	}

	// alice pauses: listed paused, leased flagged paused; resume clears it
	if code, out := meSubsCall(t, h, pAlice, MeSubsPausePath, map[string]any{"provider": "claude", "account": "my-max", "paused": true}); code != 200 || out["state"] != "paused" {
		t.Fatalf("pause: HTTP %d %v", code, out)
	}
	if nc := findLease(); nc == nil || !nc.Paused {
		t.Fatalf("paused lease: %+v", nc)
	}
	if choices, err := h.srv.sessionBindChoices(pAlice, "", "claude"); err != nil || len(choices) != 0 {
		t.Fatalf("central proxy choices while paused: %v %v", choices, err)
	}
	if code, out := meSubsCall(t, h, pAlice, MeSubsPausePath, map[string]any{"provider": "claude", "account": "my-max", "paused": false}); code != 200 || out["paused"] != false {
		t.Fatalf("resume: HTTP %d %v", code, out)
	}

	// an admin sees it on the vault's list, as alice's
	_, raw := h.get(t, "/v1/fleet/credentials")
	if !strings.Contains(string(raw), `"principal_id":"`+pAlice+`","provider":"claude","account":"my-max"`) {
		t.Fatalf("admin credential list lacks alice's row: %s", raw)
	}

	// every action is audited under her
	audit, _ := h.srv.Store.CredAuditLog(pAlice, 50)
	var put bool
	for _, a := range audit {
		put = put || a.Action == store.CredPut && strings.Contains(a.Detail, "own · signed in in the browser")
	}
	if !put {
		t.Fatalf("no own put in the audit: %+v", audit)
	}

	// disconnect: gone from the vault, the lease and both lists
	if code, out := meSubsCall(t, h, pAlice, MeSubsDeletePath, map[string]any{"provider": "claude", "account": "my-max"}); code != 200 {
		t.Fatalf("delete: HTTP %d %v", code, out)
	}
	if _, err := h.srv.Store.Credential(pAlice, "claude", "my-max"); err == nil {
		t.Fatal("row survived the disconnect")
	}
	settings, _ = h.srv.Store.FleetSettings()
	if strings.Contains(settings[credUserKey(pAlice)], aliceSubUUID) || strings.Contains(settings[credNodeKey("mac-c")], aliceSubUUID) {
		t.Fatalf("allowlists after disconnect: %v", settings)
	}
}

// ChatGPT's sign-in: the pasted redirect address carries the code; the
// exchange goes urlencoded (control.OAuthEncodingForm) and the stored row
// takes its workspace from the id_token. A refused code is a 422, nothing stored.
func TestMeSubs_CodexPasteURLAndRefusal(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	enablePeople(t, h, pAlice)
	ex := &fakeExchange{}
	h.srv.OAuthExchange = ex.fn
	code, row := meSubsConnect(t, h, pAlice, "codex", "my-gpt", func(st string) string {
		return "http://localhost:1455/auth/callback?code=c-codex&scope=openid&state=" + st
	})
	if code != 200 || row["provider"] != "codex" || !strings.HasPrefix(row["account_uuid"].(string), "codex:account:") {
		t.Fatalf("codex finish: HTTP %d %v", code, row)
	}
	if ex.forms[0]["code"] != "c-codex" || ex.encs[0] != control.OAuthEncodingForm || ex.forms[0]["redirect_uri"] != codexRedirect {
		t.Fatalf("codex exchange = %v enc %q", ex.forms[0], ex.encs[0])
	}
	ex.fail = true
	if code, out := meSubsConnect(t, h, pAlice, "claude", "refused", func(st string) string { return "bad#" + st }); code != http.StatusUnprocessableEntity ||
		!strings.Contains(out["error"].(string), "invalid_grant") {
		t.Fatalf("refused code: HTTP %d %v", code, out)
	}
	if _, err := h.srv.Store.Credential(pAlice, "claude", "refused"); err == nil {
		t.Fatal("a refused sign-in was stored")
	}
	// no exchange configured: the hub says so instead of minting a sign-in
	h.srv.OAuthExchange = nil
	if code, _ := meSubsCall(t, h, pAlice, MeSubsLoginPath, map[string]any{"provider": "claude", "account": "x"}); code != http.StatusServiceUnavailable {
		t.Fatalf("no exchange: HTTP %d, want 503", code)
	}
}
