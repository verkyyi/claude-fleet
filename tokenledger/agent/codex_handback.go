package agent

import (
	"fmt"
	"path/filepath"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
)

// Before a machine tenant's Codex work ran as the login, the root program
// renewed in the login's Codex home itself, so a home can still hold the
// agent's own files from then: its lock and its renewal and upstream records,
// an auth.json the Codex CLI rewrote as root, and the CLI's own directories.
// The login's machine-op cannot use those. handBackCodexHome repairs a home
// once, before its first machine-op, and never hands a regular file to the
// login (a regular file in the home may be a second name for one that is not
// the login's to have):
//
//   - the agent's own records (codexAgentRecords), directly in the home, are
//     removed — the machine-op makes them again as the login;
//   - an auth.json of the agent's with one link is read, and only when it is a
//     Codex subscription login of the account this profile was last seen
//     signed in to is it written again as a new file of the login's;
//     otherwise it is left as it is and the profile reports why;
//   - a directory the Codex CLI makes (codexCLIDirs), directly in the home,
//     and the home itself when it is one of the login's Codex homes
//     (~/.codex, ~/.codex-accounts/<label>), are handed over on their own
//     descriptor.
//
// Nothing else is touched, nothing is followed, and nothing below the home's
// top level is looked at.

// codexAgentRecords are the files the agent itself keeps in a Codex home
// (shared/codex: refresh.go, upstream.go).
var codexAgentRecords = map[string]bool{
	".ccquota-auth.lock":       true,
	".ccquota-auth-state.json": true,
	".ccquota-upstream.json":   true,
}

// codexCLIDirs are the directories the Codex CLI makes in its home: its
// transcripts (shared/scan/sources.go), their archive, its scratch space
// (bin/fleet-move-to-pod.sh leaves it behind) and its log.
var codexCLIDirs = map[string]bool{
	"sessions":          true,
	"archived_sessions": true,
	"tmp":               true,
	"log":               true,
}

// handBackMax bounds how many entries one home's hand-back looks at.
const handBackMax = 4096

// codexAuthName is the Codex CLI's file login.
const codexAuthName = "auth.json"

type hbKind int

const (
	hbOther hbKind = iota
	hbRegular
	hbDir
)

// hbEntry is what the hand-back knows of one entry: its type (not followed),
// owner and link count.
type hbEntry struct {
	kind  hbKind
	uid   uint32
	nlink uint64
}

type hbAction int

const (
	hbSkip     hbAction = iota
	hbRemove            // one of the agent's records: unlinked by name
	hbAuth              // the agent's auth.json: read, checked, written anew as the login's
	hbChownDir          // a Codex CLI directory: handed over by its descriptor
)

// handBackAction is what the hand-back does with name (directly in a Codex
// home) when it is e; self is the agent's own uid. A regular file is never
// handed over.
func handBackAction(name string, e hbEntry, self uint32) hbAction {
	if e.uid != self {
		return hbSkip
	}
	switch e.kind {
	case hbRegular:
		if codexAgentRecords[name] {
			return hbRemove
		}
		if name == codexAuthName && e.nlink == 1 {
			return hbAuth
		}
	case hbDir:
		if codexCLIDirs[name] {
			return hbChownDir
		}
	}
	return hbSkip
}

// handBackResult is one home's hand-back: what it did, and — when the agent's
// auth.json was left as it is — why, in words the hub shows.
type handBackResult struct {
	dirs, removed int
	auth          bool
	degraded      string
}

// handBackAuth checks b, the agent's own auth.json of a profile last seen
// signed in to bound: it is written again as the login's only when it is a
// Codex subscription login of that same account.
func handBackAuth(b []byte, bound string) error {
	a, err := codex.ParseAuthFile(b)
	if err != nil {
		return fmt.Errorf("it is not a Codex login file this agent can read")
	}
	if bound == "" || a.Identity.AccountUUID != bound {
		return fmt.Errorf("it is not the account this profile was last seen signed in to")
	}
	return nil
}

// authLeftReason is the status reason for an auth.json left as it is.
func authLeftReason(home string, why error) string {
	return fmt.Sprintf("Codex login file %s is still the agent's from an earlier version and was not handed over (%v); sign in to this profile again", filepath.Join(home, codexAuthName), why)
}

// codexHomeKnown says home is one of ra's own Codex homes by name: ~/.codex,
// or ~/.codex-accounts/<label>.
func codexHomeKnown(ra *RunAs, home string) bool {
	if ra == nil || ra.Home == "" {
		return false
	}
	h, base := filepath.Clean(ra.Home), filepath.Clean(home)
	if base == filepath.Join(h, ".codex") {
		return true
	}
	return filepath.Dir(base) == filepath.Join(h, ".codex-accounts") && filepath.Base(base) != "." && filepath.Base(base) != ".."
}
