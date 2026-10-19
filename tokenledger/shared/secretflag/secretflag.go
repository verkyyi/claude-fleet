// Package secretflag is how a ccquota command takes a credential: a flag whose
// -h never prints its value, a token down a pipe, a token in a root-kept file.
// The hub's commands and the node's both use it (claude-fleet#4812).
package secretflag

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// secretValue is a string flag whose value never reaches -h output
// (claude-fleet#1508). A token flag defaulted straight from $CCQUOTA_TOKEN made
// PrintDefaults print the node's enrollment token as `(default "ccq_…")`, so a
// worker glancing at `ccquota place -h` copied it into its own context. String()
// is always empty — DefValue is "", PrintDefaults treats it as a zero value and
// prints no default — and the usage names the environment variable instead.
type secretValue struct{ p *string }

func (s secretValue) String() string { return "" }

func (s secretValue) Set(v string) error {
	*s.p = v
	return nil
}

// EnvFlag is fs.String(name, os.Getenv(env), usage) for a credential:
// same default, same explicit override, but -h shows `(default: $ENV)`.
func EnvFlag(fs *flag.FlagSet, name, env, usage string) *string {
	p := new(string)
	*p = os.Getenv(env)
	fs.Var(secretValue{p}, name, usage+" (default: $"+env+")")
	return p
}

// FromFD reads one token line from an inherited file descriptor and
// closes it (claude-fleet#1971): bin/fleet-credsep-launch.py runs as root,
// reads node.env from the separated store and passes the agent its token down
// a pipe, so the token is never in an environment or a file this login can
// read. An empty fd name is "" and no error.
func FromFD(fd string) (string, error) {
	if fd == "" {
		return "", nil
	}
	n, err := strconv.Atoi(fd)
	if err != nil || n < 3 {
		return "", fmt.Errorf("CCQUOTA_TOKEN_FD=%q: a file descriptor number >= 3", fd)
	}
	f := os.NewFile(uintptr(n), "token-fd")
	if f == nil {
		return "", fmt.Errorf("CCQUOTA_TOKEN_FD=%d: not open", n)
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && line == "" {
		return "", fmt.Errorf("CCQUOTA_TOKEN_FD=%d: %w", n, err)
	}
	os.Unsetenv("CCQUOTA_TOKEN_FD")
	return strings.TrimSpace(line), nil
}

// FromFile reads the token line from path (claude-fleet#3724): the admin
// seat's agent runs as _fleetadmin under launchd / systemd, and root keeps its
// token in a file only root writes and only that account's group reads — never
// in the unit's environment. A link, or a file anyone else may read or anyone
// but its owner may write, is refused. An empty path is "" and no error.
func FromFile(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	st, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("CCQUOTA_TOKEN_FILE: %w", err)
	}
	if !st.Mode().IsRegular() || st.Mode().Perm()&0o026 != 0 {
		return "", fmt.Errorf("CCQUOTA_TOKEN_FILE=%s: must be a regular file no one else may read or write (mode %v)", path, st.Mode())
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("CCQUOTA_TOKEN_FILE: %w", err)
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return strings.TrimSpace(line), nil
}
