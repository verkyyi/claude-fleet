package store

// The Postgres leg of this package's tests (claude-fleet#2120): pgleg.go.
//
// pgSkip is the list of tests the Postgres leg does not run, each with the
// reason; TestMain prints it, so the CI log of the tokenledger-pg job is the
// list. It is empty since C2 #2121 and the CI job keeps it that way.

import (
	"os"
	"testing"
)

var pgSkip = map[string]string{}

// openSQLite opens the SQLite file at path whatever CCQUOTA_DB_URL says: a
// test that builds a database the way an older hub wrote it is testing the
// SQLite upgrade, which no Postgres database has, so on the Postgres leg it
// still runs — on SQLite.
func openSQLite(path string) (*Store, error) {
	return openStore(sqliteDialect, path, "sqlite "+path)
}

func TestMain(m *testing.M) { os.Exit(TestMainPostgres(m, pgSkip)) }
