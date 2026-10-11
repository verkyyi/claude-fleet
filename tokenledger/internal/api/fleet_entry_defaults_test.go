package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/dns"
)

// A hub that writes address records means the door (claude-fleet#3199):
// fleet.entry defaults on and fleet.entry_domain to the deploy's zone, never
// copied into the database; a stored value — off too — wins.
func TestEntryDefaultsFollowTheDeploy(t *testing.T) {
	h := entryHarness(t)
	_ = h.srv.Store.SetFleetSetting(EntryKey, "", time.Now()) // back to the default
	if h.srv.entryOn() || h.srv.setting(EntryDomainKey) != "" {
		t.Fatal("no DNS: off, no zone")
	}
	h.srv.EntryDNS = NewEntryDNS(dns.NewFake(), "cf")
	h.srv.EntryDNS.Zone = "cf.24haowan.com"
	if !h.srv.entryOn() || h.srv.setting(EntryDomainKey) != "cf.24haowan.com" {
		t.Fatalf("DNS: entry %v, zone %q", h.srv.entryOn(), h.srv.setting(EntryDomainKey))
	}
	settings, _ := h.srv.Store.FleetSettings()
	if settings[EntryKey] != "" || settings[EntryDomainKey] != "" {
		t.Fatalf("a deploy default was stored: %v", settings)
	}
	for _, v := range h.srv.hubSettingsView(settings) {
		if (v.Key == EntryKey || v.Key == EntryDomainKey) && v.Source != "deploy" {
			t.Fatalf("%s: source %q, want deploy", v.Key, v.Source)
		}
	}
	if err := h.srv.MigrateLegacySettings(time.Now()); err != nil {
		t.Fatal(err)
	}
	if settings, _ = h.srv.Store.FleetSettings(); settings[EntryKey] != "" {
		t.Fatalf("the migration copied a deploy default: %v", settings)
	}
	_ = h.srv.Store.SetFleetSetting(EntryKey, "off", time.Now())
	if h.srv.entryOn() {
		t.Fatal("a stored off is overruled by the deploy")
	}
}

// A list change makes the home's next report a real check, not the last one
// answered again (claude-fleet#3199).
func TestEntryPushClearsTheReachGap(t *testing.T) {
	h := entryHarness(t)
	h.srv.entryReachAt.Store("macmini", time.Now())
	h.srv.entryReachAt.Store("macmini-m4", time.Now())
	h.srv.broadcastEntry(1, "macmini")
	if _, ok := h.srv.entryReachAt.Load("macmini"); ok {
		t.Fatal("the home's gap stands")
	}
	if _, ok := h.srv.entryReachAt.Load("macmini-m4"); !ok {
		t.Fatal("another machine's gap went too")
	}
}
