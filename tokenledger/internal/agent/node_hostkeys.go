package agent

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

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
	if podRelay() {
		if k := podSSHDKey(); k != "" {
			lines = append(lines, k)
		}
	}
	return control.HostKeys(lines)
}

// The key a pod's sshd shows right now (claude-fleet#4149): the hub's pod roll
// patches only a Deployment's image, so a pod rendered before #4151 has no
// /run/sshd-key mount in its fleet container and the file above is never there
// — and the sshd makes a new key at each start anyway. So the agent asks the
// sshd itself, on the relay's own address: one key exchange, never a login, at
// most once per podKeyEvery (the sshd logs each probe as a closed preauth).
var (
	podKeyEvery   = 5 * time.Minute
	podKeyTimeout = 3 * time.Second
	podKeyMu      sync.Mutex
	podKeyAt      time.Time
	podKeyLast    string
)

var errPodKeySeen = errors.New("pod sshd: host key seen")

func podSSHDKey() string {
	podKeyMu.Lock()
	defer podKeyMu.Unlock()
	if !podKeyAt.IsZero() && time.Since(podKeyAt) < podKeyEvery {
		return podKeyLast
	}
	podKeyAt = time.Now()
	conn, err := net.DialTimeout("tcp", sshRelayTarget, podKeyTimeout)
	if err != nil {
		podKeyLast = ""
		return ""
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(podKeyTimeout))
	var seen ssh.PublicKey
	_, _, _, err = ssh.NewClientConn(conn, sshRelayTarget, &ssh.ClientConfig{
		User:              "fleet-hostkey",
		HostKeyAlgorithms: []string{ssh.KeyAlgoED25519},
		HostKeyCallback: func(_ string, _ net.Addr, k ssh.PublicKey) error {
			seen = k
			return errPodKeySeen
		},
	})
	if seen == nil || !errors.Is(err, errPodKeySeen) {
		podKeyLast = ""
		return ""
	}
	podKeyLast = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(seen)))
	return podKeyLast
}
