package cli

import "github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"

// runCredProxy is `ccquota credproxy` — the cluster credential proxy. The hub's
// image runs the same command (its own Deployment, deploy/k8s/credproxy), so its
// implementation is shared/credproxy.Main (claude-fleet#4814).
func runCredProxy(args []string) error { return credproxy.Main(Version, args) }
