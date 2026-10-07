package store

// The Postgres leg of this package's tests (claude-fleet#2120).
//
// `go test ./internal/store/...` with CCQUOTA_DB_URL unset is the SQLite leg
// and nothing here runs. With it set to a Postgres server the WHOLE suite runs
// again against that server: every database file a test opens becomes its own
// schema there (dbURL below), so a test that closes and reopens "the same
// file" reopens the same data, and two tests never see each other's rows. The
// schemas are dropped when the run ends.
//
// pgSkip is the list of tests the Postgres leg does not run yet, each with the
// reason; TestMain prints it, so the CI log of the tokenledger-pg job is the
// list. Shrinking it is EPIC #2119's later members' job (C2 #2121: the fleet_*
// tables); a test leaves it by being deleted from the map, nothing else.

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

	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	skipFleet  = "fleet_* tables: Postgres leg is C2 #2121"
	skipSQLite = "builds an SQLite file the way an older hub wrote it — an upgrade no Postgres database has"
)

var pgSkip = map[string]string{
	"TestFleetCredsColumnsAddedToOldTable": skipFleet,
	"TestPoolPrincipalIsReserved":          skipFleet,

	"TestMigrate_AddsFleetColumnsToAnOlderDatabase":      skipSQLite,
	"TestMigrate_AddsRetiredAtToAnOlderDatabase":         skipSQLite,
	"TestMigrateProvider_PreservesRollupHistory":         skipSQLite,
	"TestSourcesMigrationPreservesPrunedHistoryAndDedup": skipSQLite,
}

func TestMain(m *testing.M) {
	base := os.Getenv(envDBURL)
	if base == "" {
		os.Exit(m.Run())
	}
	os.Exit(runPG(m, base))
}

func runPG(m *testing.M, base string) int {
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

	if len(pgSkip) > 0 {
		names := make([]string, 0, len(pgSkip))
		for n := range pgSkip {
			names = append(names, n)
		}
		sort.Strings(names)
		fmt.Printf("pg leg: %d test(s) not run on Postgres:\n", len(names))
		for _, n := range names {
			fmt.Printf("  SKIP-PG %s — %s\n", n, pgSkip[n])
		}
		pat := make([]string, len(names))
		for i, n := range names {
			pat[i] = regexp.QuoteMeta(n)
		}
		skip := "^(" + strings.Join(pat, "|") + ")$"
		if prev := flag.Lookup("test.skip").Value.String(); prev != "" {
			skip = prev + "|" + skip
		}
		flag.Set("test.skip", skip)
	}
	return m.Run()
}
