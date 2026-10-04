// Package control is the wire format of the fleet control channel: the one
// long-lived connection every agent dials OUT to the hub (claude-fleet#1408).
//
// Why the agent dials and not the hub: the hub runs in a cloud region that
// cannot reach into anyone's home network, and the machines it describes sit
// behind NAT. A connection the node opens over 443 is the only path that
// exists in both directions, so it carries everything the hub will ever say to
// a node — today only the heartbeat, later the reads and writes of C2/C3/C6.
//
// Every message is one JSON object with a type, an op_id and the sender's
// protocol version. The version is on EVERY message, not only the hello, so a
// node upgraded mid-connection is never read with the old rules — and so the
// hub can refuse a write to a node it cannot speak to, while still listing it.
package control

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Proto is the protocol version this build speaks.
//
// Bump it when a message changes meaning; adding an optional field does not
// need a bump, because both sides ignore keys they do not know.
const Proto = 1

// MinProto is the oldest node protocol the hub still accepts writes from. A
// node below it stays listed (with its version, so the reason is visible) but
// every write op addressed to it is refused before it leaves the hub.
const MinProto = 1

// Path is where the hub accepts the control channel.
const Path = "/v1/node/connect"

// Message types.
const (
	// TypeHello is the node's first message: who it is and what it speaks.
	TypeHello = "hello"
	// TypeWelcome is the hub's answer to a hello.
	TypeWelcome = "welcome"
	// TypeHeartbeat is the node's periodic status report.
	TypeHeartbeat = "heartbeat"
	// TypeAck acknowledges a message by op_id.
	TypeAck = "ack"
	// TypeError reports a refused message by op_id.
	TypeError = "error"
)

// Error codes.
const (
	CodeProtoMismatch = "PROTO_MISMATCH"
	CodeBadMessage    = "BAD_MESSAGE"
)

// ErrIncompatible is returned when a write is addressed to a node whose
// protocol version the hub does not accept writes from.
var ErrIncompatible = errors.New("node protocol version is not compatible with this hub")

// Message is one frame on the control channel.
type Message struct {
	Type    string          `json:"type"`
	OpID    string          `json:"op_id"`
	Proto   int             `json:"proto"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// Error is a refusal carried on a TypeError message.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// New builds a message of the given type carrying payload, with a fresh op_id.
func New(typ string, payload any) (Message, error) {
	m := Message{Type: typ, OpID: NewOpID(), Proto: Proto}
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return Message{}, fmt.Errorf("encode %s payload: %w", typ, err)
		}
		m.Payload = b
	}
	return m, nil
}

// NewOpID returns a random 128-bit identifier, hex encoded.
func NewOpID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Compatible reports whether the hub accepts writes from a node speaking proto.
func Compatible(proto int) bool {
	return proto >= MinProto && proto <= Proto
}

// Hello is the payload of TypeHello.
type Hello struct {
	// HeartbeatMS is how often (ms) this node sends a heartbeat. The hub
	// judges a node lost after three of them go missing, so the threshold
	// follows the node's own cadence instead of a constant both sides must
	// agree on.
	HeartbeatMS int `json:"heartbeat_ms"`
	// AgentVersion is the ccquota build.
	AgentVersion string `json:"agent_version,omitempty"`
}

// Welcome is the payload of TypeWelcome.
type Welcome struct {
	// Accepted is false when the hub will not send this node writes; the
	// connection stays up so the node is still listed and still reports.
	Accepted bool   `json:"accepted"`
	HubProto int    `json:"hub_proto"`
	MinProto int    `json:"min_proto"`
	Reason   string `json:"reason,omitempty"`
}

// Heartbeat is the payload of TypeHeartbeat: what one login on one machine
// looks like right now.
type Heartbeat struct {
	Hostname string `json:"hostname"`
	OSUser   string `json:"os_user,omitempty"`
	OS       string `json:"os,omitempty"`
	Arch     string `json:"arch,omitempty"`

	// Load1 is the one-minute load average; NCPU the logical core count. Both
	// zero when the platform would not say.
	Load1 float64 `json:"load1"`
	NCPU  int     `json:"ncpu"`
	// MemFreeBytes is memory available without swapping; MemTotalBytes the
	// machine's total. Zero when unknown.
	MemFreeBytes  uint64 `json:"mem_free_bytes"`
	MemTotalBytes uint64 `json:"mem_total_bytes"`

	// Sessions is how many fleet sessions (worker + scratch windows) this
	// login runs across all its fleets.
	Sessions int `json:"sessions"`
	// MachineID is the claude-fleet control identity (fleet-control.py's
	// machine_id), when the login has claude-fleet installed.
	MachineID string `json:"machine_id,omitempty"`
	// Fleets is this login's fleets, each with its window snapshot, as
	// fleet-control.py's discover + fleet_status report them. Nil when the
	// login has no claude-fleet, or the read failed (FleetError says why).
	Fleets     []Fleet `json:"fleets,omitempty"`
	FleetError string  `json:"fleet_error,omitempty"`
	// FleetVersion is the claude-fleet install's HEAD, when known.
	FleetVersion string `json:"fleet_version,omitempty"`

	AgentVersion string    `json:"agent_version,omitempty"`
	ObservedAt   time.Time `json:"observed_at"`
}

// Fleet is one fleet's snapshot. Workers is relayed as fleet-control.py
// printed it: the hub stores it verbatim and C2 reads it, so this package does
// not freeze a schema that belongs to claude-fleet.
type Fleet struct {
	FleetID string          `json:"fleet_id"`
	Name    string          `json:"name"`
	Repo    string          `json:"repo,omitempty"`
	State   string          `json:"state,omitempty"`
	Workers json.RawMessage `json:"workers,omitempty"`
	Count   int             `json:"count"`
}
