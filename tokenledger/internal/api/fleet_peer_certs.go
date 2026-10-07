package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Machine-to-machine access through the hub (claude-fleet#1626).
//
// A machine reaching another one — `fleet-remote-view.sh` opening a session
// there, `fleet-node-upgrade.sh --host`, `fleet-move.sh` — used to ride a
// personal key the target kept in authorized_keys forever: the hub never knew
// who went where. Now the source NODE asks the hub, with its own enrollment
// token, for a certificate to ONE target machine, for ONE purpose; the hub
// checks the target is the same owner's, signs a certificate whose only
// principal is that owner's login there and which dies in five minutes
// (sshca.PeerTTL — enough to open the connection, which then outlives it),
// records the issuance (store.fleet_peer_certs) BEFORE handing it out, and
// the target's sshd admits it through the same TrustedUserCAKeys every
// machine already has (node_sshca.go). No hub, no certificate: the access
// pauses, and nothing falls back to a standing key.
//
// Ownership: the owner of a node is the person whose ACTIVE fleet account is
// the node's login on its machine (principalOnNode: PrincipalForLogin, else
// the 登录即认人 row bound to that node — #2249); the target login is
// that person's login on the target machine. A login no person owns (the
// operator's own, opened by hand) reaches only the login of the same name on
// the target — and only one no person owns either.

// peerPurposes are the uses a machine-to-machine certificate is issued for;
// the purpose rides in the key id, so sshd's log on the target says it.
var peerPurposes = map[string]bool{"view": true, "upgrade": true, "move": true}

var peerMachineRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$`)

// PeerCertResponse is the body of a granted POST /v1/node/peer-cert.
type PeerCertResponse struct {
	Certificate string    `json:"certificate"` // the content of <key>-cert.pub
	Serial      string    `json:"serial"`
	KeyID       string    `json:"key_id"`
	Login       string    `json:"login"`  // ssh -l
	Target      string    `json:"target"` // the roster's hostname
	ValidBefore time.Time `json:"valid_before"`
	TTLSec      int       `json:"ttl_sec"`
}

// errPeer carries an HTTP status with the refusal.
type errPeer struct {
	status int
	msg    string
}

func (e *errPeer) Error() string { return e.msg }

// handleNodePeerCert serves POST /v1/node/peer-cert:
//
//	{"target":"m4","purpose":"view","public_key":"ssh-ed25519 …","ttl_sec":300}
//
// authenticated by the requesting node's enrollment token.
func (s *Server) handleNodePeerCert(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var req struct {
		Target    string `json:"target"`
		Purpose   string `json:"purpose"`
		PublicKey string `json:"public_key"`
		TTLSec    int    `json:"ttl_sec"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	if !peerMachineRE.MatchString(req.Target) {
		httpError(w, http.StatusBadRequest, "target must be a machine name")
		return
	}
	if !peerPurposes[req.Purpose] {
		httpError(w, http.StatusBadRequest, "purpose must be view, upgrade or move")
		return
	}
	key, err := sshca.ParseUserKey(req.PublicKey)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := s.issuePeerCert(ep, req.Target, req.Purpose, key, time.Duration(req.TTLSec)*time.Second, time.Now())
	if err != nil {
		var pe *errPeer
		if errors.As(err, &pe) {
			httpError(w, pe.status, pe.msg)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// peerSelf is who a node is: its roster row's host and login, else the
// enrollment's.
func (s *Server) peerSelf(ep *store.Endpoint) (host, user string) {
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

// peerTargetHosts resolves a machine name — the roster's hostname, its first
// label, or a CCQUOTA_FLEET_ROUTES alias — to the roster hostnames it names.
func (s *Server) peerTargetHosts(name string, rows []store.Node) map[string]bool {
	want := map[string]bool{strings.ToLower(name): true}
	for _, m := range s.fleetMachines() {
		if strings.EqualFold(m.alias(), name) {
			want[strings.ToLower(m.Hostname)] = true
		}
	}
	out := map[string]bool{}
	for _, n := range rows {
		h := strings.ToLower(n.Hostname)
		if want[h] || want[strings.ToLower(firstLabel(n.Hostname))] {
			out[n.Hostname] = true
		}
	}
	return out
}

// issuePeerCert checks ownership, signs, records, and builds the answer.
func (s *Server) issuePeerCert(ep *store.Endpoint, target, purpose string, key ssh.PublicKey, ttl time.Duration, now time.Time) (*PeerCertResponse, error) {
	srcHost, srcUser := s.peerSelf(ep)
	// Both ends read "whose login" the one way session-cred does
	// (principalOnNode, claude-fleet#2249): the machine's account, else the
	// 登录即认人 row bound to that very node — its name may not be the one
	// the login was recorded under (`m.local` vs `m`).
	owner, err := s.principalOnNode(ep.ID, srcHost, srcUser)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		return nil, err
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		return nil, err
	}
	live, err := s.Store.ListEndpoints("")
	if err != nil {
		return nil, err
	}
	active := map[string]bool{}
	for _, e := range live {
		active[e.ID] = true
	}
	hosts := s.peerTargetHosts(target, rows)
	if len(hosts) == 0 {
		return nil, &errPeer{http.StatusUnprocessableEntity, fmt.Sprintf("no machine %q on this hub", target)}
	}
	if len(hosts) > 1 {
		return nil, &errPeer{http.StatusConflict, fmt.Sprintf("%q names more than one machine", target)}
	}
	var tHost string
	for h := range hosts {
		tHost = h
	}
	if strings.EqualFold(tHost, srcHost) {
		return nil, &errPeer{http.StatusBadRequest, "the target is this machine"}
	}
	// The target login: the owner's login there (or, unowned, the same name).
	var hit *store.Node
	for i := range rows {
		n := &rows[i]
		if n.Hostname != tHost || !active[n.EndpointID] || n.OSUser == "" {
			continue
		}
		who, err := s.principalOnNode(n.EndpointID, n.Hostname, n.OSUser)
		if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
			return nil, err
		}
		if (owner != "" && who == owner) || (owner == "" && who == "" && n.OSUser == srcUser) {
			hit = n
			break
		}
	}
	if hit == nil {
		return nil, &errPeer{http.StatusForbidden, fmt.Sprintf("%s@%s has no login of its owner on %s", srcUser, firstLabel(srcHost), firstLabel(tHost))}
	}
	src := srcUser + "@" + firstLabel(srcHost)
	iss, err := s.SSHCA.SignPeer(sshca.PeerRequest{
		Key: key, Source: src, Target: hit.OSUser + "@" + firstLabel(tHost),
		Purpose: purpose, Login: hit.OSUser, TTL: ttl,
	}, now)
	if err != nil {
		return nil, err
	}
	serial := strconv.FormatUint(iss.Serial, 10)
	if err := s.Store.RecordPeerCert(store.FleetPeerCert{
		Serial: serial, SourceEndpoint: ep.ID, SourceHost: srcHost, SourceUser: srcUser,
		TargetEndpoint: hit.EndpointID, TargetHost: tHost, Login: hit.OSUser, Purpose: purpose,
		KeyID: iss.KeyID, KeyFingerprint: iss.KeyFingerprint, IssuedAt: now, ValidBefore: iss.ValidBefore,
	}); err != nil {
		return nil, fmt.Errorf("record certificate: %w", err)
	}
	log.Printf("fleet: issued peer certificate %s %s, key %s, until %s",
		serial, iss.KeyID, iss.KeyFingerprint, iss.ValidBefore.UTC().Format(time.RFC3339))
	return &PeerCertResponse{
		Certificate: iss.Line + "\n", Serial: serial, KeyID: iss.KeyID, Login: hit.OSUser,
		Target: tHost, ValidBefore: iss.ValidBefore, TTLSec: int(iss.ValidBefore.Sub(now).Seconds()),
	}, nil
}

// handleFleetPeerCerts lists the issuances — the operator's audit view.
func (s *Server) handleFleetPeerCerts(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	out, err := s.Store.FleetPeerCerts(limit)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"peer_certs": out})
}
