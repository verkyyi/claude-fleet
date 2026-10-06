package agent

import "testing"

// claude-fleet#1719: only CCQUOTA_FLEET_COMPUTE=0 says anything — unset sends
// exactly what an agent older than #1719 sent (nil, compute on).
func TestComputeClaim(t *testing.T) {
	if c := (&Agent{}).computeClaim(); c != nil {
		t.Fatalf("compute on: claim %v, want nil", *c)
	}
	c := (&Agent{cfg: Config{FleetComputeOff: true}}).computeClaim()
	if c == nil || *c {
		t.Fatalf("compute off: claim %v, want false", c)
	}
}
