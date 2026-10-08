//go:build unix

package agent

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"syscall"

	"golang.org/x/sys/unix"
)

func setCredential(cmd *exec.Cmd, ra *RunAs) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	// Only root may set the supplementary groups; anyone else (a test
	// running tenants as itself) keeps its own.
	cmd.SysProcAttr.Credential = &syscall.Credential{Uid: ra.UID, Gid: ra.GID,
		Groups: capGroups(ra.Groups, ra.GID, runtime.GOOS), NoSetGroups: os.Geteuid() != 0}
}

// darwinMaxGroups is macOS's NGROUPS_MAX: setgroups(2) answers EINVAL to a
// longer list, so every command the machine agent started as a login in more
// groups failed with «fork/exec …: invalid argument» (m4, claude-fleet#2336).
const darwinMaxGroups = 16

// capGroups keeps a supplementary list setgroups(2) accepts on goos: the login's
// own group, staff (20) and admin (80 — sudo) first, then the rest in order,
// duplicates dropped, at most darwinMaxGroups on darwin. Elsewhere: unchanged.
func capGroups(groups []uint32, gid uint32, goos string) []uint32 {
	if goos != "darwin" || len(groups) <= darwinMaxGroups {
		return groups
	}
	in := map[uint32]bool{}
	for _, g := range groups {
		in[g] = true
	}
	out := make([]uint32, 0, darwinMaxGroups)
	seen := map[uint32]bool{}
	add := func(g uint32) {
		if len(out) < darwinMaxGroups && in[g] && !seen[g] {
			seen[g] = true
			out = append(out, g)
		}
	}
	for _, g := range []uint32{gid, 20, 80} {
		add(g)
	}
	for _, g := range groups {
		add(g)
	}
	return out
}

// credFacts is what setCredential asks of the kernel for ra: how many
// supplementary groups it hands setgroups(2), and how many the login has.
func credFacts(ra *RunAs) []string {
	set := capGroups(ra.Groups, ra.GID, runtime.GOOS)
	if os.Geteuid() != 0 {
		return []string{fmt.Sprintf("not root (euid %d): no uid change allowed", os.Geteuid())}
	}
	return []string{fmt.Sprintf("%d supplementary groups set of %d", len(set), len(ra.Groups))}
}

func fileOwner(fi os.FileInfo) (uint32, bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return st.Uid, true
}

// errnoName is «EINVAL: » for an error carrying an errno, else "".
func errnoName(err error) string {
	var no syscall.Errno
	if errors.As(err, &no) {
		if n := unix.ErrnoName(no); n != "" {
			return n + ": "
		}
	}
	return ""
}
