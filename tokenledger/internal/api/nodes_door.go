package api

import (
	"log"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// MachineDoor is a machine's entry port as the admin's 机器与 pod reads it
// (claude-fleet#3934, EPIC #3923 C11): open — the hub reached it there on a
// check no older than EntryReachFresh (Port the port it answered at; the same
// rule as EntryReachable) · cluster — a person's pod, reached through the
// cluster's door (podBehindDoor) · off — neither. Only on the full roster
// (stampDoors), and only while the entry port or a door is set up at all.
type MachineDoor struct {
	State string `json:"state"`
	Port  int    `json:"port,omitempty"`
}

// stampDoors writes each host machine's door onto the operator's roster. One
// read of the reach table for the whole roster; a read that fails leaves
// every door absent (the page says —), never off.
func (s *Server) stampDoors(snap *NodesSnapshot, now time.Time) {
	if s.Store == nil || (!s.entryOn() && len(s.doorMachines()) == 0) {
		return
	}
	all, err := s.Store.EntryReachAll()
	if err != nil {
		log.Printf("fleet: doors: %v", err)
		return
	}
	for i := range snap.Machines {
		mv := &snap.Machines[i]
		if mv.Role == MachineRoleClient {
			continue
		}
		mv.Door = machineDoorOf(mv.Hostname, s.podBehindDoor(mv.Hostname), all, now)
	}
}

// machineDoorOf is one machine's door from the reach table's rows.
func machineDoorOf(host string, pod bool, rows []store.EntryReach, now time.Time) *MachineDoor {
	if pod {
		return &MachineDoor{State: "cluster"}
	}
	for _, r := range rows {
		if (sameMachine(r.Machine, host) || sameMachine(host, r.Machine)) && r.Reachable && now.Sub(r.CheckedAt) <= EntryReachFresh {
			return &MachineDoor{State: "open", Port: r.Port}
		}
	}
	return &MachineDoor{State: "off"}
}
