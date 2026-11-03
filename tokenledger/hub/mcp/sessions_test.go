package mcp

import (
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/pricing"
)

// The session tools (task T4DN) are the fleet module's: a hub without it lists
// none of them and answers none of them.
func TestSessionToolsOnlyWithTheFleetModule(t *testing.T) {
	names := func(fleet bool) map[string]bool {
		st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { st.Close() })
		ts := httptest.NewServer(Handler(&api.Server{Store: st, Pricing: pricing.Default(), Fleet: fleet}))
		t.Cleanup(ts.Close)
		out := rpc(t, ts, "tools/list", nil)
		got := map[string]bool{}
		for _, x := range out["result"].(map[string]any)["tools"].([]any) {
			got[x.(map[string]any)["name"].(string)] = true
		}
		if !fleet {
			res := rpc(t, ts, "tools/call", map[string]any{"name": "sessions_list", "arguments": map[string]any{}})
			if r, _ := res["result"].(map[string]any); r == nil || r["isError"] != true {
				t.Errorf("sessions_list answered on a hub without the fleet module: %v", res)
			}
		}
		return got
	}
	off, on := names(false), names(true)
	for _, n := range api.SessionTools {
		if off[n] {
			t.Errorf("%s listed without the fleet module", n)
		}
		if !on[n] {
			t.Errorf("%s not listed with the fleet module", n)
		}
	}
	if len(sessionToolSpecs()) != len(api.SessionTools) {
		t.Errorf("%d specs for %d tools", len(sessionToolSpecs()), len(api.SessionTools))
	}
}
