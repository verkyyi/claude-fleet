package e2e

import (
	"github.com/verkyyi/claude-fleet/tokenledger/hub/apitest"
)

// The hub/api harness under the names the联调 tests were written with
// (claude-fleet#4814: they lived in hub/api until the hub module stopped
// naming the node).
type harness = apitest.Harness

const viewerToken = apitest.ViewerToken

var (
	newHarness      = apitest.NewHarness
	newFleetHarness = apitest.NewFleetHarness
	waitFor         = apitest.WaitFor
	getFleet        = apitest.GetFleet
	roster          = apitest.Roster
	dialNode        = apitest.DialNode
	openTestStore   = apitest.OpenStore
)

// The people the hub/api tests sign in as (hub/api people_test.go).
const (
	pAlice = "gh:1001"
	pBob   = "gh:1002"
	pCarol = "gh:1003"
	pGhost = "gh:1099" // never on the list
)

// A provider's refresh tokens (hub/api fleet_oauth_refresh_test.go).
const (
	codexRefreshSecret = "rt-SECRET-codex-0"
	codexRefreshNext   = "rt-SECRET-codex-1"
	codexIDToken       = "id-SECRET-token-1"
)

func hasString(list []string, v string) bool {
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}
