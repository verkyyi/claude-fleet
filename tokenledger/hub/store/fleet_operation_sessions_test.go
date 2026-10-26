package store

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func operationStore(t *testing.T) *Store {
	t.Helper()
	s := newStore(t)
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestOperationSessionBackfillRequiresExpiryReview(t *testing.T) {
	s := operationStore(t)
	now := time.Now().UTC()
	const a = "11111111-1111-4111-8111-111111111111"
	const b = "22222222-2222-4222-8222-222222222222"
	for _, status := range []string{"recorded", "accepted", "running", "unknown", "pending", "succeeded", "failed"} {
		// Old rows, including non-JSON envelopes and more than one reference.
		if _, err := s.write.Exec(`INSERT INTO fleet_operations(id,fleet_id,action,request,actor,idem,status,created,updated,result) VALUES(?,'fleet','worker_message',?,'alice',?,?,?,?,?)`, status, "legacy "+a+" "+b, status, status, now.Add(-25*time.Hour).Format(rfc), now.Format(rfc), `{"proof":"kept"}`); err != nil {
			t.Fatal(err)
		}
	}
	// Simulate an upgrade from a database with no derived index.
	if _, err := s.write.Exec(`DELETE FROM fleet_operation_sessions`); err != nil {
		t.Fatal(err)
	}
	if err := s.ensureOperationSessions(); err != nil {
		t.Fatal(err)
	}
	if err := s.ensureOperationSessions(); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operation_sessions WHERE session_id=? AND status NOT IN ('succeeded','failed','expired')`, a).Scan(&count); err != nil || count != 5 {
		t.Fatalf("pending=%d err=%v", count, err)
	}
	fresh := FleetOperation{ID: "fresh", Action: "worker_message", Request: `{"params":{"worker_id":"fleet/` + a + `","text":"` + b + `"}}`, Actor: "alice", Idem: "fresh", Status: "unknown", Created: now, Updated: now}
	if err := s.InsertFleetOperation(fresh); err != nil {
		t.Fatal(err)
	}
	n, err := s.ExpireFleetOperations(now)
	if n != 0 || !errors.Is(err, ErrOperationExpiryReviewRequired) {
		t.Fatalf("unreviewed expiry: %d %v", n, err)
	}
	for _, status := range []string{"recorded", "accepted", "running", "unknown", "pending", "succeeded", "failed"} {
		op, err := s.FleetOperation(status)
		if err != nil || op.Status != status || op.Result != `{"proof":"kept"}` {
			t.Fatalf("unreviewed row changed: %+v %v", op, err)
		}
	}
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action='operation_expire'`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("unreviewed audit=%d %v", count, err)
	}
	if err := s.UpdateFleetOperation("fresh", "succeeded", "{}", now); err != nil {
		t.Fatal(err)
	}
	if err := s.ReconcileFleetOperation(fresh, "running", "{}", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	op, _ := s.FleetOperation("fresh")
	if op.Status != "succeeded" || !op.Updated.Equal(now) {
		t.Fatalf("touch changed terminal: %+v", op)
	}
}

// The production-sized planner fixture must use the session index without
// disabling sequential scans. The old correlated LIKE scanned the 14MB table
// once for each hidden session; the new predicate does not read that table.
func TestHiddenHistoryIndexedPlan(t *testing.T) {
	s := operationStore(t)
	now := time.Now().UTC().Format(rfc)
	tx, err := s.write.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	for i := 0; i < 7024; i++ {
		id := fmt.Sprintf("%08x-1111-4111-8111-111111111111", i)
		status := "succeeded"
		if i < 785 {
			status = "unknown"
		}
		request := `{"params":{"worker_id":"fleet/` + id + `","text":"` + strings.Repeat("x", 2000) + `"}}`
		if _, err := tx.Exec(`INSERT INTO fleet_operations(id,fleet_id,action,request,actor,idem,status,created,updated) VALUES(?,'fleet','worker_message',?,'alice',?,?,?,?)`, id, request, id, status, now, now); err != nil {
			t.Fatal(err)
		}
		if err := indexOperationSessions(tx, FleetOperation{ID: id, Request: request, Status: status}); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 60; i++ {
		id := fmt.Sprintf("%08x-1111-4111-8111-111111111111", i*100)
		if _, err := tx.Exec(`INSERT INTO fleet_ids(id,owner,code,short,endpoint_id,seq,closed_at,updated_at) VALUES(?,'alice',?,?,'node',1,1,?)`, id, id, id, now); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(`INSERT INTO fleet_history_hides(owner,id,seq,hidden) VALUES('alice',?,1,1)`, id); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`ANALYZE fleet_operation_sessions`); err != nil {
		t.Fatal(err)
	}
	q := hiddenHistoryCandidatesSQL() + ` AND h.owner=?`
	prefix := "EXPLAIN QUERY PLAN "
	if s.d == postgresDialect {
		prefix = "EXPLAIN (ANALYZE, BUFFERS) "
	}
	rows, err := s.read.Query(prefix+q, "alice")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var plan strings.Builder
	for rows.Next() {
		var line string
		if s.d == postgresDialect {
			err = rows.Scan(&line)
		} else {
			var a, b, c int
			err = rows.Scan(&a, &b, &c, &line)
		}
		if err != nil {
			t.Fatal(err)
		}
		plan.WriteString(line)
		plan.WriteByte('\n')
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	t.Log(plan.String())
	if !strings.Contains(plan.String(), "fleet_operation_sessions_history_pending") || strings.Contains(plan.String(), "Seq Scan on fleet_operation_sessions") || strings.Contains(plan.String(), "fleet_operations") {
		t.Fatalf("full scan: %s", plan.String())
	}
}

// Compare the indexed predicate to the actual pre-R4 predicate on both engines,
// including expired/unknown statuses and legacy upper-case references.
func TestHistoryOperationPredicateMatchesLegacy(t *testing.T) {
	s := operationStore(t)
	now := time.Now()
	for n, status := range []string{"recorded", "accepted", "pending", "running", "unknown", "expired", "cancelled", "", "succeeded", "failed"} {
		for _, upper := range []bool{false, true} {
			id := fmt.Sprintf("%08x-abcd-4abc-8abc-%012d", n+100, n)
			ref := id
			suffix := "lower"
			if upper {
				ref = strings.ToUpper(ref)
				suffix = "upper"
				id = fmt.Sprintf("%08x-abcd-4abc-8abc-%012d", n+200, n)
				ref = strings.ToUpper(id)
			}
			op := FleetOperation{ID: status + suffix, Actor: "alice", Idem: status + suffix, Status: status, Request: "legacy/" + ref, Created: now, Updated: now}
			if err := s.InsertFleetOperation(op); err != nil {
				t.Fatal(err)
			}
			var legacy, indexed bool
			if err := s.read.QueryRow(`SELECT EXISTS(SELECT 1 FROM fleet_operations WHERE status NOT IN ('succeeded','failed') AND request LIKE '%' || ? || '%')`, id).Scan(&legacy); err != nil {
				t.Fatal(err)
			}
			if err := s.read.QueryRow(`SELECT EXISTS(`+historyPendingOperation+`)`, id).Scan(&indexed); err != nil {
				t.Fatal(err)
			}
			if legacy != indexed {
				t.Fatalf("status=%q uppercase=%t: legacy=%t indexed=%t", status, upper, legacy, indexed)
			}
		}
	}
}

func TestOperationSessionCasefoldBackfill(t *testing.T) {
	s := operationStore(t)
	const id = "aaaaaaaa-abcd-4abc-8abc-aaaaaaaaaaaa"
	now := time.Now().UTC().Format(rfc)
	if _, err := s.write.Exec(`INSERT INTO fleet_operations(id,fleet_id,action,request,actor,idem,status,created,updated) VALUES('legacy-upper','','worker_message',?,'alice','legacy-upper','unknown',?,?)`, strings.ToUpper(id), now, now); err != nil {
		t.Fatal(err)
	}
	// The first R4 parser wrote only this receipt for upper-case legacy text.
	if _, err := s.write.Exec(`INSERT INTO fleet_operation_sessions(operation_id,session_id,status) VALUES('legacy-upper','','unknown') ON CONFLICT(operation_id,session_id) DO NOTHING`); err != nil {
		t.Fatal(err)
	}
	if err := s.ensureOperationSessions(); err != nil {
		t.Fatal(err)
	}
	var legacy, indexed bool
	if err := s.read.QueryRow(`SELECT EXISTS(SELECT 1 FROM fleet_operations WHERE status NOT IN ('succeeded','failed') AND request LIKE '%' || ? || '%')`, id).Scan(&legacy); err != nil {
		t.Fatal(err)
	}
	if err := s.read.QueryRow(`SELECT EXISTS(`+historyPendingOperation+`)`, id).Scan(&indexed); err != nil {
		t.Fatal(err)
	}
	if indexed != legacy {
		t.Fatalf("legacy uppercase backfill: old=%t indexed=%t", legacy, indexed)
	}
}
