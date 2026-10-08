package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A managed machine's desired state (claude-fleet#2214, EPIC #2329 共同约定 1).
//
//	operator  POST /v1/fleet/nodes/join-codes        → a trusted, managed join code (1 h)
//	operator  GET  /v1/fleet/nodes/<endpoint>/desired → what the machine should look like
//	operator  PUT  /v1/fleet/nodes/<endpoint>/desired ← replace it (if_version guards a race)
//	machine   GET  /v1/node/desired                  → its own, with its token
//
// Only the operator writes; the node reads its own and reports, on every
// heartbeat, the version it converged to (control.DesiredReport). The shape is
// docs/MANAGED-NODE.md — C3–C6 read it, so a field added here is added there.

// FleetNodesPrefix is the per-machine subtree.
const FleetNodesPrefix = "/v1/fleet/nodes/"

var (
	desiredReleaseRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$`)
	desiredNameRE    = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)
	desiredVerRE     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$`)
)

// DesiredBody is the desired state proper — what the node converges to.
type DesiredBody struct {
	// Release is the fleet release (the stable tag's commit) the machine runs.
	Release string `json:"release,omitempty"`
	// Components pins each part's version: ccquota, claude, codex, runtime, …
	Components map[string]string `json:"components,omitempty"`
	// Accounts are the system logins the machine should have; Spares how
	// many empty ones it keeps ready.
	Accounts []string `json:"accounts,omitempty"`
	Spares   int      `json:"spare_accounts,omitempty"`
}

// DesiredState is GET's answer: the body plus who the machine is.
type DesiredState struct {
	EndpointID string `json:"endpoint_id"`
	Version    int    `json:"version"`
	DesiredBody
	Trust       string     `json:"trust"`
	TrustSource string     `json:"trust_source,omitempty"`
	Role        string     `json:"role,omitempty"`
	UpdatedAt   *time.Time `json:"updated_at,omitempty"`
	UpdatedBy   string     `json:"updated_by,omitempty"`
}

func (b DesiredBody) validate() error {
	if b.Release != "" && !desiredReleaseRE.MatchString(b.Release) {
		return errors.New("release: a tag or commit")
	}
	if len(b.Components) > 32 {
		return errors.New("components: at most 32")
	}
	for k, v := range b.Components {
		if !desiredNameRE.MatchString(k) || !desiredVerRE.MatchString(v) {
			return errors.New("components: name → version, letters digits . + _ - only")
		}
	}
	if len(b.Accounts) > 64 {
		return errors.New("accounts: at most 64")
	}
	for _, a := range b.Accounts {
		if !desiredNameRE.MatchString(a) {
			return errors.New("accounts: system login names")
		}
	}
	if b.Spares < 0 || b.Spares > 32 {
		return errors.New("spare_accounts: 0 to 32")
	}
	return nil
}

// desiredState composes an endpoint's state for GET.
func (s *Server) desiredState(endpointID, host string, now time.Time) (DesiredState, error) {
	d, err := s.Store.DesiredOf(endpointID)
	if err != nil {
		return DesiredState{}, err
	}
	out := DesiredState{EndpointID: endpointID, Version: d.Version, UpdatedBy: d.UpdatedBy}
	_ = json.Unmarshal([]byte(d.Body), &out.DesiredBody)
	if d.Version > 0 {
		at := d.UpdatedAt.UTC()
		out.UpdatedAt = &at
	}
	settings, _ := s.trustSettings(now)
	out.Trust, out.TrustSource = s.endpointTrust(endpointID, host, settings)
	if et, err := s.Store.EndpointTrustOf(endpointID); err == nil {
		out.Role = et.Role
	}
	return out, nil
}

// desiredView is the roster's 期望 / 实际 pair; nil when the hub keeps no
// desired state for the endpoint and its node reports none.
func (s *Server) desiredView(endpointID string, rep *control.DesiredReport) *DesiredView {
	d, err := s.Store.DesiredOf(endpointID)
	if err != nil || (d.Version == 0 && rep == nil) {
		return nil
	}
	v := &DesiredView{Want: d.Version}
	var b DesiredBody
	_ = json.Unmarshal([]byte(d.Body), &b)
	v.WantRelease = b.Release
	if rep != nil {
		v.Reached, v.Release, v.Diff = rep.Version, rep.Release, rep.Diff
	}
	return v
}

// handleFleetNodes serves the per-machine subtree (adminOnly wraps it).
func (s *Server) handleFleetNodes(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	rest := strings.TrimPrefix(r.URL.Path, FleetNodesPrefix)
	if rest == "join-codes" {
		s.fleetJoinCodes(w, r, true)
		return
	}
	id, what, ok := strings.Cut(rest, "/")
	if !ok || what != "desired" || id == "" {
		http.NotFound(w, r)
		return
	}
	ep, err := s.Store.EndpointByID(id)
	if err != nil || ep.RetiredAt != nil {
		httpError(w, http.StatusNotFound, "no such machine")
		return
	}
	now := time.Now()
	switch r.Method {
	case http.MethodGet:
		st, err := s.desiredState(ep.ID, ep.Hostname, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, st)
	case http.MethodPut:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		var req struct {
			DesiredBody
			// IfVersion is the version the writer read; absent = overwrite.
			IfVersion *int `json:"if_version"`
			// Trust, when present, is the operator's word on THIS endpoint:
			// trusted | untrusted | "" (back to the machine-name rule).
			Trust *string `json:"trust"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "the body must be one desired-state object (docs/MANAGED-NODE.md): "+err.Error())
			return
		}
		if err := req.DesiredBody.validate(); err != nil {
			httpError(w, http.StatusBadRequest, err.Error())
			return
		}
		if req.Trust != nil {
			switch *req.Trust {
			case "", TrustTrusted, TrustUntrusted:
			default:
				httpError(w, http.StatusBadRequest, "trust: trusted, untrusted or empty")
				return
			}
		}
		body, _ := json.Marshal(req.DesiredBody)
		ifv := -1
		if req.IfVersion != nil {
			ifv = *req.IfVersion
		}
		actor := actorOf(r)
		ver, err := s.Store.PutDesired(ep.ID, string(body), actor, ifv, now)
		if errors.Is(err, store.ErrDesiredVersion) {
			writeJSON(w, http.StatusConflict, map[string]any{"error": "version_conflict",
				"message": "the desired state changed since it was read — read it again", "version": ver})
			return
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if err := s.Store.FleetAudit(actor, "node_desired", "endpoint:"+ep.ID, "PUT v"+strconv.Itoa(ver), "", now); err != nil {
			log.Printf("desired audit: %v", err)
		}
		if req.Trust != nil {
			was, _ := s.endpointTrust(ep.ID, ep.Hostname, mustSettings(s, now))
			if err := s.Store.SetEndpointTrust(ep.ID, *req.Trust, store.TrustSourceOperator); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			to := *req.Trust
			if to == "" {
				to = "(machine name)"
			}
			s.leaseAudit(actor, "node_trust", "endpoint:"+ep.ID, was+" → "+to, now)
		}
		st, err := s.desiredState(ep.ID, ep.Hostname, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, st)
	default:
		w.Header().Set("Allow", "GET, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET or PUT")
	}
}

// handleNodeDesired is the node's own read, with its token.
func (s *Server) handleNodeDesired(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	host, _ := s.nodeIdentity(ep)
	st, err := s.desiredState(ep.ID, host, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func mustSettings(s *Server, now time.Time) map[string]string {
	m, _ := s.trustSettings(now)
	return m
}
