package api

import (
	"errors"
	"log"
	"strings"
	"sync"
	"sync/atomic"
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
	// Pinned: a code minted for one machine enrolled it (an opened login, an
	// admin seat, a pod or a login in one): its machine never moves.
	Pinned bool
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

// nodeSelfFrom holds a report (host, user) to ep's enrollment. The answer is
// cached per endpoint for the report it was asked about (identCache): a
// heartbeat and the registry write it feeds ask twice, and nothing it reads
// moves between them.
func (s *Server) nodeSelfFrom(ep *store.Endpoint, host, user string) nodeIdent {
	repUser := user // the cache is keyed by the report as asked
	if id, ok := s.identCached(ep.ID, host, repUser); ok {
		return id
	}
	gen := s.Store.IdentityGen()
	id := nodeIdent{Host: host, User: user, ReportedHost: host, ReportedUser: user}
	et, err := s.Store.EndpointTrustOf(ep.ID)
	if err != nil {
		log.Printf("node %s: read its enrollment: %v", ep.ID, err)
		return id
	}
	enr := s.enrollment(ep.ID)
	id.EnrolledHost, id.EnrolledUser = enrolledMachine(et), et.EnrolledUser
	id.Unstamped = et.EnrolledUser == ""
	id.ByDevice, id.Member, id.Pinned = enr.ByDevice, enr.Member, enr.Pinned
	// A machine's program is root by an operator's or the hub's code — never
	// a device's road, whoever's device (task MPCX).
	id.Machine = et.EnrolledUser == "root" && !enr.ByDevice
	pod := s.podOf(enr, et)
	if id.EnrolledHost != "" && !sameEnrolledName(id.EnrolledHost, host) {
		switch {
		case host == "":
			id.Host = id.EnrolledHost // it never said: the enrollment's, as before
		case id.Member || enr.Pinned || pod:
			// A member's device, a login or seat the hub opened on one
			// machine, a pod: the machine is the enrollment's. A machine's
			// rename is its own program's to carry, never a login's.
			id.Host, id.HostDrift = id.EnrolledHost, true
		case s.nameHeld(ep.ID, host):
			id.Host, id.HostDrift = id.EnrolledHost, true
		}
	}
	if id.ByDevice && isDeviceAlias(id.EnrolledUser) && (user == "" || user == "root") {
		// A device that runs as root (or names no login) enrolled under its
		// person's alias login (deviceRoadLogin): that report is the alias.
		user = id.EnrolledUser
		id.User = user
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
	s.identStore(ep.ID, host, repUser, gen, id)
	return id
}

// machineSeatLogins are the logins a machine's own node program runs demoted
// under on a machine `fleet node install` set up (the core's service seat).
var machineSeatLogins = map[string]bool{"_fleetnode": true, "fleetnode": true}

// nameHeld: host, a name the endpoint did not enroll as, names a machine that
// is not this endpoint's to claim (task MPCX) — a machine name the hub trusts,
// a machine some other endpoint enrolled as, or a user pod's name. A name
// nothing holds (a Mac's HostName, a renamed host) is not. Whether the
// endpoint's own machine is trusted does not enter. An unreadable answer is a
// yes.
func (s *Server) nameHeld(endpointID, host string) bool {
	if isUserPodName(host) {
		return true
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return true
	}
	if s.machineTrusted(firstLabel(host), settings) || s.machineTrusted(host, settings) {
		return true
	}
	other, err := s.Store.EnrolledByAnother(endpointID, host)
	return err != nil || other
}

// machineLoginOpen: login is one a machine's program speaks for on machine,
// the machine it enrolled as (task MPCX) — an active account the hub opened
// there (never a login a device recorded: ActiveAccountsOn leaves op=login
// rows out), a live endpoint enrolled there as that login by any road but a
// device's (a lane, the admin seat, an operator's login), or the machine's
// service seat. A pod's program gets no seat: its node runs as the pod's own
// login. An unreadable answer is no.
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
			if a.Login == login && a.Op != store.AccountOpLogin {
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

// enrollRec is store.EndpointEnrollment plus Member, cached (enrollment).
type enrollRec struct {
	store.EndpointEnrollment
	// Member: ByDevice, and none of those devices' people is one of the
	// hub's admins (memberDevice).
	Member bool
}

// enrollment is endpointID's enrollment record: the join-code facts cached
// until the identity generation moves (or identTTL passes — another
// replica's write), the device person's standing read through. An
// unreadable record reads as the most held one: a member's device, pinned, a
// pod — never the operator's own; it is not cached.
func (s *Server) enrollment(endpointID string) enrollRec {
	e, err := s.enrollmentRaw(endpointID)
	if err != nil {
		log.Printf("node %s: read how it enrolled: %v", endpointID, err)
		return enrollRec{EndpointEnrollment: store.EndpointEnrollment{ByDevice: true, Pinned: true, Pod: true}, Member: true}
	}
	// Whether a device's person is an admin is read every time, never
	// cached (task MPCX): a demotion or a revoked device counts at once.
	rec := enrollRec{EndpointEnrollment: e, Member: e.ByDevice}
	for _, p := range e.DevicePeople {
		if s.isOperator(p) {
			rec.Member = false
			break
		}
	}
	return rec
}

// enrollmentRaw is the join-code facts alone (cached; no person's role read).
func (s *Server) enrollmentRaw(endpointID string) (store.EndpointEnrollment, error) {
	gen := s.Store.IdentityGen()
	if v, ok := s.enrollCache.Load(endpointID); ok && v.(enrollEntry).gen == gen && time.Since(v.(enrollEntry).at) < identTTL {
		return v.(enrollEntry).rec, nil
	}
	e, err := s.Store.EnrollmentOf(endpointID)
	if err != nil {
		return e, err
	}
	s.cacheStore(&s.enrollCache, &s.enrollCount, endpointID, enrollEntry{gen: gen, at: time.Now(), rec: e})
	return e, nil
}

// loginOwner is the person whose active account (host, login) is ("" for
// none): whom a relay to that login is for.
func (s *Server) loginOwner(host, login string) string {
	p, err := s.Store.PrincipalForLogin(host, login)
	if err != nil {
		return ""
	}
	return p
}

// linkServes: the link of endpointID may carry traffic meant for owner's
// login (task MPCX). A device's link carries only its own person's — never
// another person's, whatever machine and login it enrolled as — and a login
// no one owns only when the device is an admin's own; any other link as
// before. An unreadable record carries nothing.
func (s *Server) linkServes(endpointID, owner string) bool {
	e, err := s.enrollmentRaw(endpointID)
	if err != nil {
		return false
	}
	if !e.ByDevice {
		return true
	}
	if owner == "" {
		// A login no person owns: the operator's. Only the operator's own
		// device carries it (its people all admins) — a linked computer of
		// theirs that never recorded a login.
		saw := false
		for _, p := range e.DevicePeople {
			if p == "" || !s.isOperator(p) {
				return false
			}
			saw = true
		}
		return saw
	}
	saw := false
	for _, p := range e.DevicePeople {
		if p == "" {
			continue
		}
		if !strings.EqualFold(p, owner) {
			return false
		}
		saw = true
	}
	return saw
}

type enrollEntry struct {
	gen uint64
	at  time.Time
	rec store.EndpointEnrollment
}

// deviceEnrolled is who enrolled endpointID by a device's road, or tied it to
// a device later (store.EnrollmentOf); an unreadable record reads as enrolled
// by nobody the hub can name — never as an operator's own endpoint.
func (s *Server) deviceEnrolled(endpointID string) (principals []string, byDevice bool) {
	e := s.enrollment(endpointID)
	return e.DevicePeople, e.ByDevice
}

// memberDevice: endpointID was enrolled by a device road (`fleet login`'s node
// pass, a `fleet node join` scan) or linked to a device, and none of those
// devices is a hub admin's. Such an endpoint is a person's own terminal:
// whatever login it enrolled under, it is never an admin node and never a
// machine's program. An operator's own linked computer is not one.
func (s *Server) memberDevice(endpointID string) bool { return s.enrollment(endpointID).Member }

// podEndpoint: endpointID is a person's pod's node program or a login inside
// a pod (task MPCX) — enrolled by the code the hub minted for that pod, or as
// a user pod's name. Its token is readable by the pod's person, so it does
// only what is that pod's own. An unreadable record reads as a pod.
func (s *Server) podEndpoint(endpointID string) bool {
	e := s.enrollment(endpointID)
	return e.Pod || isUserPodName(enrolledMachine(store.EndpointTrust{EnrolledHost: e.EnrolledHost}))
}

func (s *Server) podOf(e enrollRec, et store.EndpointTrust) bool {
	return e.Pod || isUserPodName(enrolledMachine(et))
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
// admins): no member's device enrolled it or was linked to it, and it is no
// person's pod — a pod's node runs as its person, whatever login it says. A
// login's own name never makes an endpoint the operator's. Cached
// (enrollment), so a reader over every fleet row asks the database once per
// endpoint.
func (s *Server) operatorEndpoint(endpointID string) bool {
	if endpointID == "" {
		return false
	}
	return !s.memberDevice(endpointID) && !s.podEndpoint(endpointID)
}

// ownerlessOperator: an endpoint whose login no person owns may act as the
// operator's (task MPCX) — the operator's own agent, enrolled by an
// operator's code or `ccquota enroll`, or the operator's own linked computer
// (its device's person is an admin). Never a member's device, never a pod,
// and never a login the hub opened on a machine (`<machine>-<login>` code) —
// a spare waiting for its person has none yet — unless that login is on the
// hub's admin list.
func (s *Server) ownerlessOperator(endpointID string) bool {
	if endpointID == "" {
		return false
	}
	e := s.enrollment(endpointID)
	if e.ByDevice {
		return !e.Member
	}
	if e.OpenedLogin != "" && !s.isFleetAdmin(e.OpenedLogin) {
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
// runs or previews onto this link. A member's renamed laptop is routed to
// under the name it enrolled as, where its person's login is recorded and its
// sessions are listed. Cached with nodeSelf's answer.
func (s *Server) routeSelf(ep *store.Endpoint, id nodeIdent) (host, user string) {
	if h, u, ok := s.routeCached(ep.ID, id); ok {
		return h, u
	}
	gen := s.Store.IdentityGen()
	host, user = id.Host, id.User
	s.routeStore(ep.ID, id, gen, host, user)
	return host, user
}

// identTTL bounds how long a cached identity answer stands without a write on
// this replica moving IdentityGen (store.identityChanged): another replica's
// enrollment, trust word, account change or role change reaches this one
// within it — the multi-replica bound. A device's answer stands
// identDeviceTTL at most, and its person's admin standing is read through.
const identTTL = 30 * time.Second

// identEntry is one endpoint's cached answer: nodeSelfFrom's for one report,
// and routeSelf's for it once asked.
type identEntry struct {
	host, user string // the report asked about
	gen        uint64
	at         time.Time
	id         nodeIdent
	routed     bool
	rHost      string
	rUser      string
}

func (s *Server) identCached(endpointID, host, user string) (nodeIdent, bool) {
	v, ok := s.identCache.Load(endpointID)
	if !ok {
		return nodeIdent{}, false
	}
	e := v.(identEntry)
	if e.host != host || e.user != user || e.gen != s.Store.IdentityGen() || time.Since(e.at) >= identTTLFor(e.id) {
		return nodeIdent{}, false
	}
	return e.id, true
}

// identTTLFor is how long one answer stands: identTTL, but a device's only
// identDeviceTTL — its standing rests on its person's role, which no write
// on this replica's generation need announce.
func identTTLFor(id nodeIdent) time.Duration {
	if id.ByDevice {
		return identDeviceTTL
	}
	return identTTL
}

// identDeviceTTL bounds a device endpoint's cached identity.
const identDeviceTTL = 3 * time.Second

// identCacheMax bounds each identity cache; past it the cache starts over.
const identCacheMax = 8192

// cacheStore puts v under key in m, counting new keys in n; a cache that
// grows past identCacheMax is emptied first.
func (s *Server) cacheStore(m *sync.Map, n *atomic.Int64, key string, v any) {
	if _, loaded := m.Swap(key, v); loaded {
		return
	}
	if n.Add(1) > identCacheMax {
		m.Range(func(k, _ any) bool { m.Delete(k); return true })
		n.Store(0)
		m.Store(key, v)
		n.Store(1)
	}
}

// forgetIdentity drops endpointID's cached answers (its link closed, it was
// retired): the cache holds live nodes, not every endpoint ever seen.
func (s *Server) forgetIdentity(endpointID string) {
	if _, ok := s.identCache.LoadAndDelete(endpointID); ok {
		s.identCount.Add(-1)
	}
	if _, ok := s.enrollCache.LoadAndDelete(endpointID); ok {
		s.enrollCount.Add(-1)
	}
}

func (s *Server) identStore(endpointID, host, user string, gen uint64, id nodeIdent) {
	s.cacheStore(&s.identCache, &s.identCount, endpointID, identEntry{host: host, user: user, gen: gen, at: time.Now(), id: id})
}

func (s *Server) routeCached(endpointID string, id nodeIdent) (string, string, bool) {
	v, ok := s.identCache.Load(endpointID)
	if !ok {
		return "", "", false
	}
	e := v.(identEntry)
	if !e.routed || e.id != id || e.gen != s.Store.IdentityGen() || time.Since(e.at) >= identTTLFor(e.id) {
		return "", "", false
	}
	return e.rHost, e.rUser, true
}

func (s *Server) routeStore(endpointID string, id nodeIdent, gen uint64, host, user string) {
	v, ok := s.identCache.Load(endpointID)
	if !ok {
		return
	}
	e := v.(identEntry)
	if e.id != id || e.gen != gen {
		return
	}
	e.routed, e.rHost, e.rUser = true, host, user
	s.cacheStore(&s.identCache, &s.identCount, endpointID, e)
}
