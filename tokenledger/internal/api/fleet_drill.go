package api

import (
	"bytes"
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Drill people (claude-fleet#2010, EPIC #1906 C16): an onboarding drill
// confirms its scan as a stand-in colleague the hub minted for it, never as
// the operator signed in on the browser. The flow:
//
//	POST /v1/admin/drill          an admin mints one → {person_id, login, approve_code, expires_at}
//	POST /fleet/login/approve     {code, approve_code} confirms ONE device login as that person
//	DELETE /v1/self               the drill person removes itself (its own cert, or the code)
//
// A drill person gets no credentials and no session passes (fleet_creds.go,
// fleet_session_cred.go), sees only its own sessions like any non-admin, and
// is deleted with its devices and nodes when its life runs out.
const (
	DrillPath     = "/v1/admin/drill"
	DrillSelfPath = "/v1/self"
	// LoginApprovePath is the scan's confirmation without a browser.
	LoginApprovePath = "/fleet/login/approve"

	DrillDefaultTTL = 2 * time.Hour
	DrillMaxTTL     = 24 * time.Hour
	drillMinTTL     = 5 * time.Minute

	// The signatures a client makes for these doors: their own namespace, so
	// a signature made for any other door is never accepted here.
	DrillSigNamespace = "fleet-drill@claude-fleet"

	// LeaseDrill: a drill person borrows nothing (claude-fleet#2010).
	LeaseDrill = "drill"
)

// DrillInviteMessage is what `fleet drill invite` signs.
func DrillInviteMessage(ts int64, host, login string, ttlSecs int) string {
	return fmt.Sprintf("fleet-drill %d invite %s %s %d", ts, host, login, ttlSecs)
}

// DrillSelfDeleteMessage is what a drill person signs to delete itself.
func DrillSelfDeleteMessage(ts int64) string {
	return fmt.Sprintf("fleet-drill %d delete-self", ts)
}

// A drill login is a hub login (ValidExistingLogin) that says it is a drill.
var drillLoginRe = regexp.MustCompile(`^drill[a-z0-9]{1,11}$`)

// MintDrillCode is a one-time approve code: 130 random bits, "fd_" + base32.
func MintDrillCode() (string, error) {
	b := make([]byte, 17)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate approve code: %w", err)
	}
	return "fd_" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))[:26], nil
}

type drillInviteRequest struct {
	Host       string `json:"host"`
	Login      string `json:"login,omitempty"`
	TTLSeconds int    `json:"ttl_seconds,omitempty"`
	Cert       string `json:"cert,omitempty"`
	Sig        string `json:"sig,omitempty"`
	TS         int64  `json:"ts,omitempty"`
}

// DrillInviteResponse is the body of POST /v1/admin/drill. ApproveCode is
// shown this once; the hub keeps only its hash.
type DrillInviteResponse struct {
	PersonID    string    `json:"person_id"`
	Kind        string    `json:"kind"`
	Login       string    `json:"login"`
	Host        string    `json:"host"`
	ApproveCode string    `json:"approve_code"`
	ExpiresAt   time.Time `json:"expires_at"`
}

// handleAdminDrill serves POST /v1/admin/drill. Two doors, both an admin's:
// the operator's own connection certificate signing DrillInviteMessage (the
// way `fleet drill invite` asks), or the viewer gate + adminOnly (the
// operator's token, a GitHub admin's session).
func (s *Server) handleAdminDrill(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		httpError(w, http.StatusBadRequest, "unreadable body")
		return
	}
	var req drillInviteRequest
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &req); err != nil {
			httpError(w, http.StatusBadRequest, "body must be JSON: "+err.Error())
			return
		}
	}
	if req.Cert == "" {
		s.viewerOnly(s.adminOnly(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			actor := principalOf(r.Context())
			if actor == "" {
				actor = "operator"
			}
			s.createDrill(w, r, req, actor)
		}))).ServeHTTP(w, r)
		return
	}
	now := time.Now()
	if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
		httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
		return
	}
	id, err := s.verifySSHRelayCert(req.Cert, req.Sig, DrillInviteMessage(req.TS, req.Host, req.Login, req.TTLSeconds), DrillSigNamespace, now)
	if err != nil {
		var re *sshRelayError
		if errors.As(err, &re) {
			httpError(w, http.StatusUnauthorized, re.msg)
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !s.principalIsAdmin(id.Principal) {
		httpError(w, http.StatusForbidden, "only an admin can invite a drill person")
		return
	}
	s.createDrill(w, r, req, id.Principal)
}

// principalIsAdmin: a GitHub person CCQUOTA_GITHUB_ADMINS names, or a person
// whose login is a fleet admin login (CCQUOTA_FLEET_ADMIN_USERS — the
// operator's own). A drill person never is.
func (s *Server) principalIsAdmin(pid string) bool {
	if pid == "" || s.Store.IsDrill(pid) {
		return false
	}
	if gid, ok := githubIDOf(pid); ok {
		role, err := s.githubRole(gid)
		return err == nil && role == roleAdmin
	}
	p, err := s.Store.Principal(pid)
	return err == nil && s.isFleetAdmin(p.Login)
}

func (s *Server) createDrill(w http.ResponseWriter, r *http.Request, req drillInviteRequest, actor string) {
	now := time.Now()
	s.SweepDrills(now)
	ttl := DrillDefaultTTL
	if req.TTLSeconds != 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
		if ttl < drillMinTTL || ttl > DrillMaxTTL {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("ttl_seconds must be %d…%d", int(drillMinTTL.Seconds()), int(DrillMaxTTL.Seconds())))
			return
		}
	}
	host, ok := s.drillHost(req.Host)
	if !ok {
		httpError(w, http.StatusBadRequest, "host must be a machine on the hub's roster (got "+fmt.Sprintf("%q", req.Host)+")")
		return
	}
	login := req.Login
	if login == "" {
		login = "drill" + now.UTC().Format("01021504")
	}
	if !drillLoginRe.MatchString(login) || !control.ValidExistingLogin(login) {
		httpError(w, http.StatusBadRequest, "login must be drill + 1-11 lowercase letters or digits (got "+fmt.Sprintf("%q", login)+")")
		return
	}
	code, err := MintDrillCode()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	var rnd [8]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	pid := "drill-" + fmt.Sprintf("%x", rnd[:])
	d := store.DrillPerson{PrincipalID: pid, Login: login, Hostname: host, CodeHash: HashToken(code),
		CreatedBy: actor, CreatedAt: now, ExpiresAt: now.Add(ttl)}
	if err := s.Store.CreateDrill(d); err != nil {
		httpError(w, http.StatusConflict, err.Error())
		return
	}
	log.Printf("fleet: %s invited drill person %s (login %s on %s) until %s", actor, pid, login, host, d.ExpiresAt.UTC().Format(time.RFC3339))
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, DrillInviteResponse{PersonID: pid, Kind: store.DrillKind, Login: login, Host: host,
		ApproveCode: code, ExpiresAt: d.ExpiresAt.UTC()})
}

// drillHost is the roster's spelling of the machine the drill's login lives
// on: an exact hostname, else the one whose first label matches.
func (s *Server) drillHost(want string) (string, bool) {
	want = strings.TrimSpace(want)
	if want == "" {
		return "", false
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		return "", false
	}
	match := ""
	for _, n := range nodes {
		if n.Hostname == want {
			return n.Hostname, true
		}
		if strings.EqualFold(firstLabel(n.Hostname), firstLabel(want)) {
			match = n.Hostname
		}
	}
	return match, match != ""
}

// approveRequest is the body of POST /fleet/login/approve.
type approveRequest struct {
	Code        string `json:"code"`
	ApproveCode string `json:"approve_code"`
}

// handleLoginApprove serves POST /fleet/login/approve: a drill's scan,
// confirmed by its approve code instead of a browser. The code is the whole
// credential; it binds the login to ITS person, once.
func (s *Server) handleLoginApprove(w http.ResponseWriter, r *http.Request) {
	if s.SSHCA == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	var req approveRequest
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		if err := json.NewDecoder(io.LimitReader(r.Body, 16<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "body must be JSON")
			return
		}
	} else {
		req.Code, req.ApproveCode = r.FormValue("code"), r.FormValue("approve_code")
	}
	pid, resp, purpose, err := s.approveWithCode(r, strings.ToUpper(strings.TrimSpace(req.Code)), strings.TrimSpace(req.ApproveCode), time.Now())
	switch {
	case errors.Is(err, store.ErrDrillCode):
		httpError(w, http.StatusForbidden, "approve code unknown, already used or expired")
	case errors.Is(err, errLoginGone):
		httpError(w, http.StatusGone, "this code has expired or was already used — run fleet login again")
	case err != nil:
		httpError(w, http.StatusForbidden, "签发失败："+err.Error())
	default:
		writeJSON(w, http.StatusOK, map[string]any{"status": "approved", "person_id": pid, "kind": store.DrillKind,
			"purpose": purpose, "principals": resp.Principals, "valid_before": resp.ValidBefore})
	}
}

// errLoginGone: no pending device login under that user code.
var errLoginGone = errors.New("no pending login under that code")

// approveWithCode confirms the pending login under userCode as the drill
// person approveCode belongs to — never as whoever else is on the request.
func (s *Server) approveWithCode(r *http.Request, userCode, approveCode string, now time.Time) (string, *CertResponse, string, error) {
	if !validUserCode(userCode) || !s.devices.withUser(userCode, now, func(*deviceLogin) {}) {
		return "", nil, "", errLoginGone
	}
	hash := HashToken(approveCode)
	d, err := s.Store.UseDrillCode(hash, now)
	if err != nil {
		return "", nil, "", err
	}
	resp, purpose, err := s.approveDeviceLogin(r, d.PrincipalID, userCode, now)
	if err != nil && (errors.Is(err, errLoginGone) || resp == nil) {
		// Nothing was issued: the code may be spent again.
		if uerr := s.Store.UnuseDrillCode(hash); uerr != nil {
			log.Printf("fleet: drill %s: give the approve code back: %v", d.PrincipalID, uerr)
		}
	}
	if err == nil {
		log.Printf("fleet: drill person %s confirmed login %s by approve code", d.PrincipalID, userCode)
		// Its first session needs a machine of its own (claude-fleet#2549):
		// the same placement a newcomer's first look runs, started now so
		// the client meets 「正在为你开机器」, not 「No fleet」.
		s.accountStateOf(d.PrincipalID, now)
	}
	return d.PrincipalID, resp, purpose, err
}

type selfDeleteRequest struct {
	ApproveCode string `json:"approve_code,omitempty"`
	Cert        string `json:"cert,omitempty"`
	Sig         string `json:"sig,omitempty"`
	TS          int64  `json:"ts,omitempty"`
}

// handleSelf serves DELETE /v1/self: a drill person deletes itself — the
// person, its devices, its nodes — proven by its own connection certificate
// (signing DrillSelfDeleteMessage) or by its approve code (a drill whose scan
// never finished has no certificate). Anyone who is not a drill is refused:
// a real person is never one request away from erasing themselves.
func (s *Server) handleSelf(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		w.Header().Set("Allow", http.MethodDelete)
		httpError(w, http.StatusMethodNotAllowed, "DELETE only")
		return
	}
	var req selfDeleteRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "body must be JSON")
		return
	}
	now := time.Now()
	var pid string
	switch {
	case req.Cert != "":
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		id, err := s.verifySSHRelayCert(req.Cert, req.Sig, DrillSelfDeleteMessage(req.TS), DrillSigNamespace, now)
		if err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		pid = id.Principal
	case req.ApproveCode != "":
		d, err := s.Store.DrillByCode(HashToken(req.ApproveCode), now)
		if err != nil {
			httpError(w, http.StatusUnauthorized, "approve code unknown or expired")
			return
		}
		pid = d.PrincipalID
	default:
		httpError(w, http.StatusUnauthorized, "a connection certificate or the drill's approve code is required")
		return
	}
	d, err := s.Store.Drill(pid)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if d == nil {
		httpError(w, http.StatusForbidden, "only a drill person can delete itself")
		return
	}
	if left := s.closeDrillLogins(d, now); len(left) > 0 {
		// The login the hub opened for it is still on a machine: the person
		// stays until that is removed — ask again (or the sweep finishes it).
		writeJSON(w, http.StatusAccepted, map[string]any{"status": "removing", "person_id": pid, "logins": left})
		return
	}
	out, err := s.Store.DeleteDrill(pid, pid, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	log.Printf("fleet: drill person %s deleted itself (%d device(s), node(s) %v)", pid, out.Devices, out.Nodes)
	writeJSON(w, http.StatusOK, out)
}

// SweepDrills deletes every drill person whose life is over.
func (s *Server) SweepDrills(now time.Time) {
	if s.Store == nil {
		return
	}
	gone, err := s.Store.ExpiredDrills(now)
	if err != nil {
		log.Printf("fleet: drill sweep: %v", err)
		return
	}
	for _, d := range gone {
		if left := s.closeDrillLogins(&d, now); len(left) > 0 {
			log.Printf("fleet: drill person %s expired — removing %s first", d.PrincipalID, strings.Join(left, ", "))
			continue
		}
		out, err := s.Store.DeleteDrill(d.PrincipalID, "expired", now)
		if err != nil {
			log.Printf("fleet: drill sweep: delete %s: %v", d.PrincipalID, err)
			continue
		}
		log.Printf("fleet: drill person %s expired — deleted with %d device(s), node(s) %v", d.PrincipalID, out.Devices, out.Nodes)
	}
}

// drillCloseGiveUp is how long a drill waits on the removal of a login the
// hub opened for it before it is deleted anyway (the machine gone, its admin
// node never back): the login is then the operator's, and the log says so.
// A variable so tests can move it.
var drillCloseGiveUp = time.Hour

// closeDrillLogins removes every login the hub opened for drill person d
// (claude-fleet#2549: its first session's machine) — a real OS login on a
// machine, which deleting the person's rows would leave behind with nobody
// to close it. It queues the removal of each one still there and answers
// what is still on a machine as login@machine; empty means the person can
// go. Its own computer (the bare login `fleet drill invite` named) is the
// drill script's to remove, never the hub's.
func (s *Server) closeDrillLogins(d *store.DrillPerson, now time.Time) []string {
	accts, err := s.Store.FleetAccounts(d.PrincipalID)
	if err != nil {
		log.Printf("fleet: drill %s: accounts: %v", d.PrincipalID, err)
		return []string{"(its accounts could not be read)"}
	}
	var left []string
	queued := false
	for _, a := range accts {
		if strings.EqualFold(a.Hostname, d.Hostname) && a.Login == d.Login {
			continue
		}
		where := a.Login + "@" + a.Hostname
		switch a.State {
		case store.AccountRemoved:
			continue // gone from the machine: dropped with the person
		case store.AccountPending:
			// Never sent: forgotten now, before the dispatcher can send it.
			// One it sent in between refuses, and is waited on as creating.
			if err := s.Store.ForgetPrincipal(a.PrincipalID, a.Hostname); err == nil {
				continue
			}
		case store.AccountActive:
			if err := s.Store.RequestAccountRemoval(a.PrincipalID, a.Hostname, now); err != nil {
				log.Printf("fleet: drill %s: queue removal of %s: %v", d.PrincipalID, where, err)
			} else {
				log.Printf("fleet: drill %s: removing the login opened for it, %s", d.PrincipalID, where)
				queued = true
			}
		case store.AccountCreating, store.AccountRemovePending, store.AccountRemoving, store.AccountUnknown:
			if a.State == store.AccountUnknown && a.Op != control.AccountRemove {
				// A create nobody heard back on: the name may be someone
				// else's login there — never removed on a guess.
				log.Printf("fleet: drill %s: %s was opened with no answer — left for the operator", d.PrincipalID, where)
				continue
			}
			if now.Sub(a.RequestedAt) > drillCloseGiveUp {
				log.Printf("fleet: drill %s: %s still %s after %s — left for the operator", d.PrincipalID, where, a.State, drillCloseGiveUp)
				continue
			}
		default:
			// failed: a create that failed (perhaps on a login that was
			// already there — someone else's) or a remove that did.
			log.Printf("fleet: drill %s: %s %s (%s) — left for the operator", d.PrincipalID, where, a.State, a.Detail)
			continue
		}
		left = append(left, where)
	}
	if queued {
		go s.dispatchAccounts()
	}
	return left
}
