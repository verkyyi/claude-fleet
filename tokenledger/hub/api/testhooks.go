package api

import (
	"context"
	"net"
	"net/http"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Test hooks: what the联调 tests see and set inside the hub (claude-fleet#4814,
// EPIC #4810 C4). Those tests start a real node, and the hub module never names
// the node — not even in a test — so they live in their own module,
// tokenledger/e2e, and reach the hub through hub/apitest and these. Nothing in
// the hub calls them; a name ending in ForTest is never a road for the hub's
// own code (the agent package's SetTermHelperForTest is the same idea).

// NodeConn is a node's control connection as the hub holds it.
type NodeConn = nodeConn

// NodeForTest is endpoint id's live control connection, nil when none.
func (s *Server) NodeForTest(id string) *NodeConn { return s.nodes.get(id) }

// HostnameForTest is the hostname the node said in its hello.
func (c *nodeConn) HostnameForTest() string { return c.hostname() }

// MachineForTest is the machine endpoint a tenant login rides on ("" = its own link).
func (c *nodeConn) MachineForTest() string { return c.wire.machine() }

// TokHashForTest is the hash of the token the node connected with.
func (c *nodeConn) TokHashForTest() string { return c.tokHash }

// AttachmentGenerationForTest is the attachment generation the node said.
func (c *nodeConn) AttachmentGenerationForTest() string { return c.attachmentGeneration }

// PendingRelayForTest is a relay the test parked by hand: the open message's
// RelayID and Secret, and the node's callback on Attach.
type PendingRelayForTest struct {
	ID, Secret string
	Attach     <-chan *websocket.Conn
	// Release ends it: the data half returns and the table forgets it.
	Release func()
}

// PendTermRelayForTest parks a terminal relay to endpoint endpointID over nc
// (id "" = a new one), as the term route does before it sends the node its TermOpen.
func (s *Server) PendTermRelayForTest(id, endpointID string, nc *NodeConn, cancel context.CancelFunc) *PendingRelayForTest {
	return pend(&s.termRelays, id, endpointID, nc, cancel)
}

// PendChatRelayForTest is PendTermRelayForTest for a chat relay.
func (s *Server) PendChatRelayForTest(id, endpointID string, nc *NodeConn, cancel context.CancelFunc) *PendingRelayForTest {
	return pend(&s.chatRelays, id, endpointID, nc, cancel)
}

func pend(t *sshRelayTable, id, endpointID string, nc *NodeConn, cancel context.CancelFunc) *PendingRelayForTest {
	if id == "" {
		id = control.NewOpID()
	}
	if cancel == nil {
		cancel = func() {}
	}
	attach := make(chan *websocket.Conn, 1)
	p := &pendingSSHRelay{id: id, secret: control.NewOpID(), endpointID: endpointID, node: nc,
		attach: attach, done: make(chan struct{}), cancel: cancel}
	t.put(p)
	return &PendingRelayForTest{ID: p.id, Secret: p.secret, Attach: attach,
		Release: func() { close(p.done); t.drop(p.id) }}
}

// TermRelaysOpenForTest · ChatRelaysOpenForTest · SSHRelaysOpenForTest count
// the relays in flight.
func (s *Server) TermRelaysOpenForTest() int { return s.termRelays.open() }
func (s *Server) ChatRelaysOpenForTest() int { return s.chatRelays.open() }
func (s *Server) SSHRelaysOpenForTest() int  { return s.sshRelays.open() }

// SSHRelaysOfForTest is how many ssh relays actor holds.
func (s *Server) SSHRelaysOfForTest(actor string) int {
	s.sshRelays.mu.Lock()
	defer s.sshRelays.mu.Unlock()
	return s.sshRelays.perUser[actor]
}

// CloseNodeTermRelaysForTest ends every terminal relay riding on nc, as its
// control channel dropping does.
func (s *Server) CloseNodeTermRelaysForTest(nc *NodeConn) { s.termRelays.closeNode(nc) }

// ChatInflightForTest is how many people have a chat turn in flight.
func (s *Server) ChatInflightForTest() int {
	s.chatGate.mu.Lock()
	defer s.chatGate.mu.Unlock()
	return len(s.chatGate.inflight)
}

// ForwardedForTest counts the calls this replica handed to another.
func (s *Server) ForwardedForTest() int64 { return s.forwarded.Load() }

// DialChatRelayForTest opens person's chat relay to login on host.
func (s *Server) DialChatRelayForTest(ctx context.Context, person, host, login string) (net.Conn, error) {
	return s.dialChatRelay(ctx, person, host, login)
}

// SSHRelayLocalForTest · SSHRelayReadyForTest: is host's node on this replica,
// and would this replica take an ssh relay to it.
func (s *Server) SSHRelayLocalForTest(host string) bool { return s.sshRelayLocal(host) }
func (s *Server) SSHRelayReadyForTest(host string) bool { return s.sshRelayReadiness()(host) }

// SetTermPingForTest runs a terminal relay's half-open probe and re-admission
// at these periods until restore.
func SetTermPingForTest(every, timeout, recheck time.Duration) (restore func()) {
	oe, ot, or := termPingEvery, termPingTimeout, termRecheckEvery
	termPingEvery, termPingTimeout, termRecheckEvery = every, timeout, recheck
	return func() { termPingEvery, termPingTimeout, termRecheckEvery = oe, ot, or }
}

// SetWorkersPushEveryForTest pushes the workers roster at this period until restore.
func SetWorkersPushEveryForTest(d time.Duration) (restore func()) {
	old := workersPushEvery.Get()
	workersPushEvery.Set(d)
	return func() { workersPushEvery.Set(old) }
}

// MaintenanceKeyForTest is the fleet setting that puts machine into 维护中.
func MaintenanceKeyForTest(machine string) string { return maintenanceKey(machine) }

// EntryReturnCookieForTest names the cookie holding where sign-in returns to.
const EntryReturnCookieForTest = entryReturnCookie

// LoginReturnForTest is where sign-in sends r back to.
func LoginReturnForTest(w http.ResponseWriter, r *http.Request) string { return loginReturn(w, r) }

// The chat city database's layout (ip2region xdb v4).
const (
	GeoHeaderForTest  = geoHeader
	GeoVectorForTest  = geoVector
	GeoSegmentForTest = geoSegment
)

// RoleUserForTest · RoleTrialForTest are a session's roles.
const (
	RoleUserForTest  = roleUser
	RoleTrialForTest = roleTrial
)

// SessionKeyForTest is the key GitHub sign-in signs sessions with.
func (g *GitHubAuth) SessionKeyForTest() string { return g.sessionKey() }

// GitHubIDOfForTest is a gh:<id> principal's GitHub id.
func GitHubIDOfForTest(principal string) (int64, bool) { return githubIDOf(principal) }

// IsPersonForTest: is principal a person's (p:<uuid>)?
func IsPersonForTest(principal string) bool { return isPerson(principal) }

// AttachmentFrameForTest is one websocket frame of an attachment.
type AttachmentFrameForTest struct {
	Type websocket.MessageType
	Data []byte
	Err  error
}

// ReadAttachmentFramesForTest reads c's frames until it ends or ctx does.
func ReadAttachmentFramesForTest(ctx context.Context, c *websocket.Conn) <-chan AttachmentFrameForTest {
	in := readAttachmentFrames(ctx, c)
	out := make(chan AttachmentFrameForTest, 1)
	go func() {
		for {
			var f attachmentFrame
			select {
			case f = <-in:
			case <-ctx.Done():
				return
			}
			select {
			case out <- AttachmentFrameForTest{f.typ, f.b, f.err}:
			case <-ctx.Done():
				return
			}
			if f.err != nil {
				return
			}
		}
	}()
	return out
}

// SendAttachmentSignalForTest writes one signalling message to c.
func SendAttachmentSignalForTest(ctx context.Context, c *websocket.Conn, v control.AttachmentSignal) error {
	return sendAttachmentSignal(ctx, c, v)
}

// UserForTest is the login the node runs as.
func (c *nodeConn) UserForTest() string { return c.user() }

// CanChatForTest: did the node offer CapChat?
func (c *nodeConn) CanChatForTest() bool { return c.canChat }

// DropTermControllerForTest · DropTermRenewForTest take the capability back, as
// an older node never offered it.
func (c *nodeConn) DropTermControllerForTest() { c.canTermController = false }
func (c *nodeConn) DropTermRenewForTest()      { c.canTermRenew = false }

// RelayRefusalCodeForTest is a relay refusal's code (NO_CHAT, TOO_MANY, …);
// ok is false for any other error.
func RelayRefusalCodeForTest(err error) (code string, ok bool) {
	re, ok := err.(*sshRelayError)
	if !ok {
		return "", false
	}
	return re.code, true
}

// CanTermForTest: did the node offer CapTerm?
func (c *nodeConn) CanTermForTest() bool { return c.canTerm }

// EndpointHostForTest is the hostname the hub has on record for ep.
func (s *Server) EndpointHostForTest(ep store.Endpoint) string { return s.endpointHost(ep) }

// CloseLinkForTest drops the node's control channel from the hub's side.
func (c *nodeConn) CloseLinkForTest(code websocket.StatusCode, reason string) {
	c.wire.close(code, reason)
}

// SetChatRecheckForTest makes a running chat request's recheck tick every d.
func SetChatRecheckForTest(d time.Duration) (restore func()) {
	old := chatRecheckEvery.Get()
	chatRecheckEvery.Set(d)
	return func() { chatRecheckEvery.Set(old) }
}

// CloseKeptChatRelaysForTest closes every kept relay (a test's «released»).
func (s *Server) CloseKeptChatRelaysForTest() {
	s.chatPool.mu.Lock()
	defer s.chatPool.mu.Unlock()
	for _, e := range s.chatPool.m {
		e.tr.CloseIdleConnections()
	}
}
