package store

// Moving a hub's database from SQLite to Postgres in one go (claude-fleet#2122,
// EPIC #2119 C3): `ccquota db migrate` and `ccquota db verify`.
//
// The whole copy is ONE Postgres transaction. That is what makes a move safe to
// interrupt: a move killed half way (the process, the pod, the network) leaves
// the target exactly as it was, and running it again is a clean start — there
// is no half-copied state to resume from, so nothing has to know how to. A dry
// run is the same transaction rolled back at the end, after the verify ran
// inside it: the rehearsal copies and checks every row the real move would, and
// the target keeps nothing (bar the empty schema a hub would create anyway).
//
// The source is read inside one SQLite read transaction too, so every table
// comes from the same instant even if something still writes the file — though
// the runbook puts the hub in read-only mode first (CCQUOTA_READONLY=1), since
// a write after that instant would not be in the copy.
//
// Verify is per table: the row count and a SHA-256 over every row in primary-key
// order, each value normalised to the TARGET column's type on both sides (a
// SQLite INTEGER and a Postgres BIGINT holding 7 hash the same). It never prints
// a value — only names, counts and digests — so a credential in a row cannot
// reach a log through it, and the connection string is printed as host/database
// only.

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// moveLogTable is the target's record of a finished move. It is what tells a
// second `migrate` that the target is no longer an empty database (the hub may
// have been writing to it since) — the copy refuses to overwrite it unless told.
const moveLogTable = "db_move_log"

// moveSeedTables are the tables a fresh Open writes into by itself (the
// numbered-migration record and the rollup's version stamps). Rows there do not
// make a target "already in use"; rows anywhere else do.
var moveSeedTables = map[string]bool{"hub_migrations": true, "rollup_meta": true}

// MoveOptions is one `ccquota db migrate`.
type MoveOptions struct {
	From      string    // the SQLite file (a path, or sqlite:///path)
	To        string    // the Postgres connection string
	DryRun    bool      // copy + (verify) inside the transaction, then roll back
	Verify    bool      // compare every table inside the same transaction
	Overwrite bool      // replace a target that already holds data
	Out       io.Writer // the per-table report; nil = discard

	// afterTable runs after each table is copied; an error aborts the move
	// there. The tests' stand-in for a move killed half way.
	afterTable func(table string) error
}

// TableCheck is one table's line in a move or a verify.
type TableCheck struct {
	Table            string
	SrcRows, DstRows int64
	SrcHash, DstHash string
}

// OK says whether the two sides hold the same rows.
func (c TableCheck) OK() bool { return c.SrcRows == c.DstRows && c.SrcHash == c.DstHash }

// MoveReport is what a move or a verify found.
type MoveReport struct {
	Tables   []TableCheck // verified tables, in copy order (empty without a verify)
	Copied   int          // tables copied
	Rows     int64        // rows copied
	Differ   []string     // tables whose count or digest differ (and target-only tables holding rows)
	Verified bool
}

// MoveSourcePath turns --from into a file path: sqlite:///data/x.db and
// /data/x.db are the same file.
func MoveSourcePath(s string) string {
	for _, p := range []string{"sqlite://", "sqlite:"} {
		if strings.HasPrefix(s, p) {
			return strings.TrimPrefix(s, p)
		}
	}
	return s
}

// MoveDatabase copies the SQLite database at o.From into the Postgres database
// at o.To. See the file comment for the guarantees.
func MoveDatabase(ctx context.Context, o MoveOptions) (*MoveReport, error) {
	out := o.Out
	if out == nil {
		out = io.Discard
	}
	start := time.Now()
	if !isPostgresURL(o.To) {
		return nil, errors.New("--to must be a postgres:// connection string")
	}
	srcPath := MoveSourcePath(o.From)
	src, err := openMoveSource(srcPath)
	if err != nil {
		return nil, err
	}
	defer src.Close()
	srcTx, err := src.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", srcPath, err)
	}
	defer srcTx.Rollback()
	srcTables, err := sqliteDialect.tables(srcTx)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", srcPath, err)
	}

	if err := sourceIsCurrent(srcTx); err != nil {
		return nil, err
	}

	// The target's schema is the hub's own, created the way a hub creates it —
	// with the fleet tables too when the source has them.
	if err := prepareMoveTarget(o.To, srcTables); err != nil {
		return nil, err
	}

	conn, name, err := connectMoveTarget(ctx, o.To)
	if err != nil {
		return nil, err
	}
	defer conn.Close(context.Background())
	mode := ""
	if o.DryRun {
		mode = "  (dry run: everything is rolled back at the end)"
	}
	fmt.Fprintf(out, "migrate: sqlite %s → postgres %s%s\n", srcPath, name, mode)

	tx, err := conn.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin on %s: %w", name, err)
	}
	defer tx.Rollback(context.Background())

	plans, err := planMove(ctx, srcTx, tx, srcTables)
	if err != nil {
		return nil, err
	}
	if err := moveGuard(ctx, tx, o.Overwrite); err != nil {
		return nil, err
	}

	if _, err := tx.Exec(ctx, `SET CONSTRAINTS ALL DEFERRED`); err != nil {
		return nil, err
	}
	idents := make([]string, len(plans))
	for i, p := range plans {
		idents[i] = quoteIdent(p.dstTable)
	}
	if len(idents) > 0 {
		if _, err := tx.Exec(ctx, `TRUNCATE `+strings.Join(idents, ", ")+` RESTART IDENTITY`); err != nil {
			return nil, fmt.Errorf("empty the target tables: %w", err)
		}
	}

	// Secondary indexes are dropped for the copy and rebuilt once at the end
	// (claude-fleet#2216): one sort per index instead of a b-tree insert per
	// row. Inside the same transaction, so a rollback puts them back too.
	idx, err := dropSecondaryIndexes(ctx, tx, plans)
	if err != nil {
		return nil, err
	}

	rep := &MoveReport{}
	srcHashes := map[string]TableCheck{}
	fmt.Fprintf(out, "copy:\n")
	for _, p := range plans {
		t0 := time.Now()
		var sh *rowHasher
		if o.Verify {
			sh = newRowHasher(p.kinds)
		}
		n, err := copyTable(ctx, srcTx, tx, p, sh)
		if err != nil {
			return nil, fmt.Errorf("copy %s: %w", p.table, err)
		}
		if sh != nil {
			srcHashes[p.table] = TableCheck{Table: p.table, SrcRows: n, SrcHash: sh.sum()}
		}
		if err := alignIdentities(ctx, srcTx, tx, p); err != nil {
			return nil, fmt.Errorf("align %s's sequence: %w", p.table, err)
		}
		rep.Copied++
		rep.Rows += n
		fmt.Fprintf(out, "  %-34s %12d rows  %6.1fs\n", p.table, n, time.Since(t0).Seconds())
		if o.afterTable != nil {
			if err := o.afterTable(p.table); err != nil {
				return nil, err
			}
		}
	}
	if _, err := tx.Exec(ctx, `SET CONSTRAINTS ALL IMMEDIATE`); err != nil {
		return nil, fmt.Errorf("foreign keys: %w", err)
	}
	// After the foreign keys: Postgres builds no index on a table with
	// deferred checks still pending.
	t0 := time.Now()
	if _, err := tx.Exec(ctx, `SET LOCAL maintenance_work_mem = '256MB'`); err != nil {
		return nil, err
	}
	for _, def := range idx {
		if _, err := tx.Exec(ctx, def); err != nil {
			return nil, fmt.Errorf("rebuild an index: %w", err)
		}
	}
	fmt.Fprintf(out, "  %-34s %12d built %6.1fs\n", "(indexes)", len(idx), time.Since(t0).Seconds())

	if o.Verify {
		if err := verifyPlans(ctx, srcTx, tx, plans, srcHashes, rep, out); err != nil {
			return nil, err
		}
	}

	if o.DryRun {
		if err := tx.Rollback(ctx); err != nil {
			return nil, err
		}
		fmt.Fprintf(out, "migrate: dry run — %d table(s), %d row(s) copied in %.1fs, rolled back; the target holds no data from it\n",
			rep.Copied, rep.Rows, time.Since(start).Seconds())
		return rep, nil
	}
	if len(rep.Differ) > 0 {
		return rep, fmt.Errorf("verify: %d table(s) differ (%s) — rolled back, the target is unchanged",
			len(rep.Differ), strings.Join(rep.Differ, ", "))
	}
	if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS `+moveLogTable+` (
		id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
		finished_at TEXT NOT NULL,
		source      TEXT NOT NULL,
		tables      BIGINT NOT NULL,
		rows_copied BIGINT NOT NULL)`); err != nil {
		return nil, fmt.Errorf("record the move: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO `+moveLogTable+` (finished_at, source, tables, rows_copied) VALUES ($1, $2, $3, $4)`,
		fmtTime(time.Now()), srcPath, rep.Copied, rep.Rows); err != nil {
		return nil, fmt.Errorf("record the move: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit: %w", err)
	}
	fmt.Fprintf(out, "migrate: committed — %d table(s), %d row(s) in %.1fs\n", rep.Copied, rep.Rows, time.Since(start).Seconds())
	return rep, nil
}

// VerifyDatabase compares the SQLite database at from with the Postgres
// database at to, table by table, reading both in one consistent snapshot. It
// writes nothing to either.
func VerifyDatabase(ctx context.Context, from, to string, out io.Writer) (*MoveReport, error) {
	if out == nil {
		out = io.Discard
	}
	if !isPostgresURL(to) {
		return nil, errors.New("--to must be a postgres:// connection string")
	}
	srcPath := MoveSourcePath(from)
	src, err := openMoveSource(srcPath)
	if err != nil {
		return nil, err
	}
	defer src.Close()
	srcTx, err := src.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", srcPath, err)
	}
	defer srcTx.Rollback()
	srcTables, err := sqliteDialect.tables(srcTx)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", srcPath, err)
	}
	conn, name, err := connectMoveTarget(ctx, to)
	if err != nil {
		return nil, err
	}
	defer conn.Close(context.Background())
	fmt.Fprintf(out, "verify: sqlite %s ↔ postgres %s\n", srcPath, name)
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("begin on %s: %w", name, err)
	}
	defer tx.Rollback(context.Background())
	plans, err := planMove(ctx, srcTx, tx, srcTables)
	if err != nil {
		return nil, err
	}
	rep := &MoveReport{}
	if err := verifyPlans(ctx, srcTx, tx, plans, nil, rep, out); err != nil {
		return nil, err
	}
	return rep, nil
}

// ---- the two ends -----------------------------------------------------------

// openMoveSource opens the SQLite file read-only. It never creates one: a
// typo'd --from must not "move" an empty database over a real one.
func openMoveSource(path string) (*sql.DB, error) {
	if path == "" {
		return nil, errors.New("--from is empty")
	}
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("source database: %w", err)
	}
	// A big page cache and the file mapped: the copy reads every page once,
	// and a read() per page was most of the source side's time (#2216).
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(5000)"+
		"&_pragma=cache_size(-262144)&_pragma=mmap_size(4294967296)")
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

// sourceIsCurrent refuses a source an older hub left behind: a numbered
// migration this binary knows has not run on it, so its tables are not the
// ones the target gets (migration 1 drops eight). A hub of this version runs
// them at its start; on a copy, `ccquota hub --migrate-only --db <copy>` does.
func sourceIsCurrent(srcTx *sql.Tx) error {
	done := map[int]bool{}
	if has, err := sqliteDialect.tableExists(srcTx, "hub_migrations"); err != nil {
		return err
	} else if has {
		rows, err := srcTx.Query(`SELECT id FROM hub_migrations`)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id int
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			done[id] = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}
	for _, m := range migrations {
		if !done[m.ID] {
			return fmt.Errorf("the source predates hub migration %d (%s): run `ccquota hub --migrate-only --db <file>` on it "+
				"(a hub of this version does that at its start), then move it", m.ID, m.Name)
		}
	}
	return nil
}

// prepareMoveTarget creates the hub's schema on the target, as `ccquota hub`
// would on its first start there (the fleet tables only when the source has
// them, as a hub creates them only with the fleet module on).
func prepareMoveTarget(url string, srcTables []string) error {
	st, err := openStore(postgresDialect, url, "postgres")
	if err != nil {
		return err
	}
	defer st.Close()
	have, err := st.d.tables(st.write)
	if err != nil {
		return err
	}
	if len(missing(srcTables, have)) == 0 {
		return nil
	}
	return st.EnsureNodes()
}

// connectMoveTarget connects to the target, returning a printable name for it
// (host/database — never the connection string, which carries the password).
func connectMoveTarget(ctx context.Context, url string) (*pgx.Conn, string, error) {
	cfg, err := pgx.ParseConfig(url)
	if err != nil {
		// pgx's message quotes the connection string, password and all.
		return nil, "", errors.New("--to: not a valid postgres:// connection string")
	}
	name := cfg.Host + "/" + cfg.Database
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, name, fmt.Errorf("connect to %s: %w", name, err)
	}
	return conn, name, nil
}

// ---- the plan -----------------------------------------------------------------

type colKind int

const (
	kindInt colKind = iota
	kindFloat
	kindText
	kindBytes
	kindBool
)

// movePlan is one table: which columns go where, as what, in which order.
type movePlan struct {
	table, dstTable  string
	srcCols, dstCols []string
	kinds            []colKind
	orderBy          []int    // indexes into the columns: the primary key, else all
	identity         []string // the target's identity columns
}

// planMove matches every source table to its target table, parents first.
// A source table or column the target lacks is an error: copying around it
// would drop data without saying so.
func planMove(ctx context.Context, srcTx *sql.Tx, tx pgx.Tx, srcTables []string) ([]movePlan, error) {
	dstTables, err := pgStrings(ctx, tx, `SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename`)
	if err != nil {
		return nil, err
	}
	dstByLower := map[string]string{}
	for _, t := range dstTables {
		dstByLower[strings.ToLower(t)] = t
	}
	if m := missing(srcTables, dstTables); len(m) > 0 {
		return nil, fmt.Errorf("the target has no table for %s — is this binary older than the hub that wrote the source?", strings.Join(m, ", "))
	}

	order, err := parentsFirst(srcTx, srcTables)
	if err != nil {
		return nil, err
	}
	var plans []movePlan
	for _, t := range order {
		p := movePlan{table: t, dstTable: dstByLower[strings.ToLower(t)]}
		srcCols, err := sqliteDialect.columns(srcTx, t)
		if err != nil {
			return nil, err
		}
		dst, err := pgColumns(ctx, tx, p.dstTable)
		if err != nil {
			return nil, err
		}
		var pk []struct{ pos, idx int }
		for i, c := range srcCols {
			d, ok := dst[strings.ToLower(c.name)]
			if !ok {
				return nil, fmt.Errorf("the target's %s has no column %s", p.dstTable, c.name)
			}
			k, err := kindOf(d.typ)
			if err != nil {
				return nil, fmt.Errorf("%s.%s: %w", t, c.name, err)
			}
			p.srcCols = append(p.srcCols, c.name)
			p.dstCols = append(p.dstCols, d.name)
			p.kinds = append(p.kinds, k)
			if c.pk > 0 {
				pk = append(pk, struct{ pos, idx int }{c.pk, i})
			}
			if d.identity {
				p.identity = append(p.identity, d.name)
			}
		}
		sort.Slice(pk, func(a, b int) bool { return pk[a].pos < pk[b].pos })
		for _, k := range pk {
			p.orderBy = append(p.orderBy, k.idx)
		}
		if len(p.orderBy) == 0 {
			for i := range p.srcCols {
				p.orderBy = append(p.orderBy, i)
			}
		}
		plans = append(plans, p)
	}
	return plans, nil
}

// parentsFirst orders tables so a table comes after every table its foreign
// keys point at (a cycle, or a self-reference, falls back to name order; the
// copy defers the foreign keys to the commit anyway).
func parentsFirst(q querier, tables []string) ([]string, error) {
	deps := map[string]map[string]bool{}
	in := map[string]bool{}
	for _, t := range tables {
		in[strings.ToLower(t)] = true
	}
	for _, t := range tables {
		fks, err := sqliteDialect.foreignKeys(q, t)
		if err != nil {
			return nil, err
		}
		deps[t] = map[string]bool{}
		for _, fk := range fks {
			if p := strings.ToLower(fk.table); in[p] && p != strings.ToLower(t) {
				deps[t][p] = true
			}
		}
	}
	sorted := append([]string(nil), tables...)
	sort.Strings(sorted)
	var out []string
	done := map[string]bool{}
	for len(out) < len(sorted) {
		progressed := false
		for _, t := range sorted {
			if done[strings.ToLower(t)] {
				continue
			}
			ready := true
			for p := range deps[t] {
				if !done[p] {
					ready = false
					break
				}
			}
			if ready {
				out = append(out, t)
				done[strings.ToLower(t)] = true
				progressed = true
			}
		}
		if !progressed { // a cycle: the rest in name order
			for _, t := range sorted {
				if !done[strings.ToLower(t)] {
					out = append(out, t)
					done[strings.ToLower(t)] = true
				}
			}
		}
	}
	return out, nil
}

type pgColumn struct {
	name, typ string
	identity  bool
}

func pgColumns(ctx context.Context, tx pgx.Tx, table string) (map[string]pgColumn, error) {
	rows, err := tx.Query(ctx, `
		SELECT a.attname, t.typname, a.attidentity <> ''
		FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
		WHERE a.attrelid = (SELECT c.oid FROM pg_class c
		                    WHERE c.relname = $1 AND c.relnamespace = current_schema()::regnamespace)
		  AND a.attnum > 0 AND NOT a.attisdropped`, table)
	if err != nil {
		return nil, fmt.Errorf("inspect %s: %w", table, err)
	}
	defer rows.Close()
	out := map[string]pgColumn{}
	for rows.Next() {
		var c pgColumn
		if err := rows.Scan(&c.name, &c.typ, &c.identity); err != nil {
			return nil, err
		}
		out[strings.ToLower(c.name)] = c
	}
	return out, rows.Err()
}

func kindOf(pgType string) (colKind, error) {
	switch pgType {
	case "int8", "int4", "int2":
		return kindInt, nil
	case "float8", "float4":
		return kindFloat, nil
	case "text", "varchar", "bpchar":
		return kindText, nil
	case "bytea":
		return kindBytes, nil
	case "bool":
		return kindBool, nil
	}
	return 0, fmt.Errorf("column type %s is not one the move knows how to copy", pgType)
}

// moveGuard refuses a target that already holds a finished move, or data
// anywhere but the tables a fresh hub seeds itself: once a hub has run on the
// target, copying the old file over it would throw away everything since.
func moveGuard(ctx context.Context, tx pgx.Tx, overwrite bool) error {
	if overwrite {
		return nil
	}
	tables, err := pgStrings(ctx, tx, `SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename`)
	if err != nil {
		return err
	}
	var used []string
	for _, t := range tables {
		if t == moveLogTable {
			var at, from string
			err := tx.QueryRow(ctx, `SELECT finished_at, source FROM `+moveLogTable+` ORDER BY id DESC LIMIT 1`).Scan(&at, &from)
			if err == nil {
				return fmt.Errorf("the target already holds a finished move (%s, from %s); a hub may have written to it since. "+
					"--overwrite replaces it", at, from)
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			continue
		}
		if moveSeedTables[t] {
			continue
		}
		var held bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM `+quoteIdent(t)+`)`).Scan(&held); err != nil {
			return err
		}
		if held {
			used = append(used, t)
		}
	}
	if len(used) > 0 {
		return fmt.Errorf("the target is not empty (%d table(s) hold rows: %s); --overwrite replaces it",
			len(used), strings.Join(used, ", "))
	}
	return nil
}

// ---- copy -------------------------------------------------------------------

// copyTable streams one table into the target with COPY. With sh set it reads
// in primary-key order and feeds every row to sh as it goes, so the verify
// needs no second pass over the source.
func copyTable(ctx context.Context, srcTx *sql.Tx, tx pgx.Tx, p movePlan, sh *rowHasher) (int64, error) {
	var order []int
	if sh != nil {
		order = p.orderBy
	}
	rows, err := srcTx.QueryContext(ctx, selectSQL(p.table, p.srcCols, order))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	vals := make([]any, len(p.srcCols))
	ptrs := make([]any, len(vals))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	var rowErr error
	src := pgx.CopyFromFunc(func() ([]any, error) {
		if !rows.Next() {
			if err := rows.Err(); err != nil {
				return nil, err
			}
			return nil, nil
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		out := make([]any, len(vals))
		for i, v := range vals {
			c, err := convertValue(v, p.kinds[i])
			if err != nil {
				rowErr = fmt.Errorf("column %s: %w", p.srcCols[i], err)
				return nil, rowErr
			}
			out[i] = c
		}
		if sh != nil {
			sh.add(out)
		}
		return out, nil
	})
	n, err := tx.CopyFrom(ctx, pgx.Identifier{p.dstTable}, p.dstCols, src)
	if rowErr != nil {
		return n, rowErr
	}
	return n, err
}

// alignIdentities moves each identity column's sequence past the highest id
// the table has ever handed out: the largest copied id, or SQLite's own
// AUTOINCREMENT high-water mark when rows above it were deleted (so an id is
// never reused, as SQLite would not have reused it).
func alignIdentities(ctx context.Context, srcTx *sql.Tx, tx pgx.Tx, p movePlan) error {
	for _, col := range p.identity {
		var top int64
		if err := tx.QueryRow(ctx, `SELECT COALESCE(MAX(`+quoteIdent(col)+`), 0) FROM `+quoteIdent(p.dstTable)).Scan(&top); err != nil {
			return err
		}
		if has, _ := sqliteDialect.tableExists(srcTx, "sqlite_sequence"); has {
			var seq sql.NullInt64
			err := srcTx.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name = ?`, p.table).Scan(&seq)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			if seq.Valid && seq.Int64 > top {
				top = seq.Int64
			}
		}
		var err error
		if top > 0 {
			_, err = tx.Exec(ctx, `SELECT setval(pg_get_serial_sequence($1, $2), $3, true)`, quoteIdent(p.dstTable), col, top)
		} else {
			_, err = tx.Exec(ctx, `SELECT setval(pg_get_serial_sequence($1, $2), 1, false)`, quoteIdent(p.dstTable), col)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// convertValue is a value as read from either side, in the target column's
// kind. A conversion that would change the value is an error, never a guess.
func convertValue(v any, k colKind) (any, error) {
	if v == nil {
		return nil, nil
	}
	switch k {
	case kindInt:
		switch x := v.(type) {
		case int64:
			return x, nil
		case int32:
			return int64(x), nil
		case int16:
			return int64(x), nil
		case bool:
			if x {
				return int64(1), nil
			}
			return int64(0), nil
		case float64:
			if x == math.Trunc(x) && math.Abs(x) < 1<<53 {
				return int64(x), nil
			}
		}
	case kindFloat:
		switch x := v.(type) {
		case float64:
			return x, nil
		case float32:
			return float64(x), nil
		case int64:
			return float64(x), nil
		}
	case kindText:
		var s string
		switch x := v.(type) {
		case string:
			s = x
		case []byte:
			s = string(x)
		case int64:
			s = strconv.FormatInt(x, 10)
		case float64:
			s = strconv.FormatFloat(x, 'g', -1, 64)
		default:
			return nil, fmt.Errorf("a %T where text belongs", v)
		}
		if strings.IndexByte(s, 0) >= 0 {
			return nil, errors.New("a text value holds a NUL byte, which Postgres text cannot store")
		}
		if !utf8.ValidString(s) {
			return nil, errors.New("a text value is not valid UTF-8, which Postgres text cannot store")
		}
		return s, nil
	case kindBytes:
		switch x := v.(type) {
		case []byte:
			// SQLite hands a zero-length BLOB back as a nil []byte inside a
			// non-nil interface; pgx writes a nil []byte as NULL. Empty stays
			// empty (claude-fleet#2216: the 2026-10-07 rehearsal turned every
			// empty fleet_worker_records.content into NULL).
			if x == nil {
				return []byte{}, nil
			}
			return x, nil
		case string:
			return []byte(x), nil
		}
	case kindBool:
		switch x := v.(type) {
		case bool:
			return x, nil
		case int64:
			return x != 0, nil
		}
	}
	return nil, fmt.Errorf("a %T cannot be stored in this column without changing it", v)
}

// ---- verify -----------------------------------------------------------------

// verifyPlans checks every table. src holds the source side already hashed
// during the copy (MoveDatabase); a table missing from it — every table, for
// VerifyDatabase — is read from the source here, beside the target's read.
func verifyPlans(ctx context.Context, srcTx *sql.Tx, tx pgx.Tx, plans []movePlan, src map[string]TableCheck,
	rep *MoveReport, out io.Writer) error {
	fmt.Fprintf(out, "verify:\n")
	seen := map[string]bool{}
	for _, p := range plans {
		seen[p.dstTable] = true
		t0 := time.Now()
		c, err := checkTable(ctx, srcTx, tx, p, src)
		if err != nil {
			return fmt.Errorf("verify %s: %w", p.table, err)
		}
		rep.Tables = append(rep.Tables, c)
		mark, rel := "ok  ", "="
		if !c.OK() {
			mark, rel = "DIFF", "≠"
			rep.Differ = append(rep.Differ, p.table)
		}
		hashes := c.SrcHash[:16]
		if c.SrcHash != c.DstHash {
			hashes += " ≠ " + c.DstHash[:16]
		}
		fmt.Fprintf(out, "  %s %-34s %12d %s %-12d %s %6.1fs\n", mark, p.table, c.SrcRows, rel, c.DstRows, hashes, time.Since(t0).Seconds())
	}
	// A table only the target has is fine while it is empty (a newer hub's
	// table, or the move's own record); rows in one did not come from here.
	dstTables, err := pgStrings(ctx, tx, `SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename`)
	if err != nil {
		return err
	}
	for _, t := range dstTables {
		if seen[t] || t == moveLogTable {
			continue
		}
		var n int64
		if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM `+quoteIdent(t)).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			rep.Differ = append(rep.Differ, t)
			fmt.Fprintf(out, "  DIFF %-34s only in the target, %d row(s)\n", t, n)
		}
	}
	rep.Verified = true
	fmt.Fprintf(out, "verify: %d table(s), %d match, %d differ\n", len(rep.Tables), len(rep.Tables)-countDiffer(rep), len(rep.Differ))
	return nil
}

func countDiffer(rep *MoveReport) int {
	n := 0
	for _, c := range rep.Tables {
		if !c.OK() {
			n++
		}
	}
	return n
}

// checkTable counts and digests one table on both sides, rows in primary-key
// order — the source from src when the copy already hashed it, else read here
// while the target is read.
func checkTable(ctx context.Context, srcTx *sql.Tx, tx pgx.Tx, p movePlan, src map[string]TableCheck) (TableCheck, error) {
	c, have := src[p.table]
	c.Table = p.table
	var srcErr error
	done := make(chan struct{})
	if have {
		close(done)
	} else {
		go func() {
			defer close(done)
			c.SrcRows, c.SrcHash, srcErr = hashSource(ctx, srcTx, p)
		}()
	}

	h := newRowHasher(p.kinds)
	var dstRows int64
	dstErr := func() error {
		rows, err := tx.Query(ctx, selectSQL(p.dstTable, p.dstCols, p.orderBy))
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			v, err := rows.Values()
			if err != nil {
				return err
			}
			if err := h.add(v); err != nil {
				return err
			}
			dstRows++
		}
		return rows.Err()
	}()
	<-done
	if srcErr != nil {
		return c, srcErr
	}
	if dstErr != nil {
		return c, dstErr
	}
	c.DstRows, c.DstHash = dstRows, h.sum()
	return c, nil
}

func hashSource(ctx context.Context, srcTx *sql.Tx, p movePlan) (int64, string, error) {
	h := newRowHasher(p.kinds)
	rows, err := srcTx.QueryContext(ctx, selectSQL(p.table, p.srcCols, p.orderBy))
	if err != nil {
		return 0, "", err
	}
	defer rows.Close()
	vals := make([]any, len(p.srcCols))
	ptrs := make([]any, len(vals))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	var n int64
	for rows.Next() {
		if err := rows.Scan(ptrs...); err != nil {
			return n, "", err
		}
		if err := h.add(vals); err != nil {
			return n, "", err
		}
		n++
	}
	if err := rows.Err(); err != nil {
		return n, "", err
	}
	return n, h.sum(), nil
}

// rowHasher is a table's SHA-256 over its rows, each value in the target
// column's kind and length-prefixed, so ("ab","c") and ("a","bc") never hash
// alike. One buffer is reused across rows: the hash runs over every row of a
// million-row table, and a formatted write per value cost as much as the copy.
type rowHasher struct {
	h     hash.Hash
	kinds []colKind
	buf   []byte
}

func newRowHasher(kinds []colKind) *rowHasher {
	return &rowHasher{h: sha256.New(), kinds: kinds}
}

func (r *rowHasher) add(vals []any) error {
	b := append(r.buf[:0], 'r')
	for i, v := range vals {
		c, err := convertValue(v, r.kinds[i])
		if err != nil {
			return err
		}
		switch x := c.(type) {
		case nil:
			b = append(b, 'n')
		case int64:
			b = append(strconv.AppendInt(append(b, 'i'), x, 10), ';')
		case float64:
			b = append(strconv.AppendFloat(append(b, 'f'), x, 'g', -1, 64), ';')
		case bool:
			b = append(strconv.AppendBool(append(b, 'b'), x), ';')
		case string:
			b = append(append(strconv.AppendInt(append(b, 's'), int64(len(x)), 10), ':'), x...)
		case []byte:
			b = append(append(strconv.AppendInt(append(b, 's'), int64(len(x)), 10), ':'), x...)
		}
	}
	r.buf = b
	r.h.Write(b)
	return nil
}

func (r *rowHasher) sum() string { return hex.EncodeToString(r.h.Sum(nil)) }

// dropSecondaryIndexes drops every index of the copied tables that backs no
// constraint (a primary key or a UNIQUE constraint stays) and returns the
// statements that rebuild them.
func dropSecondaryIndexes(ctx context.Context, tx pgx.Tx, plans []movePlan) ([]string, error) {
	var names, defs []string
	for _, p := range plans {
		rows, err := tx.Query(ctx, `
			SELECT i.relname, pg_get_indexdef(i.oid)
			FROM pg_index x
			JOIN pg_class i ON i.oid = x.indexrelid
			JOIN pg_class t ON t.oid = x.indrelid
			WHERE t.relname = $1 AND t.relnamespace = current_schema()::regnamespace
			  AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
			ORDER BY i.relname`, p.dstTable)
		if err != nil {
			return nil, fmt.Errorf("inspect %s's indexes: %w", p.dstTable, err)
		}
		for rows.Next() {
			var n, d string
			if err := rows.Scan(&n, &d); err != nil {
				rows.Close()
				return nil, err
			}
			names, defs = append(names, n), append(defs, d)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	for _, n := range names {
		if _, err := tx.Exec(ctx, `DROP INDEX `+quoteIdent(n)); err != nil {
			return nil, fmt.Errorf("drop index %s for the copy: %w", n, err)
		}
	}
	return defs, nil
}

// ---- helpers ----------------------------------------------------------------

// selectSQL reads cols from table, ordered by the given column indexes (nil =
// unordered). Spelled so SQLite and Postgres both read it the same way: quoted
// names, and NULLs first on both (Postgres puts them last by default).
func selectSQL(table string, cols []string, orderBy []int) string {
	q := make([]string, len(cols))
	for i, c := range cols {
		q[i] = quoteIdent(c)
	}
	s := `SELECT ` + strings.Join(q, ", ") + ` FROM ` + quoteIdent(table)
	if len(orderBy) > 0 {
		o := make([]string, len(orderBy))
		for i, idx := range orderBy {
			o[i] = q[idx] + ` NULLS FIRST`
		}
		s += ` ORDER BY ` + strings.Join(o, ", ")
	}
	return s
}

func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

// missing lists the names in want that have is lacking, case-insensitively.
func missing(want, have []string) []string {
	h := map[string]bool{}
	for _, t := range have {
		h[strings.ToLower(t)] = true
	}
	var out []string
	for _, t := range want {
		if !h[strings.ToLower(t)] {
			out = append(out, t)
		}
	}
	return out
}

func pgStrings(ctx context.Context, tx pgx.Tx, q string, args ...any) ([]string, error) {
	rows, err := tx.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
