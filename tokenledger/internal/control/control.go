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
	// TypeAccountOp is a hub→node write: open or close one person's OS login
	// on that machine (claude-fleet#1411). Only an admin node executes it.
	TypeAccountOp = "account_op"
	// TypeAccountResult is the node's answer to a TypeAccountOp, carrying the
	// op's op_id. The hub acks it; until then the node keeps it and re-sends it
	// on its next connection, so a result is never lost to a dropped link.
	TypeAccountResult = "account_result"
	// TypeRequest is a hub→node READ (claude-fleet#1409): one fleet-control.py
	// method from ReadMethods, answered by a TypeResult (or TypeError) with the
	// same op_id. Sent only to a node whose hello listed CapRead.
	TypeRequest = "request"
	// TypeResult answers a TypeRequest or a TypeWrite.
	TypeResult = "result"
	// TypeWrite is a hub→node WRITE (claude-fleet#1410): fleet-control.py's
	// `submit`, carrying an operation the hub has already journalled. The
	// node's controller journals it again under the same operation id before
	// it starts a detached executor, so the answer (a TypeResult with the
	// node's operation record, or a TypeError) says only that the node took
	// it — what the executor did is read back later with operation_get. Sent
	// only to a node whose hello listed CapWrite.
	TypeWrite = "write"
	// TypeSSHCA is a hub→node write: trust this SSH user CA for new
	// connections to this machine (claude-fleet#1412). Only an admin node
	// executes it; it is idempotent and re-sent on every admin connect.
	TypeSSHCA = "ssh_ca"
	// TypeSSHCAResult is the node's answer to a TypeSSHCA, by op_id.
	TypeSSHCAResult = "ssh_ca_result"
	// TypeRelay carries one node-to-node relay (claude-fleet#1421): a child's
	// report to its parent, or a message to a worker, on another machine.
	// Node→hub, the op_id is the relay's own id; the hub stores it and
	// answers TypeAck (stored, or already stored) or TypeError (refused, for
	// good). Hub→node, the op_id is again the relay id, and the node answers
	// TypeRelayResult. Sent only to a node whose hello listed CapRelay.
	TypeRelay = "relay"
	// TypeRelayResult is a node's answer to a hub TypeRelay.
	TypeRelayResult = "relay_result"
	// TypeWorkers is the hub's map of where the node owner's workers live on
	// every machine (claude-fleet#1421), pushed after heartbeats to a node
	// that listed CapRelay. The node keeps it as claude-fleet's local cache
	// ($FLEET_CONF_DIR/control/hub-workers.tsv), so routing never asks the
	// network.
	TypeWorkers = "workers"
)

// CapRead is the hello capability a node lists when it answers TypeRequest.
// A capability, not a proto bump: an older agent simply never says it, so the
// hub never asks it and serves that node from its last heartbeat instead.
const CapRead = "read"

// CapWrite is the hello capability a node lists when it accepts TypeWrite
// (claude-fleet#1410). An agent that never says it is never sent a write: the
// hub refuses the operation as UNAVAILABLE before journalling anything.
const CapWrite = "write"

// CapRelay is the hello capability a node lists when it sends and takes
// TypeRelay and keeps a TypeWorkers map (claude-fleet#1421). The hub never
// pushes a relay or a map to a node that did not say it; relays for it wait.
const CapRelay = "relay"

// CapMove is the hello capability a node lists when it takes a session moved
// to it through the hub (claude-fleet#1426): before it hands a
// worker_move_in write to claude-fleet, it downloads the move's transcript
// bundle over HTTP. The hub never moves a session to a node that did not say it.
const CapMove = "move"

// Relay kinds.
const (
	RelayChildReport = "child_report"
	RelayMessage     = "message"
)

// MaxRelayPayload bounds one relay's payload: a child report is a few hundred
// bytes, a message at most a few thousand.
const MaxRelayPayload = 16 << 10

// Relay is the payload of TypeRelay, in both directions. From and To are
// worker_ids; the hub routes on To's fleet and checks From's belongs to the
// sending node.
type Relay struct {
	ID      string          `json:"id"`
	Kind    string          `json:"kind"`
	From    string          `json:"from"`
	To      string          `json:"to"`
	Payload json.RawMessage `json:"payload"`
	// FromNode is the sender's machine as the hub's roster names it; set by
	// the hub on the way down, never trusted from a sender.
	FromNode string `json:"from_node,omitempty"`
}

// RelayResult is the payload of TypeRelayResult.
type RelayResult struct {
	ID string `json:"id"`
	// OK is "applied (or already applied) on this node". Retry, with OK
	// false, asks the hub to keep it pending and push it again later; with
	// neither, the relay failed for good.
	OK     bool   `json:"ok"`
	Retry  bool   `json:"retry,omitempty"`
	Detail string `json:"detail,omitempty"`
}

// WorkerLoc is one worker in a TypeWorkers map.
type WorkerLoc struct {
	WorkerID  string `json:"worker_id"`
	Node      string `json:"node"`
	OriginWID string `json:"origin_wid,omitempty"`
}

// Workers is the payload of TypeWorkers.
type Workers struct {
	Rows []WorkerLoc `json:"rows"`
}

// ReadMethods is the whole list of fleet-control.py methods the hub may ask a
// node for over the channel. All are reads; a write never travels as a
// request — it is a TypeWrite naming one of WriteMethods, with its own journal
// (claude-fleet#1410). The gh_* reads answer from the node's fleet-gh.sh (its
// daemons' local copy first), exactly as the SSH hub's did.
var ReadMethods = map[string]bool{
	"discover":      true,
	"fleet_status":  true,
	"config_get":    true,
	"operation_get": true,
	"gh_issue_view": true,
	"gh_pr_view":    true,
	"gh_pr_checks":  true,
}

// WriteMethods is the whole list of fleet-control.py methods a TypeWrite may
// name: `submit`, whose params are the operation envelope. Which actions a
// submit may carry is fleet-control.py's own whitelist (validate_write), not
// something the channel widens.
var WriteMethods = map[string]bool{
	"submit": true,
}

// Error codes.
const (
	CodeProtoMismatch = "PROTO_MISMATCH"
	CodeBadMessage    = "BAD_MESSAGE"
	// CodeNotAdmin refuses an account op on a node that is not its machine's
	// admin agent. The node says it itself; the hub never relies on that alone.
	CodeNotAdmin = "NOT_ADMIN"
	// CodeBadArgs refuses an account op whose arguments fail the node's own
	// whitelist.
	CodeBadArgs = "BAD_ARGS"
	// CodeRefused is a node declining a request it does not serve (a method
	// outside ReadMethods).
	CodeRefused = "REFUSED"
	// CodeUnknownOutcome is a write the node may or may not have taken: its
	// controller ran but did not answer in a form that says. The hub
	// journals it as unknown and never sends it again.
	CodeUnknownOutcome = "UNKNOWN_OUTCOME"
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
	// Admin is this login's claim to be its machine's admin agent — the
	// operator's login, with password-less sudo — and so willing to run
	// account ops (claude-fleet#1411). A claim, not a grant: the hub also
	// requires the login on its own allowlist before it sends one.
	Admin bool `json:"admin,omitempty"`
	// Capabilities lists optional message families this node serves
	// (CapRead). Absent on an agent older than claude-fleet#1409.
	Capabilities []string `json:"capabilities,omitempty"`
}

// HasCap reports whether a hello listed capability c.
func (h Hello) HasCap(c string) bool {
	for _, x := range h.Capabilities {
		if x == c {
			return true
		}
	}
	return false
}

// Request is the payload of TypeRequest: one fleet-control.py rpc call. The
// node fills in its own machine_id; Params goes through verbatim.
type Request struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Result is the payload of TypeResult: fleet-control.py's result, verbatim,
// plus the machine_id it answered as. A fleet-control.py refusal comes back
// as a TypeError carrying its code and message instead.
type Result struct {
	MachineID string          `json:"machine_id,omitempty"`
	Result    json.RawMessage `json:"result"`
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
	// login runs across all its fleets. It sums only the fleets that were
	// read: a fleet whose status read failed is State "unknown" with Count 0,
	// so when UnreadableFleets is non-empty this number is a floor, never the
	// count (claude-fleet#1465) — read it through SessionsCount.
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

	// Routes is how people reach this machine's sshd from outside
	// (claude-fleet#1414): its tailnet name, a public port the gateway
	// forwards to it. The hub merges them into the route list it hands
	// `fleet connect`, which measures each and picks the best. Absent on an
	// agent older than #1414, or one that knows no route.
	Routes []NodeRoute `json:"routes,omitempty"`

	// Ready says whether this login can take a NEW session
	// (claude-fleet#1475): gh is logged in, a Claude or Codex credential is
	// usable and every hosted repo's checkout exists. nil on an agent older
	// than #1475 — placement reads that as ready, so an old node is never
	// silently dropped. NotReady names what is missing when it is false.
	Ready    *bool  `json:"ready,omitempty"`
	NotReady string `json:"not_ready,omitempty"`

	AgentVersion string    `json:"agent_version,omitempty"`
	ObservedAt   time.Time `json:"observed_at"`
}

// FleetStateUnknown is a fleet whose fleet_status read failed: the agent
// sends it with Count 0, which is "could not count", never "none".
const FleetStateUnknown = "unknown"

// UnreadableFleets names this beat's fleets whose status could not be read
// (claude-fleet#1465), each as "<name>: <reason>" when the agent sent one.
// Empty when every fleet was read.
func (hb Heartbeat) UnreadableFleets() []string {
	var out []string
	for _, f := range hb.Fleets {
		if f.State != FleetStateUnknown {
			continue
		}
		name := f.Name
		if name == "" {
			name = f.FleetID
		}
		if f.Error != "" {
			name += ": " + f.Error
		}
		out = append(out, name)
	}
	return out
}

// SessionsCount is this login's session count, or nil when any of its fleets
// could not be read — a machine that may run 22 sessions must never read as
// idle (claude-fleet#1465).
func (hb Heartbeat) SessionsCount() *int {
	if len(hb.UnreadableFleets()) > 0 {
		return nil
	}
	n := hb.Sessions
	return &n
}

// NodeRoute is one way into a machine's sshd: a name people see ("tailnet",
// "public"), a host and a port (0 = 22).
type NodeRoute struct {
	Name string `json:"name"`
	Host string `json:"host"`
	Port int    `json:"port,omitempty"`
}

// Fleet is one fleet's snapshot. Workers is relayed as fleet-control.py
// printed it: the hub stores it verbatim and C2 reads it, so this package does
// not freeze a schema that belongs to claude-fleet.
type Fleet struct {
	FleetID string `json:"fleet_id"`
	Name    string `json:"name"`
	Repo    string `json:"repo,omitempty"`
	// Checkout and Agent are the rest of discover's inventory row
	// (claude-fleet#1409): checkout is the third input of the fleet UUID, so
	// the hub can re-derive it and refuse a heartbeat whose ids do not add
	// up. Empty from an agent older than that.
	Checkout string `json:"checkout,omitempty"`
	Agent    string `json:"agent,omitempty"`
	// Repos is every repo the fleet hosts (claude-fleet#1512): its own repo
	// first, then the repos/ overlays (#788) — fleet_repos. Placement and
	// moves match a repo against any of them. Absent from an older agent: the
	// hub then reads [Repo], as it always has.
	Repos   []string        `json:"repos,omitempty"`
	State   string          `json:"state,omitempty"`
	Workers json.RawMessage `json:"workers,omitempty"`
	Count   int             `json:"count"`
	// Error is why the status read failed, when State is "unknown"
	// (claude-fleet#1465): fleet-control.py's fault, adapter stderr included.
	// Absent from an older agent — the state alone still says "unknown".
	Error string `json:"error,omitempty"`
}

// Account ops (claude-fleet#1411). There are exactly two, and both run one of
// claude-fleet's own scripts with arguments fixed by the node, not the hub:
//
//	create  fleet-login-new.sh <login> --full-name <name> --share-pool --apply
//	remove  fleet-login-remove.sh <login> --keep-home --apply
//
// The hub chooses only the login and the display name, and both are checked
// against ValidLogin / ValidFullName on the node before anything runs.
const (
	AccountCreate = "create"
	AccountRemove = "remove"
)

// AccountOp is the payload of TypeAccountOp.
type AccountOp struct {
	Op       string `json:"op"`
	Login    string `json:"login"`
	FullName string `json:"full_name,omitempty"`
}

// AccountResult is the payload of TypeAccountResult.
type AccountResult struct {
	Op    string `json:"op"`
	Login string `json:"login"`
	// OK is the script's exit 0.
	OK bool `json:"ok"`
	// Exit is the script's exit status; -1 when it never ran or was killed.
	Exit int `json:"exit"`
	// Exists is fleet-login-new.sh's exit 3: the login (or its home) is
	// already on this machine. Never read as success — it may be someone
	// else's login.
	Exists bool `json:"exists,omitempty"`
	// Detail is the tail of the script's output, or why it did not run.
	Detail string `json:"detail,omitempty"`
}

// MaxLoginLen bounds a hub-generated login. macOS allows longer short names;
// a short one stays readable in `ls /Users` and in a prompt.
const MaxLoginLen = 16

// ValidLogin is the one shape of login the hub may generate and a node may
// accept: a lowercase letter, then lowercase letters and digits. No dot, dash
// or underscore, so it can never be mistaken for an option or a path.
func ValidLogin(s string) bool {
	return len(s) > 0 && s[0] >= 'a' && s[0] <= 'z' && ValidExistingLogin(s)
}

// ValidExistingLogin is the shape of a login the operator may NAME — one
// that already exists on a machine and is adopted, mapped to a person
// (CCQUOTA_FLEET_PRINCIPAL_LOGINS) or put on a certificate — as opposed to
// one the hub would create. The same alphabet as ValidLogin, so it still
// cannot be an option or a path, but a leading digit is allowed: macOS
// permits it, and `24haowan` is a real login (claude-fleet#1458). A create
// op keeps ValidLogin on both sides, so a login of this shape is never
// minted or made, only recorded.
func ValidExistingLogin(s string) bool {
	if len(s) < 2 || len(s) > MaxLoginLen {
		return false
	}
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z':
		case c >= '0' && c <= '9':
		default:
			return false
		}
	}
	switch s {
	case "root", "admin", "daemon", "nobody", "guest", "shared":
		return false
	}
	return true
}

// ValidFullName bounds the display name passed to sysadminctl -fullName:
// 1–64 characters, no control characters, and never starting with '-'.
func ValidFullName(s string) bool {
	n := 0
	for _, c := range s {
		if c < 0x20 || c == 0x7f {
			return false
		}
		n++
	}
	return n >= 1 && n <= 64 && s[0] != '-'
}

// SSH user CA (claude-fleet#1412). The hub sends only the CA's public key; the
// node fixes everything else itself — the two paths it writes, the one line
// of sshd configuration, and the order: write, `sshd -t`, roll back on
// failure. It never touches sshd_config itself, any authorized_keys, or a
// running sshd.
const (
	// SSHCAKeyPath is where a node keeps the trusted CA public key.
	SSHCAKeyPath = "/etc/ssh/fleet_user_ca.pub"
	// SSHCAConfPath is the sshd_config.d drop-in that points sshd at it.
	SSHCAConfPath = "/etc/ssh/sshd_config.d/100-fleet-user-ca.conf"
)

// SSHCA is the payload of TypeSSHCA.
type SSHCA struct {
	// PublicKey is the CA public key, one authorized_keys line, no options.
	PublicKey string `json:"public_key"`
}

// SSHCAResult is the payload of TypeSSHCAResult.
type SSHCAResult struct {
	OK bool `json:"ok"`
	// Changed is false when the machine already trusted exactly this key.
	Changed bool `json:"changed"`
	// RolledBack: the new configuration failed `sshd -t` and the previous
	// files were put back; sshd was never asked to read the bad one.
	RolledBack bool   `json:"rolled_back,omitempty"`
	Detail     string `json:"detail,omitempty"`
}

// The relay (claude-fleet#1413): when a person cannot reach a machine
// directly, the hub carries their SSH connection over the one path that always
// exists — the node's own outbound link. The hub never decrypts it; it only
// pairs two WebSockets and copies bytes.
//
//	client ──wss SSHRelayPath?node=m4──▶ hub ──TypeSSHRelayOpen on the control channel──▶ agent
//	agent  ──wss SSHRelayDataPath?id=…──▶ hub        agent ──tcp──▶ 127.0.0.1:22
//
// The data stream is a SECOND connection the agent dials, not frames on the
// control channel: a 10MB scp must never queue a heartbeat behind it, and the
// control channel's read limit is sized for JSON, not for a byte stream.
const (
	// SSHRelayPath is where a client asks for a relay to a machine.
	SSHRelayPath = "/v1/ssh-relay/connect"
	// SSHRelayDataPath is where the agent dials the data half of one relay.
	SSHRelayDataPath = "/v1/node/ssh-relay"

	// TypeSSHRelayOpen is a hub→node request: dial SSHRelayDataPath for this
	// relay and splice it to the local sshd. Sent only to a node whose hello
	// listed CapSSHRelay.
	TypeSSHRelayOpen = "ssh_relay_open"

	// CapSSHRelay is the hello capability of an agent that serves TypeSSHRelayOpen.
	CapSSHRelay = "ssh_relay"

	// SSHRelaySigNamespace is the ssh-keygen -Y namespace a client signs the
	// hub's relay challenge under. A signature made for anything else (git
	// commits use "git", files "file") is never accepted as a relay login.
	SSHRelaySigNamespace = "fleet-relay@claude-fleet"

	// RoutesPath is where `fleet connect` asks which machines it may reach
	// and the ways in (claude-fleet#1414).
	RoutesPath = "/v1/fleet/routes"
	// RoutesSigNamespace is the ssh-keygen -Y namespace a client signs its
	// route-list request under (the message is RoutesSigMessage).
	RoutesSigNamespace = "fleet-routes@claude-fleet"

	// SessionsPath is where a sidebar asks for its person's sessions on every
	// machine (claude-fleet#1423); since claude-fleet#1475 it admits a
	// connection certificate the way RoutesPath does, so a colleague's
	// sidebar needs no token at all.
	SessionsPath = "/v1/fleet/fleet_sessions"
	// SessionsSigNamespace is the ssh-keygen -Y namespace a sidebar signs
	// its session-list request under (the message is SessionsSigMessage).
	SessionsSigNamespace = "fleet-sessions@claude-fleet"
)

// RoutesSigMessage is what a client signs to ask for its route list with a
// connection certificate: a timestamp the hub accepts only near its own clock.
func RoutesSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-routes %d", unix)
}

// SessionsSigMessage is what a sidebar signs to read its sessions with a
// connection certificate (claude-fleet#1475), same shape as RoutesSigMessage.
func SessionsSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-sessions %d", unix)
}

// `fleet` with no argument (claude-fleet#1470): the device renews its
// certificate by its own key, and asks the hub which of its machines to enter.
// Each request signs under its own namespace, like the relay and the route
// list, so no signature is ever good for more than the one thing it was made
// for.
const (
	// RenewPath is where a registered device renews its certificate without
	// a scan: POST {public_key, ts, sig} with sig = ssh-keygen -Y sign of
	// RenewSigMessage(ts) under RenewSigNamespace by the DEVICE key (not the
	// certificate — the one being renewed may have run out).
	RenewPath         = "/v1/fleet/login/renew"
	RenewSigNamespace = "fleet-renew@claude-fleet"
	// HomePath is where `fleet` asks which machine to enter: POST
	// {cert, sig, ts, last} like RoutesPath, signed under HomeSigNamespace
	// over HomeSigMessage(ts).
	HomePath         = "/v1/fleet/home"
	HomeSigNamespace = "fleet-home@claude-fleet"
)

// RenewSigMessage is what a device signs to renew its certificate.
func RenewSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-renew %d", unix)
}

// HomeSigMessage is what a client signs to ask which machine to enter.
func HomeSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-home %d", unix)
}

// A write by connection certificate (claude-fleet#1487, EPIC #1479 C8): a
// sidebar on another machine — or the `fleet` shell, which holds no viewer
// token — acts on one of its person's workers through bin/fleet-hub-write.sh.
const (
	// WritePath takes POST {cert, sig, ts, tool, args_json}: tool is one of
	// the hub's write tools (or operation_get, to read the result back),
	// args_json the tool's arguments as the exact JSON text that was signed.
	WritePath = "/v1/fleet/write"
	// WriteSigNamespace is the ssh-keygen -Y namespace the request is signed
	// under; the message is WriteSigMessage, so a signature is good for this
	// one write and nothing else — not another tool, not other arguments.
	WriteSigNamespace = "fleet-write@claude-fleet"
)

// WriteSigMessage is what a client signs to write by certificate: the
// timestamp, the tool and the SHA-256 (hex) of the args_json bytes it sends.
func WriteSigMessage(unix int64, tool, argsSHA256 string) string {
	return fmt.Sprintf("fleet-write %d %s %s", unix, tool, argsSHA256)
}

// The OAuth refresh relay (claude-fleet#1490): the hub's own egress may sit
// where a provider's token endpoint refuses it — the production hub runs in
// Shenzhen, and auth.openai.com answers a mainland IP with 403
// unsupported_country_region_territory — so the ONE outbound POST a refresh
// is travels by an admin node instead. The hub stays the only holder of the
// refresh token and the only writer per account; the node receives the form
// for one request, posts it once from its own network and hands back the
// provider's answer verbatim. Nothing is written or logged on the node: the
// form and the answer live in one goroutine's memory and die with it.
//
//	hub  ──TypeOAuthRefresh {provider, form}──▶ admin node ──POST──▶ provider
//	hub  ◀──TypeOAuthRefreshResult {status, body}── admin node ◀───────┘
//
// The node fixes the token endpoint itself, by provider (control.OAuthTokenURL
// on the agent side): a relay is a way to refresh a Claude or Codex token,
// never a general forwarder, so a hub can neither name a host nor send a body
// anywhere else.
const (
	// TypeOAuthRefresh is the hub→node request. Sent only to a connected
	// admin node whose hello listed CapOAuthRefresh.
	TypeOAuthRefresh = "oauth_refresh"
	// TypeOAuthRefreshResult is the node's answer, by op_id. A refusal (not
	// admin, unknown provider, malformed) comes back as a TypeError instead.
	TypeOAuthRefreshResult = "oauth_refresh_result"
	// CapOAuthRefresh is the hello capability of an admin agent that relays
	// refreshes. An older agent never says it and is never asked.
	CapOAuthRefresh = "oauth_refresh"
	// MaxOAuthRefreshBody bounds the provider answer a node hands back: a
	// token response is a few KB; a 403 page from a proxy can be more.
	MaxOAuthRefreshBody = 64 << 10
)

// The providers' public token endpoints — the same ones the Claude Code and
// Codex CLIs refresh with. Here, not in credvault, because the NODE picks the
// endpoint for a relayed refresh (never the hub), and the agent must not
// depend on the vault.
const (
	ClaudeTokenURL = "https://platform.claude.com/v1/oauth/token"
	CodexTokenURL  = "https://auth.openai.com/oauth/token"
)

// OAuthTokenURL is the token endpoint for provider; "" for one the relay does
// not serve (github has no refresh).
func OAuthTokenURL(provider string) string {
	switch provider {
	case "claude":
		return ClaudeTokenURL
	case "codex":
		return CodexTokenURL
	}
	return ""
}

// OAuthRefresh is the payload of TypeOAuthRefresh.
type OAuthRefresh struct {
	// Provider is claude or codex; the node picks the endpoint from it.
	Provider string `json:"provider"`
	// Form is the JSON body of the token request, exactly as the hub would
	// have posted it itself (grant_type, refresh_token, client_id, scope).
	// A secret: the node never logs or stores it.
	Form map[string]string `json:"form"`
}

// OAuthRefreshResult is the payload of TypeOAuthRefreshResult: what the
// provider answered, verbatim, or why the node could not ask it.
type OAuthRefreshResult struct {
	// Status is the provider's HTTP status; 0 when the request never got an
	// answer (Error says why).
	Status int `json:"status"`
	// Body is the provider's answer body, truncated at MaxOAuthRefreshBody.
	// On success it carries the new tokens: a secret the hub seals at once.
	Body string `json:"body,omitempty"`
	// Error is a transport failure on the node (dial, TLS, timeout) — never
	// a provider refusal, which comes back as its status and body.
	Error string `json:"error,omitempty"`
}

// SSHRelayOpen is the payload of TypeSSHRelayOpen.
type SSHRelayOpen struct {
	// RelayID names the relay; the agent dials SSHRelayDataPath?id=<RelayID>.
	RelayID string `json:"relay_id"`
	// Secret is a one-time value the agent echoes back as the X-Relay-Secret
	// header, so a data stream cannot be attached to someone else's relay by
	// another endpoint that guessed its id.
	Secret string `json:"secret,omitempty"`
}

// SSHRelayHello is the client-side handshake on SSHRelayPath, one JSON text frame
// each way before any byte of the SSH stream:
//
//	hub → client  {"type":"challenge","nonce":"…"}          (only when the HTTP
//	              request carried no session or token)
//	client → hub  {"type":"auth","cert":"…","sig":"…"}       an SSH user cert
//	              signed by the hub's CA, and an ssh-keygen -Y sign signature
//	              over the nonce under SSHRelaySigNamespace by the cert's key
//	hub → client  {"type":"ready"} | {"type":"error","code":…,"message":…}
//
// After "ready" every frame is binary: the SSH stream, verbatim.
type SSHRelayHello struct {
	Type    string `json:"type"`
	Nonce   string `json:"nonce,omitempty"`
	Cert    string `json:"cert,omitempty"`
	Sig     string `json:"sig,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}
