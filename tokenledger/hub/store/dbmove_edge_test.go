package store

import (
	"bytes"
	"context"
	"database/sql"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// workerRecordEdgeSource is a hub database whose fleet_worker_records holds,
// one per row, every awkward content a hub's SQLite can: NULL, an empty BLOB,
// bytes, non-UTF-8 bytes, a NUL inside text, TEXT stored in the BLOB column
// (type affinity keeps it TEXT), an empty TEXT. extra runs on the file after.
func workerRecordEdgeSource(t *testing.T, extra ...string) string {
	t.Helper()
	from := filepath.Join(t.TempDir(), "ccquota.db")
	st, err := openSQLite(from)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 7, 20, 15, 0, 0, time.UTC)
	base := FleetWorkerRecord{WorkerID: "w", FleetID: "f", Owner: "o", EndpointID: "e", Repo: "r", Kind: "evidence", Name: "n", CreatedAt: now}
	var recs []FleetWorkerRecord
	for i, c := range [][]byte{nil, {}, []byte("plain"), {0, 1, 0xff, 0xfe}, []byte("中文\x00tail")} {
		r := base
		r.ID = string(rune('a' + i))
		r.Content = c
		recs = append(recs, r)
	}
	if err := st.PutWorkerRecords(recs); err != nil {
		t.Fatal(err)
	}
	st.Close()
	db, err := sql.Open("sqlite", from)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ins := `INSERT INTO fleet_worker_records (id, worker_id, fleet_id, owner, endpoint_id, repo, kind, name, content, size, created_at)
		VALUES (?,'w','f','o','e','r','history','h', %s, 0, '2026-10-07T20:15:00Z')`
	for id, v := range map[string]string{"t1": `CAST('as text' AS TEXT)`, "t2": `''`, "t3": `X''`, "t4": `CAST(X'00ff41' AS TEXT)`} {
		if _, err := db.Exec(strings.Replace(ins, "%s", v, 1), id); err != nil {
			t.Fatal(err)
		}
	}
	for _, q := range extra {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	return from
}

// claude-fleet#2216: the 2026-10-07 production rehearsal moved
// fleet_worker_records with the same count and a different digest — an empty
// BLOB arrived as NULL. Every edge value moves as it is: verify finds 0
// differ, and the hub's own read (WorkerRecords) answers the same on both.
func TestMoveDatabaseWorkerRecordEdgeValues(t *testing.T) {
	to := moveTarget(t)
	from := workerRecordEdgeSource(t)
	ctx := context.Background()
	var out bytes.Buffer
	rep, err := MoveDatabase(ctx, MoveOptions{From: from, To: to, Verify: true, Out: &out})
	if err != nil || len(rep.Differ) > 0 {
		t.Fatalf("move: %v, differ %v\n%s", err, rep, out.String())
	}

	src, err := openSQLite(from)
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()
	dst, err := openStore(postgresDialect, to, "postgres")
	if err != nil {
		t.Fatal(err)
	}
	defer dst.Close()
	q := WorkerRecordQuery{Owner: "o", Content: true}
	a, err := src.WorkerRecords(q)
	if err != nil {
		t.Fatal(err)
	}
	b, err := dst.WorkerRecords(q)
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 9 || !reflect.DeepEqual(a, b) {
		t.Fatalf("the hub reads differently after the move:\nsqlite   %+v\npostgres %+v", a, b)
	}
	// The bytes themselves: NULL stays NULL, empty stays empty.
	var nulls, empties int
	if err := moveConn(t, to).QueryRow(ctx, `SELECT COUNT(*) FILTER (WHERE content IS NULL),
		COUNT(*) FILTER (WHERE content = ''::bytea) FROM fleet_worker_records`).Scan(&nulls, &empties); err != nil {
		t.Fatal(err)
	}
	if nulls != 1 || empties != 3 {
		t.Fatalf("target holds %d NULL and %d empty contents, want 1 and 3", nulls, empties)
	}
}

// A NUL byte or invalid UTF-8 in a TEXT column is something Postgres text
// cannot hold: the move refuses, naming the table and column, rather than
// changing the value.
func TestMoveDatabaseRefusesUnstorableText(t *testing.T) {
	to := moveTarget(t)
	for name, v := range map[string]string{"nul": `'a' || CHAR(0) || 'b'`, "non-utf8": `CAST(X'ff41' AS TEXT)`} {
		t.Run(name, func(t *testing.T) {
			from := workerRecordEdgeSource(t, `UPDATE fleet_worker_records SET note = `+v+` WHERE id = 'c'`)
			_, err := MoveDatabase(context.Background(), MoveOptions{From: from, To: to, Overwrite: true})
			if err == nil || !strings.Contains(err.Error(), "fleet_worker_records") || !strings.Contains(err.Error(), "note") {
				t.Fatalf("want a refusal naming fleet_worker_records.note, got %v", err)
			}
		})
	}
}
