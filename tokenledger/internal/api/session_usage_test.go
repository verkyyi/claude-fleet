package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Each fleet_sessions row carries its session's pool tokens today
// (claude-fleet#3377): its worker_id's rows since this UTC midnight, nobody
// else's session, and none recorded ⇒ no field at all.
func TestFleetSessions_TokensToday(t *testing.T) {
	h, admin, user := adminViewsHarness(t)
	st, now := h.srv.Store, time.Now()
	adminWID := "11111111-1111-4111-8111-111111111111/w-issue-1"
	aliceWID := "22222222-2222-4222-8222-222222222222/w-issue-2"
	for _, u := range []store.PoolUsage{
		{Principal: githubPrincipal(ghAdmin.ID), WorkerID: adminWID, Provider: "claude", In: 100, CacheRead: 999, At: now},
		{Principal: githubPrincipal(ghAdmin.ID), WorkerID: adminWID, Provider: "codex", Out: 50, At: now},
		{Principal: githubPrincipal(ghAdmin.ID), WorkerID: adminWID, Provider: "claude", In: 1000, At: now.Add(-48 * time.Hour)},
		{Principal: githubPrincipal(ghAdmin.ID), Provider: "claude", In: 3000, At: now}, // on no session
		{Principal: githubPrincipal(ghAlice.ID), WorkerID: aliceWID, Provider: "claude", In: 7, At: now},
	} {
		if err := st.AddPoolUsage(u); err != nil {
			t.Fatal(err)
		}
	}
	read := func(who string, cookie *http.Cookie) map[string]int64 {
		t.Helper()
		var fs struct {
			Sessions []FleetSession `json:"sessions"`
		}
		if code := getJSON(t, h, cookie, "/v1/fleet/fleet_sessions", &fs); code != http.StatusOK {
			t.Fatalf("%s fleet_sessions = %d", who, code)
		}
		out := map[string]int64{}
		for _, s := range fs.Sessions {
			if s.WorkerID != nil {
				out[*s.WorkerID] = s.TokensToday
			}
		}
		return out
	}
	if got := read("admin", admin); len(got) != 1 || got[adminWID] != 150 {
		t.Errorf("admin's sessions = %v; want only %s at 150 (today's in + out, no cache read, not yesterday's)", got, adminWID)
	}
	if got := read("alice", user); len(got) != 1 || got[aliceWID] != 7 {
		t.Errorf("alice's sessions = %v; want only %s at 7", got, aliceWID)
	}
	if code, b := rolesGet(t, h, admin, "/v1/fleet/fleet_sessions"); code != http.StatusOK || !strings.Contains(string(b), `"tokens_today":150`) {
		t.Errorf("fleet_sessions body lacks tokens_today: %d %s", code, b)
	}
}

func TestFleetSessions_NoTokensNoField(t *testing.T) {
	h, admin, _ := adminViewsHarness(t)
	if code, b := rolesGet(t, h, admin, "/v1/fleet/fleet_sessions"); code != http.StatusOK || strings.Contains(string(b), "tokens_today") {
		t.Errorf("nothing recorded, but the answer names tokens_today: %d %s", code, b)
	}
}
