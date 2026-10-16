package control

import (
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"
)

// The terminal relay (claude-fleet#3838, EPIC #3836 C1): a person's browser
// reaches a terminal on their OWN home login — a worker session they own, or
// their personal terminal — over the same road as the chat relay:
//
//	browser ──wss /v1/term/connect?worker=… | ?target=personal──▶ hub (same origin, signed in)
//	hub ──TypeTermOpen {relay_id, secret, login}──▶ that login's agent (CapTerm only)
//	agent ──wss TermDataPath?id=…──▶ hub
//	hub ──first frame {"grant": "ftg1.…"}──▶ agent, which verifies it, then
//	agent ──as the login: `ccquota term-pty`──▶ a PTY on a grouped tmux view
//
// The grant is a hub statement (the chat relay's keying: this login's node token
// hash) whose prefix and audience name the TERMINAL — a chat statement never
// opens one, a grant never reaches a conversation — and which binds the person,
// the login, this relay and the target the hub resolved as theirs. The open
// carries no target: what is reached is only what the signed grant names, and a
// target is a fixed word or a fleet id, never a path, a command or a socket.
const (
	// TermDataPath is where the agent dials the data half of one terminal.
	TermDataPath = "/v1/node/term"

	// TypeTermOpen is a hub→node request: dial TermDataPath for this relay
	// and attach it to the target its grant names. Sent only to a node whose
	// hello listed CapTerm.
	TypeTermOpen = "term_open"

	// CapTerm is the hello capability of an agent that serves TypeTermOpen.
	CapTerm = "term"

	// TermAudience is the one audience a terminal grant carries.
	TermAudience = "term"

	// TermTargetPersonal names the person's personal terminal.
	TermTargetPersonal = "personal"
	// termWorkerPrefix prefixes a worker target: worker:<fleet_id>.
	termWorkerPrefix = "worker:"

	termGrantPrefix = "ftg1"
	// TermGrantMaxTTL bounds exp-iat: a grant is minted per relay, the moment
	// the agent attaches, and read once.
	TermGrantMaxTTL = 5 * time.Minute

	// TermFrameMax is the largest binary frame either side may send: bytes.
	TermFrameMax = 32 << 10
	// TermControlMax is the largest text (control) frame.
	TermControlMax = 1 << 10
	// TermColsMax / TermRowsMax bound a resize.
	TermColsMax = 1000
	TermRowsMax = 500
)

// TermOpen is the payload of TypeTermOpen: no target field on purpose.
type TermOpen struct {
	RelayID string `json:"relay_id"`
	Secret  string `json:"secret,omitempty"`
	Login   string `json:"login"`
}

// TermRelayHello is the first frame on the data stream, hub → agent (text).
type TermRelayHello struct {
	Grant string `json:"grant"`
}

// TermGrant is a verified terminal grant.
type TermGrant struct {
	V int `json:"v"`
	// Aud is TermAudience: a statement for any other service is refused.
	Aud    string `json:"aud"`
	Person string `json:"person"`
	Login  string `json:"login"`
	Relay  string `json:"relay"`
	// Target is TermTargetPersonal or worker:<fleet_id>, resolved by the hub
	// as the person's own.
	Target string `json:"target"`
	Iat    int64  `json:"iat"`
	Exp    int64  `json:"exp"`
}

var termFleetIDRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,63}$`)

// TermWorkerTarget is the target word for one worker window's fleet id.
func TermWorkerTarget(fleetID string) string { return termWorkerPrefix + fleetID }

// ValidTermTarget is whether t is a target a grant may name: the personal
// word, or worker:<fleet id> in the fleet id's own alphabet.
func ValidTermTarget(t string) bool {
	if t == TermTargetPersonal {
		return true
	}
	id, ok := strings.CutPrefix(t, termWorkerPrefix)
	return ok && termFleetIDRE.MatchString(id)
}

// SignTermGrant is the hub's half.
func SignTermGrant(g TermGrant, tokenHash string) string {
	return signStatement(termGrantPrefix, g, tokenHash)
}

// VerifyTermGrant is the agent's half: signed with this login's token hash,
// for the terminal, this login and this relay, a valid target, holding now.
func VerifyTermGrant(s, tokenHash, login, relay string, now time.Time) (*TermGrant, error) {
	bad := func(why string) error { return errors.New("terminal grant: " + why) }
	raw, err := verifyStatement(termGrantPrefix, s, tokenHash)
	if err != nil {
		return nil, bad(err.Error())
	}
	var g TermGrant
	if err := json.Unmarshal(raw, &g); err != nil || g.V != 1 || g.Person == "" {
		return nil, bad("malformed claims")
	}
	switch {
	case g.Aud != TermAudience:
		return nil, bad("for another service")
	case g.Login != login:
		return nil, bad("for another login")
	case g.Relay != relay:
		return nil, bad("for another relay")
	case !ValidTermTarget(g.Target):
		return nil, bad("no such target")
	}
	if why := statementWindow(g.Iat, g.Exp, TermGrantMaxTTL, now); why != "" {
		return nil, bad(why)
	}
	return &g, nil
}

// TermControl is one text frame of a terminal stream. From the browser only
// resize; from the agent ready (the PTY is up — input may start) and exit;
// from the hub hello and error.
type TermControl struct {
	T     string `json:"t"`
	Epoch uint64 `json:"epoch,omitempty"`
	Cols  int    `json:"cols,omitempty"`
	Rows  int    `json:"rows,omitempty"`
	Code  int    `json:"code,omitempty"`
	// hello's fields (the hub → browser): which terminal, which generation,
	// which connection, how it travels.
	V    int    `json:"v,omitempty"`
	Term string `json:"term,omitempty"`
	Gen  string `json:"gen,omitempty"`
	Conn string `json:"conn,omitempty"`
	Mode string `json:"mode,omitempty"`
	// error's.
	Err string `json:"error,omitempty"`
	Msg string `json:"msg,omitempty"`
}

// ParseTermResize reads a browser's control frame: only a resize, in bounds.
func ParseTermResize(raw []byte) (cols, rows int, err error) {
	if len(raw) > TermControlMax {
		return 0, 0, errors.New("control frame too large")
	}
	var c TermControl
	if err := json.Unmarshal(raw, &c); err != nil {
		return 0, 0, errors.New("control frame is not JSON")
	}
	if c.T != "resize" {
		return 0, 0, errors.New("unknown control " + truncate(c.T, 16))
	}
	if c.Cols < 1 || c.Cols > TermColsMax || c.Rows < 1 || c.Rows > TermRowsMax {
		return 0, 0, errors.New("resize out of range")
	}
	return c.Cols, c.Rows, nil
}

// ParseTermAgentControl reads an agent's control frame: ready or exit.
func ParseTermAgentControl(raw []byte) (TermControl, error) {
	var c TermControl
	if len(raw) > TermControlMax {
		return c, errors.New("control frame too large")
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return c, errors.New("control frame is not JSON")
	}
	switch c.T {
	case "ready":
		return c, nil
	case "exit":
		return TermControl{T: "exit", Code: c.Code}, nil
	}
	return c, errors.New("unknown control " + truncate(c.T, 16))
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
