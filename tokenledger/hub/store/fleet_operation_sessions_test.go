package store

import (
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

func TestOperationSessionBackfillAndExpiry(t *testing.T) {
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
	if err != nil || n != 5 {
		t.Fatalf("expired=%d err=%v", n, err)
	}
	if n, err = s.ExpireFleetOperations(now); err != nil || n != 0 {
		t.Fatalf("repeat=%d err=%v", n, err)
	}
	if err := s.UpdateFleetOperation("accepted", "running", "{}", now); err != nil {
		t.Fatal(err)
	}
	// Old replicas and specialized writers cannot resurrect an expired row.
	if _, err := s.write.Exec(`UPDATE fleet_operations SET status='running',result='{}' WHERE id='recorded'`); err != nil {
		t.Fatal(err)
	}
	for _, status := range []string{"recorded", "accepted", "running", "unknown", "pending"} {
		op, err := s.FleetOperation(status)
		if err != nil || op.Status != "expired" || op.Result != `{"proof":"kept"}` {
			t.Fatalf("lost receipt: %+v %v", op, err)
		}
	}
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action='operation_expire'`).Scan(&count); err != nil || count != 5 {
		t.Fatalf("audit=%d %v", count, err)
	}
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operation_sessions WHERE session_id=? AND status NOT IN ('succeeded','failed','expired')`, b).Scan(&count); err != nil || count != 1 {
		t.Fatalf("fresh operation hidden: %d %v", count, err)
	}
	if err := s.UpdateFleetOperation("fresh", "succeeded", "{}", now); err != nil {
		t.Fatal(err)
	}
	if err := s.ReconcileFleetOperation(fresh, "running", "{}", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := s.TouchUnfinishedOperation("fresh", now.Add(time.Hour)); err != nil {
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
	if !strings.Contains(plan.String(), "fleet_operation_sessions_pending") || strings.Contains(plan.String(), "Seq Scan on fleet_operation_sessions") || strings.Contains(plan.String(), "fleet_operations") {
		t.Fatalf("full scan: %s", plan.String())
	}
}
