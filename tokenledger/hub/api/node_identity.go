package api

import (
	"errors"
	"log"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Who a node is, for the hub's decisions (task MPCX).
//
// A node's hostname and os_user are its own word: every usage push and every
// heartbeat rewrites them. What the hub decides on — whose login it is, which
// machine it speaks for, whether it is an admin — reads the identity the
// endpoint ENROLLED with instead: endpoints.enrolled_host (claude-fleet#2214)
// and endpoints.enrolled_user, both written once, at enrollment. The report
// stays what the roster shows; when it disagrees with the enrollment the
// enrollment decides, and each connection writes one node_identity audit row.
//
// A machine NAME that moved is held to the enrollment when the endpoint is a
// member's device or the new name is a trusted machine it did not join as; an
// endpoint an operator's or the hub's code enrolled keeps a renamed host's
// report, as before (its login is held either way).
//
// A machine's own node program (enrolled as root — `fleet node install` — by
// an operator's or the hub's code, never a member's device road) is held the
// same way, with what it legitimately varies left to it: a Mac's HostName may
// differ from the LocalHostName it joined as, so a renamed host keeps its
// report unless it names a trusted machine it did not join as, a machine
// another node program enrolled as, or a user pod; and it speaks for the
// logins the hub opened on the machine it enrolled as (an account row there,
// an endpoint enrolled there) and the machine's service seat (_fleetnode /
// fleetnode) — any other login it reports is held to root. A user pod's
// program (podEndpoint) is held to its pod: its token is readable by the
// pod's person, so its host never moves and only the pod's own logins count.

// nodeIdent is an endpoint's identity as the hub reads it.
type nodeIdent struct {
	// Host / User are what every decision reads.
	Host, User string
	// Reported* are the node's own word; Enrolled* its enrollment ("" when it
	// never said one).
	ReportedHost, ReportedUser string
	EnrolledHost, EnrolledUser string
	// HostDrift / UserDrift: the report disagrees with the enrollment and the
	// enrollment decided.
	HostDrift, UserDrift bool
	// Machine: a machine's own node program (enrolled as root, not by a
	// member's device road) — the only endpoint that speaks for a machine.
	Machine bool
	// Unstamped: the endpoint has said no login yet (an operator's
	// `ccquota enroll` before its first report — every join stamps one). Its
	// first report will be its enrollment; until then the old rules hold.
	Unstamped bool
	// ByDevice: a device road enrolled it (`fleet login`'s node pass, a
	// `fleet node join` scan, a node linked to a device) — whoever's device.
	// Member: ByDevice, and none of those devices is a hub admin's
	// (memberDevice).
	ByDevice, Member bool
}

// machineByLegacy is the rule before task MPCX, for an endpoint that has not
// said who it is yet (Unstamped): a root report or a link that says machine.
// It holds only for an endpoint no device road enrolled — an operator's
// `ccquota enroll` before its first report; a device's endpoint is never a
// machine's program by what it says.
func (id nodeIdent) machineByLegacy(machineLink bool) bool {
	return id.Unstamped && !id.ByDevice && (id.ReportedUser == "root" || machineLink)
}

// drift says the report moved nothing only because the enrollment decided.
func (id nodeIdent) drift() bool { return id.HostDrift || id.UserDrift }

// reportedSelf is a node's own word: its roster row's host and login, else
// its endpoint row's.
func (s *Server) reportedSelf(ep *store.Endpoint) (host, user string) {
	host, user = ep.Hostname, ep.OSUser
	if n := s.nodeRow(ep.ID); n != nil {
		if n.Hostname != "" {
			host = n.Hostname
		}
		if n.OSUser != "" {
			user = n.OSUser
		}
	}
	return host, user
}

// nodeSelf is ep's identity: its roster report, held to its enrollment.
func (s *Server) nodeSelf(ep *store.Endpoint) nodeIdent {
	host, user := s.reportedSelf(ep)
	return s.nodeSelfFrom(ep, host, user)
}

// sameEnrolledName: the reported name is the machine the endpoint joined as —
// one first label, or the same name once the join's own trimming
// (sanitizeJoinField: first label, label-safe, 32 at most) is applied to both.
func sameEnrolledName(enrolled, reported string) bool {
	return sameName(enrolled, reported) ||
		(enrolled != "" && strings.EqualFold(sanitizeJoinField(enrolled), sanitizeJoinField(reported)))
}

// nodeSelfFrom holds a report (host, user) to ep's enrollment.
func (s *Server) nodeSelfFrom(ep *store.Endpoint, host, user string) nodeIdent {
	id := nodeIdent{Host: host, User: user, ReportedHost: host, ReportedUser: user}
	et, err := s.Store.EndpointTrustOf(ep.ID)
	if err != nil {
		log.Printf("node %s: read its enrollment: %v", ep.ID, err)
		return id
	}
	id.EnrolledHost, id.EnrolledUser = enrolledMachine(et), et.EnrolledUser
	id.Unstamped = et.EnrolledUser == ""
	principals, byDevice := s.deviceEnrolled(ep.ID)
	id.ByDevice, id.Member = byDevice, s.membersOnly(principals, byDevice)
	id.Machine = et.EnrolledUser == "root" && !id.Member
	pod := id.Machine && s.podEndpoint(ep.ID)
	if id.EnrolledHost != "" && !sameEnrolledName(id.EnrolledHost, host) {
		switch {
		case host == "":
			id.Host = id.EnrolledHost // it never said: the enrollment's, as before
		case id.Machine && (pod || s.nameBorrowed(host, et) || s.machineNameTaken(ep.ID, host)):
			id.Host, id.HostDrift = id.EnrolledHost, true
		case !id.Machine && (id.Member || s.nameBorrowed(host, et)):
			id.Host, id.HostDrift = id.EnrolledHost, true
		}
	}
	if id.EnrolledUser != "" && user != id.EnrolledUser {
		switch {
		case user == "":
			id.User = id.EnrolledUser
		case id.Machine && !s.machineLoginOpen(id.EnrolledHost, user, pod):
			id.User, id.UserDrift = id.EnrolledUser, true
		case !id.Machine:
			id.User, id.UserDrift = id.EnrolledUser, true
		}
	}
	return id
}

// machineSeatLogins are the logins a machine's own node program runs demoted
// under on a machine `fleet node install` set up (the core's service seat).
var machineSeatLogins = map[string]bool{"_fleetnode": true, "fleetnode": true}

// machineNameTaken: host is a name a machine's program may not report as its
// own (task MPCX) — one another machine's program enrolled as, or a user pod's
// (the hub minted that name for a pod; a machine never renames into it). An
// unreadable answer is a yes.
func (s *Server) machineNameTaken(endpointID, host string) bool {
	if isUserPodName(host) {
		return true
	}
	taken, err := s.Store.MachineProgramEnrolledAs(endpointID, host)
	return err != nil || taken
}

// machineLoginOpen: login is one a machine's program speaks for on machine,
// the machine it enrolled as (task MPCX) — an active account the hub opened
// there, a live endpoint enrolled there as that login (a lane, the admin seat,
// an operator's login), or the machine's service seat. A pod's program gets
// no seat: its node runs as the pod's own login. An unreadable answer is no.
func (s *Server) machineLoginOpen(machine, login string, pod bool) bool {
	if machine == "" || login == "" {
		return false
	}
	if machineSeatLogins[login] {
		return !pod
	}
	for _, name := range []string{machine, firstLabel(machine)} {
		accts, err := s.Store.ActiveAccountsOn(name)
		if err != nil {
			return false
		}
		for _, a := range accts {
			if a.Login == login {
				return true
			}
		}
		if name == firstLabel(machine) {
			break
		}
	}
	ok, err := s.Store.LoginEnrolledOn(machine, login)
	return err == nil && ok
}

// nameBorrowed: host is a trusted machine the endpoint did not enroll as
// (nodeTrust's name_borrowed). A machine name that merely moved since an
// operator's or the hub's code enrolled the endpoint — a renamed Mac, a join
// that named the machine differently — is not borrowed and keeps its report,
// as before; a member's device is held to its enrollment either way.
func (s *Server) nameBorrowed(host string, et store.EndpointTrust) bool {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return true // unreadable: the enrollment decides
	}
	_, src := nodeTrust(host, et, settings)
	return src == TrustSourceNameBorrowed
}

// deviceEnrolled is who enrolled endpointID by a device's road
// (store.DeviceEnrollers); an unreadable record reads as enrolled by nobody
// the hub can name — never as an operator's own endpoint.
func (s *Server) deviceEnrolled(endpointID string) (principals []string, byDevice bool) {
	principals, byDevice, err := s.Store.DeviceEnrollers(endpointID)
	if err != nil {
		log.Printf("node %s: read how it enrolled: %v", endpointID, err)
		return nil, true
	}
	return principals, byDevice
}

// memberDevice: endpointID was enrolled by a device road (`fleet login`'s node
// pass, a `fleet node join` scan) and none of those devices is a hub admin's.
// Such an endpoint is a person's own terminal: whatever login it enrolled
// under, it is never an admin node and never a machine's program.
func (s *Server) memberDevice(endpointID string) bool {
	return s.membersOnly(s.deviceEnrolled(endpointID))
}

// membersOnly: a device road enrolled it, and none of those devices' people is
// one of the hub's admins.
func (s *Server) membersOnly(principals []string, byDevice bool) bool {
	if !byDevice {
		return false
	}
	for _, p := range principals {
		if s.isOperator(p) {
			return false
		}
	}
	return true
}

// podEndpoint: endpointID is a person's pod's own node program (task MPCX) —
// enrolled by the code the hub minted for that pod, or enrolled as a user
// pod's name. Its token is readable by the pod's person, so whatever a
// machine's program may do, this one does only for its own pod. An
// unreadable record reads as a pod.
func (s *Server) podEndpoint(endpointID string) bool {
	pod, err := s.Store.PodEnrolled(endpointID)
	if err != nil {
		log.Printf("node %s: read how it enrolled: %v", endpointID, err)
		return true
	}
	if pod {
		return true
	}
	et, err := s.Store.EndpointTrustOf(endpointID)
	if errors.Is(err, store.ErrNoSuchEndpoint) {
		return false
	}
	if err != nil {
		return true
	}
	return isUserPodName(enrolledMachine(et))
}

// isOperator: pid is one of the hub's admins right now (personRole).
func (s *Server) isOperator(pid string) bool {
	if pid == "" {
		return false
	}
	role, err := s.personRole(pid)
	return err == nil && role == roleAdmin
}

// nodeAdminOK is the hub's half of a node's admin role (task MPCX): the login
// it ENROLLED as is on the hub's admin list (CCQUOTA_FLEET_ADMIN_USERS — an
// admin seat the hub issued, or an admin login an operator joined), and no
// member's device road enrolled it. The hello's own admin:true is the node's
// half; the login a report names now is neither.
func (s *Server) nodeAdminOK(ep *store.Endpoint) bool {
	et, err := s.Store.EndpointTrustOf(ep.ID)
	if err != nil {
		return false
	}
	login := et.EnrolledUser
	if login == "" {
		login = ep.OSUser // a row that never said one: its first report is its enrollment
	}
	return s.isFleetAdmin(login) && !s.memberDevice(ep.ID)
}

// operatorEndpoint is the endpoint's half of "this node is the operator's"
// (task MPCX), beside a login on the admin list (or a hub that names no
// admins): no member's device road enrolled it, and it is no person's pod —
// a pod's node runs as its person, whatever login it says. A login's own
// name never makes an endpoint the operator's.
func (s *Server) operatorEndpoint(endpointID string) bool {
	if endpointID == "" {
		return false
	}
	return !s.memberDevice(endpointID) && !s.podEndpoint(endpointID)
}

// ownerlessOperator: an endpoint whose login no person owns may act as the
// operator's (task MPCX) — the operator's own agent, enrolled by an
// operator's code or `ccquota enroll`. Never one a device road enrolled (a
// device is a person's or nothing) and never a person's pod.
func (s *Server) ownerlessOperator(endpointID string) bool {
	if endpointID == "" {
		return false
	}
	if _, byDevice := s.deviceEnrolled(endpointID); byDevice {
		return false
	}
	return !s.podEndpoint(endpointID)
}

// errOwnerless is the refusal of a person's road to a node no person owns
// that is not the operator's own (ownerlessOperator).
var errOwnerless = errors.New("no person owns this node's login, and it is not one of the operator's own nodes")

// nodeLoginPrincipal is the person whose account login is on host, for endpoint
// endpointID (task MPCX): a 登录即认人 row counts only for the endpoint it is
// bound to, and an endpoint a device road enrolled answers only to that
// device's person — a hub-managed row of somebody else on a name it chose is
// not theirs. ErrNoPrincipal when none.
func (s *Server) nodeLoginPrincipal(endpointID, host, login string) (string, error) {
	p, managed, err := s.Store.PrincipalForNodeLogin(endpointID, host, login)
	if err != nil || !managed {
		return p, err
	}
	principals, byDevice := s.deviceEnrolled(endpointID)
	if !byDevice {
		return p, nil
	}
	for _, d := range principals {
		if d != "" && strings.EqualFold(d, p) {
			return p, nil
		}
	}
	return "", store.ErrNoPrincipal
}

// auditIdentityDrift writes the one node_identity row a connection gets when
// its report disagrees with its enrollment.
func (s *Server) auditIdentityDrift(ep *store.Endpoint, id nodeIdent, now time.Time) {
	if !id.drift() {
		return
	}
	s.leaseAudit("node:"+ep.ID, "node_identity", "endpoint:"+ep.ID,
		"REPORT DIFFERS — enrolled as "+id.EnrolledUser+"@"+id.EnrolledHost+", reports "+
			id.ReportedUser+"@"+id.ReportedHost+": the enrollment decides", now)
}

// errNodeDrift is the refusal of a road that needs the node to be what it
// enrolled as.
var errNodeDrift = errors.New("this node reports a login other than the one it enrolled as")

// routeSelf is the machine and login a link is routed to by (task MPCX): the
// identity nodeSelf holds it to — so a report naming another person's machine
// or login moves none of their relays, chats, terminals, service logs, svc
// runs or previews onto this link — except one shape: a link whose machine
// name moved (a member's renamed laptop) to a name nothing else on the hub
// holds — no other endpoint reports it, no login is open on it, it is no
// machine the hub has a trust word for — keeps that name, since its sessions
// are listed under it. Its login stays held either way.
func (s *Server) routeSelf(ep *store.Endpoint, id nodeIdent) (host, user string) {
	host, user = id.Host, id.User
	if id.HostDrift && id.ReportedHost != "" && !s.hostClaimed(ep.ID, id.ReportedHost) {
		host = id.ReportedHost
	}
	return host, user
}

// hostClaimed: host names a machine the hub knows apart from endpointID — a
// trust word for it, a login open on it, or another endpoint reporting it. An
// unreadable answer is a yes.
func (s *Server) hostClaimed(endpointID, host string) bool {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return true
	}
	if _, ok := settings[trustKey(host)]; ok {
		return true
	}
	if accts, err := s.Store.ActiveAccountsOn(host); err != nil || len(accts) > 0 {
		return true
	}
	if fl := firstLabel(host); fl != host {
		if accts, err := s.Store.ActiveAccountsOn(fl); err != nil || len(accts) > 0 {
			return true
		}
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		return true
	}
	for _, n := range rows {
		if n.EndpointID != endpointID && (sameMachine(n.Hostname, host) || sameMachine(host, n.Hostname)) {
			return true
		}
	}
	return false
}
