package store_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

func TestSessionArchiveRealActivity(t *testing.T) {
	for _, tc := range []struct {
		name, event string
		active      bool
	}{
		{"reopen", `"ev":"reopened","maintenance":false`, true},
		{"segment", `"ev":"native","native":"new","trigger":"resume"`, true},
		{"compact", `"ev":"native","native":"new","compact":true`, true},
		{"warm", `"ev":"reopened","maintenance":true`, false},
		{"old-node-warm", `"ev":"reopened"`, false},
		{"warm-native", `"ev":"native","native":"new","maintenance":true`, false},
		{"migration", `"ev":"native","native":"old","trigger":"migrated"`, false},
		{"park", `"ev":"closed","reason":"parked"`, false},
		{"cleanup", `"ev":"closed","reason":"idle"`, false},
		{"progress", `"ev":"progress","state":"working","summary":"bookkeeping"`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := storetest.OpenFleet(t)
			if _, err := push(t, s, "ep", idA, sampleLedger(t, idA)[:1]); err != nil {
				t.Fatal(err)
			}
			if err := s.SetSessionArchived("operator", idA, true); err != nil {
				t.Fatal(err)
			}
			now := time.Now().Unix()
			if _, err := s.DB().Exec(`UPDATE fleet_session_archives SET archived_at=?`, now-10); err != nil {
				t.Fatal(err)
			}
			event := ledger(t, fmt.Sprintf(`{%s,"seq":2,"ts":%d}`, tc.event, now-1))
			for i := 0; i < 2; i++ { // replay cannot reactivate twice or reverse the activity clock
				if _, err := push(t, s, "ep", idA, event); err != nil {
					t.Fatal(err)
				}
				got, err := s.SessionArchivePreferences("operator")
				if err != nil || got[idA] == tc.active {
					t.Fatalf("preferences=%v err=%v", got, err)
				}
			}
			var archived int
			if err := s.DB().QueryRow(`SELECT archived FROM fleet_session_archives WHERE id=?`, idA).Scan(&archived); err != nil || (archived == 0) != tc.active {
				t.Fatalf("not persisted: %d %v", archived, err)
			}
		})
	}
}

func TestSessionArchiveActivityBoundaryAndPolling(t *testing.T) {
	s := storetest.OpenFleet(t)
	if _, err := push(t, s, "ep", idA, sampleLedger(t, idA)[:1]); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSessionArchived("operator", idA, true); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	baseline := now - 10
	if _, err := s.DB().Exec(`UPDATE fleet_session_archives SET archived_at=?`, baseline); err != nil {
		t.Fatal(err)
	}
	// Retried archive is idempotent, keeping the original cutoff.
	if err := s.SetSessionArchived("operator", idA, true); err != nil {
		t.Fatal(err)
	}
	var at int64
	if err := s.DB().QueryRow(`SELECT archived_at FROM fleet_session_archives WHERE id=?`, idA).Scan(&at); err != nil || at != baseline {
		t.Fatalf("cutoff %d %v", at, err)
	}
	for _, activity := range []int64{0, baseline - 1, baseline, now + 1, baseline + 1} {
		body := fmt.Sprintf(`[{"identity":%q,"activity_at":%d,"state":"parked"}]`, idA, activity)
		if _, err := s.RecordFleetSnapshot("ep", "machine", "alice", "machine", []store.FleetReport{{FleetID: "fleet", Name: "test", State: "up", WorkersJSON: body}}, time.Unix(now, 0)); err != nil {
			t.Fatal(err)
		}
		// Reading another owner's board must not mutate this preference.
		if _, err := s.SessionArchivePreferences("other"); err != nil {
			t.Fatal(err)
		}
		got, err := s.SessionArchivePreferences("operator")
		if err != nil || got[idA] != (activity != baseline+1) {
			t.Fatalf("activity %d: %v %v", activity, got, err)
		}
	}
	// A new explicit archive wins over all already-seen activity.
	if err := s.SetSessionArchived("operator", idA, true); err != nil {
		t.Fatal(err)
	}
	got, err := s.SessionArchivePreferences("operator")
	if err != nil || !got[idA] {
		t.Fatalf("rearchive: %v %v", got, err)
	}
}

func TestSessionArchiveLegacyMigration(t *testing.T) {
	s := storetest.OpenFleet(t)
	if _, err := push(t, s, "ep", idA, sampleLedger(t, idA)[:1]); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DB().Exec(`ALTER TABLE fleet_session_archives DROP COLUMN archived_at`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DB().Exec(`INSERT INTO fleet_session_archives(owner,id,archived) VALUES(?,?,1)`, "operator", idA); err != nil {
		t.Fatal(err)
	}
	before := time.Now().Unix()
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	var at int64
	if err := s.DB().QueryRow(`SELECT archived_at FROM fleet_session_archives WHERE id=?`, idA).Scan(&at); err != nil || at < before {
		t.Fatalf("migration cutoff=%d %v", at, err)
	}
	if _, err := s.DB().Exec(`UPDATE fleet_session_archives SET archived_at=?`, before-10); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if err := s.DB().QueryRow(`SELECT archived_at FROM fleet_session_archives WHERE id=?`, idA).Scan(&at); err != nil || at != before-10 {
		t.Fatalf("migration repeated=%d %v", at, err)
	}
	prefs, err := s.SessionArchivePreferences("operator")
	if err != nil || !prefs[idA] {
		t.Fatalf("history undid legacy archive: %v %v", prefs, err)
	}
}
