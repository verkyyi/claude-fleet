package api

// The Postgres leg of this package's tests (claude-fleet#2121, EPIC #2119 C2):
// with CCQUOTA_DB_URL set every store a test opens is its own schema on that
// server (store.TestMainPostgres), so the fleet half — machines, sessions,
// leases, the vault, device certificates, the audit — is read and written
// through the same handlers on both databases.

import (
	"os"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func TestMain(m *testing.M) { os.Exit(store.TestMainPostgres(m, nil)) }
