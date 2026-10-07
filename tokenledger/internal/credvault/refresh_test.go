package credvault

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ProxyRefresher reads a relayed answer exactly as HTTPRefresher reads a direct
// one, and turns "could not ask" into ErrRefreshUnavailable — never a
// provider's refusal.
func TestProxyRefresherParsesAndClassifies(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	s := Secret{RefreshToken: "rt-0", AccountID: "acct"}

	ok := &ProxyRefresher{Now: func() time.Time { return now }, Via: func(_ context.Context, provider string, form map[string]string) (ProxyAnswer, error) {
		if provider != Codex || form["refresh_token"] != "rt-0" || form["client_id"] != CodexClientID || form["grant_type"] != "refresh_token" {
			t.Fatalf("form = %v", form)
		}
		return ProxyAnswer{Status: 200, Via: "op@m5", Body: []byte(`{"access_token":"at-1","refresh_token":"rt-1","id_token":"id-1","expires_in":3600}`)}, nil
	}}
	acc, next, via, err := ok.RefreshVia(context.Background(), Codex, s)
	if err != nil || via != "op@m5" || acc.AccessToken != "at-1" || acc.IDToken != "id-1" || acc.AccountID != "acct" ||
		next.RefreshToken != "rt-1" || next.IDToken != "id-1" || acc.ExpiresAt == nil || !acc.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("ok: %+v %+v %q %v", acc, next, via, err)
	}

	down := &ProxyRefresher{Via: func(context.Context, string, map[string]string) (ProxyAnswer, error) {
		return ProxyAnswer{}, errors.New("no admin node is online")
	}}
	if _, next, _, err := down.RefreshVia(context.Background(), Codex, s); !errors.Is(err, ErrRefreshUnavailable) || next.RefreshToken != "rt-0" {
		t.Fatalf("down: %v %+v", err, next)
	}

	refused := &ProxyRefresher{Via: func(context.Context, string, map[string]string) (ProxyAnswer, error) {
		return ProxyAnswer{Status: 403, Via: "op@m4", Body: []byte(`{"error":{"code":"unsupported_country_region_territory"}}`)}, nil
	}}
	_, next, via, err = refused.RefreshVia(context.Background(), Codex, s)
	if err == nil || errors.Is(err, ErrRefreshUnavailable) || via != "op@m4" || next.RefreshToken != "rt-0" {
		t.Fatalf("refused: %v %q %+v", err, via, next)
	}

	// Through the vault: the audit row names the node.
	v := newVault(t, ok)
	if err := v.Put("pool", Codex, "default", s); err != nil {
		t.Fatal(err)
	}
	v.Now = func() time.Time { return now }
	if _, err := v.Lease(context.Background(), "pool", Codex, "default"); err != nil {
		t.Fatal(err)
	}
	rows, _ := v.Store.CredAuditLog("pool", 10)
	found := false
	for _, r := range rows {
		if r.Action == "refresh" && r.Detail == "ok · refresh_via=op@m5" {
			found = true
		}
	}
	if !found {
		t.Fatalf("audit = %+v", rows)
	}
	if _, _, err := (&ProxyRefresher{}).Refresh(context.Background(), GitHub, Secret{Token: "x"}); err == nil {
		t.Fatal("github has no refresh")
	}
}

// RelayRefresher (claude-fleet#1976): a Codex refresh goes to the relay's
// /openai-auth/oauth/token with the hub's pass; a relay that cannot be asked
// falls back to the node path; a provider's refusal never does.
func TestRelayRefresher(t *testing.T) {
	now := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	s := Secret{RefreshToken: "rt-0", AccountID: "acct"}
	var answer func(w http.ResponseWriter)
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var f map[string]string
		_ = json.NewDecoder(r.Body).Decode(&f)
		if r.Method != http.MethodPost || r.URL.Path != RelayTokenPath || r.Header.Get(RelayPassHeader) != "frh1.pass" ||
			r.Header.Get("Content-Type") != "application/json" || f["refresh_token"] != "rt-0" || f["client_id"] != CodexClientID {
			t.Errorf("relay got %s %s pass=%q form=%v", r.Method, r.URL.Path, r.Header.Get(RelayPassHeader), f)
		}
		answer(w)
	}))
	defer relay.Close()
	nodeRuns := 0
	node := &ProxyRefresher{Now: func() time.Time { return now }, Via: func(context.Context, string, map[string]string) (ProxyAnswer, error) {
		nodeRuns++
		return ProxyAnswer{Status: 200, Via: "op@m5", Body: []byte(`{"access_token":"at-node","refresh_token":"rt-node","expires_in":3600}`)}, nil
	}}
	r := &RelayRefresher{URL: relay.URL + "/", Pass: func() (string, error) { return "frh1.pass", nil }, Fallback: node,
		Now: func() time.Time { return now }}

	answer = func(w http.ResponseWriter) {
		io.WriteString(w, `{"access_token":"at-1","refresh_token":"rt-1","id_token":"id-1","expires_in":3600}`)
	}
	acc, next, via, err := r.RefreshVia(context.Background(), Codex, s)
	if err != nil || via != RelayVia || acc.AccessToken != "at-1" || next.RefreshToken != "rt-1" || nodeRuns != 0 {
		t.Fatalf("relay up: %+v %+v %q %v node=%d", acc, next, via, err, nodeRuns)
	}

	// The provider refuses: that is the answer — no fallback, token kept.
	answer = func(w http.ResponseWriter) {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, `{"error":"invalid_grant"}`)
	}
	if _, next, via, err := r.RefreshVia(context.Background(), Codex, s); err == nil || errors.Is(err, ErrRefreshUnavailable) ||
		via != RelayVia || next.RefreshToken != "rt-0" || nodeRuns != 0 {
		t.Fatalf("provider refusal: %v %q %+v node=%d", err, via, next, nodeRuns)
	}
	answer = func(w http.ResponseWriter) {
		w.WriteHeader(http.StatusForbidden)
		io.WriteString(w, `{"error":{"code":"unsupported_country_region_territory"}}`)
	}
	if _, _, via, err := r.RefreshVia(context.Background(), Codex, s); err == nil || via != RelayVia || nodeRuns != 0 {
		t.Fatalf("provider 403: %v %q node=%d", err, via, nodeRuns)
	}

	// The relay itself cannot carry it: each falls back, and says why.
	for name, a := range map[string]func(w http.ResponseWriter){
		"pass refused": func(w http.ResponseWriter) {
			w.WriteHeader(http.StatusForbidden)
			io.WriteString(w, `{"error":"relay_refused","message":"hub pass refused: expired"}`)
		},
		"gateway":  func(w http.ResponseWriter) { w.WriteHeader(http.StatusBadGateway) },
		"no route": func(w http.ResponseWriter) { w.WriteHeader(http.StatusNotFound) },
	} {
		answer = a
		before := nodeRuns
		acc, next, via, err := r.RefreshVia(context.Background(), Codex, s)
		if err != nil || nodeRuns != before+1 || acc.AccessToken != "at-node" || next.RefreshToken != "rt-node" ||
			!strings.HasPrefix(via, "op@m5 (relay unavailable: ") {
			t.Fatalf("%s: %+v %q %v", name, acc, via, err)
		}
	}
	// Unreachable relay.
	down := httptest.NewServer(http.NotFoundHandler())
	down.Close()
	rd := &RelayRefresher{URL: down.URL, Pass: r.Pass, Fallback: node, Now: r.Now}
	if acc, _, via, err := rd.RefreshVia(context.Background(), Codex, s); err != nil || acc.AccessToken != "at-node" || !strings.Contains(via, "relay unavailable") {
		t.Fatalf("unreachable: %+v %q %v", acc, via, err)
	}
	// No pass to sign: never posts, falls back.
	rp := &RelayRefresher{URL: relay.URL, Pass: func() (string, error) { return "", errors.New("no key") }, Fallback: node, Now: r.Now}
	if _, _, via, err := rp.RefreshVia(context.Background(), Codex, s); err != nil || !strings.Contains(via, "relay pass: no key") {
		t.Fatalf("no pass: %q %v", via, err)
	}
	// No fallback wired: a relay outage is refresh_unavailable, named relay.
	rn := &RelayRefresher{URL: down.URL, Pass: r.Pass}
	if _, next, via, err := rn.RefreshVia(context.Background(), Codex, s); !errors.Is(err, ErrRefreshUnavailable) || via != RelayVia || next.RefreshToken != "rt-0" {
		t.Fatalf("no fallback: %v %q", err, via)
	}

	// Claude keeps the node path: the relay route is OpenAI's only.
	before := nodeRuns
	if _, _, via, err := r.RefreshVia(context.Background(), Claude, Secret{RefreshToken: "c-rt"}); err != nil || via != "op@m5" || nodeRuns != before+1 {
		t.Fatalf("claude: %q %v", via, err)
	}

	// Through the vault: the audit row says refresh_via=relay.
	answer = func(w http.ResponseWriter) {
		io.WriteString(w, `{"access_token":"at-1","refresh_token":"rt-1","expires_in":36000}`)
	}
	v := newVault(t, r)
	v.Now = func() time.Time { return now }
	if err := v.Put("pool", Codex, "default", s); err != nil {
		t.Fatal(err)
	}
	if _, err := v.Lease(context.Background(), "pool", Codex, "default"); err != nil {
		t.Fatal(err)
	}
	rows, _ := v.Store.CredAuditLog("pool", 10)
	if len(rows) == 0 || rows[0].Action != "refresh" || rows[0].Detail != "ok · refresh_via=relay" {
		t.Fatalf("audit = %+v", rows)
	}
}
