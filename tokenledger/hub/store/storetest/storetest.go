// Package storetest opens a fresh hub store for a test — store.Open on a byte
// copy of one migrated template per test binary (claude-fleet#2574, #4794), or
// on the Postgres leg (CCQUOTA_DB_URL) a schema made as before. Both the hub's
// own tests (hub/api) and the联调 tests (tokenledger/e2e, through hub/apitest)
// open their stores here (claude-fleet#4814).
package storetest

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Open is store.Open on a fresh database in t's temp dir, closed at
// cleanup — without paying for the schema every time (claude-fleet#2574).
// Applying the schema + migrations to an empty SQLite file costs ~0.5s under
// -race (modernc's SQLite is Go, and the race detector instruments all of
// it), and ~600 tests here each opened one: the package sat at 585s of
// go test's 10m default. So the first call migrates ONE template per test
// binary and every test opens a byte copy of it, which Open finds already
// applied. On the Postgres leg (CCQUOTA_DB_URL) the path is not a file and
// each test's schema is made as before.
func Open(t testing.TB) *store.Store {
	t.Helper()
	return openTestStoreFrom(t, &testStoreTpl, nil)
}

// OpenFleet is Open with the fleet registry applied
// (store.EnsureNodes), from a template of its own (claude-fleet#4794). Its
// ALTER TABLEs re-parse the whole SQLite schema each, and the fleet harness ran
// them for every one of ~900 tests: 65% of the package's CPU under -race. On
// SQLite the copy already holds what EnsureNodes makes, so it is not run
// again; on the Postgres leg it is, as before.
func OpenFleet(t testing.TB) *store.Store {
	t.Helper()
	st := openTestStoreFrom(t, &testFleetStoreTpl, func(st *store.Store) error { return st.EnsureNodes() })
	if os.Getenv("CCQUOTA_DB_URL") != "" {
		if err := st.EnsureNodes(); err != nil {
			t.Fatal(err)
		}
	}
	return st
}

func openTestStoreFrom(t testing.TB, tpl *storeTemplate, prep func(*store.Store) error) *store.Store {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	if os.Getenv("CCQUOTA_DB_URL") == "" {
		files, err := tpl.get(prep)
		if err != nil {
			t.Fatal(err)
		}
		for suffix, raw := range files {
			if err := os.WriteFile(path+suffix, raw, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	st, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

type storeTemplate struct {
	once  sync.Once
	files map[string][]byte // "" = the database, "-wal" … = what Close left beside it
	err   error
}

var testStoreTpl, testFleetStoreTpl storeTemplate

func (tpl *storeTemplate) get(prep func(*store.Store) error) (map[string][]byte, error) {
	tpl.once.Do(func() {
		tpl.files, tpl.err = buildStoreTemplate(prep)
	})
	return tpl.files, tpl.err
}

func buildStoreTemplate(prep func(*store.Store) error) (map[string][]byte, error) {
	dir, err := os.MkdirTemp("", "tl-api-store-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	tpl := filepath.Join(dir, "tpl.db")
	st, err := store.Open(tpl)
	if err != nil {
		return nil, err
	}
	if prep != nil {
		if err := prep(st); err != nil {
			st.Close()
			return nil, err
		}
	}
	if err := st.Close(); err != nil {
		return nil, err
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	files := map[string][]byte{}
	for _, e := range ents {
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		files[strings.TrimPrefix(e.Name(), "tpl.db")] = raw
	}
	return files, nil
}
