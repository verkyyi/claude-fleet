package api

import (
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// TestMachineRole pins the one judge of machines[].role (claude-fleet#2795).
func TestMachineRole(t *testing.T) {
	m := MachineView{Hostname: "m"}
	cases := []struct {
		name  string
		nodes []NodeView
		want  string
	}{
		{"machine link", []NodeView{{Hostname: "m", MachineLink: true}, {Hostname: "m", Personal: true}}, MachineRoleHost},
		{"managed login", []NodeView{{Hostname: "m", Role: store.NodeRoleManaged, ComputeOff: true}}, MachineRoleHost},
		{"only personal", []NodeView{{Hostname: "m", Personal: true}}, MachineRoleClient},
		{"personal + hosting login", []NodeView{{Hostname: "m", Personal: true}, {Hostname: "m", OSUser: "w1"}}, MachineRoleHost},
		{"only coordinates", []NodeView{{Hostname: "m", ComputeOff: true}}, MachineRoleClient},
		{"lost hosting login", []NodeView{{Hostname: "m", Status: "lost"}}, MachineRoleHost},
		{"another machine's host", []NodeView{{Hostname: "x", MachineLink: true}, {Hostname: "m", Personal: true}}, MachineRoleClient},
	}
	for _, c := range cases {
		if got := machineRole(m, c.nodes); got != c.want {
			t.Errorf("%s: role = %q, want %q", c.name, got, c.want)
		}
	}
}

// The roster says it: a personal-only machine is client, the hosting one host.
func TestRosterMachineRole(t *testing.T) {
	h, _, _, _, _ := personalM4(t)
	machines, _ := nodeStatuses(t, h)
	if r := machines["m4"]["role"]; r != MachineRoleClient {
		t.Fatalf("personal m4 role = %v, want client: %v", r, machines["m4"])
	}
	if r := machines["m5"]["role"]; r != MachineRoleHost {
		t.Fatalf("m5 role = %v, want host: %v", r, machines["m5"])
	}
}
