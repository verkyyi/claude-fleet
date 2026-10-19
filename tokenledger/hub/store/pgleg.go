package store

// The Postgres leg of a package's tests (claude-fleet#2120, #2121).
//
// `go test` with CCQUOTA_DB_URL unset is the SQLite leg and nothing here runs.
// With it set to a Postgres server a package's TestMain hands its run to
// TestMainPostgres and the WHOLE suite runs again against that server: every
// database file a test opens becomes its own schema there, so a test that
// closes and reopens "the same file" reopens the same data, and two tests
// never see each other's rows. The schemas are dropped when the run ends.
//
// It lives outside a _test file so internal/api's tests (which store.Open a
// t.TempDir() file each) run their Postgres leg through the same road.
//
// A fresh schema costs every test ~1.3s under -race (the schema + migrations
// on an empty database), which on ~1200 hub/api tests was most of the leg's
// time (claude-fleet#4817). So a test that only wants a fresh store says so
// first (PGTemplate — hub/store/storetest, the store package's newStore): its
// database is then a `CREATE DATABASE … TEMPLATE` copy of one migrated
// database per test binary — the Postgres twin of storetest's SQLite byte copy
// (claude-fleet#2574, #4794) — and Open finds the schema already applied. Every
// other path is its own empty schema as before. The leg prints what the copies
// cost (`pg leg: … per test`), so the CI log is the number.

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"flag"
	"fmt"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestMainPostgres runs m: as it always did with CCQUOTA_DB_URL unset, else
// on Postgres with each database file its own schema. skip names the tests
// the Postgres leg does not run, each with its reason; the leg prints the
// list, so a CI log is the list.
func TestMainPostgres(m *testing.M, skip map[string]string) int {
	base := os.Getenv(envDBURL)
	if base == "" {
		return m.Run()
	}
	admin, err := sql.Open("pgx", base)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pg leg:", err)
		return 1
	}
	defer admin.Close()
	if err := admin.Ping(); err != nil {
		fmt.Fprintln(os.Stderr, "pg leg: cannot reach "+envDBURL+":", err)
		return 1
	}

	leg := &pgLeg{admin: admin, base: base, tpls: map[string]*pgTpl{}, paths: map[string]string{}, dbs: map[string]bool{}, fresh: map[string]bool{}}
	var mu sync.Mutex
	schemas := map[string]bool{}
	dbURL = func(path string) string {
		if u, ok := leg.url(path); ok {
			return u
		}
		sum := sha256.Sum256([]byte(path))
		schema := "t_" + hex.EncodeToString(sum[:8])
		mu.Lock()
		defer mu.Unlock()
		if !schemas[schema] {
			if _, err := admin.Exec(`CREATE SCHEMA IF NOT EXISTS ` + schema); err != nil {
				panic(err)
			}
			schemas[schema] = true
		}
		u, err := url.Parse(base)
		if err != nil {
			panic(err)
		}
		q := u.Query()
		q.Set("search_path", schema)
		u.RawQuery = q.Encode()
		return u.String()
	}
	pgLegNow = leg
	defer func() {
		pgLegNow = nil
		for s := range schemas {
			admin.Exec(`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`)
		}
		leg.drop()
	}()

	names := make([]string, 0, len(skip))
	for n := range skip {
		names = append(names, n)
	}
	sort.Strings(names)
	fmt.Printf("pg leg: %d test(s) not run on Postgres\n", len(names))
	for _, n := range names {
		fmt.Printf("  SKIP-PG %s — %s\n", n, skip[n])
	}
	if len(names) > 0 {
		pat := make([]string, len(names))
		for i, n := range names {
			pat[i] = regexp.QuoteMeta(n)
		}
		re := "^(" + strings.Join(pat, "|") + ")$"
		if prev := flag.Lookup("test.skip").Value.String(); prev != "" {
			re = prev + "|" + re
		}
		flag.Set("test.skip", re)
	}
	code := m.Run()
	leg.report()
	return code
}

// pgLegNow is the running Postgres leg (TestMainPostgres), nil off it.
var pgLegNow *pgLeg

// pgLeg is the template half of the Postgres leg (claude-fleet#4817).
type pgLeg struct {
	admin *sql.DB
	base  string

	mu    sync.Mutex
	tpls  map[string]*pgTpl // name → its template database
	paths map[string]string // a path PGTemplate marked → its template's name
	dbs   map[string]bool   // every database made, the templates too
	fresh map[string]bool   // a copy no Open has seen yet (takeFresh)

	copies           int
	cloneDur, opened time.Duration
	opens            int
}

type pgTpl struct {
	db    string
	built time.Duration
	err   error
}

// PGTemplate says the database at path is a fresh store and nothing else: on
// the Postgres leg it is then a copy of one migrated template database per
// test binary and name (prep applied once to the template — what the caller
// would otherwise run on every store), and ok is true; off the leg nothing
// happens and ok is false, so the caller does what it always did. Call it
// before Open(path).
func PGTemplate(path, name string, prep func(*Store) error) (ok bool, err error) {
	leg := pgLegNow
	if leg == nil {
		return false, nil
	}
	leg.mu.Lock()
	defer leg.mu.Unlock()
	tpl := leg.tpls[name]
	if tpl == nil {
		tpl = &pgTpl{db: fmt.Sprintf("tpl_%d_%s", os.Getpid(), name)}
		leg.tpls[name] = tpl
		t0 := time.Now()
		tpl.err = leg.buildTemplate(tpl.db, prep)
		tpl.built = time.Since(t0)
	}
	if tpl.err != nil {
		return false, tpl.err
	}
	leg.paths[path] = name
	return true, nil
}

// buildTemplate makes database db and migrates it: Open, prep, Close — so no
// connection is left on it when it is copied.
func (l *pgLeg) buildTemplate(db string, prep func(*Store) error) error {
	l.admin.Exec(`DROP DATABASE IF EXISTS ` + db + ` WITH (FORCE)`)
	if _, err := l.admin.Exec(`CREATE DATABASE ` + db); err != nil {
		return fmt.Errorf("pg leg: create template %s: %w", db, err)
	}
	l.dbs[db] = true
	st, err := openStore(postgresDialect, l.dbURLFor(db), "postgres")
	if err != nil {
		return fmt.Errorf("pg leg: migrate template %s: %w", db, err)
	}
	if prep != nil {
		if err := prep(st); err != nil {
			st.Close()
			return fmt.Errorf("pg leg: prepare template %s: %w", db, err)
		}
	}
	return st.Close()
}

// url is path's database when PGTemplate marked it: made from its template on
// the first call, the same database after (a test that reopens "the same
// file" reopens the same data).
func (l *pgLeg) url(path string) (string, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	name, ok := l.paths[path]
	if !ok {
		return "", false
	}
	sum := sha256.Sum256([]byte(path))
	db := "c_" + hex.EncodeToString(sum[:8])
	if !l.dbs[db] {
		t0 := time.Now()
		if _, err := l.admin.Exec(`CREATE DATABASE ` + db + ` TEMPLATE ` + l.tpls[name].db); err != nil {
			panic(fmt.Errorf("pg leg: copy template %s: %w", l.tpls[name].db, err))
		}
		l.cloneDur += time.Since(t0)
		l.copies++
		l.dbs[db] = true
		l.fresh[path] = true
	}
	return l.dbURLFor(db), true
}

// takeFresh says whether path's database is a template copy that no Open has
// seen yet — and from here on it is not. Open skips the schema pass on it: the
// template had it from this binary's own Open, and nothing has written since.
func (l *pgLeg) takeFresh(path string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	f := l.fresh[path]
	delete(l.fresh, path)
	return f
}

// openedFrom records how long Open took on a copied database (the copy's own
// time is in url): the fixed cost a test pays before its first line.
func (l *pgLeg) openedFrom(path string, d time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, ok := l.paths[path]; ok {
		l.opened += d
		l.opens++
	}
}

func (l *pgLeg) dbURLFor(db string) string {
	u, err := url.Parse(l.base)
	if err != nil {
		panic(err)
	}
	u.Path = "/" + db
	return u.String()
}

func (l *pgLeg) report() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.copies == 0 {
		return
	}
	names := make([]string, 0, len(l.tpls))
	for n := range l.tpls {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Printf("pg leg: template %s built in %.2fs\n", n, l.tpls[n].built.Seconds())
	}
	per := (l.cloneDur + l.opened).Seconds() / float64(l.copies)
	fmt.Printf("pg leg: %d test database(s) copied from a template, %.3fs per test (copy %.3fs + open %.3fs)\n",
		l.copies, per, l.cloneDur.Seconds()/float64(l.copies), l.opened.Seconds()/float64(max(l.opens, 1)))
}

func (l *pgLeg) drop() {
	l.mu.Lock()
	defer l.mu.Unlock()
	for db := range l.dbs {
		l.admin.Exec(`DROP DATABASE IF EXISTS ` + db + ` WITH (FORCE)`)
	}
}
