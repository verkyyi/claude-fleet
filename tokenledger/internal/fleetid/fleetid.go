// Package fleetid is claude-fleet's identity scheme, spelled in Go
// (claude-fleet#1409): the machine UUID, the fleet UUID derived from it, and
// the durable worker id every cross-machine route keys on.
//
// The source of truth is Python — bin/fleet_hub_common.py and
// bin/fleet_control.py — because that is what runs on every node and what the
// SSH-era Fleet Hub registered fleets under. The hub moving to Go must not
// renumber anything: a fleet UUID a caller holds, a grant that names it, a
// worker_id a dispatcher stored, all have to stay valid. So every function here
// is a transliteration, and fleetid_test.go checks it value for value against
// the Python, not against a reading of it.
package fleetid

import (
	"crypto/sha1"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// uuidRE is a canonical (lowercase, hyphenated) UUID — what Python's
// str(uuid.UUID(x)) == x accepts, and nothing else.
var uuidRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// keyRE is WORKER_KEY_RE: [<repo slug>:](issue|scratch)-<N>.
const keyRE = `(?:[A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?(?:issue|scratch)-[1-9][0-9]{0,9}`

// identityRE is a session's lifelong identity (claude-fleet#1646): its window's
// @fleet_id, a canonical UUID.
const identityRE = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`

// workerIDRE is WORKER_ID_RE: <fleet UUID>/<fleet_id> (claude-fleet#1646), or —
// an alias kept for one version — the old <fleet UUID>/<key>.
var workerIDRE = regexp.MustCompile(`^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/(` + keyRE + `|` + identityRE + `)$`)

var (
	slugDropRE   = regexp.MustCompile(`[^A-Za-z0-9._-]`)
	slugValidRE  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	scratchDirRE = regexp.MustCompile(`^(?:.*-)?scratch-([1-9][0-9]{0,9})$`)
)

// ErrNotUUID is returned for anything that is not a canonical UUID.
var ErrNotUUID = errors.New("expected a canonical UUID")

// ErrBadWorkerID is parse_worker_id's refusal.
var ErrBadWorkerID = errors.New("worker_id must be <fleet UUID>/<fleet_id>, <fleet UUID>/[<repo>:]issue-<N> or <fleet UUID>/[<repo>:]scratch-<N>")

// IsUUID reports whether s is a canonical UUID.
func IsUUID(s string) bool { return uuidRE.MatchString(s) }

// FleetID is fleet_control.py's
//
//	uuid.uuid5(uuid.UUID(machine_id), canonical([session, repo, checkout]))
//
// machineID is the node's own control identity (a uuid4 it minted once, in
// $FLEET_CONF_DIR/control); session, repo and checkout are the fleet's
// inventory row. The same three values on the same machine always give the
// same fleet UUID; the same values on another machine never do.
func FleetID(machineID, session, repo, checkout string) (string, error) {
	ns, err := parseUUID(machineID)
	if err != nil {
		return "", err
	}
	return uuid5(ns, Canonical([]string{session, repo, checkout})), nil
}

// RepoSlug is fleet_slug: owner/name → owner-name, with anything outside
// [A-Za-z0-9._-] dropped.
func RepoSlug(repo string) string {
	return slugDropRE.ReplaceAllString(strings.ReplaceAll(repo, "/", "-"), "")
}

// WorkerKey is worker_key: the durable key of one window — issue-<N> for a
// worker (issue > 0), scratch-<N> for a scratch session whose worktree basename
// ends in scratch-<digits>, else "" (Python's None). repo is the adapter's
// column 9: empty in a one-repo fleet (the key stays bare), the window's
// owner/name in a multi-repo one (<slug>:issue-<N>), "?" when unknown — which
// gives "", never a guess.
func WorkerKey(issue int, scratch bool, worktree, repo string) string {
	key := ""
	switch {
	case issue > 0:
		key = "issue-" + strconv.Itoa(issue)
	case scratch:
		base := strings.TrimRight(worktree, "/")
		if i := strings.LastIndex(base, "/"); i >= 0 {
			base = base[i+1:]
		}
		if m := scratchDirRE.FindStringSubmatch(base); m != nil {
			key = "scratch-" + m[1]
		}
	}
	if key != "" && repo != "" {
		slug := ""
		if repo != "?" {
			slug = RepoSlug(repo)
		}
		if !slugValidRE.MatchString(slug) {
			return ""
		}
		key = slug + ":" + key
	}
	return key
}

// WorkerID is worker_identity: <fleet UUID>/<key>, or "" when there is no key.
func WorkerID(fleetID, key string) string {
	if key == "" {
		return ""
	}
	return fleetID + "/" + key
}

// operatorRE is the sender of a message no worker sent (claude-fleet#1649): the
// person at a login, from a shell or a daemon with no pane — `<fleet UUID>/
// operator@<login>`. It is a relay's `from` only, never an address: nothing
// routes TO it but the receipt for the message it sent.
var operatorRE = regexp.MustCompile(`^(` + identityRE + `)/operator@([A-Za-z0-9._-]{1,64})$`)

// ParseOperatorSender is (fleet UUID, login) for an operator sender, ok false
// for anything else — a worker_id included.
func ParseOperatorSender(id string) (fleetID, login string, ok bool) {
	m := operatorRE.FindStringSubmatch(id)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// ParseWorkerID is parse_worker_id: (fleet UUID, key), or ErrBadWorkerID. The
// key half is a session identity (IsUUID) for the <fleet UUID>/<fleet_id> form;
// a caller that needs a real key (a lease, a placement, a move) matches its own
// key pattern on it, which an identity never passes.
func ParseWorkerID(id string) (fleetID, key string, err error) {
	m := workerIDRE.FindStringSubmatch(id)
	if m == nil {
		return "", "", ErrBadWorkerID
	}
	return m[1], m[2], nil
}

// Canonical is fleet_hub_common.canonical for a list of strings:
//
//	json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
//
// It is written out rather than left to encoding/json because the two differ
// exactly where a fleet name or checkout path could reach: Go escapes <, >, &
// and U+2028/U+2029, Python with ensure_ascii=False escapes none of them, and a
// single differing byte is a different fleet UUID.
func Canonical(values []string) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, v := range values {
		if i > 0 {
			b.WriteByte(',')
		}
		writeString(&b, v)
	}
	b.WriteByte(']')
	return b.String()
}

func writeString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

func parseUUID(s string) ([16]byte, error) {
	var out [16]byte
	if !IsUUID(s) {
		return out, ErrNotUUID
	}
	hex := strings.ReplaceAll(s, "-", "")
	for i := 0; i < 16; i++ {
		v, err := strconv.ParseUint(hex[2*i:2*i+2], 16, 8)
		if err != nil {
			return out, ErrNotUUID
		}
		out[i] = byte(v)
	}
	return out, nil
}

// uuid5 is RFC 4122 §4.3 with SHA-1, as Python's uuid.uuid5.
func uuid5(ns [16]byte, name string) string {
	h := sha1.New()
	h.Write(ns[:])
	h.Write([]byte(name))
	sum := h.Sum(nil)
	var u [16]byte
	copy(u[:], sum[:16])
	u[6] = (u[6] & 0x0f) | 0x50
	u[8] = (u[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}
