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
