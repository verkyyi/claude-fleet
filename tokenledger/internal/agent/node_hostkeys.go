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
	return filepath.Join(nodeStateDir(), "entry", "ssh_host_ed25519_key.pub")
}

// containerHostKeyFile is a container machine's sshd key (fleet-node-linux.py
// container: made once on the machine's own disk, its sshd_config.d names it
// alone — claude-fleet#4127). The image keeps no /etc/ssh host key, so this
// is the one its sshd shows. No such machine ⇒ no file ⇒ nothing added.
func containerHostKeyFile() string {
	return filepath.Join(nodeStateDir(), "ssh", "ssh_host_ed25519_key.pub")
}

// podHostKeyFile is a person's pod's sshd key (render.py: the sshd container
// makes it at each start, the fleet container sees the .pub read-only): a
// relayed login lands on that sshd, not the door, so its key travels with the
// door's (claude-fleet#4149). Not a pod ⇒ nothing added.
var podHostKeyFile = "/run/sshd-key/host.pub"

func nodeStateDir() string {
	if st := os.Getenv("FLEET_NODE_STATE"); st != "" {
		return st
	}
	return "/var/db/fleet-node"
}

// nodeHostKeys is the heartbeat's HostKeys: every readable, well-formed one.
func nodeHostKeys() []string {
	var lines []string
	files := append(append([]string(nil), hostKeyFiles...), containerHostKeyFile(), entryHostKeyFile())
	if podRelay() {
		files = append(files, podHostKeyFile)
	}
	for _, f := range files {
		if b, err := os.ReadFile(f); err == nil {
			lines = append(lines, string(b))
		}
	}
	return control.HostKeys(lines)
}
