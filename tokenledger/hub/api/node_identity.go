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
// One kind of endpoint keeps its report: a machine's own node program
// (enrolled as root — `fleet node install` — by an operator's or the hub's
// code, never a member's device road). It speaks for its machine whatever
// service login it runs demoted under (a person's pod, the _fleetnode seat),
// and a Mac's HostName may differ from the LocalHostName it joined as; nothing
// it reports reaches past the machine root already holds.

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
}

// machineByLegacy is the rule before task MPCX, for an endpoint that has not
// said who it is yet (Unstamped): a root report or a link that says machine.
// No member's device reaches it — every device road stamps its login.
func (id nodeIdent) machineByLegacy(machineLink bool) bool {
	return id.Unstamped && (id.ReportedUser == "root" || machineLink)
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
	id.Machine = et.EnrolledUser == "root" && !s.memberDevice(ep.ID)
	if id.EnrolledHost != "" && !sameEnrolledName(id.EnrolledHost, host) {
		switch {
		case host == "":
			id.Host = id.EnrolledHost // it never said: the enrollment's, as before
		case !id.Machine:
			id.Host, id.HostDrift = id.EnrolledHost, true
		}
	}
	if id.EnrolledUser != "" && user != id.EnrolledUser {
		switch {
		case user == "":
			id.User = id.EnrolledUser
		case !id.Machine:
			id.User, id.UserDrift = id.EnrolledUser, true
		}
	}
	return id
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
	principals, byDevice := s.deviceEnrolled(endpointID)
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
