package control

import (
	"strings"

	"golang.org/x/crypto/ssh"
)

// HostKey reads one sshd host public key ("<type> <base64> [comment]", an
// ssh_host_*_key.pub line) into the form Heartbeat.HostKeys carries and
// `fleet connect` writes into known_hosts: "<type> <base64>", no comment
// (claude-fleet#2983). A certificate, an unknown type or anything that does
// not parse is refused — the line ends up in a file ssh trusts.
func HostKey(line string) (string, bool) {
	pub, _, _, rest, err := ssh.ParseAuthorizedKey([]byte(strings.TrimSpace(line)))
	if err != nil || len(strings.TrimSpace(string(rest))) > 0 {
		return "", false
	}
	switch pub.Type() {
	case ssh.KeyAlgoED25519, ssh.KeyAlgoECDSA256, ssh.KeyAlgoECDSA384, ssh.KeyAlgoECDSA521, ssh.KeyAlgoRSA:
	default:
		return "", false
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pub))), true
}

// HostKeys is HostKey over a list: the good ones, each once, in order.
func HostKeys(lines []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, l := range lines {
		if k, ok := HostKey(l); ok && !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out
}
