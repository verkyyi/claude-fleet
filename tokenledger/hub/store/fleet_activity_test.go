package store_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

func TestSessionActivitySurvivesClosureAndIgnoresPolling(t *testing.T) {
	s := storetest.OpenFleet(t)
	if _, err := push(t, s, "ep", idA, sampleLedger(t, idA)[:1]); err != nil {
		t.Fatal(err)
	}
	workers := func(at int64) string {
		return fmt.Sprintf(`[{"identity":%q,"activity_at":%d}]`, idA, at)
	}
	snapshot := func(endpoint, fleet, machine, body string) {
		t.Helper()
		if _, err := s.RecordFleetSnapshot(endpoint, machine, "alice", machine,
			[]store.FleetReport{{FleetID: fleet, Name: "test", State: "up", WorkersJSON: body}}, time.Unix(2000, 0)); err != nil {
			t.Fatal(err)
		}
	}
	check := func(want int64) {
		t.Helper()
		rows, err := s.BoardIDs("operator", 0)
		if err != nil || len(rows) != 1 || rows[0].ActivityAt != want {
			t.Fatalf("activity want %d: rows=%+v err=%v", want, rows, err)
		}
	}
	snapshot("ep", "fleet", "machine", workers(1100))
	check(1100)
	for _, body := range []string{workers(1000), workers(0), workers(2100), `[{"identity":"` + idA + `"}]`, `[]`} {
		snapshot("ep", "fleet", "machine", body)
		check(1100)
	}
	snapshot("other", "other-fleet", "other-machine", workers(1900))
	check(1100)
	if err := s.UpdateFleetWorkers("fleet", "up", 1, workers(1200), time.Unix(2000, 0)); err != nil {
		t.Fatal(err)
	}
	check(1200)
	if _, err := push(t, s, "ep", idA, ledger(t, `{"ev":"closed","id":"`+idA+`","seq":2,"ts":1500}`)); err != nil {
		t.Fatal(err)
	}
	snapshot("ep", "fleet", "machine", `[]`)
	check(1200)
	record, err := s.FleetIDOf("operator", idA)
	if err != nil || record.ActivityAt != 1200 {
		t.Fatalf("historical record activity: %+v %v", record, err)
	}
	rows, err := s.BoardIDs("someone-else", 0)
	if err != nil || len(rows) != 0 {
		t.Fatalf("owner isolation: %+v %v", rows, err)
	}
}
