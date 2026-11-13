package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// AdminTokenNodePath is where a managed machine asks for its admin role
// account's own node token (claude-fleet#3724, EPIC #3500 C15·b-3): the root
// install step, with the MACHINE's credential, for `_fleetadmin` (macOS) /
// `fleetadmin` (Linux) on that machine — the login its
// com.claude-fleet.admin-agent runs `ccquota agent` as.
const AdminTokenNodePath = "/v1/node/admin-token"

// adminRoleLogins are the only logins this door mints for: the admin role
// account's two spellings (bin/fleet_admin_seat.py role()). A person's login
// is never one — its token is its own join's.
var adminRoleLogins = map[string]bool{"_fleetadmin": true, "fleetadmin": true}

// AdminTokenResponse is the body of a successful POST AdminTokenNodePath. The
// token is shown this once; only its hash is kept.
type AdminTokenResponse struct {
	EndpointID string `json:"endpoint_id"`
	Login      string `json:"login"`
	Machine    string `json:"machine"`
	Token      string `json:"token"`
	Hub        string `json:"hub"`
	// Outcome is issued (a new endpoint) or reissued (the same endpoint, a
	// new token — the old one resolves for ReissueTokenGrace).
	Outcome string `json:"outcome"`
}

// handleNodeAdminToken serves AdminTokenNodePath. Three rules, each its own
// refusal (BREAK-IT fleetadmin-token-misissued): only the machine's own node
// program asks (the endpoint that enrolled as root by an operator's or the
// hub's code — nodeSelf, task MPCX) — a login's token is refused; only for the admin role account's name, and only
// one the hub already counts as an admin (CCQUOTA_FLEET_ADMIN_USERS); and
// only for THIS machine — the endpoint is enrolled as the asker's host,
// never one named in the body. Every issue is one fleet_audit line.
func (s *Server) handleNodeAdminToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	ep, _, ok := s.nodeEndpointOr(w, r, "the machine's node token is required", "unrecognised node token")
	if !ok {
		return
	}
	// The machine's program is the endpoint that ENROLLED as root by an
	// operator's or the hub's code (nodeSelf, task MPCX); its machine is the
	// one it speaks for, never a report or a hello's capability.
	self := s.nodeSelf(ep)
	link := false
	if c := s.nodes.get(ep.ID); c != nil && c.machineLink {
		link = true
	}
	if !self.Machine && !self.machineByLegacy(link) {
		httpError(w, http.StatusForbidden, "only the machine's own node token asks for its admin role account's token")
		return
	}
	if s.podEndpoint(ep.ID) {
		httpError(w, http.StatusForbidden, "a person's pod has no admin role account")
		return
	}
	// The seat is the machine's the endpoint ENROLLED as (task MPCX) — never
	// a name its report gives: a machine's program asks for its own seat only.
	host := self.EnrolledHost
	if host == "" {
		httpError(w, http.StatusConflict, "this machine has not said its name yet — wait for its first heartbeat")
		return
	}
	var req struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	login := strings.TrimSpace(req.Login)
	if !adminRoleLogins[login] {
		httpError(w, http.StatusForbidden, "only the admin role account (_fleetadmin / fleetadmin) gets a token here")
		return
	}
	if !s.isFleetAdmin(login) {
		httpError(w, http.StatusForbidden, login+" is not one of this hub's admin logins — add it to CCQUOTA_FLEET_ADMIN_USERS first")
		return
	}
	now := s.joinNow()
	out, err := s.issueAdminToken(r, host, login, s.seatOf(ep, self, host, login), now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	what := fmt.Sprintf("%s %s on %s · admin seat", strings.ToUpper(out.Outcome), login, firstLabel(host))
	if err := s.Store.FleetAudit("node:root@"+firstLabel(host), "admin_token", "endpoint:"+out.EndpointID, what, "", now); err != nil {
		log.Printf("admin token audit: %v", err)
	}
	writeJSON(w, http.StatusOK, out)
}

// issueAdminToken is the token itself: the live endpoint of login on host
// gets a new one, else a fixed-kind endpoint is enrolled pinned to host
// (a code the hub mints for that machine and spends at once).
func (s *Server) issueAdminToken(r *http.Request, host, login, seat string, now time.Time) (*AdminTokenResponse, error) {
	tok, err := MintToken()
	if err != nil {
		return nil, err
	}
	out := &AdminTokenResponse{Login: login, Machine: firstLabel(host), Token: tok, Hub: s.nodeHubURL(r)}
	if seat != "" {
		if err := s.Store.RotateEndpointToken(seat, HashToken(tok), now, ReissueTokenGrace); err != nil {
			return nil, err
		}
		out.EndpointID, out.Outcome = seat, "reissued"
		return out, nil
	}
	if id, err := s.Store.LiveEndpointOn(host, login); err == nil {
		if err := s.Store.RotateEndpointToken(id, HashToken(tok), now, ReissueTokenGrace); err != nil {
			return nil, err
		}
		out.EndpointID, out.Outcome = id, "reissued"
		return out, nil
	} else if !errors.Is(err, store.ErrNoSuchEndpoint) {
		return nil, err
	}
	code, err := MintJoinCode()
	if err != nil {
		return nil, err
	}
	if err := s.Store.CreateJoinCodeFor(HashToken(code), "", store.NodeKindFixed, "", "", host, now, time.Minute); err != nil {
		return nil, err
	}
	id := fmt.Sprintf("ep_%d", now.UnixNano())
	label := firstLabel(host) + "-" + login
	if err := s.Store.RedeemJoinCode(HashToken(code), now, id, label, HashToken(tok), host, login); err != nil {
		return nil, err
	}
	out.EndpointID, out.Outcome = id, "issued"
	return out, nil
}

// seatOf is the live admin seat this machine already has, "" for none (task
// MPCX): one enrolled as the machine the program enrolled as (any case, first
// label), else — for a seat an older hub issued under the name the program
// reported (a Mac's HostName) — one enrolled as that name, but only while the
// name is no other machine's: not trusted, no other machine program enrolled
// as it, no pod's.
func (s *Server) seatOf(ep *store.Endpoint, self nodeIdent, host, login string) string {
	if id, err := s.Store.LiveSeatOn(host, login); err == nil {
		return id
	}
	rep := self.ReportedHost
	if rep == "" || sameName(rep, host) || isUserPodName(rep) {
		return ""
	}
	if settings, err := s.Store.FleetSettings(); err != nil || s.machineTrusted(firstLabel(rep), settings) {
		return ""
	}
	if taken, err := s.Store.MachineProgramEnrolledAs(ep.ID, rep); err != nil || taken {
		return ""
	}
	if id, err := s.Store.LiveSeatOn(rep, login); err == nil {
		return id
	}
	return ""
}
