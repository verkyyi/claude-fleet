package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
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
	if err := verifySSHSig(key, []byte(req.Sig), []byte(control.LoginNodeSigMessage(req.TS)), control.LoginNodeSigNamespace); err != nil {
		refuseJSON(w, http.StatusUnauthorized, "bad_signature", "node pass signature refused: "+err.Error())
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
	out, what, err := s.deviceNode(r, fp, host, req.OSUser, now)
	var tn *trustedNameErr
	switch {
	case errors.As(err, &tn):
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		refuseJSON(w, http.StatusConflict, "trusted_name", err.Error())
		return
	case err != nil:
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, err.Error(), now)
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out.AccountRefused = s.recordLoginAccount(pid, fp, out, req.OSUser, now)
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

// deviceNode is the device's node pass, and what it did ("linked" ·
// "reissued" · "enrolled"):
//
//   - the request carries this computer's live node token (a node joined
//     before 登录即登记, by a scan or a code): that node is tied to the device
//     and its token handed back unchanged — never a second node;
//   - the device's live endpoint: the same endpoint with a fresh token;
//   - none yet: a new fixed-kind enrollment tagged with the device.
func (s *Server) deviceNode(r *http.Request, fp, hostname, osUser string, now time.Time) (*NodeJoinResponse, string, error) {
	if tok := bearer(r); tok != "" {
		if ep, err := s.Store.EndpointByTokenHash(HashToken(tok)); err == nil &&
			(ep.OSUser == "" || ep.OSUser == sanitizeJoinField(osUser)) {
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
			return s.joinResponse(r, ep.ID, ep.Label, tok, ep.OSUser), "linked", nil
		}
	}
	if id, err := s.Store.DeviceNodeEndpoint(fp); err == nil {
		tok, err := MintToken()
		if err != nil {
			return nil, "", err
		}
		if err := s.Store.RotateEndpointToken(id, HashToken(tok)); err != nil {
			return nil, "", err
		}
		ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
		if err != nil {
			return nil, "", err
		}
		if err := s.Store.FleetAudit("device:"+fp, "node_join", "endpoint:"+id, "REISSUED "+ep.Label+" 随登录登记", "", now); err != nil {
			log.Printf("join audit: %v", err)
		}
		return s.joinResponse(r, id, ep.Label, tok, ep.OSUser), "reissued", nil
	} else if !errors.Is(err, store.ErrNoSuchEndpoint) {
		return nil, "", err
	}
	if host := sanitizeJoinField(hostname); host != "" {
		settings, _ := s.trustSettings(now)
		if s.machineTrusted(host, settings) {
			return nil, "", &trustedNameErr{host}
		}
	}
	out, err := s.enrollDeviceNode(r, fp, hostname, osUser)
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
func (s *Server) enrollDeviceNode(r *http.Request, fp, hostname, osUser string) (*NodeJoinResponse, error) {
	code, err := MintJoinCode()
	if err != nil {
		return nil, err
	}
	if err := s.Store.CreateJoinCodeForDevice(HashToken(code), fp, s.joinNow(), JoinCodeTTL); err != nil {
		return nil, err
	}
	return s.redeemJoin(r, code, hostname, osUser)
}

// principalOnNode is the person behind login on a node: the machine's
// account (PrincipalForLogin), else the login row 登录即认人 bound to this
// very endpoint — the computer's name is the agent's own word and may not be
// the one it registered under.
func (s *Server) principalOnNode(endpointID, host, login string) (string, error) {
	p, err := s.Store.PrincipalForLogin(host, login)
	if errors.Is(err, store.ErrNoPrincipal) {
		return s.Store.PrincipalForEndpointLogin(endpointID, login)
	}
	return p, err
}

// recordLoginAccount is 登录即认人 (claude-fleet#2212): the system login the
// person ran `fleet login` under, on the computer they confirmed it on, is
// theirs — one active fleet_accounts row, by computer (never the global
// machine-login mapping, never another machine). A row someone else holds is
// left alone and audited; it never fails the node pass. It answers why the
// login is NOT the person's afterwards — read back the way every reader reads
// it (principalOnNode) — empty when it is (claude-fleet#2249).
func (s *Server) recordLoginAccount(pid, fp string, out *NodeJoinResponse, osUser string, now time.Time) string {
	osUser = sanitizeJoinField(osUser)
	if osUser == "" || !control.ValidExistingLogin(osUser) {
		return fmt.Sprintf("system login %s is not one the hub records", osUser)
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(out.Token))
	if err != nil || ep.Hostname == "" {
		return "this node has no machine name on the hub"
	}
	p, err := s.Store.Principal(pid)
	if err != nil {
		return "account not recorded: " + err.Error()
	}
	wrote, err := s.Store.RecordLoginAccount(p, ep.Hostname, osUser, ep.ID, "登录即认人 · device "+fp, now)
	switch {
	case err != nil:
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, "account not recorded: "+err.Error(), now)
		return "account not recorded: " + err.Error()
	case wrote:
		s.deviceAudit(store.DeviceNodePass, fp, pid, pid, fmt.Sprintf("account %s on %s is %s · 登录即认人", osUser, ep.Hostname, pid), now)
	}
	if who, err := s.principalOnNode(ep.ID, ep.Hostname, osUser); err != nil || who != pid {
		why := fmt.Sprintf("login %s on %s is not recorded as yours", osUser, ep.Hostname)
		if who != "" {
			why = fmt.Sprintf("login %s on %s already belongs to someone else", osUser, ep.Hostname)
		}
		s.deviceAudit(store.DeviceNodePassRefused, fp, pid, pid, why, now)
		return why
	}
	return ""
}
