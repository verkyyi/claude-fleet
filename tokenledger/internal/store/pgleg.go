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

	var mu sync.Mutex
	schemas := map[string]bool{}
	dbURL = func(path string) string {
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
	defer func() {
		for s := range schemas {
			admin.Exec(`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`)
		}
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
	return m.Run()
}
