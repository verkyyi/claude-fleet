package api

import (
	"fmt"
	"testing"
	"time"
)

// One machine's admission is its newest heartbeat's verdict, never any one
// login's veto (claude-fleet#4251): macmini's 18 logins, one of them an older
// «负载过高», held every trial on the machine.
func TestMachineAdmitNewestReading(t *testing.T) {
	t0 := time.Date(2026, 10, 14, 22, 35, 0, 0, time.UTC)
	yes, no := true, false
	snap := func(noAt int) NodesSnapshot {
		var s NodesSnapshot
		for i := 0; i < 18; i++ {
			at := t0.Add(time.Duration(i) * time.Second)
			v := NodeView{Hostname: "macmini", OSUser: fmt.Sprintf("fleetu%d", i), Status: "online", LastHeartbeat: &at, Admit: &yes}
			if i == noAt {
				v.Admit = &no
			}
			s.Nodes = append(s.Nodes, v)
		}
		return s
	}
	if !machineAdmit(snap(3), "macmini") {
		t.Errorf("1 of 18 logins says no on an older reading: the machine should admit")
	}
	if machineAdmit(snap(17), "macmini") {
		t.Errorf("the newest reading says no: the machine should not admit")
	}
	if !machineAdmit(snap(17), "mac-d") {
		t.Errorf("a machine with no reading should admit")
	}
	s := snap(17)
	s.Nodes[17].Status = "lost"
	if !machineAdmit(s, "MACMINI") {
		t.Errorf("a lost login's «no» should not count")
	}
	if got := trialPageReason(trialWaitBusyAdmit); got != trialWaitBusy {
		t.Errorf("page reason of %q = %q; want busy", trialWaitBusyAdmit, got)
	}
	if got := trialPageReason(trialWaitLoad); got != trialWaitLoad {
		t.Errorf("page reason of load = %q", got)
	}
}
