package main

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
)

// CCQUOTA_FLEET_HUB_QUOTA (claude-fleet#2169): unset or off reads nothing —
// srv.HubQuota stays nil, exactly as before; relay needs the relay URL and the
// pass key; a bad value or interval refuses to start.
func TestFleetHubQuota(t *testing.T) {
	v := &credvault.Vault{}
	for _, off := range []string{"", "off", "OFF"} {
		t.Setenv("CCQUOTA_FLEET_HUB_QUOTA", off)
		srv := &api.Server{SessionCredKey: bytes.Repeat([]byte{9}, 32)}
		t.Setenv("CCQUOTA_FLEET_CRED_RELAY_URL", "https://relay.example")
		if err := fleetHubQuota(srv, v); err != nil || srv.HubQuota != nil {
			t.Fatalf("%q: %v %#v", off, err, srv.HubQuota)
		}
	}
	t.Setenv("CCQUOTA_FLEET_HUB_QUOTA", "relay")
	srv := &api.Server{}
	t.Setenv("CCQUOTA_FLEET_CRED_RELAY_URL", "")
	if err := fleetHubQuota(srv, v); err == nil || !strings.Contains(err.Error(), "CCQUOTA_FLEET_CRED_RELAY_URL") {
		t.Fatalf("no URL: %v", err)
	}
	t.Setenv("CCQUOTA_FLEET_CRED_RELAY_URL", "https://relay.example")
	if err := fleetHubQuota(srv, v); err == nil || !strings.Contains(err.Error(), "CCQUOTA_FLEET_SESSION_CRED_KEY") {
		t.Fatalf("no key: %v", err)
	}
	srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	if err := fleetHubQuota(srv, nil); err != nil || srv.HubQuota != nil {
		t.Fatalf("vault off: %v %#v", err, srv.HubQuota)
	}
	if err := fleetHubQuota(srv, v); err != nil || srv.HubQuota == nil || srv.HubQuota.Interval != api.DefaultHubQuotaInterval || srv.HubQuota.RelayURL != "https://relay.example" {
		t.Fatalf("on: %v %#v", err, srv.HubQuota)
	}
	t.Setenv("CCQUOTA_FLEET_HUB_QUOTA_INTERVAL", "10m")
	srv.HubQuota = nil
	if err := fleetHubQuota(srv, v); err != nil || srv.HubQuota.Interval != 10*time.Minute {
		t.Fatalf("interval: %v %#v", err, srv.HubQuota)
	}
	for _, bad := range []string{"10s", "soon"} {
		t.Setenv("CCQUOTA_FLEET_HUB_QUOTA_INTERVAL", bad)
		if err := fleetHubQuota(&api.Server{SessionCredKey: srv.SessionCredKey}, v); err == nil {
			t.Fatalf("interval %q accepted", bad)
		}
	}
	t.Setenv("CCQUOTA_FLEET_HUB_QUOTA", "node")
	if err := fleetHubQuota(srv, v); err == nil {
		t.Fatal("an unknown mode was accepted")
	}
}
