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
	// TypeTeam is the hub's word that the team configuration is at
	// TeamVersion (claude-fleet#1899, EPIC #1906 C6): sent to a node that
	// listed CapTeam on the first heartbeat of each connection, whenever the
	// version it last told that connection is not the current one, and to
	// every such node the moment the operator PUTs a new version. The node
	// runs fleet-agent-team.py sync and retries on its next beat until one
	// succeeds; it answers nothing. No team layer (version 0) → never sent.
	TypeTeam = "team"
	// TypePerson is the hub's word that a person's own configuration is at
	// Version (claude-fleet#2784, EPIC #2781 C3): sent to a node that listed
	// CapPerson and whose login is bound to that person, on the first
	// heartbeat of each connection and the moment the person (or the
	// operator's restore) PUTs a new version. The node runs the same
	// fleet-agent-team.py sync as for TypeTeam and retries on its next beat.
	// No personal layer (version 0) or no person behind the login → never sent.
	TypePerson = "person"
	// TypeRelease is the hub's word that a new release is stable
	// (claude-fleet#3146, EPIC #3139 C7): sent to a node that listed
	// CapRelease the moment the hub's stable pointer moves, and on the first
	// heartbeat of each connection. It is only a wake-up: the node starts the
	// update it would have run on its own clock — a machine's updater, a
	// login's install-sync — which still reads the target from the hub and
	// still only moves forward. The node answers nothing; a push it misses is
	// caught by its own clock (5 / 30 minutes). No stable → never sent.
	TypeRelease = "release"
	// TypeTicket is the hub's word that one of a person's hub tickets moved
	// (claude-fleet#2677, EPIC #3570 C1): a comment, a state change, a claim
	// or an edit. Sent the moment it happens to every connected node that
	// listed CapTicket and whose login belongs to the ticket's owner — never
	// to anyone else's. The payload names the ticket and the change, never its
	// words: the node reads them by number. Nothing moves → never sent.
	TypeTicket = "ticket"
	// TypeRepoAuthority is the hub's word that a repo's task authority moved
	// (claude-fleet#4730): a freeze, apply or rollback, sent to every
	// connected host of that repo whose hello listed CapRepoAuthority, and on
	// each such connection's first beat for every repo it hosts that has had
	// a transition. Only a wake-up: the node re-reads the mode with its own
	// credential (fleet-hub-node.sh authority-sync) and rewrites its overlay's
	// FLEET_TASK_AUTHORITY; the payload's mode is never written as is.
	TypeRepoAuthority = "repo_authority"
	// TypeCreds is the hub's word that the credentials a node may lease
	// changed (claude-fleet#3744): a subscription stored, deleted, paused or
	// resumed, a machine or person revoked or lifted. Sent the moment it
	// happens to every connected node that listed CapCreds. Only a wake-up —
	// the node leases at once instead of on its own clock (hours apart), and
	// that lease's answer is the whole truth: what it no longer lists, the
	// node removes. The payload carries no credential and no account name.
	TypeCreds = "creds"
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

// CapTeam is the hello capability a node lists when it follows TypeTeam
// (claude-fleet#1899): its login has claude-fleet's fleet-agent-team.py. The
// hub never pushes a team version to a node that did not say it, so an older
// agent sees nothing new and keeps following on install-sync's tick.
const CapTeam = "team"

// CapPerson is the hello capability a node lists when it follows TypePerson
// (claude-fleet#2784). An older agent never says it, so it is never sent one
// and keeps reading the personal layer on install-sync's tick.
const CapPerson = "person"

// CapTicket is the hello capability a node lists when it follows TypeTicket
// (claude-fleet#2677). An older agent never says it and is never sent one.
const CapTicket = "ticket"

// CapCreds is the hello capability a node lists when it leases again on
// TypeCreds (claude-fleet#3744). An older agent never says it, is never sent
// one, and keeps leasing on its own clock.
const CapCreds = "creds"

// CapRelease is the hello capability a node lists when it wakes its update on
// TypeRelease (claude-fleet#3146): a machine link whose node daemon runs the
// updater, or a login that follows stable with fleet-install-sync.sh. The hub
// never pushes a release to a node that did not say it, so an older agent
// keeps following on its own clock, byte for byte.
const CapRelease = "release"

// CapMove is the hello capability a node lists when it takes a session moved
// to it through the hub (claude-fleet#1426): before it hands a
// worker_move_in write to claude-fleet, it downloads the move's transcript
// bundle over HTTP. The hub never moves a session to a node that did not say it.
const CapMove = "move"

// CapAttach is the hello capability a node lists when it takes the files a
// client's writing area sends with a start (claude-fleet#2393): before it
// hands a worker_start naming attachments to claude-fleet, it downloads each
// one over HTTP into the directory its claude-fleet named. The hub never
// names an attachment to a node that did not say it — the client is told the
// file did not go.
const CapAttach = "attach"

// CapTestIdentity is the hello capability a node lists when its claude-fleet
// takes `test` on a scratch worker_start (claude-fleet#2505): the session the
// TEST identity's client placed is stamped @test_identity, named test-…, kept
// off the person's list and closed once done. The hub names `test` only to a
// node that said it — an older one would refuse the unknown field.
const CapTestIdentity = "test_identity"

// CapTask is the hello capability a node lists when its claude-fleet takes
// `task` on a worker_start and runs `task_issue` (claude-fleet#3325): the start
// belongs to the hub's task record T<n> — the window is stamped @task, and a
// no-repo one files no desk ticket (the record is its ticket) — and a record's
// 「建 GitHub 单」 files the issue on the machine that holds its session. The
// hub names `task` only to a node that said it — an older one would refuse the
// unknown field, and its start opens as before.
const CapTask = "task"

// CapLaunch requires process/native-session verification before initial input.
const CapLaunch = "launch_v1"

// CapRepoAuthority enforces the central repo freeze on local starts too.
const CapRepoAuthority = "repo_authority_v1"

// CapCredsep is the hello capability an admin node lists when every login its
// create op opens is credential-separated from the start (claude-fleet#2294):
// no subscription token in the login's home, its sessions only through the
// proxy. The hub opens spare logins (claude-fleet#2263) only on a machine
// whose admin node says it, and hands one out only when its create result
// said AccountResult.Credsep "separated".
const CapCredsep = "credsep"

// CapLoginJoin is the hello capability an admin node lists when its create
// op hands AccountOp.JoinCode to the create script (claude-fleet#2652), so the
// login it opens enrolls as its own node and brings its fleet up. An admin
// built before that ignores the code: the login opens and its fleet never
// reports (claude-fleet#3032, a stale admin agent restored from the attic).
// The hub sends a create only to an admin that lists it, and places a
// newcomer only on a machine that has one.
const CapLoginJoin = "login_join"

// CapRecycle is the hello capability an admin node lists when its remove
// script has the --recycle mode (claude-fleet#3504): the hub may then wash a
// person's login back into a spare (AccountReset) instead of deleting it. An
// admin without it is sent a remove, as before.
const CapRecycle = "recycle"

// CapRecycleKeep is the hello capability an admin node lists when its wash
// keeps a recycled login's node token instead of re-joining it
// (claude-fleet#4195): the token lives only in root's books (the credential
// store, the machine daemon's logins/<login>.env), so nothing the last person
// could read or change holds it. The hub then leaves that login's node enrolled
// while the reset runs — it takes away the last person's passes, leases, link,
// 家 and certificates instead — and keeps it when the answer says `node: kept`.
// An admin without it re-joins with the reset's join code, as before.
const CapRecycleKeep = "recycle_keep"

// CapMachine is the hello capability of a MACHINE link (claude-fleet#2333,
// EPIC #2329 C5): one connection, dialled by `ccquota agent --machine` with
// the machine's own node token, that carries every login of the machine. Each
// login then says its own hello on that link — a TypeHello with Message.Login
// set and its own node token in Hello.LoginToken — and from there every
// message for or from that login carries Login. The hub keeps each login its
// own endpoint (roster row, leases, relays), only the wire is shared. A hub
// that does not know the capability refuses nothing: it reads the machine
// hello as one more node, and the logins' hellos as unknown — so a machine
// agent falls back to nothing and an older hub is never sent a login it
// cannot route.
const CapMachine = "machine"

// CapUserPod is listed by a MACHINE link (CapMachine) that is one person's
// pod (claude-fleet#3550, EPIC #3500 C5): extras/managed-node/render.py
// --user-pod sets FLEET_USER_POD=1, the pod's stable name u-<nonce> is its
// hostname, and it carries exactly one login. The hub treats it as a machine
// like any other — the roster marks it user_pod — and the person's ceiling is
// the fleet setting fleet.user_pod_limits.<principal>. A link that does not
// list it is byte for byte as before.
const CapUserPod = "user_pod"

// A cluster's ops link (claude-fleet#3553, EPIC #3500 C8): fleet-ops — the one
// node in a cluster that reads it — lists CapClusterOps in its hello, its
// hostname the cluster's name, and the hub hands it provisioner tickets
// (ClusterTicket, signed with the account-op key) to carry, unopened, to the
// cluster's fleet-provisioner. Only a cluster the hub's fleet.clusters names is
// ever sent one. The answer is the provisioner's own exit and line.
//
//	hub ──TypeClusterOp {ticket}──▶ fleet-ops ──POST /v1/op──▶ fleet-provisioner
//	hub ◀──TypeClusterOpResult {rc, line}── fleet-ops ◀───────────┘
const (
	CapClusterOps       = "cluster_ops"
	TypeClusterOp       = "cluster_op"
	TypeClusterOpResult = "cluster_op_result"
)

// ClusterOp is TypeClusterOp's payload.
type ClusterOp struct {
	Ticket string `json:"ticket"`
}

// ClusterOpResult is TypeClusterOpResult's payload: the provisioner's exit (0
// done · 3 refused · 1 failed) and its one line; Error when fleet-ops could
// not reach it at all.
type ClusterOpResult struct {
	RC    int    `json:"rc"`
	Line  string `json:"line,omitempty"`
	Error string `json:"error,omitempty"`
}

// A service run on a machine's service login (claude-fleet#4086). Claude Code
// runs only where its region allows, so a service run (svc:<name>) is not a
// cluster Job: the hub hands each attempt to ONE login whose agent lists
// CapSvcRun — a login the operator made a service login (CCQUOTA_FLEET_SVC=1 in
// its env, written by root) and the hub's fleet.svc.logins names. The agent
// starts bin/fleet-svc-local.sh as that login (a fresh directory per attempt,
// removed after it), answers TypeResult {ok} at once, and the run reads its spec
// and hands in its result itself, with the one-time key, over the hub's HTTP
// road (/v1/node/svc-runs) — the same road a cluster Job's runner takes.
//
//	hub ──TypeSvcRun {run, attempt, deadline, token}──▶ the service login's agent
//	hub ◀──TypeResult {ok, line}── (started, or why not)
//	hub ──TypeSvcRunCancel {run, attempt}──▶ (kill it, clean its directory)
const (
	CapSvcRun        = "svc_run"
	TypeSvcRun       = "svc_run"
	TypeSvcRunCancel = "svc_run_cancel"
)

// SvcRunStart is TypeSvcRun's payload: the attempt, its deadline in seconds and
// its one-time key (fsj_…), which the agent hands the runner on its stdin only.
type SvcRunStart struct {
	Run      string `json:"run"`
	Attempt  int    `json:"attempt"`
	Deadline int    `json:"deadline"`
	Token    string `json:"token"`
}

// SvcRunCancel is TypeSvcRunCancel's payload.
type SvcRunCancel struct {
	Run     string `json:"run"`
	Attempt int    `json:"attempt"`
}

// SvcRunAck answers either: OK = started / stopped; Line says why not.
type SvcRunAck struct {
	OK   bool   `json:"ok"`
	Line string `json:"line,omitempty"`
}

// A throwaway Job's state and log (claude-fleet#3552, EPIC #3500 C7). The
// provisioner makes the Job from a create-job ticket; fleet-ops — read-only:
// jobs, pods and their logs — reads it back for the hub, which relays it to
// the session that asked (`fleet job`). The hub names the Job and the user pod
// it must belong to; fleet-ops answers only for a Job labelled fleet/owner
// that pod.
//
//	hub ──TypeClusterJob {job, owner, offset}──▶ fleet-ops ──GET──▶ the API server
//	hub ◀──TypeClusterJobResult {state, log, offset}── fleet-ops
const (
	TypeClusterJob       = "cluster_job"
	TypeClusterJobResult = "cluster_job_result"
)

// The Job states a ClusterJobResult says.
const (
	JobPending   = "pending"
	JobRunning   = "running"
	JobSucceeded = "succeeded"
	JobFailed    = "failed"
	JobGone      = "gone" // no such Job: never made, or deleted after its TTL
)

// CodeNoSuchJob is fleet-ops refusing a Job that is not the asking pod's — or
// not a fleet Job at all; it never says whose it is.
const CodeNoSuchJob = "NO_SUCH_JOB"

// ClusterJobChunk bounds the log one answer carries.
const ClusterJobChunk = 256 << 10

// ClusterJob is TypeClusterJob's payload: the Job, the user pod that owns it,
// and how many bytes of its log the asker already has.
type ClusterJob struct {
	Job    string `json:"job"`
	Owner  string `json:"owner"`
	Offset int64  `json:"offset,omitempty"`
}

// ClusterJobResult is TypeClusterJobResult's payload: the Job's state, the
// next ≤ ClusterJobChunk bytes of its log from the asked offset, and the
// offset after them. Error when the API server could not be read.
type ClusterJobResult struct {
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
	Log    string `json:"log,omitempty"`
	Offset int64  `json:"offset"`
	Error  string `json:"error,omitempty"`
}

// CodeWrongLogin refuses a message on a machine link whose Login is not one
// that link carries, or a login hello whose token belongs to another login or
// another machine (claude-fleet#2333) — an op never runs as the wrong login.
const CodeWrongLogin = "WRONG_LOGIN"

// CodeLinkClosed is the hub telling a machine link that one login's session on
// it ended (revoked, superseded, malformed): the node drops that login and
// says its hello again after a backoff. Never sent on a plain link.
const CodeLinkClosed = "LINK_CLOSED"

// GateItem is one public-gate item's verdict (claude-fleet#3574): its id in
// conf/public-gate.tsv, PASS or not, and why in the judge's words.
type GateItem struct {
	ID   string `json:"id"`
	Pass bool   `json:"pass"`
	Why  string `json:"why,omitempty"`
}

// CredsepSeparated is AccountResult.Credsep for a login opened separated.
const CredsepSeparated = "separated"

// CredsepCentral is AccountResult.Credsep for a login in one person's pod that
// keeps no credential at all — every session goes through the cluster's one
// credential proxy (claude-fleet#3757). A spare pod's login is ready with it
// (claude-fleet#3553).
const CredsepCentral = "central"

// Heartbeat.Credsep's other words (claude-fleet#2295): CredsepNot — the
// login is not separated, or `fleet-credsep.sh check` finds its credentials
// readable after all (exit 1; a mere warning, exit 4, stays separated —
// claude-fleet#4623); CredsepUnknown — the script is missing or could not be
// run. The hub leases every login real tokens only on CredsepSeparated (#4607).
const (
	CredsepNot     = "not"
	CredsepUnknown = "unknown"
)

// Relay kinds.
const (
	RelayChildReport = "child_report"
	RelayMessage     = "message"
	// RelayReceipt flows hub → SENDER only (claude-fleet#1647): what became
	// of a relay that node sent — delivered, failed or expired. From is the
	// relay's target, To its sender; the id is the relay's own. A node never
	// sends one: the hub refuses it at the door like any unknown kind.
	RelayReceipt = "receipt"
)

// ReceiptOpPrefix marks the OpID of a receipt push, so the sender node's
// TypeRelayResult for it is told apart from a target's answer to a relay.
const ReceiptOpPrefix = "rcpt:"

// RelayReceiptBody is a receipt's payload.
type RelayReceiptBody struct {
	RID    string `json:"rid"`
	Kind   string `json:"kind"`
	To     string `json:"to"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

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
	// Worker is the sender node's worker assertion (claude-fleet#1810): which
	// of its sessions sent this, signed by the node. Sender → hub only; the
	// hub checks it, audits it, and never passes it on.
	Worker string `json:"worker,omitempty"`
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

// Creds is the payload of TypeCreds: what changed, for the node's log only.
type Creds struct {
	Why string `json:"why,omitempty"`
}

// Team is the payload of TypeTeam.
type Team struct {
	TeamVersion int `json:"team_version"`
}

// Person is the payload of TypePerson: whose layer, and its version.
type Person struct {
	Principal string `json:"principal"`
	Version   int    `json:"version"`
}

// Ticket is the payload of TypeTicket: which ticket, and what happened to it.
type Ticket struct {
	Repo      string `json:"repo"`
	Number    int64  `json:"number"`
	Kind      string `json:"kind"` // comment | state | claim | edit
	CommentID int64  `json:"comment_id,omitempty"`
}

// RepoAuthority is the payload of TypeRepoAuthority.
type RepoAuthority struct {
	Repo     string `json:"repo"`
	Mode     string `json:"mode"`
	Revision int64  `json:"revision"`
}

// Release is the payload of TypeRelease: the stable release and its signed
// seq (one past the release it replaced) — a node ignores a seq it is already
// at or past.
type Release struct {
	SHA string `json:"sha"`
	Seq int64  `json:"seq"`
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
	Type  string `json:"type"`
	OpID  string `json:"op_id"`
	Proto int    `json:"proto"`
	// Login names the login a message is for or from, on a machine link
	// only (CapMachine, claude-fleet#2333). Empty on a plain link, and for
	// the machine's own messages on a machine link.
	Login   string          `json:"login,omitempty"`
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
	// AttachmentGeneration names this login agent's current control lifetime.
	AttachmentGeneration string `json:"attachment_generation,omitempty"`
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
	// Compute is false when this login only coordinates (claude-fleet#1719,
	// CCQUOTA_FLEET_COMPUTE=0): heartbeat, identity and certificates, but no
	// placement and no credential lease. nil — an agent older than #1719, or
	// one started without the setting — is compute on, as every node was.
	Compute *bool `json:"compute,omitempty"`
	// ComputeForce is `fleet node compute on --force` (claude-fleet#1720):
	// the person opened this login although its probe said it does not suit
	// running sessions. The hub honours it over the probe and audits it.
	ComputeForce bool `json:"compute_force,omitempty"`
	// Probe is this machine's own reading of whether it suits running
	// sessions (claude-fleet#1720) — nil when bin/fleet-node-probe.sh never
	// ran here, which the hub reads exactly as before the probe existed.
	Probe *NodeProbe `json:"probe,omitempty"`
	// Personal is a person's own computer (claude-fleet#1721, `fleet node
	// compute on --personal`, a laptop's default): an auto placement never
	// picks it, and a start lands on it only when it was asked for FROM it —
	// its own client, or a session already running there. false/absent is a
	// shared machine, as every node was.
	Personal bool `json:"personal,omitempty"`
	// LoginToken is a login's own node token, carried ONLY by that login's
	// hello on a machine link (claude-fleet#2333): the machine's token opens
	// the link, each login's token proves the login. Never logged, never
	// echoed; empty everywhere else.
	LoginToken string `json:"login_token,omitempty"`
}

// NodeProbe is bin/fleet-node-probe.sh's verdict (claude-fleet#1720), read off
// $FLEET_CONF_DIR/node-probe.json: the egress region, whether Anthropic's and
// OpenAI's APIs answer from here, and whether the machine is a laptop.
type NodeProbe struct {
	Loc       string    `json:"loc,omitempty"`
	Anthropic string    `json:"anthropic,omitempty"` // reachable | unsupported_region | unreachable
	OpenAI    string    `json:"openai,omitempty"`
	Laptop    bool      `json:"laptop,omitempty"`
	TS        time.Time `json:"ts"`
	Verdict   string    `json:"verdict"` // ok | unsupported_region | unreachable
	Reason    string    `json:"reason,omitempty"`

	// Route is the road the login's sessions take (claude-fleet#3364): relay
	// = this machine's egress is not served and its credential proxy goes
	// through the relay, so Loc and Verdict are the relay's and LocLocal is
	// this machine's. "" / direct = judged by this machine, as before.
	Route    string `json:"route,omitempty"`
	LocLocal string `json:"loc_local,omitempty"`
}

// Where is the probe's egress as a sentence fragment: `CN`, or for a relay
// login `SG via relay (local CN)` (claude-fleet#3364).
func (p *NodeProbe) Where() string {
	loc := p.Loc
	if loc == "" {
		loc = "未知"
	}
	if p.Route != "relay" {
		return loc
	}
	local := p.LocLocal
	if local == "" {
		local = "未知"
	}
	return loc + " via relay (local " + local + ")"
}

// Probe verdicts (claude-fleet#1720).
const (
	ProbeOK                = "ok"
	ProbeUnsupportedRegion = "unsupported_region"
	ProbeUnreachable       = "unreachable"
)

// ComputeOn reads a hello's or heartbeat's Compute: only an explicit false is
// off (claude-fleet#1719).
func ComputeOn(c *bool) bool { return c == nil || *c }

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
	// LoginsRefused is the machine link's own word (claude-fleet#2501):
	// login → the hub's WRONG_LOGIN for its last hello, for every login of
	// the machine whose lane the hub will not take (a token reissued away,
	// an endpoint retired). Absent when every lane is up, and from a plain
	// agent or an older machine agent.
	LoginsRefused map[string]string `json:"logins_refused,omitempty"`
	// Services is the machine link's own word too (claude-fleet#2526, EPIC
	// #2524 C2): every entry of the machine daemon's login-level register
	// (fleet-node-supervisor.py's state.json `services`), each a summary — a
	// state, its last and next run, its log's last line. nil from a plain
	// agent, an older machine agent, a machine with no daemon or an empty
	// register.
	Services []ServiceStatus `json:"services,omitempty"`
	// CIRunner is the machine link's word too (claude-fleet#3144, EPIC #3139
	// C5): the machine's test runner (fleet-node-supervisor.py's state.json
	// `ci_runner`) — idle · busy · paused · error · off, and why. nil from a
	// plain agent, an older one, or a machine with no test runner (no ci.env).
	CIRunner *CIRunnerStatus `json:"ci_runner,omitempty"`
	OSUser   string          `json:"os_user,omitempty"`
	OS       string          `json:"os,omitempty"`
	Arch     string          `json:"arch,omitempty"`

	// Load1 is the one-minute load average; NCPU the logical core count. Both
	// zero when the platform would not say.
	Load1 float64 `json:"load1"`
	NCPU  int     `json:"ncpu"`
	// MemFreeBytes is memory available without swapping; MemTotalBytes the
	// machine's total. Zero when unknown.
	MemFreeBytes  uint64 `json:"mem_free_bytes"`
	MemTotalBytes uint64 `json:"mem_total_bytes"`
	// MemPressure is the kernel's memory-pressure level (claude-fleet#1994):
	// darwin's kern.memorystatus_vm_pressure_level — 1 normal, 2 warn,
	// 4 critical. 0 (absent) is unknown: Linux and an older agent; placement
	// excludes a machine at warn (2) or above, and never one for being unknown.
	MemPressure int `json:"mem_pressure,omitempty"`
	// CPUBusy is the share of the machine's CPU time spent in user + system
	// over about the last minute, 0..1 (claude-fleet#2882): what placement
	// gates on, since load1 counts every runnable process — two hundred small
	// fleet processes read a 15-core machine at 20 while three cores work.
	// Absent from an older agent and before the first minute was read; load
	// is then the gate, as before.
	CPUBusy *float64 `json:"cpu_busy,omitempty"`
	// MaxCPUBusy is this machine's own CPU-busy ceiling for new sessions
	// (machine.env FLEET_MAX_CPU_BUSY, 0..1); 0 = the hub's.
	MaxCPUBusy float64 `json:"max_cpu_busy,omitempty"`
	// SysAt is when Load1 / NCPU / MemFreeBytes / MemTotalBytes / MemPressure
	// were read (claude-fleet#2798): the agent samples them on their own
	// clock, so a beat held up by a slow fleet read never carries a stale or
	// empty load under a fresh ObservedAt. SysUnread names what the platform
	// would not say ("load", "mem") — a zero there is 「读不到」, not a zero.
	// Both absent from an older agent: the hub then says 「时间未知」.
	SysAt     *time.Time `json:"sys_at,omitempty"`
	SysUnread []string   `json:"sys_unread,omitempty"`
	// FleetAt is when the fleet half (Fleets, Sessions, the capacity, Ready,
	// Credsep, FleetVersion) was read (claude-fleet#2798). A read past its
	// budget leaves the beat carrying the LAST completed one with its own
	// older time — never an empty one. Absent from an older agent and before
	// any read finished.
	FleetAt *time.Time `json:"fleet_at,omitempty"`
	// Versions is a managed machine's parts against its release
	// (claude-fleet#2798): only on the machine link's beat, read on its own
	// slower clock at VersionsAt. Absent from a plain agent, an older machine
	// agent, and a machine with no updater.
	Versions   *Versions  `json:"versions,omitempty"`
	VersionsAt *time.Time `json:"versions_at,omitempty"`

	// Sessions is how many fleet sessions (worker + scratch windows) this
	// login runs across all its fleets. It sums only the fleets that were
	// read: a fleet whose status read failed is State "unknown" with Count 0,
	// so when UnreadableFleets is non-empty this number is a floor, never the
	// count (claude-fleet#1465) — read it through SessionsCount.
	Sessions int `json:"sessions"`
	// MaxSessions is this login's OWN session cap (claude-fleet#1587): the
	// FLEET_GLOBAL_MAX_SESSIONS its spawn gate refuses at, 0 = unlimited.
	// CapSessions is the count that gate reads — awake worker + scratch
	// windows, a sleeper holds no slot — so the two compare the way the node
	// itself would. Both absent from an agent or claude-fleet older than
	// #1587: placement then filters nothing, as it always did.
	MaxSessions int  `json:"max_sessions,omitempty"`
	CapSessions *int `json:"cap_sessions,omitempty"`
	// Admit is the login's own admission verdict (claude-fleet#1836): the
	// answer its spawn gate (fleet_machine_admit) gives right now — false =
	// new sessions are held there, AdmitWhy says why (内存紧张 / 负载过高) —
	// and Room how many more sessions its memory has room for
	// (fleet_machine_headroom). Since #1831 the count cap defaults to 0, so
	// this is the gate a placed start actually meets. All absent from an
	// agent or claude-fleet older than #1836, and Room absent with the gate
	// switched off (FLEET_ADMIT=0): placement then holds on nothing here.
	Admit    *bool  `json:"admit,omitempty"`
	AdmitWhy string `json:"admit_why,omitempty"`
	Room     *int   `json:"room,omitempty"`
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
	// Installs is this login's three kinds of install as `fleet-installs.sh
	// --json` reads them for it (claude-fleet#2697): the machine runtime, its
	// own login install and its client shell. Absent from an older agent or a
	// login without the script; the hub judges at_stable against its stable.
	Installs *Installs `json:"installs,omitempty"`

	// Routes is how people reach this machine's sshd from outside
	// (claude-fleet#1414): its tailnet name, a public port the gateway
	// forwards to it. The hub merges them into the route list it hands
	// `fleet connect`, which measures each and picks the best. Absent on an
	// agent older than #1414, or one that knows no route.
	Routes []NodeRoute `json:"routes,omitempty"`

	// HostKeys is this machine's sshd host public keys, one
	// "<type> <base64>" each (claude-fleet#2983): the hub hands them to
	// `fleet connect` with the routes, so a new person's first connection
	// is checked against them instead of asking ssh's yes/no question. A
	// key the machine does not report is still refused. Absent on an agent
	// older than #2983, or one that cannot read /etc/ssh.
	HostKeys []string `json:"host_keys,omitempty"`

	// Credsep is this login's credential separation as `fleet-credsep.sh
	// status` + `check` judge it (claude-fleet#2295, EPIC #2293 共同约定 1):
	// CredsepSeparated only when status says separated AND check passes or
	// merely warns (claude-fleet#4623), CredsepNot / CredsepUnknown otherwise. Absent from an agent older than
	// #2295 — the hub reads that as not separated for a role=user person.
	Credsep string `json:"credsep,omitempty"`
	// Gate is this machine's half of the public gate (claude-fleet#3574,
	// EPIC #3569 C4): every conf/public-gate.tsv row judged where=node, as
	// `fleet-gate-check.sh --local` reads them on this machine. The hub's
	// /v1/fleet/gate folds every machine's into one verdict per item. Absent
	// from an agent older than #3574 or a login without the script.
	Gate []GateItem `json:"gate,omitempty"`

	// Ready says whether this login can take a NEW session
	// (claude-fleet#1475): gh is logged in, a Claude or Codex credential is
	// usable and every hosted repo's checkout exists. nil on an agent older
	// than #1475 — placement reads that as ready, so an old node is never
	// silently dropped. NotReady names what is missing when it is false.
	Ready    *bool  `json:"ready,omitempty"`
	NotReady string `json:"not_ready,omitempty"`

	// RepoNotReady is the same verdict for a start ON a repo
	// (claude-fleet#3424): Ready waives gh for a login hosting only the seed
	// repo, so a newcomer's home session can start, but an issue there reads,
	// pushes and opens a PR. Non-empty names what such a start lacks ("gh");
	// empty — and absent from an older agent — means Ready says it all.
	RepoNotReady string `json:"repo_not_ready,omitempty"`

	// Compute repeats the hello's (claude-fleet#1719) so the roster row the
	// hub keeps says it too: false = coordinate only, never placed or leased.
	Compute *bool `json:"compute,omitempty"`
	// ComputeForce and Probe repeat the hello's too (claude-fleet#1720): the
	// agent re-reads both every beat, so `fleet node compute` and the daily
	// probe reach the hub without a reconnect.
	ComputeForce bool       `json:"compute_force,omitempty"`
	Probe        *NodeProbe `json:"probe,omitempty"`
	// Personal repeats the hello's (claude-fleet#1721), re-read every beat.
	Personal bool `json:"personal,omitempty"`
	// Desired is how far a managed machine converged on the desired state
	// the hub keeps for it (claude-fleet#2214, docs/MANAGED-NODE.md). Absent
	// from an agent that manages nothing — the roster then shows no 期望 /
	// 实际 columns, byte for byte as before.
	Desired *DesiredReport `json:"desired,omitempty"`

	AgentVersion string    `json:"agent_version,omitempty"`
	ObservedAt   time.Time `json:"observed_at"`
}

// Versions is a managed machine's 版本与更新 (claude-fleet#2798), as
// `fleet-node-update.py versions --json` says it: the release its runtime link
// names, what each part actually answers, what release.json pins, and where the
// updater is.
type Versions struct {
	// Runtime is the release sha <root>/current names; "" = no release here.
	Runtime string `json:"runtime,omitempty"`
	// Actual is part → the version it answers (ccquota · claude · codex ·
	// tmux), "" for one that did not answer. Want is release.json's pins.
	Actual map[string]string `json:"actual,omitempty"`
	Want   map[string]string `json:"want,omitempty"`
	// Daemon is the release the machine daemon runs.
	Daemon string `json:"daemon,omitempty"`
	// Update is the updater's own record (update.json): its last result,
	// the phase a tick is in, when, and why.
	Update *UpdateState `json:"update,omitempty"`
	// Error says why the read failed; the rest is then absent.
	Error string `json:"error,omitempty"`
}

// Installs is one login's reading of fleet-installs.sh (claude-fleet#2697),
// trimmed to what the hub shows: each install's version and where it came
// from. AtStable is the script's own judgement against the stable it knew
// (nil = it knew none); the hub re-judges against its own stable.
type Installs struct {
	Stable  string         `json:"stable,omitempty"`
	Runtime *InstallItem   `json:"runtime,omitempty"`
	Logins  []LoginInstall `json:"logins,omitempty"`
	At      *time.Time     `json:"at,omitempty"`
}

// LoginInstall is one login's install, client shell and client install.
type LoginInstall struct {
	Login   string       `json:"login"`
	Install *InstallItem `json:"install,omitempty"`
	Shell   *InstallItem `json:"shell,omitempty"`
	Client  *InstallItem `json:"client,omitempty"`
}

// InstallItem is one install: its version (a commit sha, or "-"), how it is
// laid (Kind link|dir for a login install; Follows for a shell that follows
// its login install), its source (hub · runtime · github · dev · ?) and
// whether it is at stable (nil = not known).
type InstallItem struct {
	Version  string `json:"version"`
	Kind     string `json:"kind,omitempty"`
	Follows  bool   `json:"follows,omitempty"`
	Source   string `json:"source,omitempty"`
	AtStable *bool  `json:"at_stable"`
	// BehindSecs is how long this machine has known a stable it is not at
	// (fleet-installs.sh's behind_secs); absent when at stable or not known.
	BehindSecs *int64 `json:"behind_secs,omitempty"`
}

// UpdateState is the updater's state as update.json keeps it.
type UpdateState struct {
	Result string     `json:"result,omitempty"`
	Phase  string     `json:"phase,omitempty"`
	At     *time.Time `json:"at,omitempty"`
	Reason string     `json:"reason,omitempty"`
}

// CIRunnerStates are the words a machine's test runner says (claude-fleet#3144).
var CIRunnerStates = []string{"idle", "busy", "paused", "error", "off"}

// CIRunnerStatus is a machine's test runner as its daemon last wrote it: a
// state, why (paused: what it yields to — "load: 0.92/core > 0.75"), when the
// daemon wrote it and since when it holds, the runs it took. Never a credential.
type CIRunnerStatus struct {
	State  string     `json:"state"`
	Why    string     `json:"why,omitempty"`
	At     *time.Time `json:"at,omitempty"`
	Since  *time.Time `json:"since,omitempty"`
	Runs   int        `json:"runs"`
	Failed int        `json:"failed"`
}

// ServiceStatus is one entry of a machine's login-level register
// (claude-fleet#2526): a program kept running (kind service) or run on a
// schedule (kind task, #2529) AS one login. Names and a state only — never an
// env value or a credential; LastLogLine is at most ServiceLineMax bytes.
type ServiceStatus struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Login string `json:"login"`
	// State is the daemon's word: running · stopped · down (exited, waiting
	// to restart) · invalid (an entry the daemon will not run) · no_login
	// (the login is gone) · idle (an on-demand service that exited idle, kept
	// off until it is opened again, #3647); a task's also scheduled · retrying ·
	// ok · failed (past its retries, #2529).
	State       string     `json:"state"`
	StartedAt   *time.Time `json:"started_at,omitempty"`
	LastRun     *time.Time `json:"last_run,omitempty"`
	NextRun     *time.Time `json:"next_run,omitempty"`
	LastLogLine string     `json:"last_log_line,omitempty"`
	Restarts    int        `json:"restarts,omitempty"`
	LastRC      *int       `json:"last_rc,omitempty"`
	// Why says what is wrong: an invalid entry's reason, a failing task's
	// last error.
	Why string `json:"why,omitempty"`
}

// ServiceLineMax bounds ServiceStatus.LastLogLine: the beat carries a
// summary, the log itself stays on the machine.
const ServiceLineMax = 200

// Failed reports whether the entry wants a person: it is meant to run and
// does not (down / failed / invalid / no_login). Running and stopped are fine.
func (s ServiceStatus) Failed() bool {
	switch s.State {
	case "down", "failed", "invalid", "no_login":
		return true
	}
	return false
}

// A service's log, live (claude-fleet#2797, EPIC #2792 C5): the hub asks the
// login's lane for ONE entry of the register — the lane's own login, never a
// path — and the machine program (root) reads only that entry's log file, the
// path the daemon's service_log() computed into state.json, opened without
// following a link and only when the login owns it. TypeServiceLog opens a
// follow (the last Tail lines, then each new one) or answers one page before
// an offset; every TypeServiceLogLines carries the request's op_id; a follow
// ends at TypeServiceLogStop, or when no TypeServiceLog with Renew and the same
// op_id has come for ServiceLogLease. Sent only to a lane whose hello listed
// CapServiceLog; a refusal is a TypeError by op_id.
const (
	TypeServiceLog      = "service_log"
	TypeServiceLogLines = "service_log_lines"
	TypeServiceLogStop  = "service_log_stop"
	// CapServiceLog is the hello capability of a machine program's lane that
	// serves TypeServiceLog. An older one never says it and is never asked.
	CapServiceLog = "service_log"
)

// The bounds of a log stream: a page of at most ServiceLogTail lines (the
// first screen, and each page scrolled up), a line cut at ServiceLogLineMax
// bytes, at most ServiceLogRate bytes a second (the middle of a burst is
// dropped and counted), and a follow nobody renewed for ServiceLogLease ends.
const (
	ServiceLogTail    = 200
	ServiceLogLineMax = 2 << 10
	ServiceLogRate    = 64 << 10
	ServiceLogLease   = 60 * time.Second
)

// ServiceLog is the payload of TypeServiceLog.
type ServiceLog struct {
	// Login is the lane's own; a lane refuses another (WRONG_LOGIN).
	Login string `json:"login"`
	Name  string `json:"name"`
	// Tail is how many lines to start with (≤ ServiceLogTail).
	Tail int `json:"tail"`
	// Follow keeps the stream open for new lines; without it the answer is
	// one page, Done.
	Follow bool `json:"follow,omitempty"`
	// Before asks for the page ending at this byte offset (scrolling up).
	Before *int64 `json:"before,omitempty"`
	// Renew extends a follow already open under this op_id; nothing is re-sent.
	Renew bool `json:"renew,omitempty"`
}

// ServiceLogLine is one line of a log; TS is when the node read it (a new
// line of a follow), absent for a line that was already there.
type ServiceLogLine struct {
	TS   *time.Time `json:"ts,omitempty"`
	Text string     `json:"text"`
}

// ServiceLogLines is the payload of TypeServiceLogLines.
type ServiceLogLines struct {
	Lines []ServiceLogLine `json:"lines"`
	// Skipped counts the lines dropped from the middle of a burst past
	// ServiceLogRate.
	Skipped int `json:"skipped,omitempty"`
	// From is the byte offset of the first line (the next page's Before);
	// Start says nothing comes before it in this file.
	From  int64 `json:"from"`
	Start bool  `json:"start,omitempty"`
	// Rotated: the file was replaced (rotated) and the follow reopened it.
	Rotated bool `json:"rotated,omitempty"`
	// Done ends the stream: a page answered, or a follow stopped.
	Done bool      `json:"done,omitempty"`
	At   time.Time `json:"at"`
}

// DesiredReport is a managed node's word on its desired state: the version it
// last converged to, the release it runs, and a one-line summary of what
// still differs ("" = nothing).
type DesiredReport struct {
	Version int    `json:"version"`
	Release string `json:"release,omitempty"`
	Diff    string `json:"diff,omitempty"`
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

// Full reports whether this login is at its own session cap
// (claude-fleet#1587), with the count and cap it read. false when the beat
// carries no cap, or the cap is unlimited.
func (hb Heartbeat) Full() (bool, int, int) {
	if hb.MaxSessions <= 0 || hb.CapSessions == nil {
		return false, 0, 0
	}
	return *hb.CapSessions >= hb.MaxSessions, *hb.CapSessions, hb.MaxSessions
}

// Paused reports whether this login's own gate is holding new sessions
// (claude-fleet#1836) — it said admit false, or room for fewer than one more —
// and why, in the gate's words. false when the beat carries neither field.
func (hb Heartbeat) Paused() (bool, string) {
	switch {
	case hb.Admit != nil && !*hb.Admit:
		if hb.AdmitWhy != "" {
			return true, hb.AdmitWhy
		}
		return true, "admit=false"
	case hb.Room != nil && *hb.Room < 1:
		return true, fmt.Sprintf("内存余量不够再开一个（room %d）", *hb.Room)
	}
	return false, ""
}

// NodeRoute is one way into a machine's sshd: a name people see ("tailnet",
// "public", "lan"), a host and a port (0 = 22). Prefix is the prefix length of
// the network a "lan" route's address sits on (claude-fleet#3074): a client
// tests that route only when one of its own interfaces is on the same network.
// 0 = not said (every other route, and an agent older than #3074).
type NodeRoute struct {
	Name   string `json:"name"`
	Host   string `json:"host"`
	Port   int    `json:"port,omitempty"`
	Prefix int    `json:"prefix,omitempty"`
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
//	reset   fleet-login-remove.sh <login> --recycle --keep-home --apply
//
// The hub chooses only the login and the display name, and both are checked
// against ValidCreateLogin / ValidFullName on the node before anything runs.
//
// reset (claude-fleet#3504, EPIC #3500 C12) washes a person's login for the
// next one instead of deleting it: the remove script's --recycle mode keeps the
// OS user, empties what the person left, re-joins the login with the op's
// fresh join code and ends with two lines — `reset: clean|dirty …` then
// `credsep: separated|…` (AccountResult.Reset / .Credsep). Sent only to an
// admin whose hello lists CapRecycle.
const (
	AccountCreate = "create"
	AccountRemove = "remove"
	AccountReset  = "reset"
)

// ResetClean is AccountResult.Reset for a login the reset check found clean
// (bin/fleet-login-reset-check.py's last line `reset: clean`).
const ResetClean = "clean"

// RemoveExitNoLogin is fleet-login-remove.sh's exit when the machine has no
// such login (claude-fleet#2696): nothing to remove, so the hub records the
// remove done — a create that never made it, or a login closed by hand. An
// older script refused it (exit 3) and the remove read failed.
const RemoveExitNoLogin = 4

// AccountOp is the payload of TypeAccountOp.
type AccountOp struct {
	Op       string `json:"op"`
	Login    string `json:"login"`
	FullName string `json:"full_name,omitempty"`
	// Existing says the login is not a new one: the hub already holds it as
	// this person's active login on another machine (adopted, claude-fleet#2105),
	// and asks for the same name here. It widens the node's check from
	// ValidLogin to ValidCreateLogin(login, true); an older node ignores it and
	// keeps refusing a digit-leading login.
	Existing bool `json:"existing,omitempty"`
	// DropHome asks a remove to delete the home outright instead of archiving
	// it first (claude-fleet#2652): a drill person's throwaway login holds
	// nothing worth keeping, and the archive of its clone + Claude is most of
	// a drill's teardown time. An older node ignores it and archives.
	DropHome bool `json:"drop_home,omitempty"`
	// JoinCode is a one-time join code (fj_…) the hub minted for this create
	// (claude-fleet#2652): the new login joins the hub with it as its OWN node
	// and brings its fleet up, so the sessions the hub places for the person
	// have somewhere to land. Never logged, never in a result; an older node
	// ignores it and the login waits for its first interactive login as before.
	JoinCode string `json:"join_code,omitempty"`
	// Ticket is the hub's signed AccountTicket for this op (claude-fleet
	// #3557): set only for a node that listed CapAdminSeat, whose two root
	// scripts refuse an op without one. Never logged; an admin login's
	// agent is never sent one and ignores it.
	Ticket string `json:"ticket,omitempty"`
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
	// Credsep is how the login's credentials ended up (claude-fleet#2294):
	// CredsepSeparated when no token is readable from it. Absent from a node
	// that does not separate — a spare it opened is never handed out.
	Credsep string `json:"credsep,omitempty"`
	// Reset is a reset's verdict (claude-fleet#3504): ResetClean when the
	// script's `reset:` line said clean, else what it said ("dirty home,…").
	// Absent on any other op. Only a clean, separated reset is handed out.
	Reset string `json:"reset,omitempty"`
	// Ready is the login's check before it is handed out (claude-fleet#4673):
	// the script's last `ready:` line (bin/fleet-login-ready.sh). Absent from a
	// node older than it, or a create the hub did not open — and a spare without
	// all three is never handed out.
	Ready *AccountCheck `json:"ready,omitempty"`
}

// AccountCheck is fleet-login-ready.sh's verdict on a login (claude-fleet
// #4673): the epoch second each step passed — a session credential from the
// machine's proxy, the login's home up, a first reply — 0 when it was not
// reached, and Fail (`<step>: <why>`) when one did not pass.
type AccountCheck struct {
	CredOK       int64  `json:"cred_ok,omitempty"`
	HomeOK       int64  `json:"home_ok,omitempty"`
	FirstReplyOK int64  `json:"first_reply_ok,omitempty"`
	Fail         string `json:"fail,omitempty"`
}

// Passed says all three steps passed.
func (c AccountCheck) Passed() bool {
	return c.Fail == "" && c.CredOK > 0 && c.HomeOK > 0 && c.FirstReplyOK > 0
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

// ValidCreateLogin is the shape of login a create op may make. A login the
// hub mints is ValidLogin. One it already holds as the person's active login
// elsewhere (existing — a hand-made `acme` adopted on the first machine,
// claude-fleet#2105) may be opened under the same name on another machine:
// ValidExistingLogin, and never all digits (a numeric name reads as a uid).
func ValidCreateLogin(s string, existing bool) bool {
	if !existing {
		return ValidLogin(s)
	}
	if !ValidExistingLogin(s) {
		return false
	}
	for _, c := range s {
		if c >= 'a' && c <= 'z' {
			return true
		}
	}
	return false
}

// ValidExistingLogin is the shape of a login the operator may NAME — one
// that already exists on a machine and is adopted, mapped to a person
// (user.<id>.machine_login) or put on a certificate — as opposed to
// one the hub would create. The same alphabet as ValidLogin, so it still
// cannot be an option or a path, but a leading digit is allowed: macOS
// permits it, and `acme` is a real login (claude-fleet#1458). The hub
// never MINTS a login of this shape; a create op makes one only as a second
// machine's copy of a login the hub already holds (ValidCreateLogin).
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
//	client ──wss SSHRelayPath?node=mac-a──▶ hub ──TypeSSHRelayOpen on the control channel──▶ agent
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

	// CapPodRelay is listed beside CapSSHRelay by an agent in one person's pod
	// whose relay reaches the pod's own sshd (its port 2222, the hub's user CA
	// trusted on loopback — claude-fleet#4149). Without it a pod behind the
	// door is offered no relay: the agent there would dial a port nothing
	// listens on.
	CapPodRelay = "pod_relay"

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

	// SummaryPath is where a status bar asks for the two summaries it shows
	// beside the sessions — the machines and the subscription readings, the
	// shapes of /v1/nodes `machines` and /v1/limits?account=all `per_account`
	// (claude-fleet#1502). Those two are viewer routes; this one admits a
	// connection certificate the way SessionsPath does.
	SummaryPath = "/v1/fleet/summary"
	// SummarySigNamespace is the ssh-keygen -Y namespace a status bar signs
	// its summary request under (the message is SummarySigMessage).
	SummarySigNamespace = "fleet-summary@claude-fleet"
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

// SummarySigMessage is what a status bar signs to read its summaries with a
// connection certificate (claude-fleet#1502), same shape as SessionsSigMessage.
func SummarySigMessage(unix int64) string {
	return fmt.Sprintf("fleet-summary %d", unix)
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
	// LoginNodePath is where a registered device asks for its node pass
	// (claude-fleet#2212, 登录即登记): POST {public_key, ts, sig, hostname,
	// os_user} signed like RenewPath, under LoginNodeSigNamespace over
	// LoginNodeSigMessage(ts). The hub enrolls the device ONCE as an
	// untrusted, coordinate-only node and reissues that node's token after.
	LoginNodePath         = "/v1/fleet/login/node"
	LoginNodeSigNamespace = "fleet-login-node@claude-fleet"
)

// LoginNodeSigMessage is what a device signs to ask for its node pass.
func LoginNodeSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-login-node %d", unix)
}

// RenewSigMessage is what a device signs to renew its certificate.
func RenewSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-renew %d", unix)
}

// HomeSigMessage is what a client signs to ask which machine to enter.
func HomeSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-home %d", unix)
}

// The client lease (claude-fleet#1715, EPIC #1710 C5): one person, one
// connected `fleet` client at a time. A client takes the lease when it opens
// and renews it every 15 seconds (45 without one and it lapses); a second client of the same person
// takes it over, and the first reads taken_over on its next renewal and goes
// to its standby screen. POST {cert, sig, ts, action, lease, device, terminal,
// version} signed under ClientSigNamespace over ClientSigMessage(ts) — or a
// viewer door's GET (the current lease) / POST.
const (
	ClientPath         = "/v1/fleet/client"
	ClientSigNamespace = "fleet-client@claude-fleet"
)

// ClientSigMessage is what a client signs to take, renew, release or read its
// person's client lease.
func ClientSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-client %d", unix)
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
	// Encoding is how the node encodes Form: "" = a JSON body (every
	// refresh), "form" = application/x-www-form-urlencoded — OpenAI's token
	// endpoint takes a sign-in's authorization_code only that way (a member
	// connecting their own subscription, claude-fleet#4035). Never a URL or a
	// header: the endpoint is still the node's own pick by Provider. An older
	// node ignores it and posts JSON.
	Encoding string `json:"encoding,omitempty"`
}

// OAuthEncodingForm is OAuthRefresh.Encoding for a urlencoded body.
const OAuthEncodingForm = "form"

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

// The team configuration (claude-fleet#1726, EPIC #1718 C8): the layer the
// hub hands every computer between the fleet's defaults and the login's own.
// GET reads it by any of the hub's doors (a viewer door, a node's enrollment
// token); a client-only computer, which holds neither, POSTs {cert, sig, ts}
// signed under TeamBundleSigNamespace over TeamBundleSigMessage(ts). PUT is
// the operator's alone.
const (
	TeamBundlePath         = "/v1/fleet/team-bundle"
	TeamBundleSigNamespace = "fleet-team@claude-fleet"
)

// TeamBundleSigMessage is what a client signs to read the team layer.
func TeamBundleSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-team %d", unix)
}

// The personal configuration (claude-fleet#1856, EPIC #1855 C1): one layer
// per person, between the team's and the login's own. GET reads the
// caller's own (a person's session, a node token — the person its login is
// bound to — or a POST {cert, sig, ts} signed under PersonBundleSigNamespace
// over PersonBundleSigMessage(ts)); the operator reads anyone's with
// ?principal=<id>. PUT is the person's own (session, node token or the same
// signed body); the operator may only {restore: N} one of their versions.
const (
	PersonBundlePath         = "/v1/fleet/person-bundle"
	PersonBundleSigNamespace = "fleet-person@claude-fleet"
)

// PersonBundleSigMessage is what a client signs to read or write its
// person's layer.
func PersonBundleSigMessage(unix int64) string {
	return fmt.Sprintf("fleet-person %d", unix)
}
