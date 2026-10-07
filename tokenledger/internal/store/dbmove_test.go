package store

// ccquota db migrate / verify (claude-fleet#2122). These run on the Postgres
// leg only — a move needs a Postgres target; the SQLite leg has none.

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// moveTarget is a fresh Postgres schema for one test, or a skip on the SQLite
// leg.
func moveTarget(t *testing.T) string {
	t.Helper()
	u := dbURL(filepath.Join(t.TempDir(), "target.db"))
	if u == "" {
		t.Skip("a move needs a Postgres target (" + envDBURL + ")")
	}
	return u
}

type fillCol struct {
	name, typ string
	notNull   bool
	pk        int
}

// prodShapedSource is a hub database the way production's looks: the full
// schema with the fleet module on, and rows in EVERY table — written by a
// generic filler that reads the schema, so a table added later is covered
// without anyone remembering to. Values are deliberately awkward: ids past
// 2^31, unicode, quotes and newlines, NULLs, blobs, an AUTOINCREMENT
// high-water mark above the largest id left (rows deleted).
func prodShapedSource(t *testing.T) (path string, rows map[string]int64) {
	t.Helper()
	path = filepath.Join(t.TempDir(), "ccquota.db")
	st, err := openSQLite(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	st.Close()

	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(0)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	tables, err := sqliteDialect.tables(db)
	if err != nil {
		t.Fatal(err)
	}
	order, err := parentsFirst(db, tables)
	if err != nil {
		t.Fatal(err)
	}
	cols := map[string][]fillCol{}
	fks := map[string]map[string][2]string{} // table → column → (parent table, parent column)
	for _, tb := range tables {
		r, err := db.Query(`SELECT name, type, "notnull", pk FROM pragma_table_info(?)`, tb)
		if err != nil {
			t.Fatal(err)
		}
		for r.Next() {
			var c fillCol
			if err := r.Scan(&c.name, &c.typ, &c.notNull, &c.pk); err != nil {
				t.Fatal(err)
			}
			cols[tb] = append(cols[tb], c)
		}
		r.Close()
		fl, err := sqliteDialect.foreignKeys(db, tb)
		if err != nil {
			t.Fatal(err)
		}
		fks[tb] = map[string][2]string{}
		for _, fk := range fl {
			for i, from := range fk.from {
				to := fk.to[i]
				if to == "" { // the parent's primary key
					for _, pc := range cols[fk.table] {
						if pc.pk == i+1 {
							to = pc.name
						}
					}
				}
				fks[tb][from] = [2]string{fk.table, to}
			}
		}
	}
	var gen func(tb, col string, i int, nulls bool) any
	gen = func(tb, col string, i int, nulls bool) any {
		if p, ok := fks[tb][col]; ok {
			return gen(p[0], p[1], i, false)
		}
		var c fillCol
		for _, x := range cols[tb] {
			if x.name == col {
				c = x
			}
		}
		if nulls && !c.notNull && c.pk == 0 {
			return nil
		}
		typ := strings.ToUpper(c.typ)
		switch {
		case strings.Contains(typ, "INT"):
			if c.pk > 0 {
				return int64(i)
			}
			return int64(i) * 3_000_000_019
		case strings.Contains(typ, "REAL"):
			return float64(i) + 0.1
		case strings.Contains(typ, "BLOB"):
			return []byte{0, 1, 0xff, byte(i)}
		}
		return fmt.Sprintf("%s.%s-%d 中文 \"q\" 'x'\n✓", tb, col, i)
	}
	for _, tb := range order {
		for i := 1; i <= 4; i++ {
			var names, marks []string
			var args []any
			for _, c := range cols[tb] {
				names = append(names, quoteIdent(c.name))
				marks = append(marks, "?")
				args = append(args, gen(tb, c.name, i, i == 4))
			}
			// OR IGNORE: a CHECK (id = 1) table keeps its one legal row.
			if _, err := db.Exec(`INSERT OR IGNORE INTO `+quoteIdent(tb)+` (`+strings.Join(names, ", ")+`) VALUES (`+strings.Join(marks, ", ")+`)`, args...); err != nil {
				t.Fatalf("fill %s: %v", tb, err)
			}
		}
	}
	// A deleted row above the survivors: the sequence must not hand its id out
	// again (SQLite's AUTOINCREMENT would not).
	if _, err := db.Exec(`UPDATE sqlite_sequence SET seq = seq + 1000`); err != nil {
		t.Fatal(err)
	}
	rows = map[string]int64{}
	for _, tb := range tables {
		var n int64
		if err := db.QueryRow(`SELECT COUNT(*) FROM ` + quoteIdent(tb)).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 0 {
			t.Fatalf("the filler left %s empty: every table must hold data", tb)
		}
		rows[tb] = n
	}
	if fk, err := db.Query(`PRAGMA foreign_key_check`); err != nil {
		t.Fatal(err)
	} else {
		bad := fk.Next()
		fk.Close()
		if bad {
			t.Fatal("the filler wrote a dangling foreign key")
		}
	}
	return path, rows
}

func moveConn(t *testing.T, url string) *pgx.Conn {
	t.Helper()
	c, err := pgx.Connect(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close(context.Background()) })
	return c
}

func TestMoveDatabaseCopiesAndVerifiesEveryTable(t *testing.T) {
	to := moveTarget(t)
	from, rows := prodShapedSource(t)
	ctx := context.Background()

	var out bytes.Buffer
	rep, err := MoveDatabase(ctx, MoveOptions{From: "sqlite://" + from, To: to, Verify: true, Out: &out})
	if err != nil {
		t.Fatalf("migrate: %v\n%s", err, out.String())
	}
	if !rep.Verified || len(rep.Differ) > 0 || len(rep.Tables) != len(rows) {
		t.Fatalf("verify: %d tables, differ %v\n%s", len(rep.Tables), rep.Differ, out.String())
	}
	for _, c := range rep.Tables {
		if c.SrcRows != rows[c.Table] || !c.OK() {
			t.Errorf("%s: %+v, source has %d", c.Table, c, rows[c.Table])
		}
	}
	if strings.Contains(out.String(), "ci-only") || strings.Contains(out.String(), "中文") {
		t.Errorf("the report printed a password or a row value:\n%s", out.String())
	}

	// verify on its own agrees, and so does a hub opened on the target.
	out.Reset()
	if rep, err := VerifyDatabase(ctx, from, to, &out); err != nil || len(rep.Differ) > 0 {
		t.Fatalf("verify: %v %v\n%s", err, rep, out.String())
	}

	// Every identity sequence is past the largest id ever handed out.
	c := moveConn(t, to)
	r, err := c.Query(ctx, `SELECT c.relname, a.attname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
		WHERE a.attidentity <> '' AND c.relnamespace = current_schema()::regnamespace AND c.relname <> $1`, moveLogTable)
	if err != nil {
		t.Fatal(err)
	}
	type ident struct{ tb, col string }
	var ids []ident
	for r.Next() {
		var x ident
		r.Scan(&x.tb, &x.col)
		ids = append(ids, x)
	}
	r.Close()
	if len(ids) == 0 {
		t.Fatal("no identity column found to check")
	}
	src, _ := sql.Open("sqlite", from)
	defer src.Close()
	for _, x := range ids {
		var next, seq int64
		if err := c.QueryRow(ctx, `SELECT nextval(pg_get_serial_sequence($1, $2))`, quoteIdent(x.tb), x.col).Scan(&next); err != nil {
			t.Fatal(err)
		}
		src.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name = ?`, x.tb).Scan(&seq)
		var top int64
		src.QueryRow(`SELECT COALESCE(MAX(` + quoteIdent(x.col) + `), 0) FROM ` + quoteIdent(x.tb)).Scan(&top)
		if next <= top || next <= seq {
			t.Errorf("%s.%s: next id %d, but %d (max) / %d (sqlite_sequence) were handed out", x.tb, x.col, next, top, seq)
		}
	}

	// One changed character in one row is a DIFF on that table, and only it.
	if _, err := c.Exec(ctx, `UPDATE endpoints SET label = label || '!' WHERE endpoint_id = (SELECT MIN(endpoint_id) FROM endpoints)`); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	rep, err = VerifyDatabase(ctx, from, to, &out)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Differ) != 1 || rep.Differ[0] != "endpoints" {
		t.Fatalf("verify after a tampered row: differ %v\n%s", rep.Differ, out.String())
	}
	t.Logf("verify after tampering:\n%s", out.String())

	// A hub opens the moved database (it closes the relays left open — its
	// own write, after the verify).
	st, err := openStore(postgresDialect, to, "postgres")
	if err != nil {
		t.Fatalf("a hub opens the moved database: %v", err)
	}
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	st.Close()
}

func TestMoveDatabaseKilledHalfwayLeavesNothingAndRerunsClean(t *testing.T) {
	to := moveTarget(t)
	from, _ := prodShapedSource(t)
	ctx := context.Background()

	n := 0
	killed := errors.New("killed")
	_, err := MoveDatabase(ctx, MoveOptions{From: from, To: to, afterTable: func(string) error {
		if n++; n == 5 {
			return killed
		}
		return nil
	}})
	if !errors.Is(err, killed) {
		t.Fatalf("migrate = %v, want the kill", err)
	}
	// Nothing landed: no record of a move, no rows outside the seeded tables.
	c := moveConn(t, to)
	var tx pgx.Tx
	if tx, err = c.Begin(ctx); err != nil {
		t.Fatal(err)
	}
	if err := moveGuard(ctx, tx, false); err != nil {
		t.Fatalf("after a killed move the target should still read empty: %v", err)
	}
	tx.Rollback(ctx)

	// A killed CONNECTION (the process gone): cancel mid-copy.
	cctx, cancel := context.WithCancel(ctx)
	n = 0
	_, err = MoveDatabase(cctx, MoveOptions{From: from, To: to, afterTable: func(string) error {
		if n++; n == 3 {
			cancel()
		}
		return nil
	}})
	if err == nil {
		t.Fatal("a cancelled move reported success")
	}

	var out bytes.Buffer
	rep, err := MoveDatabase(ctx, MoveOptions{From: from, To: to, Verify: true, Out: &out})
	if err != nil || len(rep.Differ) > 0 {
		t.Fatalf("rerun: %v %v\n%s", err, rep, out.String())
	}
}

func TestMoveDatabaseRefusesAUsedTarget(t *testing.T) {
	to := moveTarget(t)
	from, _ := prodShapedSource(t)
	ctx := context.Background()
	if _, err := MoveDatabase(ctx, MoveOptions{From: from, To: to}); err != nil {
		t.Fatal(err)
	}
	_, err := MoveDatabase(ctx, MoveOptions{From: from, To: to})
	if err == nil || !strings.Contains(err.Error(), "finished move") {
		t.Fatalf("second move = %v, want a refusal naming the finished move", err)
	}
	if _, err := MoveDatabase(ctx, MoveOptions{From: from, To: to, Overwrite: true, Verify: true}); err != nil {
		t.Fatalf("--overwrite: %v", err)
	}

	// A target a hub has written to (no move record) is refused too.
	to2 := moveTarget(t)
	st, err := openStore(postgresDialect, to2, "postgres")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("m1", "", "tok-hash"); err != nil {
		t.Fatal(err)
	}
	st.Close()
	_, err = MoveDatabase(ctx, MoveOptions{From: from, To: to2})
	if err == nil || !strings.Contains(err.Error(), "not empty") {
		t.Fatalf("move onto a used target = %v, want refusal", err)
	}
}

func TestMoveDatabaseDryRunKeepsNothing(t *testing.T) {
	to := moveTarget(t)
	from, rows := prodShapedSource(t)
	ctx := context.Background()
	var out bytes.Buffer
	rep, err := MoveDatabase(ctx, MoveOptions{From: from, To: to, DryRun: true, Verify: true, Out: &out})
	if err != nil || len(rep.Differ) > 0 || len(rep.Tables) != len(rows) {
		t.Fatalf("dry run: %v %+v\n%s", err, rep, out.String())
	}
	if !strings.Contains(out.String(), "rolled back") {
		t.Errorf("dry run does not say it rolled back:\n%s", out.String())
	}
	c := moveConn(t, to)
	tx, err := c.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if err := moveGuard(ctx, tx, false); err != nil {
		t.Fatalf("the dry run left data behind: %v", err)
	}
	// verify against the untouched target reports the difference.
	out.Reset()
	rep, err = VerifyDatabase(ctx, from, to, &out)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Differ) == 0 {
		t.Fatalf("verify against an empty target found no difference:\n%s", out.String())
	}
}

// A source an older hub left (a numbered migration not run on it) is refused
// before the target is touched, with the command that brings it up to date.
func TestMoveDatabaseRefusesAnOutdatedSource(t *testing.T) {
	to := moveTarget(t)
	from, _ := prodShapedSource(t)
	db, err := sql.Open("sqlite", from)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`DELETE FROM hub_migrations`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	_, err = MoveDatabase(context.Background(), MoveOptions{From: from, To: to})
	if err == nil || !strings.Contains(err.Error(), "--migrate-only") {
		t.Fatalf("move of an outdated source = %v, want the --migrate-only refusal", err)
	}
}

func TestConvertValueNeverChangesAValue(t *testing.T) {
	ok := []struct {
		v    any
		k    colKind
		want any
	}{
		{int64(3_000_000_019), kindInt, int64(3_000_000_019)},
		{float64(7), kindInt, int64(7)},
		{int64(2), kindFloat, float64(2)},
		{[]byte("x"), kindText, "x"},
		{"y", kindBytes, []byte("y")},
		{nil, kindText, nil},
	}
	for _, c := range ok {
		got, err := convertValue(c.v, c.k)
		if err != nil || fmt.Sprint(got) != fmt.Sprint(c.want) {
			t.Errorf("convertValue(%#v, %d) = %#v, %v", c.v, c.k, got, err)
		}
	}
	for _, c := range []struct {
		v any
		k colKind
	}{
		{1.5, kindInt}, {"7", kindInt}, {"a\x00b", kindText}, {"\xff", kindText},
	} {
		if _, err := convertValue(c.v, c.k); err == nil {
			t.Errorf("convertValue(%#v, %d) changed the value instead of refusing", c.v, c.k)
		}
	}
	if MoveSourcePath("sqlite:///data/ccquota.db") != "/data/ccquota.db" || MoveSourcePath("/x.db") != "/x.db" {
		t.Error("MoveSourcePath")
	}
}

func TestSetReadOnlyRefusesWritesKeepsReads(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "ro.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Enroll("m1", "", "tok-hash"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetReadOnly(); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("m2", "", "tok-hash-2"); err == nil {
		t.Fatal("a write succeeded on a read-only store")
	}
	_, err = st.EnrollmentCounts()
	if err != nil {
		t.Fatalf("read on a read-only store: %v", err)
	}
}
