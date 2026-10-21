package api

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// One address for everyone, the door routing by username (A5SQ, design page
// 「所有人连一个地址：门按用户名接到各自的家」, v2).
//
// A person points Termius at the door's one address with their own login as
// the username and their own key. The door is the SSH server for that
// connection (the username travels only inside the encryption, so routing by
// it means terminating it): it finds the person by the key and the username
// in its book (EntryRouteList.Homes) and opens a second SSH connection to
// their home, over the hub's relay to the home's entry port (DoorHomePath).
//
// The door holds no key into any home. For that hop it hands the hub what the
// person signed to log in to the door (DoorSessionPath); the hub rebuilds the
// signed data itself, verifies it against the person's registered key, refuses
// a session it saw before, and only then signs a two-minute certificate for
// the door's one-off key — one principal, the person's home login, from
// loopback only — with the door-session CA, a CA of its own derived from the
// hub's SSH CA (sshca.Derive, no second Secret). The home's entry sshd trusts
// that CA for each login's own name alone (EntryNodeList.DoorCA). A door that
// is taken over can act only in the sessions of people who log in through it
// while it is: it has nobody else's signature, so it gets no certificate.
//
// The door says it is ready on its pull (EntryRoutesNodePath?home=1): only
// then does the list carry Homes. Absent = byte for byte as before.

// doorSessionLabel is the door-session CA's derivation label.
const doorSessionLabel = "door-session"

var doorCAOnce struct {
	sync.Mutex
	from *sshca.CA
	ca   *sshca.CA
}

// doorSessionCA is the door-session CA, nil when the hub has no SSH CA.
func (s *Server) doorSessionCA() *sshca.CA {
	if s.SSHCA == nil {
		return nil
	}
	doorCAOnce.Lock()
	defer doorCAOnce.Unlock()
	if doorCAOnce.from != s.SSHCA {
		ca, err := s.SSHCA.Derive(doorSessionLabel)
		if err != nil {
			log.Printf("fleet: derive the door-session CA: %v", err)
			return nil
		}
		doorCAOnce.from, doorCAOnce.ca = s.SSHCA, ca
	}
	return doorCAOnce.ca
}

// doorCAFor is what a home's entry list carries as DoorCA: the door-session
// CA's public key while this hub has a door and a CA, else "".
func (s *Server) doorCAFor() string {
	if len(s.doorMachines()) == 0 {
		return ""
	}
	if ca := s.doorSessionCA(); ca != nil {
		return ca.PublicKey()
	}
	return ""
}

// doorHomeKey is the fleet_entry_jump row a door's "home=1" is kept in (the
// jump's own row is the bare machine name).
func doorHomeKey(door string) string { return door + "#home" }

// noteDoorHome keeps a door's word from a pull that asked ?home=1.
func (s *Server) noteDoorHome(r *http.Request, door string, now time.Time) bool {
	if r.URL.Query().Get("home") != "1" {
		return false
	}
	if err := s.Store.SetEntryJump(doorHomeKey(door), "", now); err != nil {
		log.Printf("fleet: record the door's way home for %s: %v", door, err)
	}
	return true
}

// doorHomeRoutes is the door's Homes section: every person whose home is a
// machine (never a pod, never a fleet admin's login), with their live keys.
// A person the machine allowlist keeps off their home is listed with no key,
// as on the home's own list. A login two people's homes share goes to
// neither: the door must never guess whose home a name is.
func (s *Server) doorHomeRoutes() ([]control.EntryHomeRoute, error) {
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return nil, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	byLogin := map[string][]store.EntryHome{}
	for _, h := range homes {
		if isUserPodName(h.Machine) || s.isFleetAdmin(h.Login) || !control.ValidExistingLogin(h.Login) {
			continue
		}
		byLogin[h.Login] = append(byLogin[h.Login], h)
	}
	out := []control.EntryHomeRoute{}
	for login, hs := range byLogin {
		if len(hs) > 1 {
			log.Printf("door: login %s is home to %d people; taking none of them home", login, len(hs))
			continue
		}
		h := hs[0]
		rt := control.EntryHomeRoute{Principal: h.Person, Login: h.Login, Keys: []control.EntryNodeKey{}}
		if machineDenied(settings, h.Machine, h.Person) == "" {
			keys, err := s.Store.EntryKeys(h.Person, false)
			if err != nil {
				return nil, err
			}
			for _, k := range keys {
				rt.Keys = append(rt.Keys, control.EntryNodeKey{FP: k.FP, Type: k.Type, B64: k.B64, Name: k.Name})
			}
		}
		out = append(out, rt)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Login < out[j].Login })
	return out, nil
}

// doorHomeOf is person's home: the machine and login their address points at
// — refused (with why) when it is a pod, a fleet admin's login, or a machine
// the person's allowlist keeps them off.
func (s *Server) doorHomeOf(person string) (machine, login string, err error) {
	if person == "" {
		return "", "", sshRelayRefusal("BAD_REQUEST", "principal is required")
	}
	h, ok, err := s.Store.EntryHomeOf(person)
	if err != nil {
		return "", "", err
	}
	if !ok || isUserPodName(h.Machine) {
		return "", "", sshRelayRefusal("NOT_FOUND", "%s has no home machine for the door", person)
	}
	if s.isFleetAdmin(h.Login) || !control.ValidExistingLogin(h.Login) {
		return "", "", sshRelayRefusal("FORBIDDEN", "%s's home login is not one the door carries", person)
	}
	if why, err := s.machineDeniedFor("", h.Machine, person); err != nil {
		return "", "", err
	} else if why != "" {
		return "", "", sshRelayRefusal("FORBIDDEN", "%s：%s", MachineDisabledWord, why)
	}
	return h.Machine, h.Login, nil
}

// doorRequireDoor authenticates the door itself: "" has answered already.
func (s *Server) doorRequireDoor(w http.ResponseWriter, r *http.Request) string {
	if len(s.doorMachines()) == 0 {
		w.Header().Set("Cache-Control", "no-store")
		httpError(w, http.StatusNotFound, "this hub has no door ("+DoorKey+")")
		return ""
	}
	door := s.entryMachineOf(w, r)
	if door == "" {
		return ""
	}
	if !s.isDoor(door) {
		httpError(w, http.StatusForbidden, door+" is not this hub's door ("+DoorKey+")")
		return ""
	}
	return door
}

// doorSignedData is what a client signs to log in with publickey (RFC 4252
// §7) — rebuilt here from the session identifier, the username and the key,
// never taken from the door.
func doorSignedData(session []byte, user, algo string, key ssh.PublicKey) []byte {
	return ssh.Marshal(struct {
		Session []byte
		Msg     byte
		User    string
		Service string
		Method  string
		Signed  bool
		Algo    string
		Key     []byte
	}{session, 50, user, "ssh-connection", "publickey", true, algo, key.Marshal()})
}

// doorAlgoFits says algo names a signature key can make (RFC 8332 for RSA).
func doorAlgoFits(key ssh.PublicKey, algo string) bool {
	if key.Type() == ssh.KeyAlgoRSA {
		return algo == ssh.KeyAlgoRSASHA256 || algo == ssh.KeyAlgoRSASHA512
	}
	return algo == key.Type()
}

// doorSessionErr is a refusal of DoorSessionPath: status + the reason.
type doorSessionErr struct {
	status int
	msg    string
}

func (e *doorSessionErr) Error() string { return e.msg }

// doorSession checks req and signs its certificate: the person's signature
// over this session, fresh, by a key of the one person whose home login is
// req.User.
func (s *Server) doorSession(req control.DoorSessionRequest, door string, now time.Time) (control.DoorSessionCert, error) {
	var out control.DoorSessionCert
	bad := func(status int, format string, a ...any) (control.DoorSessionCert, error) {
		return out, &doorSessionErr{status, strings.TrimSpace(fmt.Sprintf(format, a...))}
	}
	ca := s.doorSessionCA()
	if ca == nil {
		return bad(http.StatusServiceUnavailable, "this hub has no SSH CA (CCQUOTA_FLEET_SSH_CA_KEY): no door-session certificates")
	}
	key, err := sshca.ParseUserKey(req.Key)
	if err != nil {
		return bad(http.StatusBadRequest, "key: %v", err)
	}
	dk, err := sshca.ParseUserKey(req.DoorKey)
	if err != nil {
		return bad(http.StatusBadRequest, "door_key: %v", err)
	}
	session, err := base64.StdEncoding.DecodeString(req.SessionID)
	if err != nil || len(session) < 16 || len(session) > 64 {
		return bad(http.StatusBadRequest, "session_id: not a session identifier")
	}
	raw, err := base64.StdEncoding.DecodeString(req.Sig)
	if err != nil {
		return bad(http.StatusBadRequest, "sig: not base64")
	}
	var sig ssh.Signature
	if err := ssh.Unmarshal(raw, &sig); err != nil {
		return bad(http.StatusBadRequest, "sig: not an SSH signature")
	}
	if !control.ValidExistingLogin(req.User) || !doorAlgoFits(key, req.Algo) || sig.Format != req.Algo {
		return bad(http.StatusBadRequest, "user / algo do not fit the key")
	}
	if err := key.Verify(doorSignedData(session, req.User, req.Algo, key), &sig); err != nil {
		return bad(http.StatusForbidden, "the signature does not verify: the person did not sign this session")
	}
	// the one person whose home login this is, holding this key
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return out, err
	}
	fp := ssh.FingerprintSHA256(key)
	var who []store.EntryHome
	for _, h := range homes {
		if h.Login != req.User || isUserPodName(h.Machine) {
			continue
		}
		keys, err := s.Store.EntryKeys(h.Person, false)
		if err != nil {
			return out, err
		}
		for _, k := range keys {
			if k.FP == fp {
				who = append(who, h)
				break
			}
		}
	}
	if len(who) != 1 {
		return bad(http.StatusForbidden, "%s is not the home login of this key's owner", req.User)
	}
	person := who[0].Person
	machine, login, err := s.doorHomeOf(person)
	if err != nil {
		var re *sshRelayError
		if errors.As(err, &re) {
			return bad(http.StatusForbidden, "%s", re.msg)
		}
		return out, err
	}
	sum := sha256.Sum256(session)
	tag := hex.EncodeToString(sum[:])
	fresh, err := s.Store.ClaimDoorSession(tag, person, now)
	if err != nil {
		return out, err
	}
	if !fresh {
		return bad(http.StatusConflict, "this session was presented before: a signature is good for one certificate")
	}
	iss, err := ca.SignDoorSession(sshca.DoorSessionRequest{Key: dk, Principal: person, Login: login, Session: tag[:16],
		TTL: control.DoorSessionTTL}, now)
	if err != nil {
		return out, err
	}
	hk, err := s.Store.EntryHostKey(machine)
	if err != nil {
		return out, err
	}
	out = control.DoorSessionCert{Cert: iss.Line, Principal: person, Login: login, Machine: machine,
		HostKeys: []string{}, ValidBefore: iss.ValidBefore}
	if hk != "" {
		out.HostKeys = append(out.HostKeys, hk)
	}
	log.Printf("door %s: session %s for %s (key %s) → %s@%s, cert serial %d until %s",
		door, tag[:16], person, fp, login, machine, iss.Serial, iss.ValidBefore.UTC().Format(time.RFC3339))
	return out, nil
}

// handleDoorSession serves DoorSessionPath.
func (s *Server) handleDoorSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	door := s.doorRequireDoor(w, r)
	if door == "" {
		return
	}
	var req control.DoorSessionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "body: "+err.Error())
		return
	}
	out, err := s.doorSession(req, door, time.Now())
	if err != nil {
		var de *doorSessionErr
		if errors.As(err, &de) {
			log.Printf("door %s: session refused: %s", door, de.msg)
			httpError(w, de.status, de.msg)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// entryRelayNode picks the agent that carries a relay to host's entry port:
// a connected, compatible agent there that listed CapEntryRelay — the
// person's own login's first (it is theirs), then the admin agent, then any.
func (s *Server) entryRelayNode(host, login string) (string, *nodeConn, error) {
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	ids := make([]string, 0, len(s.nodes.conns))
	for epID := range s.nodes.conns {
		ids = append(ids, epID)
	}
	sort.Strings(ids)
	best, rank := "", 99
	for _, epID := range ids {
		c := s.nodes.conns[epID]
		if !c.canSSHRelay || !c.canEntryRelay || c.hostname() != host || !control.Compatible(int(c.proto.Load())) {
			continue
		}
		r := 2
		switch {
		case c.user() == login:
			r = 0
		case c.admin:
			r = 1
		}
		if r < rank {
			best, rank = epID, r
		}
	}
	if best == "" {
		return "", nil, sshRelayRefusal("NODE_OFFLINE", "no agent on %s is connected and able to reach its entry port", host)
	}
	return best, s.nodes.conns[best], nil
}

// entryRelayLocal: a link THIS process holds can carry a relay to host's entry port.
func (s *Server) entryRelayLocal(host string) bool {
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	for _, c := range s.nodes.conns {
		if c.canSSHRelay && c.canEntryRelay && c.hostname() == host && control.Compatible(int(c.proto.Load())) {
			return true
		}
	}
	return false
}

// handleDoorHome serves DoorHomePath: the door's stream to one person's
// home, ?principal=<person>.
func (s *Server) handleDoorHome(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	person := r.URL.Query().Get("principal")
	machine, login, herr := s.doorHomeOf(person)
	// Two replicas: the home's link is held by the other one — hand it the
	// whole websocket before anything here reads who asks (as the relay
	// does: a node's signature is spent once, by the replica that serves it).
	if herr == nil && s.Replica != nil && !s.relayHopped(r) && !s.entryRelayLocal(machine) {
		for _, pc := range s.peerRelayHosts()[machine] {
			if pc.HasCap(control.CapEntryRelay) {
				s.proxyRelay(w, r, pc, "the door's stream home to "+machine)
				return
			}
		}
	}
	door := s.doorRequireDoor(w, r)
	if door == "" {
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1 << 20)
	ctx := context.Background()
	refuse := func(err error) {
		var re *sshRelayError
		if !errors.As(err, &re) {
			re = &sshRelayError{"INTERNAL", err.Error()}
		}
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_ = wsjson.Write(wctx, conn, control.SSHRelayHello{Type: "error", Code: re.code, Message: re.msg})
		cancel()
		conn.Close(websocket.StatusPolicyViolation, re.code)
	}
	if herr != nil {
		refuse(herr)
		return
	}
	// Counted and rate-limited per person: one person's sessions cannot
	// crowd out another's through the shared door.
	actor := "door:" + person
	max := s.SSHRelayMaxPerUser
	if max <= 0 {
		max = defaultSSHRelayMaxPerUser
	}
	if !s.sshRelays.admit(actor, max) {
		refuse(sshRelayRefusal("TOO_MANY", "already %d streams open home for %s; close one first", max, person))
		return
	}
	defer s.sshRelays.release(actor)
	epID, nc, err := s.entryRelayNode(machine, login)
	if err != nil {
		refuse(err)
		return
	}
	s.serveSSHRelay(ctx, conn, actor, machine, epID, nc, control.SSHRelayTargetEntry, refuse)
}
