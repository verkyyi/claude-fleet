package store

import "testing"

func TestReadPoolFor(t *testing.T) {
	if got := readPoolFor(sqliteDialect); got != readPoolSize {
		t.Fatalf("sqlite read pool = %d, want %d", got, readPoolSize)
	}
	t.Setenv("CCQUOTA_DB_READ_POOL", "")
	if got := readPoolFor(postgresDialect); got != pgReadPoolSize {
		t.Fatalf("postgres read pool = %d, want %d", got, pgReadPoolSize)
	}
	t.Setenv("CCQUOTA_DB_READ_POOL", "48")
	if got := readPoolFor(postgresDialect); got != 48 {
		t.Fatalf("postgres read pool with override = %d, want 48", got)
	}
	t.Setenv("CCQUOTA_DB_READ_POOL", "junk")
	if got := readPoolFor(postgresDialect); got != pgReadPoolSize {
		t.Fatalf("postgres read pool with junk override = %d, want %d", got, pgReadPoolSize)
	}
}
