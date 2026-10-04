package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A write by connection certificate (claude-fleet#1487, EPIC #1479 C8).
//
// The sidebar on another machine — and the `fleet` shell on a person's own
// computer — act on a row through the hub's write tools (worker_message,
// worker_stop, worker_resume, worker_answer, worker_reap, …). Those sit
// behind the viewer gate, and the one credential a colleague holds is the
// connection certificate `fleet login` wrote (claude-fleet#1412), so this
// door admits it the way SessionsPath does (claude-fleet#1475) — with one
// difference that matters for a WRITE: the signature covers the write itself.
// The client signs WriteSigMessage(ts, tool, sha256(args_json)) under
// WriteSigNamespace, and the hub verifies it over the exact args_json bytes it
// received, so a captured signature is good for this tool with these
// arguments and nothing else; the idempotency key inside args_json makes a
// replay inside the clock window the same operation, never a second one.
//
// The holder is then exactly a signed-in person: SubmitWrite scopes the
// target to the (machine, login) pairs of their ACTIVE accounts (another
// person's worker is NOT_FOUND, as for every person), authorize checks their
// grant, and the journal and the audit row carry their principal. The viewer
// token, a WeCom session and a tailnet peer still work here too (an operator's
// shell), as on every fleet door.

// WriteRequest is the body of POST control.WritePath.
type WriteRequest struct {
	Cert string `json:"cert"`
	Sig  string `json:"sig"`
	TS   int64  `json:"ts"`
	// Tool is a write tool (fleetWriteTools) or operation_get, so the
	// writer can read its own operation back through the same door.
	Tool string `json:"tool"`
	// ArgsJSON is the tool's arguments: one JSON object, as the exact text
	// that was signed (the hub hashes these bytes, then parses them).
	ArgsJSON string `json:"args_json"`
}

// handleFleetWrite serves control.WritePath outside the viewer gate.
func (s *Server) handleFleetWrite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		httpError(w, http.StatusUnsupportedMediaType, "send the request as application/json")
		return
	}
	var req WriteRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object: cert, sig, ts, tool, args_json")
		return
	}
	if !fleetWriteTools[req.Tool] && req.Tool != "operation_get" {
		httpError(w, http.StatusBadRequest, "tool must be one of the hub's write tools, or operation_get")
		return
	}
	args := map[string]any{}
	dec := json.NewDecoder(strings.NewReader(req.ArgsJSON))
	dec.UseNumber()
	if err := dec.Decode(&args); err != nil || args == nil {
		httpError(w, http.StatusBadRequest, "args_json must be one JSON object of tool arguments")
		return
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
		sum := sha256.Sum256([]byte(req.ArgsJSON))
		msg := control.WriteSigMessage(req.TS, req.Tool, hex.EncodeToString(sum[:]))
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, msg, control.WriteSigNamespace, now); err != nil {
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
		// A person: the fleet principal (FleetScope narrows the target to their
		// own logins; the journal's actor is their principal), as a WeCom
		// sign-in sets it.
		ctx = context.WithValue(withViewer(ctx, id.Principal), principalKey{}, id.Principal)
	} else if login := strings.TrimPrefix(id.Actor, "tailnet:"); login != id.Actor {
		ctx = withViewer(ctx, login)
	}
	out, err := s.CallFleetTool(r.WithContext(ctx), req.Tool, args)
	writeFleetResult(w, r, out, err)
}
