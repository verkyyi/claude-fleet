package e2e

import (
	"fmt"
	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"os"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/apitest"
)

// The Postgres leg runs these too (CCQUOTA_DB_URL): apitest.Main gives each
// test database its own schema, as hub/api's TestMain does.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "preview-pipe" {
		if err := agent.RunPreviewPipe(os.Args[2:], os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(apitest.Main(m))
}
