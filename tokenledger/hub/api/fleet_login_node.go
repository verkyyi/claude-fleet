package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// 登录即登记 (claude-fleet#2212): a computer `fleet login` confirmed is a
// registered device (#1470), and that one confirmation is all it takes to be
// a node too. The device signs a timestamp with its key — exactly like a
// renewal — and the hub answers its node pass:
//
//   - the FIRST time, it enrolls the device as a fixed-kind node through a
//     join code it mints and spends at once (the code row, tagged with the
//     device's fingerprint, is the audit trail and the dedup key);
//   - after that, the same device gets the SAME endpoint back with a fresh
//     token (the old one stops at once) — a computer that lost node.env is
//     never enrolled twice. A retired endpoint (`fleet node leave`, the /nodes
//     card) is not handed back: the next ask enrolls anew.
//
// What it never does is make the node trusted. Trust is the setting
// fleet.node_trust.<machine>, written only by PUT /v1/fleet/settings — the
// /nodes card or `fleet-node-trust.sh` with an admin credential (#1968) — and
// a machine without it reads untrusted. So a login-registered node is
// untrusted and, by the client's node.env (COMPUTE=0, PERSONAL=1), only
// coordinates. A NEW enrollment under a name the hub already trusts is
// refused (409 trusted_name): a login must not inherit another machine's trust
// by reporting its hostname — that machine joins through `fleet node join`.

// loginNodeRequest is the body of POST control.LoginNodePath.
type loginNodeRequest struct {
	PublicKey string `json:"public_key"`
	TS        int64  `json:"ts"`
	Sig       string `json:"sig"`
	Hostname  string `json:"hostname"`
	OSUser    string `json:"os_user"`
}

// handleLoginNode serves control.LoginNodePath. No credential but the
// device's own signature.
//
//	200 NodeJoinResponse    enrolled, or the device's node reissued
//	401 bad_signature       not this key's signature, or the clock is off
//	404 unknown_device      never registered (or no CA): fleet login
//	403 device_revoked / device_idle   fleet login again
//	409 no_account          the person has no active login any more
//	409 trusted_name        a trusted machine already has this name
func (s *Server) handleLoginNode(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	var req loginNodeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request")
		return
	}
	key, err := sshca.ParseUserKey(req.PublicKey)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	now := time.Now()
	fp := ssh.FingerprintSHA256(key)
	if d := now.Sub(time.Unix(req.TS, 0)); d > renewClockSkew || d < -renewClockSkew {
		refuseJSON(w, http.StatusUnauthorized, "bad_signature",
			"the signed timestamp is too far from the hub's clock — check this computer's time")
		return
	}
	// A generous budget per source before the signature (task MPCX): a flood
	// never reaches the check unbounded, and one caller behind a shared
	// address cannot spend everyone's; the tight ones come after it.
	if !s.loginNodeBudgets().pre.allow(r, now) {
		w.Header().Set("Retry-After", "60")
		refuseJSON(w, http.StatusTooManyRequests, "rate_limited", "too many node passes asked — try again in a minute")
		return
	}
	if err := verifySSHSig(key, []byte(req.Sig), []byte(control.LoginNodeSigMessage(req.TS)), control.LoginNodeSigNamespace); err != nil {
		refuseJSON(w, http.StatusUnauthorized, "bad_signature", "node pass signature refused: "+err.Error())
		return
	}
	// Then the source's and the device key's own budgets — after the
	// signature, so nobody holding only a public key, or only an address,
	// can spend them.
	if !s.loginNodeBudgets().source.allow(r, now) || !s.loginNodeBudgets().device.allowFrom(fpAddr(fp), now) {
		w.Header().Set("Retry-After", "60")
		refuseJSON(w, http.StatusTooManyRequests, "rate_limited", "too many node passes asked for this computer — try again in a minute")
		return
	}
	// One signed timestamp buys one node pass (task MPCX): the same signature
	// sent again inside the clock window is refused, not answered with a
	// fresh token. Kept per replica.
	if !s.loginNodeOnce(fp, req.TS, now) {
		refuseJSON(w, http.StatusUnauthorized, "request_replayed", "this signed request was already answered — sign a new one")
		return
	}
	dev, ok := s.usableDevice(w, fp, store.DeviceNodePassRefused, now)
	if !ok {
		return
	}
	pid := dev.PrincipalID
	// The same eligibility as the certificate: an active login somewhere.
	if _, _, _, err := s.fleetLoginsOf(pid); err != nil {
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		code := "issue_failed"
		if errors.Is(err, errNoAccount) {
			code = "no_account"
		}
		refuseJSON(w, certErrStatus(err), code, err.Error())
		return
	}
	host := req.Hostname
	if host == "" {
		host = dev.Name
	}
	out, what, err := s.deviceNode(r, pid, fp, host, req.OSUser, now)
	var tn *trustedNameErr
	var mm *machineManagedErr
	var rl *reservedLoginErr
	var nt *nameTakenErr
	switch {
	case errors.As(err, &nt):
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		refuseJSON(w, http.StatusConflict, "name_taken", err.Error())
		return
	case errors.As(err, &tn):
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		refuseJSON(w, http.StatusConflict, "trusted_name", err.Error())
		return
	case errors.As(err, &rl):
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		refuseJSON(w, http.StatusConflict, "reserved_login", err.Error())
		return
	case errors.As(err, &mm):
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		refuseJSON(w, http.StatusConflict, "machine_managed", err.Error())
		return
	case err != nil:
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.deviceAudit(store.DeviceNodePass, fp, pid, pid, fmt.Sprintf("%s %s (%s) · untrusted · 随登录登记", what, out.Label, out.EndpointID), now)
	log.Printf("fleet: device %s of %s %s node %s (%s) at login", fp, pid, what, out.Label, out.EndpointID)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// trustedNameErr: a new login-registered node would carry a name the hub
// already trusts.
type trustedNameErr struct{ name string }

func (e *trustedNameErr) Error() string {
	return fmt.Sprintf("a machine named %s is trusted on this hub; a login cannot register under its name — on that machine run: fleet node join", e.name)
}

// reservedLoginErr: a device road asked to enroll the admin role account — a
// login only the hub issues a token for (POST /v1/node/admin-token, its
// machine's root) — for a person who is not one of the hub's admins.
type reservedLoginErr struct{ login string }

func (e *reservedLoginErr) Error() string {
	return fmt.Sprintf("%s is the machine's admin role account; its node token comes only from that machine's own install (fleet node install), never from a login", e.login)
}

// ReissueTokenGrace is how long a reissued node token's predecessor still
// resolves (claude-fleet#2501): a second holder of the endpoint — the
// machine's node program, an agent not yet restarted — is not cut off the
// instant the login re-registers.
const ReissueTokenGrace = 10 * time.Minute

// machineManagedErr: a reissue for a login its machine's node program serves.
type machineManagedErr struct{ osUser, host string }

func (e *machineManagedErr) Error() string {
	who := e.osUser
	if who == "" {
		who = "this login"
	}
	return fmt.Sprintf("%s on %s is run by the machine's node program, which holds its node token — a new one here would cut it off. "+
		"Nothing was reissued; to renew it, on that machine run: sudo fleet-node-supervisor.py account adopt %s --rejoin", who, e.host, who)
}

// machineServing is the machine whose link serves endpoint id's login right
// now ("" when none does on this replica).
func (s *Server) machineServing(id string) string {
	cur := s.nodes.get(id)
	if cur == nil || cur.wire.machine() == "" {
		return ""
	}
	for _, eid := range []string{cur.wire.machine(), id} {
		if ep, err := s.Store.EndpointByID(eid); err == nil {
			if host := s.endpointHost(*ep); host != "" {
				return host
			}
		}
	}
	return cur.wire.machine()
}

// deviceNode is the device's node pass, and what it did ("linked" ·
// "reissued" · "enrolled"):
//
//   - the request carries this computer's live node token (a node joined
//     before 登录即登记, by a scan or a code): that node is tied to the device
//     and its token handed back unchanged — never a second node;
//   - the device's live endpoint: the same endpoint with a fresh token;
//   - none yet: a new fixed-kind enrollment tagged with the device.
func (s *Server) deviceNode(r *http.Request, pid, fp, hostname, osUser string, now time.Time) (*NodeJoinResponse, string, error) {
	if tok := bearer(r); tok != "" {
		// The token is handed back, so only a bearer can say it — and not one
		// its node turned off (claude-fleet#3710).
		if ep, _ := s.nodeAuthOpt(r); ep != nil &&
			(ep.OSUser == "" || ep.OSUser == sanitizeJoinLogin(osUser) || ep.OSUser == deviceRoadLogin(pid, fp, osUser)) {
			if id, err := s.Store.DeviceNodeEndpoint(fp); err != nil || id != ep.ID {
				code, err := MintJoinCode()
				if err != nil {
					return nil, "", err
				}
				if err := s.Store.LinkDeviceEndpoint(HashToken(code), fp, ep.ID, s.joinNow()); err != nil {
					return nil, "", err
				}
				if err := s.Store.FleetAudit("device:"+fp, "node_join", "endpoint:"+ep.ID, "LINKED "+ep.Label+" 随登录登记", "", now); err != nil {
					log.Printf("join audit: %v", err)
				}
			}
			out := s.joinResponse(r, ep.ID, ep.Label, tok, ep.OSUser)
			s.noteDeviceLogin(out, pid, fp, ep.ID, osUser, now)
			return out, "linked", nil
		}
	}
	if id, err := s.Store.DeviceNodeEndpoint(fp); err == nil {
		if mach := s.machineServing(id); mach != "" {
			// The login runs on its machine's node program, which holds
			// the token this would replace (claude-fleet#2501).
			return nil, "", &machineManagedErr{osUser: sanitizeJoinLogin(osUser), host: mach}
		}
		tok, err := MintToken()
		if err != nil {
			return nil, "", err
		}
		if err := s.Store.RotateEndpointToken(id, HashToken(tok), now, ReissueTokenGrace); err != nil {
			return nil, "", err
		}
		ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
		if err != nil {
			return nil, "", err
		}
		if err := s.Store.FleetAudit("device:"+fp, "node_join", "endpoint:"+id, "REISSUED "+ep.Label+" 随登录登记", "", now); err != nil {
			log.Printf("join audit: %v", err)
		}
		out := s.joinResponse(r, id, ep.Label, tok, ep.OSUser)
		s.noteDeviceLogin(out, pid, fp, id, osUser, now)
		return out, "reissued", nil
	} else if !errors.Is(err, store.ErrNoSuchEndpoint) {
		return nil, "", err
	}
	if host := sanitizeJoinField(hostname); host != "" {
		settings, _ := s.trustSettings(now)
		if s.machineTrusted(host, settings) {
			return nil, "", &trustedNameErr{host}
		}
	}
	out, err := s.enrollDeviceNode(r, pid, fp, hostname, osUser)
	if err != nil {
		return nil, "", err
	}
	if err := s.Store.FleetAudit("device:"+fp, "node_join", "endpoint:"+out.EndpointID, "JOINED "+out.Label+" 随登录登记 · untrusted", "", now); err != nil {
		log.Printf("join audit: %v", err)
	}
	return out, "enrolled", nil
}

// enrollDeviceNode enrolls a fixed-kind node through a code the hub mints and
// spends at once, tagged with the device that asked (fp) — the login's road
// and the `fleet node join` scan alike, so either finds the other's node.
//
// The device road enrolls a person's own terminal (task MPCX). For a person
// who is not one of the hub's admins (pid) it refuses the admin role account
// and a machine name the hub trusts (the scan's half of trusted_name; the
// login road refuses that name for everyone before it gets here); any other
// login — root, or a name on the admin list that is also a person's own
// login — enrolls, as an ordinary node: memberDevice keeps it from ever being
// an admin node or a machine's program, and the audit says so.
func (s *Server) enrollDeviceNode(r *http.Request, pid, fp, hostname, osUser string) (*NodeJoinResponse, error) {
	// The login it enrolls as (task MPCX): the OS login as reported, or the
	// person's alias login when it runs as root or names none — never root,
	// so a device is never a machine's program.
	login := deviceRoadLogin(pid, fp, osUser)
	if !s.isOperator(pid) {
		if adminRoleLogins[login] {
			return nil, &reservedLoginErr{login}
		}
		if host := sanitizeJoinField(hostname); host != "" {
			settings, _ := s.trustSettings(time.Now())
			if s.machineTrusted(host, settings) {
				return nil, &trustedNameErr{host}
			}
		}
	}
	// The first free name of deviceHosts; the store refuses, atomically, a
	// name a live endpoint holds — then the next is tried (task MPCX).
	var out *NodeJoinResponse
	for _, host := range s.deviceHosts(pid, fp, hostname) {
		code, err := MintJoinCode()
		if err != nil {
			return nil, err
		}
		if err := s.Store.CreateJoinCodeForDevice(HashToken(code), fp, s.joinNow(), JoinCodeTTL); err != nil {
			return nil, err
		}
		out, err = s.redeemJoin(r, code, host, login)
		if errors.Is(err, store.ErrHostTaken) {
			// The code stays unspent: minted here, never shown, gone at
			// its TTL.
			out = nil
			continue
		}
		if err != nil {
			return nil, err
		}
		break
	}
	if out == nil {
		return nil, &nameTakenErr{sanitizeJoinField(hostname)}
	}
	now := time.Now()
	s.noteDeviceLogin(out, pid, fp, out.EndpointID, osUser, now)
	if s.isFleetAdmin(login) && !s.isOperator(pid) {
		_ = s.Store.FleetAudit("device:"+fp, "node_identity", "endpoint:"+out.EndpointID,
			"ENROLLED AS AN ORDINARY NODE — "+login+" by a member's device: never an admin node", "", now)
	}
	return out, nil
}

// deviceHosts are the machine names a device road may enroll a new node
// under, in order (task MPCX): the reported name, then the name with 4, 8 and
// 16 hex of this device's fingerprint (`MacBook-Pro-1a2b`) — each only if it
// passes the same checks: no other live endpoint enrolled as it, no one else's
// login recorded there, no trust word for it (trusted or untrusted), not a
// user pod's name. A machine name stays unique to one enrollment, so every
// lookup by machine and login reaches this device's node and no one else's;
// nobody is refused because another device used the name first. The store
// re-checks the chosen name atomically at the insert (store.ErrHostTaken).
func (s *Server) deviceHosts(pid, fp, hostname string) []string {
	base := sanitizeJoinField(hostname)
	if base == "" {
		return []string{""}
	}
	sum := sha256.Sum256([]byte(fp))
	full := hex.EncodeToString(sum[:])
	var out []string
	for i, n := range []int{0, 4, 8, 16} {
		name := base
		if i > 0 {
			suffix := "-" + full[:n]
			b := base
			if len(b)+len(suffix) > 32 {
				b = b[:32-len(suffix)]
			}
			name = b + suffix
		}
		if s.deviceNameFree(pid, name) {
			out = append(out, name)
		}
	}
	return out
}

// deviceNameFree: name passes deviceHosts' checks for pid. An unreadable
// answer is no.
func (s *Server) deviceNameFree(pid, name string) bool {
	if isUserPodName(name) {
		return false
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return false
	}
	if _, ok := settings[trustKey(name)]; ok {
		return false
	}
	if _, ok := settings[trustKey(firstLabel(name))]; ok {
		return false
	}
	if taken, err := s.Store.EnrolledByAnother("", name); err != nil || taken {
		return false
	}
	held, err := s.Store.HostHeldByOthers(name, pid)
	return err == nil && !held
}

// nameTakenErr: every name a device road could enroll a new node under is
// taken.
type nameTakenErr struct{ name string }

func (e *nameTakenErr) Error() string {
	return fmt.Sprintf("no free machine name for %s on this hub — rename this computer and run fleet login again", e.name)
}

// noteDeviceLogin records the device's login (deviceRoadLogin) on endpointID's
// machine as pid's (登录即认人) and says on the node pass what the node lacks:
// AccountRefused when the row could not be written — the node is still the
// device's person's (principalOnNode) — and EntryNote when the login is one
// the door, entry relay and peer certificates do not serve (2–16 lowercase
// letters and digits, no reserved name): the node runs sessions; nobody
// reaches it over SSH as that login.
func (s *Server) noteDeviceLogin(out *NodeJoinResponse, pid, fp, endpointID, osUser string, now time.Time) {
	login := deviceRoadLogin(pid, fp, osUser)
	out.AccountRefused = s.recordLoginAccount(pid, fp, endpointID, login, now)
	if !control.ValidExistingLogin(login) {
		out.EntryNote = fmt.Sprintf("login %s is a node for sessions only: SSH entry, the door and peer certificates serve logins of 2–16 lowercase letters and digits", login)
		s.deviceAudit(store.DeviceNodePass, fp, pid, pid, "endpoint "+endpointID+": "+out.EntryNote, now)
	}
}

// sanitizeJoinLogin keeps a reported OS login as the login it is (task MPCX):
// letters (either case), digits, `_`, `-` and `.`, 32 at most — never cut at a
// dot the way a hostname is (`john.smith` stays `john.smith`).
func sanitizeJoinLogin(v string) string {
	v = strings.TrimSpace(v)
	var b strings.Builder
	for _, c := range v {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' {
			b.WriteRune(c)
		}
		if b.Len() >= 32 {
			break
		}
	}
	// Never one that starts with `.` / `-` (an option, a dotfile) or is
	// punctuation alone: that is no login.
	out := strings.TrimLeft(b.String(), ".-")
	if strings.IndexFunc(out, func(c rune) bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
	}) < 0 {
		return ""
	}
	return out
}

// deviceAliasPrefix starts the login a device road records for a device that
// runs as root or names no login: `dev-` and eight hex of its person and
// device, stable across reissues.
const deviceAliasPrefix = "dev-"

// deviceRoadLogin is the login a device road enrolls and records (task MPCX): the
// OS login (sanitizeJoinLogin), or — for root, or none at all — the person's
// alias for this device, so a container or devcontainer run as root is still
// its person's ordinary node.
func deviceRoadLogin(pid, fp, osUser string) string {
	l := sanitizeJoinLogin(osUser)
	if l != "" && l != "root" {
		return l
	}
	sum := sha256.Sum256([]byte(pid + "|" + fp))
	return deviceAliasPrefix + hex.EncodeToString(sum[:4])
}

// isDeviceAlias: login is a deviceRoadLogin alias.
func isDeviceAlias(login string) bool {
	if len(login) != len(deviceAliasPrefix)+8 || !strings.HasPrefix(login, deviceAliasPrefix) {
		return false
	}
	_, err := hex.DecodeString(login[len(deviceAliasPrefix):])
	return err == nil
}

// deviceLoginRecordable: a device road's login the hub records as its
// person's — any sanitized login but root and the admin role account.
func deviceLoginRecordable(login string) bool {
	return login != "" && login != "root" && !adminRoleLogins[login] && login == sanitizeJoinLogin(login)
}

// principalOnNode is the person behind login on a node: the machine's
// account (PrincipalForLogin), else the login row 登录即认人 bound to this
// very endpoint — the computer's name is the agent's own word and may not be
// the one it registered under.
//
// The machine's account answers only for this endpoint (nodeLoginPrincipal, task
// MPCX): never another computer's 登录即认人 row, and on an endpoint a device
// road enrolled, only that device's person.
func (s *Server) principalOnNode(endpointID, host, login string) (string, error) {
	p, err := s.nodeLoginPrincipal(endpointID, host, login)
	if errors.Is(err, store.ErrNoPrincipal) {
		p, err = s.Store.PrincipalForEndpointLogin(endpointID, login)
	}
	if errors.Is(err, store.ErrNoPrincipal) {
		if d := s.devicePerson(endpointID, login); d != "" {
			return d, nil
		}
	}
	return p, err
}

// devicePerson is the person a device road's endpoint belongs to when no
// account row names it (task MPCX): its device's person, for the login it
// enrolled as — the node is bound to (person, device), not to a machine and
// login name another device may share. "" for any other endpoint, a login it
// did not enroll as, or devices of more than one person.
func (s *Server) devicePerson(endpointID, login string) string {
	e := s.enrollment(endpointID)
	if !e.ByDevice || login == "" {
		return ""
	}
	et, err := s.Store.EndpointTrustOf(endpointID)
	if err != nil || et.EnrolledUser != login {
		return ""
	}
	who := ""
	for _, p := range e.DevicePeople {
		switch {
		case p == "":
		case who == "":
			who = p
		case !strings.EqualFold(who, p):
			return ""
		}
	}
	return who
}

// accountOpLeaseWindow bounds the lease an account op's own login is answered
// inside the op (principalForLease): the node runs each op for up to 15
// minutes (loginJoinCodeTTL's note), so the window is that op's own run.
const accountOpLeaseWindow = 15 * time.Minute

// principalForLease is principalOnNode for the roads that hand a login
// credentials — the node lease, a session pass (mint, bind, renew), the relay
// credential — plus ONE more answer (claude-fleet D0JC): the login a create or
// a reset is opening RIGHT NOW. fleet-login-ready.sh (#4673) proves the login
// with a first reply inside the op, while the hub's row is still creating /
// resetting, so with active alone every new login failed its own check.
//
// The in-flight answer is the op's row only, and only when all of these hold —
// anything else is ErrNoPrincipal, as before:
//   - the row is creating / resetting with the op sent (op_id + the node it
//     went to); a dropped link or a restarted hub has already made it unknown;
//   - it was sent at most accountOpLeaseWindow ago;
//   - the caller is not the op's node itself (an admin never leases as the
//     login it opens), is not retired, is that login, on that machine;
//   - a create: the caller enrolled at or after the send — with the op's own
//     join code, never a token from before;
//   - a reset: the row is a spare's (a login being washed back into a spare —
//     never a person's credentials handed to the login that drops them).
func (s *Server) principalForLease(endpointID, host, login string, now time.Time) (string, error) {
	p, err := s.principalOnNode(endpointID, host, login)
	if !errors.Is(err, store.ErrNoPrincipal) {
		return p, err
	}
	if p, ok := s.leaseInFlight(endpointID, host, login, now); ok {
		return p, nil
	}
	return "", store.ErrNoPrincipal
}

// leaseInFlight is principalForLease's in-flight answer: the op's principal and
// true, else "" and false.
func (s *Server) leaseInFlight(endpointID, host, login string, now time.Time) (string, bool) {
	if endpointID == "" || login == "" {
		return "", false
	}
	a, err := s.Store.AccountOpInFlight(host, login)
	if err != nil {
		return "", false
	}
	sent := a.UpdatedAt
	if now.Before(sent.Add(-time.Minute)) || now.Sub(sent) > accountOpLeaseWindow {
		return "", false
	}
	if endpointID == a.EndpointID {
		return "", false
	}
	ep, err := s.Store.EndpointByID(endpointID)
	if err != nil || ep.RetiredAt != nil {
		return "", false
	}
	// The login and machine it enrolled as (task MPCX), not its report.
	self := s.nodeSelfFrom(ep, ep.Hostname, ep.OSUser)
	if self.User != "" && self.User != login {
		return "", false
	}
	if h := self.Host; h == "" || !sameMachine(a.Hostname, h) && !sameMachine(h, a.Hostname) {
		return "", false
	}
	switch a.Op {
	case "create":
		if ep.EnrolledAt.Before(sent.Truncate(time.Second)) {
			return "", false
		}
	case "reset":
		if !store.IsSparePrincipal(a.PrincipalID) {
			return "", false
		}
	default:
		return "", false
	}
	return a.PrincipalID, true
}

// recordLoginAccount is 登录即认人 (claude-fleet#2212): the system login the
// person ran `fleet login` under, on the computer they confirmed it on, is
// theirs — one active fleet_accounts row, by computer (never the global
// machine-login mapping, never another machine). A row someone else holds is
// left alone and audited; it never fails the node pass. It answers why the
// login is NOT the person's afterwards — read back the way every reader reads
// it (principalOnNode) — empty when it is (claude-fleet#2249).
func (s *Server) recordLoginAccount(pid, fp, endpointID, osUser string, now time.Time) string {
	if !deviceLoginRecordable(osUser) {
		return fmt.Sprintf("system login %s is not one the hub records", osUser)
	}
	ep, err := s.Store.EndpointByID(endpointID)
	if err != nil {
		return "this node has no machine name on the hub"
	}
	// On the machine it ENROLLED as (task MPCX): unique to this device's
	// enrollment (deviceHost), never a name a later report gave.
	host := ep.Hostname
	if et, err := s.Store.EndpointTrustOf(endpointID); err == nil && enrolledMachine(et) != "" {
		host = enrolledMachine(et)
	}
	if host == "" {
		return "this node has no machine name on the hub"
	}
	p, err := s.Store.Principal(pid)
	if err != nil {
		return "account not recorded: " + err.Error()
	}
	wrote, err := s.Store.RecordLoginAccount(p, host, osUser, ep.ID, "登录即认人 · device "+fp, now)
	switch {
	case err != nil:
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, "account not recorded: "+err.Error(), now)
		return "account not recorded: " + err.Error()
	case wrote:
		s.deviceAudit(store.DeviceNodePass, fp, pid, pid, fmt.Sprintf("account %s on %s is %s · 登录即认人", osUser, host, pid), now)
	}
	if who, err := s.principalOnNode(ep.ID, host, osUser); err != nil || who != pid {
		why := fmt.Sprintf("login %s on %s is not recorded as yours", osUser, host)
		if who != "" {
			why = fmt.Sprintf("login %s on %s already belongs to someone else", osUser, host)
		}
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, why, now)
		return why
	}
	return ""
}

// loginNodeLimits are the node-pass road's budgets (task MPCX): per source
// address, and per device key (fpAddr). Per replica, like every clientBudget.
type loginNodeLimits struct{ pre, source, device *clientBudget }

func (s *Server) loginNodeBudgets() *loginNodeLimits {
	s.loginNodeInit.Do(func() {
		s.loginNodeLim = &loginNodeLimits{
			pre:    &clientBudget{burst: 600, perSec: 600.0 / 60, max: 4096},
			source: &clientBudget{burst: 60, perSec: 60.0 / 60, max: 4096},
			device: &clientBudget{burst: 12, perSec: 12.0 / 60, max: 4096},
		}
	})
	return s.loginNodeLim
}

// fpAddr keys a device key's budget in clientBudget's table: an address
// taken from the fingerprint's hash (never a real source address).
func fpAddr(fp string) netip.Addr {
	sum := sha256.Sum256([]byte("device-key:" + fp))
	var a [16]byte
	copy(a[:], sum[:16])
	return netip.AddrFrom16(a)
}

// loginNodeOnce marks (fp, ts) used and says whether it was fresh: a signed
// node-pass request is answered once. Entries older than twice the clock
// window are dropped; the table is bounded.
func (s *Server) loginNodeOnce(fp string, ts int64, now time.Time) bool {
	s.loginNodeMu.Lock()
	defer s.loginNodeMu.Unlock()
	if s.loginNodeSeen == nil {
		s.loginNodeSeen = map[string]time.Time{}
	}
	key := fp + "|" + strconv.FormatInt(ts, 10)
	if _, used := s.loginNodeSeen[key]; used {
		return false
	}
	if len(s.loginNodeSeen) >= loginNodeSeenMax {
		for k, at := range s.loginNodeSeen {
			if now.Sub(at) > 2*renewClockSkew {
				delete(s.loginNodeSeen, k)
			}
		}
	}
	if len(s.loginNodeSeen) >= loginNodeSeenMax {
		return false // full of live entries: refuse rather than forget one
	}
	s.loginNodeSeen[key] = now
	return true
}

// loginNodeSeenMax bounds loginNodeOnce's table.
const loginNodeSeenMax = 1 << 16
