package store

import (
	"testing"
	"time"
)

func TestRetireFleetSnapshotsKeepsHistoryAndOfflineEnrollments(t *testing.T) {
	s := taskStore(t)
	now := time.Now().UTC()
	report := []FleetReport{{FleetID: "old-fleet", Name: "fleet", State: "running", WorkerCount: 1, WorkersJSON: `[{"worker_id":"old/w","state":"done"}]`}}
	for _, ep := range []string{"old", "replacement", "offline"} {
		if err := s.Enroll(ep, ep, "hash-"+ep); err != nil {
			t.Fatal(err)
		}
		f := report[0]
		f.FleetID = ep + "-fleet"
		if _, err := s.RecordFleetSnapshot(ep, "mini", "same-login", ep+"-machine", []FleetReport{f}, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.NodeConnected("old", "mini", "same-login", "test", 1, 5000, now); err != nil {
		t.Fatal(err)
	}
	before, _ := s.Fleet("old-fleet")
	res, err := s.RetireEndpointAs("old", "operator", "test", now)
	if err != nil || res.Settled.Fleets != 1 {
		t.Fatalf("retire: %+v %v", res, err)
	}
	nodes, err := s.Nodes()
	if err != nil || len(nodes) != 0 {
		t.Fatalf("retired heartbeat remains on roster: %+v %v", nodes, err)
	}
	after, _ := s.Fleet("old-fleet")
	if after.Present || !after.EndpointRetired || after.WorkersJSON != before.WorkersJSON || !after.ObservedAt.Equal(before.ObservedAt) {
		t.Fatalf("history damaged: %+v", after)
	}
	for _, fid := range []string{"replacement-fleet", "offline-fleet"} {
		f, err := s.Fleet(fid)
		if err != nil || !f.Present || f.EndpointRetired {
			t.Fatalf("unrelated/offline changed: %+v %v", f, err)
		}
	}
	if _, err := s.RecordFleetSnapshot("old", "mini", "same-login", "old-machine", report, now); err == nil {
		t.Fatal("late heartbeat resurrected retired fleet")
	}
	// An older hub left present=1 after retirement. Reads hide it immediately,
	// and repeating retire repairs it once with an audit, retaining the snapshot.
	if _, err := s.write.Exec(`UPDATE fleet_fleets SET present=1 WHERE fleet_id='old-fleet'`); err != nil {
		t.Fatal(err)
	}
	rows, err := s.Fleets()
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range rows {
		if f.FleetID == "old-fleet" && f.Present {
			t.Fatal("legacy retired snapshot still current")
		}
	}
	res, err = s.RetireEndpointAs("old", "operator", "repair legacy", now)
	if err != nil || res.Retired || res.Settled.Fleets != 1 {
		t.Fatalf("repair: %+v %v", res, err)
	}
	var present int
	if err := s.read.QueryRow(`SELECT present FROM fleet_fleets WHERE fleet_id='old-fleet'`).Scan(&present); err != nil || present != 0 {
		t.Fatalf("persisted repair: %d %v", present, err)
	}
	res, err = s.RetireEndpointAs("old", "operator", "repeat", now)
	if err != nil || !res.Settled.empty() {
		t.Fatalf("repair not idempotent: %+v %v", res, err)
	}
}
