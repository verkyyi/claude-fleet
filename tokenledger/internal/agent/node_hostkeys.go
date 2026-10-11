package agent

import (
	"os"
	"path/filepath"

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

// entryHostKeyFile is the entry port's own host key (claude-fleet#3070, written
// by fleet-node-supervisor.py under its state dir): `fleet connect`'s `entry`
// route lands on that sshd, so its key travels with the machine's others and
// the first connection there is checked too (claude-fleet#3075). No entry on
// this machine ⇒ no file ⇒ nothing added.
func entryHostKeyFile() string {
	st := os.Getenv("FLEET_NODE_STATE")
	if st == "" {
		st = "/var/db/fleet-node"
	}
	return filepath.Join(st, "entry", "ssh_host_ed25519_key.pub")
}

// nodeHostKeys is the heartbeat's HostKeys: every readable, well-formed one.
func nodeHostKeys() []string {
	var lines []string
	for _, f := range append(append([]string(nil), hostKeyFiles...), entryHostKeyFile()) {
		if b, err := os.ReadFile(f); err == nil {
			lines = append(lines, string(b))
		}
	}
	return control.HostKeys(lines)
}
