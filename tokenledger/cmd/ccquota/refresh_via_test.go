package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
)

// CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay (claude-fleet#1976) needs the relay's
// URL and the key the hub signs its pass with, keeps the node path as its
// fallback, and the old values are unchanged.
func TestFleetRefreshViaRelay(t *testing.T) {
	direct := &credvault.HTTPRefresher{}
	vault := func() *credvault.Vault { return &credvault.Vault{Refresher: direct} }
	srv := &api.Server{}

	t.Setenv("CCQUOTA_FLEET_OAUTH_REFRESH_VIA", "relay")
	t.Setenv("CCQUOTA_FLEET_CRED_RELAY_URL", "")
	if err := fleetRefreshVia(srv, vault()); err == nil || !strings.Contains(err.Error(), "CCQUOTA_FLEET_CRED_RELAY_URL") {
		t.Fatalf("relay without a URL: %v", err)
	}
	t.Setenv("CCQUOTA_FLEET_CRED_RELAY_URL", "https://relay.example")
	if err := fleetRefreshVia(srv, vault()); err == nil || !strings.Contains(err.Error(), "CCQUOTA_FLEET_SESSION_CRED_KEY") {
		t.Fatalf("relay without a pass key: %v", err)
	}
	srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	v := vault()
	if err := fleetRefreshVia(srv, v); err != nil {
		t.Fatal(err)
	}
	r, ok := v.Refresher.(*credvault.RelayRefresher)
	if !ok || r.URL != "https://relay.example" || r.Pass == nil || r.Fallback == nil {
		t.Fatalf("relay refresher = %#v", v.Refresher)
	}
	if _, ok := r.Fallback.(*credvault.ProxyRefresher); !ok {
		t.Fatalf("fallback = %#v, want the node path", r.Fallback)
	}

	t.Setenv("CCQUOTA_FLEET_OAUTH_REFRESH_VIA", "node")
	v = vault()
	if err := fleetRefreshVia(srv, v); err != nil {
		t.Fatal(err)
	}
	if _, ok := v.Refresher.(*credvault.ProxyRefresher); !ok {
		t.Fatalf("node = %#v", v.Refresher)
	}
	t.Setenv("CCQUOTA_FLEET_OAUTH_REFRESH_VIA", "")
	v = vault()
	if err := fleetRefreshVia(srv, v); err != nil || v.Refresher != credvault.Refresher(direct) {
		t.Fatalf("unset: %#v %v", v.Refresher, err)
	}
	t.Setenv("CCQUOTA_FLEET_OAUTH_REFRESH_VIA", "carrier-pigeon")
	if err := fleetRefreshVia(srv, vault()); err == nil {
		t.Fatal("an unknown value started")
	}
}

// CCQUOTA_GITHUB_OAUTH_VIA=relay (claude-fleet#3392): the sign-in's token
// exchange through the relay. Unset / direct change nothing; relay needs the
// relay URL and the pass key; with sign-in off it is ignored; nonsense refuses.
func TestGitHubOAuthVia(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	gh := func() *api.Server { return &api.Server{GitHub: &api.GitHubAuth{ClientID: "Iv1.x", ClientSecret: "s"}} }
	for _, v := range []string{"", "direct", " Direct "} {
		srv := gh()
		if err := githubOAuthVia(srv, env(map[string]string{"CCQUOTA_GITHUB_OAUTH_VIA": v,
			"CCQUOTA_FLEET_CRED_RELAY_URL": "https://relay.example"})); err != nil || srv.GitHub.RelayURL != "" {
			t.Fatalf("%q: %v relay=%q", v, err, srv.GitHub.RelayURL)
		}
	}
	if err := githubOAuthVia(gh(), env(map[string]string{"CCQUOTA_GITHUB_OAUTH_VIA": "proxy"})); err == nil {
		t.Fatal("nonsense started")
	}
	on := map[string]string{"CCQUOTA_GITHUB_OAUTH_VIA": "relay"}
	if err := githubOAuthVia(&api.Server{}, env(on)); err != nil {
		t.Fatalf("sign-in off: %v", err)
	}
	if err := githubOAuthVia(gh(), env(on)); err == nil || !strings.Contains(err.Error(), "CCQUOTA_FLEET_CRED_RELAY_URL") {
		t.Fatalf("relay without a URL: %v", err)
	}
	on["CCQUOTA_FLEET_CRED_RELAY_URL"] = "https://relay.example"
	if err := githubOAuthVia(gh(), env(on)); err == nil || !strings.Contains(err.Error(), "CCQUOTA_FLEET_SESSION_CRED_KEY") {
		t.Fatalf("relay without a pass key: %v", err)
	}
	srv := gh()
	srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	if err := githubOAuthVia(srv, env(on)); err != nil {
		t.Fatal(err)
	}
	if srv.GitHub.RelayURL != "https://relay.example" || srv.GitHub.RelayPass == nil {
		t.Fatalf("relay not wired: %+v", srv.GitHub)
	}
	if p, err := srv.GitHub.RelayPass(); err != nil || !strings.HasPrefix(p, "frh1.") {
		t.Fatalf("pass %q %v", p, err)
	}
}
