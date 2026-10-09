package api

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// openTestStore is store.Open on a fresh database in t's temp dir, closed at
// cleanup — without paying for the schema every time (claude-fleet#2574).
// Applying the schema + migrations to an empty SQLite file costs ~0.5s under
// -race (modernc's SQLite is Go, and the race detector instruments all of
// it), and ~600 tests here each opened one: the package sat at 585s of
// go test's 10m default. So the first call migrates ONE template per test
// binary and every test opens a byte copy of it, which Open finds already
// applied. On the Postgres leg (CCQUOTA_DB_URL) the path is not a file and
// each test's schema is made as before.
func openTestStore(t testing.TB) *store.Store {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	if os.Getenv("CCQUOTA_DB_URL") == "" {
		files, err := testStoreTemplate()
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

var testStoreTpl struct {
	once  sync.Once
	files map[string][]byte // "" = the database, "-wal" … = what Close left beside it
	err   error
}

func testStoreTemplate() (map[string][]byte, error) {
	testStoreTpl.once.Do(func() {
		dir, err := os.MkdirTemp("", "tl-api-store-")
		if err != nil {
			testStoreTpl.err = err
			return
		}
		defer os.RemoveAll(dir)
		tpl := filepath.Join(dir, "tpl.db")
		st, err := store.Open(tpl)
		if err != nil {
			testStoreTpl.err = err
			return
		}
		if err := st.Close(); err != nil {
			testStoreTpl.err = err
			return
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			testStoreTpl.err = err
			return
		}
		files := map[string][]byte{}
		for _, e := range ents {
			raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				testStoreTpl.err = err
				return
			}
			files[strings.TrimPrefix(e.Name(), "tpl.db")] = raw
		}
		testStoreTpl.files = files
	})
	return testStoreTpl.files, testStoreTpl.err
}
