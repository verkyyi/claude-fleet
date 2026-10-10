package agent

import (
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The heartbeat's host keys (claude-fleet#2983): this machine's sshd public
// keys, so the hub can hand them to `fleet connect` and a new person's first
// connection is checked against them rather than asking ssh's yes/no
// question. The .pub halves are world-readable; the private halves are never
// opened.

// hostKeyFiles is where sshd keeps them, newest algorithm first (a var for
// the tests).
var hostKeyFiles = []string{
	"/etc/ssh/ssh_host_ed25519_key.pub",
	"/etc/ssh/ssh_host_ecdsa_key.pub",
	"/etc/ssh/ssh_host_rsa_key.pub",
}

// nodeHostKeys is the heartbeat's HostKeys: every readable, well-formed one.
func nodeHostKeys() []string {
	var lines []string
	for _, f := range hostKeyFiles {
		if b, err := os.ReadFile(f); err == nil {
			lines = append(lines, string(b))
		}
	}
	return control.HostKeys(lines)
}
