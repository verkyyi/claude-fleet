package control

import (
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"time"
)

// A browser terminal's bytes through the nearest door (XX79): the hub keeps
// admission, the leases and the selection on its own two sockets exactly as for
// a direct attachment; only the payload goes browser → door → home. The door
// pairs the two halves of one pipe by a ticket the hub signs with the DOOR's
// own token hash — it verifies locally, needs nothing from the hub per pipe and
// holds no authority: the home still runs nothing before the hub's signed
// select (fba1, keyed with the home's token), and stops at the lease's end.
const (
	// CapTermVia: this node dials a door's pipe for a terminal attachment.
	CapTermVia = "term-via-door-v1"
	// DoorPipePath is the door's browser-facing listener: both halves dial it.
	DoorPipePath = "/v1/door/pipe"
	// DoorPipeTicketTTL bounds a ticket: it is used once, seconds after it is made.
	DoorPipeTicketTTL = 2 * time.Minute
	doorPipePrefix    = "fdp1"
)

// Door pipe roles: each pipe has exactly one of each.
const (
	DoorPipeBrowser = "browser"
	DoorPipeHome    = "home"
)

// TermDoor is one door a browser may take its terminal through.
type TermDoor struct {
	ID    string `json:"id"`
	URL   string `json:"url"`             // wss://host[:port]/v1/door/pipe
	Probe string `json:"probe,omitempty"` // https://host[:port]/healthz — the browser's RTT probe
	Label string `json:"label,omitempty"` // what the page says: 美国门
}

// DoorPipeTicket is one half's admission to one pipe at one door.
type DoorPipeTicket struct {
	V    int    `json:"v"`
	Door string `json:"door"`
	Pipe string `json:"pipe"`
	Role string `json:"role"`
	Iat  int64  `json:"iat"`
	Exp  int64  `json:"exp"`
}

var doorIDRE = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
var doorPipeRE = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

// ValidDoorID is a door's name in fleet.term_doors.
func ValidDoorID(id string) bool { return doorIDRE.MatchString(id) }

// ValidDoorPipeURL: a door's pipe is wss://host[:port]/v1/door/pipe, nothing
// else — no user, query, fragment, and never plain ws (a browser on https).
func ValidDoorPipeURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "wss" && u.Host != "" && u.User == nil && u.RawQuery == "" &&
		u.Fragment == "" && u.Path == DoorPipePath
}

// SignDoorPipe is the hub's half: keyed with the door's token hash.
func SignDoorPipe(t DoorPipeTicket, doorTokenHash string) string {
	return signStatement(doorPipePrefix, t, doorTokenHash)
}

// VerifyDoorPipe is the door's half: signed with its own token hash, for this
// door, a well-formed pipe and role, and in its window now.
func VerifyDoorPipe(s, doorTokenHash, door string, now time.Time) (DoorPipeTicket, error) {
	var t DoorPipeTicket
	bad := errors.New("door pipe ticket refused")
	if len(s) > 2048 {
		return t, bad
	}
	b, err := verifyStatement(doorPipePrefix, s, doorTokenHash)
	if err != nil {
		return t, bad
	}
	if json.Unmarshal(b, &t) != nil || t.V != 1 || t.Door != door || !doorPipeRE.MatchString(t.Pipe) ||
		(t.Role != DoorPipeBrowser && t.Role != DoorPipeHome) ||
		statementWindow(t.Iat, t.Exp, DoorPipeTicketTTL, now) != "" {
		return t, bad
	}
	return t, nil
}
