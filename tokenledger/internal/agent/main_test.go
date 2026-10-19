package agent

import (
	"context"
	"os"
	"testing"
)

// TestMain keeps the package's tests off this machine's real network feed
// (claude-fleet#4679). A node session arms an extra beat on every rtnetlink /
// PF_ROUTE message (netwatch.go), and a CI runner's own address and link
// churn — Docker's veths, IPv6 address events — landed in tests that count
// beats exactly (TestNudgeDebouncesAndRateLimits: "burst of 5 touches → 2
// beats"). A test that wants a feed swaps in its own (node_test.go).
func TestMain(m *testing.M) {
	netChangeFeed = func(context.Context) <-chan struct{} { return nil }
	os.Exit(m.Run())
}
