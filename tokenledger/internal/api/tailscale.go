package api

import (
	"errors"
	"net/netip"
	"os"
	"os/exec"
)

// The tailscale CLI, for --https-addr: the hub asks it for this node's
// certificate. It grants no one anything — who may read the hub is the
// GitHub list (github_auth.go) or the viewer token.

var (
	tailnetV4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetV6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// IsTailnetAddr reports whether ip is in Tailscale's address ranges.
func IsTailnetAddr(ip netip.Addr) bool {
	return tailnetV4.Contains(ip) || tailnetV6.Contains(ip)
}

// FindTailscaleBin locates the tailscale CLI: an explicit path, then PATH,
// then where the macOS builds put it.
func FindTailscaleBin(explicit string) (string, error) {
	candidates := []string{explicit}
	if p, err := exec.LookPath("tailscale"); err == nil {
		candidates = append(candidates, p)
	}
	candidates = append(candidates,
		"/opt/homebrew/bin/tailscale",
		"/usr/local/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	)
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c, nil
		}
	}
	return "", errors.New("tailscale CLI not found; pass --tailscale-bin")
}
