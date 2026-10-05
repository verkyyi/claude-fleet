package agent

import (
	"context"
	"time"
)

// Network-change wake (claude-fleet#1630). A node whose link dropped waits out
// its backoff before it dials again — but when THIS machine's network changes
// (a new Wi-Fi, a wake from sleep, a cable back in) the reason the last dial
// failed is likely gone, and waiting up to 30 s for the next rung only delays
// the roster. So the kernel's own change feed — a PF_ROUTE socket on macOS, an
// rtnetlink socket on Linux — wakes the reconnect loop at once and clears the
// ladder. A platform without one returns a nil channel, which never fires: the
// backoff alone, as before.

// netChangeSettle lets a burst of address/link messages (one Wi-Fi join is a
// dozen) settle into one wake, and gives DHCP a moment to hand out an address
// before the dial that wake triggers.
var netChangeSettle = 750 * time.Millisecond

// netChangeFeed is the platform's raw feed; a test swaps in its own.
var netChangeFeed = netChangeSource

// watchNetChanges reports this machine's address / link changes, coalesced:
// the channel holds at most one pending wake. It closes nothing; the watcher
// ends with ctx.
func watchNetChanges(ctx context.Context) <-chan struct{} {
	raw := netChangeFeed(ctx)
	if raw == nil {
		return nil
	}
	out := make(chan struct{}, 1)
	go func() {
		var settle <-chan time.Time
		for {
			select {
			case <-ctx.Done():
				return
			case _, ok := <-raw:
				if !ok {
					return
				}
				if settle == nil {
					settle = time.After(netChangeSettle)
				}
			case <-settle:
				settle = nil
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}()
	return out
}
