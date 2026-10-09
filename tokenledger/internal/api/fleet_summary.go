package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The status bar's two summaries by connection certificate (claude-fleet#1502).
//
// A sidebar writes global/hub_nodes and global/hub_limits on the same round as
// the sessions (claude-fleet#1482), from /v1/nodes `machines` and
// /v1/limits?account=all `per_account`. Both sit behind the viewer gate, so a
// colleague holding only the certificate `fleet login` wrote never got either:
// their bar showed `?` for the machine and no account chip. This door answers
// both shapes in one body and admits the certificate the way
// control.SessionsPath does (a POST with a signed timestamp), narrowed for a
// person to what is theirs:
//
//   - machines: the roster through FleetScope — only machines where one of
//     their ACTIVE logins runs, exactly as /v1/nodes narrows it for a GitHub
//     sign-in.
//   - per_account: only the subscriptions some endpoint of those same logins
//     reports usage under, and without endpoint_shares (that split names
//     other people's endpoints).
//
// The operator's doors (viewer token) see everything, as on the
// two viewer routes. A revoked device is refused by verifySSHRelayCert; every
// answer is one fleet audit row (tool fleet_summary) naming the actor.

// SummaryRequest proves a connection certificate for the summaries: Sig is
// `ssh-keygen -Y sign -n fleet-summary@claude-fleet` over
// control.SummarySigMessage(TS) by the certificate's key.
type SummaryRequest struct {
	Cert string `json:"cert"`
	Sig  string `json:"sig"`
	TS   int64  `json:"ts"`
}

// SummaryResponse is the body of control.SummaryPath.
type SummaryResponse struct {
	At         time.Time       `json:"at"`
	Machines   []MachineView   `json:"machines"`
	PerAccount []AccountLimits `json:"per_account"`
	// Account: as NodesSnapshot.Account (claude-fleet#2069).
	Account *AccountState `json:"account,omitempty"`
	// Alerts is every open service_failed the reader may see
	// (claude-fleet#2526): a registered service down, a task past its
	// retries — the client's alert bar reads it off the same answer.
	Alerts []store.FleetAlert `json:"alerts"`
}

// handleFleetSummary serves control.SummaryPath outside the viewer gate.
func (s *Server) handleFleetSummary(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	now := time.Now()
	if !ok {
		var req SummaryRequest
		if r.Method == http.MethodPost {
			_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req)
		}
		if req.Cert == "" || req.Sig == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
			httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
			return
		}
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, control.SummarySigMessage(req.TS), control.SummarySigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	out, err := s.fleetSummary(r, id, now)
	outcome := "OK"
	if err != nil {
		outcome = "INTERNAL"
	}
	if aerr := s.Store.FleetAudit(id.Actor, "fleet_summary", "", outcome, "", now); aerr != nil {
		log.Printf("fleet audit: %v", aerr)
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// fleetSummary builds the answer for id: everything for the operator, the
// person's own machines and subscriptions otherwise.
func (s *Server) fleetSummary(r *http.Request, id sshRelayIdentity, now time.Time) (SummaryResponse, error) {
	var visible func(hostname, osUser string) bool
	if !id.Operator {
		var err error
		if visible, err = s.FleetScope(r.WithContext(context.WithValue(r.Context(), principalKey{}, id.Principal))); err != nil {
			return SummaryResponse{}, err
		}
		if visible == nil { // a person with no principal id: nothing is theirs
			visible = func(string, string) bool { return false }
		}
	}
	snap, err := s.nodesWhere(now, visible)
	if err != nil {
		return SummaryResponse{}, err
	}
	across, err := s.LimitsForAllSource("")
	if err != nil {
		return SummaryResponse{}, err
	}
	out := SummaryResponse{At: snap.At, Machines: snap.Machines, PerAccount: []AccountLimits{},
		Alerts: s.openServiceAlerts(visible)}
	if !id.Operator {
		out.Account = s.accountStateOf(id.Principal, now)
	}
	var mine map[string]bool
	if visible != nil {
		eps, err := s.Store.ListEndpoints("")
		if err != nil {
			return SummaryResponse{}, err
		}
		mine = map[string]bool{}
		for _, e := range eps {
			if visible(e.Hostname, e.OSUser) {
				mine[e.AccountUUID] = true
			}
		}
	}
	loc := localeOf(r)
	for _, a := range across.PerAccount {
		if mine != nil {
			if !mine[a.AccountUUID] {
				continue
			}
			if a.Limits != nil {
				a.Limits.EndpointShares = nil
			}
		}
		localizeLimits(a.Limits, loc)
		out.PerAccount = append(out.PerAccount, a)
	}
	return out, nil
}
