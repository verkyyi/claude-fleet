package e2e

import (
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"

	"testing"
	"time"
)

// setHubSetting stores one hub setting straight into the table (creating
// it on a hub that is not a fleet), the way an admin's PUT leaves it.
func setHubSetting(t *testing.T, s *Server, key, value string) {
	t.Helper()
	if err := s.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if err := s.Store.SetFleetSetting(key, value, time.Now()); err != nil {
		t.Fatal(err)
	}
}
