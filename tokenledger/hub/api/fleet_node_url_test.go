package api

import (
	"net/http"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Nothing set: the welcome names no address — byte for byte as before.
func TestNodeURLOffAnnouncesNothing(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetPublicURL = "https://hub.example.com" // never announced by itself
	c := dialNode(t, h, h.enroll(t, "mac-d"))
	if w := hello(t, c, control.Proto, 5000); w.HubURL != "" {
		t.Fatalf("no fleet.node_url, but the welcome announced %q", w.HubURL)
	}
}

// fleet.node_url set: every welcome names it, canonical.
func TestNodeURLAnnouncedInWelcome(t *testing.T) {
	h := newFleetHarness(t)
	if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": NodeURLKey, "value": "https://Core.Example.io/"}); code != http.StatusOK {
		t.Fatalf("set %s: %d %v", NodeURLKey, code, out)
	}
	c := dialNode(t, h, h.enroll(t, "mac-d"))
	if w := hello(t, c, control.Proto, 5000); w.HubURL != "https://core.example.io" {
		t.Fatalf("welcome announced %q, want https://core.example.io", w.HubURL)
	}
	// "" clears it: nothing announced again
	if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": NodeURLKey, "value": ""}); code != http.StatusOK {
		t.Fatalf("clear %s: %d %v", NodeURLKey, code, out)
	}
	c2 := dialNode(t, h, h.enroll(t, "mac-e"))
	if w := hello(t, c2, control.Proto, 5000); w.HubURL != "" {
		t.Fatalf("cleared, but the welcome announced %q", w.HubURL)
	}
}

// Only an https origin is stored: a machine is never told to send its token in
// the clear, to a path, or to a user-info URL.
func TestNodeURLRefusesNonOrigins(t *testing.T) {
	h := newFleetHarness(t)
	for _, v := range []string{"http://hub.example.com", "https://hub.example.com/v1", "https://u:p@hub.example.com",
		"https://hub.example.com?x=1", "hub.example.com", "https://", "https://a b.com"} {
		if code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": NodeURLKey, "value": v}); code != http.StatusBadRequest {
			t.Errorf("%s=%q answered %d, want 400", NodeURLKey, v, code)
		}
	}
	if got := canonNodeURL("https://hub.example.com:8443/"); got != "https://hub.example.com:8443" {
		t.Fatalf("canonNodeURL kept the port badly: %q", got)
	}
}
