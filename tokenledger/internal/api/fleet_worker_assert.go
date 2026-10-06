package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
)

// A worker assertion — 执行会话声明 (claude-fleet#1810, EPIC #1813 C8).
//
// A node's request is the node's: its enrollment token says which machine and
// login asked, never which session on it. When a session's own tool service
// (claude-fleet bin/fleet-mcp.py) does something on another machine — a spawn
// the hub places elsewhere, a message to a session there — it has already
// verified that session's worker credential (C7), and it hands the hub a
// statement of who the call is for, signed by the node:
//
//	fwa1.<base64url claims JSON>.<base64url HMAC-SHA256>
//
// keyed with the node's token hash (HashToken: SHA-256 hex of the enrollment
// token, which the node computes from its token and the hub already stores —
// so the hub needs no new secret, and only the node that holds the token, or
// the hub, can sign for it). It travels in the X-Fleet-Worker header of
// /v1/node/place and in a relay's `worker` field. Claims:
//
//	v           1
//	worker_id   <fleet UUID>/<fleet_id> — the session (fleetid.ParseWorkerID)
//	fleet_uuid  the fleet that session runs in: one of the node's own
//	fid         the session's lifelong @fleet_id
//	key         its key when the call was made (issue-N, <slug>:issue-N, scratch-N)
//	repo issue origin node   what it was working on, its parent, the machine
//	iat exp     issued / expires (unix seconds; at most workerAssertMaxTTL apart)
//
// No assertion = the node's own call, exactly as before.
const (
	workerAssertPrefix = "fwa1"
	workerAssertHeader = "X-Fleet-Worker"
	// workerAssertMaxTTL bounds exp-iat: a relay may wait in a node's outbox
	// while the hub is away, so the session's tool service signs a message
	// for a day (its credential's own life) and everything else for minutes.
	workerAssertMaxTTL = 24*time.Hour + time.Minute
	workerAssertSkew   = time.Minute
)

// workerClaims is a verified assertion's content.
type workerClaims struct {
	V         int    `json:"v"`
	WorkerID  string `json:"worker_id"`
	FleetUUID string `json:"fleet_uuid"`
	Fid       string `json:"fid"`
	Key       string `json:"key"`
	Repo      string `json:"repo"`
	Issue     string `json:"issue"`
	Origin    string `json:"origin"`
	Node      string `json:"node"`
	Iat       int64  `json:"iat"`
	Exp       int64  `json:"exp"`
}

// signWorkerAssertion is the node's half, for tests: what fleet-mcp.py prints.
func signWorkerAssertion(c workerClaims, tokenHash string) string {
	raw, _ := json.Marshal(c)
	body := workerAssertPrefix + "." + base64.RawURLEncoding.EncodeToString(raw)
	mac := hmac.New(sha256.New, []byte(tokenHash))
	mac.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// verifyWorkerAssertion checks an assertion against the token hash of the node
// that sent it. Any fault is UNAUTHENTICATED: a statement that does not hold
// is never read as "no statement" (the node's own call) — it is refused.
func verifyWorkerAssertion(a, tokenHash string, now time.Time) (*workerClaims, error) {
	bad := func(why string) error { return fault("UNAUTHENTICATED", "worker assertion: "+why) }
	parts := strings.Split(strings.TrimSpace(a), ".")
	if len(parts) != 3 || parts[0] != workerAssertPrefix {
		return nil, bad("malformed")
	}
	got, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[2], "="))
	if err != nil {
		return nil, bad("malformed")
	}
	mac := hmac.New(sha256.New, []byte(tokenHash))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(mac.Sum(nil), got) {
		return nil, bad("signature does not verify (not signed by this node)")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil, bad("malformed")
	}
	var c workerClaims
	if err := json.Unmarshal(raw, &c); err != nil || c.V != 1 {
		return nil, bad("malformed claims")
	}
	fl, fid, err := fleetid.ParseWorkerID(c.WorkerID)
	if err != nil || fl != c.FleetUUID || (c.Fid != "" && fid != c.Fid) {
		return nil, bad("worker_id must be <fleet_uuid>/<fid>")
	}
	iat, exp := time.Unix(c.Iat, 0), time.Unix(c.Exp, 0)
	switch {
	case !exp.After(now):
		return nil, bad("expired")
	case iat.After(now.Add(workerAssertSkew)), exp.Sub(iat) > workerAssertMaxTTL, !exp.After(iat):
		return nil, bad("issued/expires out of range")
	}
	return &c, nil
}

// speaksAs reports whether a worker_id names the asserted session: by its
// identity (<fleet UUID>/<fid>) or by the key it had (<fleet UUID>/<key>, the
// alias kept for one version, claude-fleet#1646).
func (c *workerClaims) speaksAs(wid string) bool {
	return wid == c.WorkerID || (c.Key != "" && wid == c.FleetUUID+"/"+c.Key)
}

// id is the asserted worker_id, "" for none.
func (c *workerClaims) id() string {
	if c == nil {
		return ""
	}
	return c.WorkerID
}

// label is how the audit names the session: its key when it had one.
func (c *workerClaims) label() string {
	if c == nil {
		return ""
	}
	if c.Key != "" {
		return c.Key
	}
	return c.Fid
}
