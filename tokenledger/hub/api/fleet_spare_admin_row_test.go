package api

import (
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A person's pod whose login shares an admin role's name stays a home choice;
// the role's login on a machine does not (task APVZ, claude-fleet#4234).
func TestFleetAdminRowSparesPods(t *testing.T) {
	s := &Server{FleetAdmins: []string{"ops", "_fleetadmin"}}
	for _, c := range []struct {
		host, user string
		admin      bool
	}{
		{"mac-a", "ops", true},
		{"mac-b", "_fleetadmin", true},
		{"u-k3x9q2", "ops", false},
		{"u-k3x9q2.fleet-workers.svc.cluster.local", "ops", false},
		{"u-k3x9q2", "fleetu7", false},
		{"mac-b", "carol", false},
	} {
		if got := s.fleetAdminRow(store.FleetRow{Hostname: c.host, OSUser: c.user}); got != c.admin {
			t.Errorf("fleetAdminRow(%s/%s) = %v, want %v", c.host, c.user, got, c.admin)
		}
	}
}
