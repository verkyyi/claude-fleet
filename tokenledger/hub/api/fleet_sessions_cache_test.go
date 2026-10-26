package api

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestSessionListCacheInvalidatesAcrossServers(t *testing.T) {
	h := newFleetHarness(t)
	node := connectFakeNode(t, h, "mac-c", false)
	node.beat("mac-c", "bob", machineB, fakeFleet(t, machineB, "fleet-b", "", "", 1))
	waitFor(t, 3*time.Second, "fleet snapshot", func() bool { fs, _ := h.srv.Store.Fleets(); return len(fs) > 0 })
	req := httptest.NewRequest("GET", "/v1/fleet/fleet_sessions", nil)
	first, err := h.srv.FleetSessions(req)
	if err != nil {
		t.Fatal(err)
	}
	key := sessionListKey{actor: "operator", all: true}
	entry := h.srv.sessionListCache.entries[key]
	if entry == nil || entry.body == nil {
		t.Fatal("list not cached")
	}
	until := entry.until
	first["count"] = -1
	second, err := h.srv.FleetSessions(req)
	if err != nil || second["count"] == -1 || !until.Equal(entry.until) {
		t.Fatalf("cache reuse: %v %v", second, err)
	}
	// Another server writes through the database, with no local broadcast.
	other := &Server{Store: h.srv.Store}
	if err := other.Store.NodeHeartbeat("ep_mac-c", "mac-c", "bob", machineB, control.Proto, `{"hostname":"mac-c"}`, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	third, err := h.srv.FleetSessions(req)
	if err != nil {
		t.Fatal(err)
	}
	if until.Equal(entry.until) || third["nodes"].([]FleetNode)[0].Availability != "lost" {
		t.Fatal("committed remote change left cached list")
	}
	// Own-view and everyone-view never share an entry, even for the same actor.
	own := req.WithContext(context.WithValue(req.Context(), ownViewKey{}, true))
	if _, err := h.srv.FleetSessions(own); err != nil {
		t.Fatal(err)
	}
	if len(h.srv.sessionListCache.entries) != 2 {
		t.Fatal("view scopes shared cache")
	}
	entry.until = time.Now().Add(-time.Second)
	if _, err := h.srv.FleetSessions(req); err != nil {
		t.Fatal(err)
	}
	if entry.until.Before(time.Now()) {
		t.Fatal("TTL did not rebuild")
	}
}
