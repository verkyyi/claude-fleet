package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The sidebar's session list by connection certificate (claude-fleet#1475).
//
// /v1/fleet/fleet_sessions used to sit behind the viewer gate only, so a
// sidebar on another machine needed the operator's viewer token to show its
// person their own sessions. The one credential a colleague already holds is
// the connection certificate `fleet login` wrote (claude-fleet#1412), so this
// door admits it the way RoutesPath does (claude-fleet#1414): a POST carrying
// the certificate and an `ssh-keygen -Y sign` over SessionsSigMessage(ts)
// under SessionsSigNamespace. The holder is then exactly a signed-in person:
// FleetScope narrows the answer to the (machine, login) pairs of their ACTIVE
// accounts, and the audit row names them. Every door handleFleet admits still
// works here (the viewer token, a WeCom session, a tailnet peer), so the
// operator's sidebar is unchanged.

// SessionsRequest proves a connection certificate for the session list: Sig
// is `ssh-keygen -Y sign -n fleet-sessions@claude-fleet` over
// control.SessionsSigMessage(TS) by the certificate's key.
//
// Wait (seconds, optional; claude-fleet#1526) asks for the long poll: with a
// matching If-None-Match the hub holds the answer until a heartbeat moves it,
// at most fleetSessionsMaxWait. Any door may send it — in the POST body, or as
// ?wait= on a GET.
type SessionsRequest struct {
	Cert string      `json:"cert"`
	Sig  string      `json:"sig"`
	TS   int64       `json:"ts"`
	Wait json.Number `json:"wait,omitempty"`
}

// handleFleetSessions serves control.SessionsPath outside the viewer gate.
func (s *Server) handleFleetSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	var req SessionsRequest
	if r.Method == http.MethodPost {
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req)
	}
	args := map[string]any{}
	if req.Wait != "" {
		args["wait"] = req.Wait
	} else if v := r.URL.Query().Get("wait"); v != "" {
		args["wait"] = v
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	if !ok {
		if req.Cert == "" || req.Sig == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
			httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
			return
		}
		now := time.Now()
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, control.SessionsSigMessage(req.TS), control.SessionsSigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	ctx := r.Context()
	if !id.Operator {
		// A person: the fleet principal FleetScope and the audit read, as a
		// WeCom sign-in sets it (viewerOnly's ssoSession branch).
		ctx = context.WithValue(withViewer(ctx, id.Principal), principalKey{}, id.Principal)
	} else if login := strings.TrimPrefix(id.Actor, "tailnet:"); login != id.Actor {
		// A tailnet peer is the operator's door, audited by its login, as
		// viewerOnly does.
		ctx = withViewer(ctx, login)
	}
	out, err := s.CallFleetTool(r.WithContext(ctx), "fleet_sessions", args)
	writeFleetResult(w, r, out, err)
}
