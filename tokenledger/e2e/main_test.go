package e2e

import (
	"os"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/apitest"
)

// The Postgres leg runs these too (CCQUOTA_DB_URL): apitest.Main gives each
// test database its own schema, as hub/api's TestMain does.
func TestMain(m *testing.M) { os.Exit(apitest.Main(m)) }
