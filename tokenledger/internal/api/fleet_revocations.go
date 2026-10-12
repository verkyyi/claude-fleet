package api

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The revocation list a relay and a door keep locally (claude-fleet#3560,
// EPIC #3500 C18, 共同约定 11).
//
// Today the Singapore relay asks the hub per request (GET /v1/relay/check,
// 30 s cached on both sides) and a connection certificate cannot be revoked
// at all inside its 12 hours. With the list on, every revocation the hub
// records ALSO lands as an entry here, and the relay and the doors follow
// the list and refuse by it themselves — at once, and with the hub away:
//
//	GET /v1/relay/revocations?since=<v>&wait=<s>   the relay's sidecar
//	                                                (Bearer CCQUOTA_FLEET_REVOCATIONS_TOKEN)
//	GET /v1/node/revocations?since=<v>&wait=<s>    a machine's door (its node token)
//
// Both answer the WHOLE list, {v, entries, ssh_ca}, the moment its version
// is not <since> — held up to `wait` (≤ 25 s) while it is, then 304. A
// reader that reconnects asks with the version it holds and gets what it
// missed in one answer. Entries ({jti} or {machine|principal|login, before},
// each with exp) are written by:
//
//   - a relay credential revoke (fleet.node_relay.<m> = "") — `frl1:<sha256>`
//     per hash it dropped;
//   - a session pass revoke (DELETE /v1/fleet/session-cred/<id>) — `fcp:<id>`;
//   - a credential revocation (POST /v1/fleet/credentials/revoke) — the scope
//     with before = now, plus a machine-wide one's relay hashes (the old road
//     refuses those too) and a person's live certificates `ssh:<serial>`;
//     lifting it lifts exactly those rows;
//   - POST /v1/fleet/revocations {serial[, lift]} — one connection
//     certificate, the operator's.
//
// The old road stays beside it (the relay double-checks for one version);
// the list only adds refusals. Off — no CCQUOTA_FLEET_REVOCATIONS_TOKEN —
// every route here is 404, nothing is written, and every other answer is
// byte for byte what it was (TestRevocationsOffAddsNothing).

const (
	// RelayRevocationsPath is the relay sidecar's list.
	RelayRevocationsPath = "/v1/relay/revocations"
	// NodeRevocationsPath is a machine door's list.
	NodeRevocationsPath = "/v1/node/revocations"

	// revFrl1Keep is how long a revoked relay credential (which never
	// expires) stays on the list: past the relay's cache and hub-down grace
	// many times over; the old road refuses it after that.
	revFrl1Keep = 24 * time.Hour
	// revScopeKeep is a scope entry's life: longer than any short credential
	// it can match is issued for.
	revScopeKeep = 7 * 24 * time.Hour
)

// revRecheck re-reads the version while a request is held: another
// replica's write fires no broadcast here. Short — the list's promise is
// «refused within 10 seconds».
var revRecheck = time.Second

func (s *Server) revOn() bool { return s.RevocationsToken != "" }

func revMachine(m string) string { return strings.ToLower(firstLabel(strings.TrimSpace(m))) }

// revRecord adds entries when the list is on; a failure is logged, never the
// caller's — the revocation itself already stands on the old road.
func (s *Server) revRecord(entries []store.Revocation, now time.Time) {
	if !s.revOn() || len(entries) == 0 {
		return
	}
	if _, err := s.Store.AddRevocations(entries, now); err != nil {
		log.Printf("revocations: %v", err)
		return
	}
	s.revChanged.fire()
}

// revLift lifts what src wrote, when the list is on.
func (s *Server) revLift(src string) {
	if !s.revOn() {
		return
	}
	n, _, err := s.Store.LiftRevocations(src)
	if err != nil {
		log.Printf("revocations: %v", err)
		return
	}
	if n > 0 {
		s.revChanged.fire()
	}
}

// revRelayHashes are the relay-credential entries of machine's setting(s).
func revRelayHashes(machine string, settings map[string]string, src string, now time.Time) []store.Revocation {
	out := []store.Revocation{}
	for k, v := range settings {
		if !strings.HasPrefix(k, NodeRelayPrefix) || v == "" {
			continue
		}
		m := k[len(NodeRelayPrefix):]
		if machine != "" && !sameMachine(machine, m) && !sameMachine(m, machine) {
			continue
		}
		for login, h := range relayEntries(v) {
			out = append(out, store.Revocation{JTI: "frl1:" + h, Machine: revMachine(m), Login: login,
				Exp: now.Add(revFrl1Keep).Unix(), Src: src})
		}
	}
	return out
}

// revCredSrc names the rows one credential revocation wrote.
func revCredSrc(host, principal string) string {
	return "cred:" + revMachine(host) + "|" + principal
}

// revForCredRevoke is what POST /v1/fleet/credentials/revoke adds: the
// scope, a machine-wide revoke's relay hashes, a person's live certificates.
func (s *Server) revForCredRevoke(host, principal, reason string, now time.Time) []store.Revocation {
	src := revCredSrc(host, principal)
	out := []store.Revocation{{Machine: revMachine(host), Principal: principal, Before: now.Unix(),
		Exp: now.Add(revScopeKeep).Unix(), Src: src, Reason: reason}}
	if host != "" && principal == "" {
		if settings, err := s.Store.FleetSettings(); err == nil {
			for _, e := range revRelayHashes(host, settings, src, now) {
				e.Machine, e.Login = "", "" // the jti alone is the entry
				out = append(out, e)
			}
		}
	}
	if principal != "" {
		if certs, err := s.Store.LiveFleetCerts(principal, now); err == nil {
			for _, c := range certs {
				out = append(out, store.Revocation{JTI: "ssh:" + c.Serial, Principal: principal,
					Exp: c.ValidBefore.Unix(), Src: src})
			}
		}
	}
	return out
}

// RevocationList is the answer both list routes give.
type RevocationList struct {
	V       int64              `json:"v"`
	At      int64              `json:"at"`
	Entries []store.Revocation `json:"entries"`
	// SSHCA is the certificate authority an `ssh:<serial>` entry is of — what
	// a door builds its KRL against. Empty when the hub signs no certificates.
	SSHCA string `json:"ssh_ca,omitempty"`
}

func (s *Server) handleRelayRevocations(w http.ResponseWriter, r *http.Request) {
	if !s.revOn() {
		http.NotFound(w, r)
		return
	}
	tok := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if tok == "" || subtle.ConstantTimeCompare([]byte(tok), []byte(s.RevocationsToken)) != 1 {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	s.serveRevocations(w, r)
}

func (s *Server) handleNodeRevocations(w http.ResponseWriter, r *http.Request) {
	if !s.revOn() {
		http.NotFound(w, r)
		return
	}
	if _, ok := s.nodeEndpoint(w, r); !ok {
		return
	}
	s.serveRevocations(w, r)
}

// serveRevocations answers the list at once when its version is not
// ?since, else holds the request up to ?wait for it to move (304 at the
// deadline).
func (s *Server) serveRevocations(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	q := r.URL.Query()
	since, haveSince := int64(-1), false
	if v, err := strconv.ParseInt(q.Get("since"), 10, 64); err == nil {
		since, haveSince = v, true
	}
	wait := fleetSessionsWaitArg(q.Get("wait"))
	var deadline <-chan time.Time
	if wait > 0 && haveSince {
		t := time.NewTimer(wait)
		defer t.Stop()
		deadline = t.C
	}
	for {
		changed := s.revChanged.wait()
		v, err := s.Store.RevocationsVersion()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !haveSince || v != since {
			break
		}
		if deadline == nil {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		recheck := time.NewTimer(revRecheck)
		select {
		case <-changed:
		case <-recheck.C:
		case <-deadline:
			recheck.Stop()
			w.WriteHeader(http.StatusNotModified)
			return
		case <-r.Context().Done():
			recheck.Stop()
			return
		}
		recheck.Stop()
	}
	now := time.Now()
	v, entries, err := s.Store.RevocationList(now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := RevocationList{V: v, At: now.Unix(), Entries: entries}
	for i := range out.Entries {
		out.Entries[i].Src, out.Entries[i].Reason = "", "" // the operator's words stay on the hub
	}
	if s.SSHCA != nil {
		out.SSHCA = s.SSHCA.PublicKey()
	}
	writeJSON(w, http.StatusOK, out)
}

// FleetRevocationRequest is POST /v1/fleet/revocations: one connection
// certificate by serial, or lift it.
type FleetRevocationRequest struct {
	Serial string `json:"serial"`
	Lift   bool   `json:"lift,omitempty"`
	Reason string `json:"reason,omitempty"`
}

// handleFleetRevocations is the operator's: GET the list as the doors see it
// (with src and reason), POST {serial[, lift]} to revoke one certificate.
func (s *Server) handleFleetRevocations(w http.ResponseWriter, r *http.Request) {
	if !s.revOn() {
		http.NotFound(w, r)
		return
	}
	now := time.Now()
	switch r.Method {
	case http.MethodGet:
		v, entries, err := s.Store.RevocationList(now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, RevocationList{V: v, At: now.Unix(), Entries: entries})
	case http.MethodPost:
		var req FleetRevocationRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
			return
		}
		c, err := s.Store.FleetCertBySerial(strings.TrimSpace(req.Serial))
		if err == store.ErrNoFleetCert {
			httpError(w, http.StatusNotFound, "no such certificate")
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		src := "cert:" + c.Serial
		if req.Lift {
			s.revLift(src)
		} else if c.ValidBefore.After(now) {
			s.revRecord([]store.Revocation{{JTI: "ssh:" + c.Serial, Principal: c.PrincipalID,
				Exp: c.ValidBefore.Unix(), Src: src, Reason: joinDetail(req.Reason, "by "+actorOf(r))}}, now)
		}
		v, err := s.Store.RevocationsVersion()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"serial": c.Serial, "lifted": req.Lift, "v": v,
			"expired": !c.ValidBefore.After(now)})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}
