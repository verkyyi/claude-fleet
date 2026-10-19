package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// OperationSettlePath is operation_settle (claude-fleet#4945): an admin ends a
// worker_start the hub cannot check — one that names no worker (a no-repo /
// scratch start whose node named no window), unknown or running for more than
// operatorSettleAge. The hub settles every start it CAN check itself
// (settleNeverAppeared, claude-fleet#4932); this is the person vouching for the
// rest. The start ends failed (SETTLED_BY_OPERATOR, its prior status and result
// kept), and fleet_audit records who and why.
//
//	POST {"operation_id": "<uuid>", "reason": "<why>"} → 200 the operation
const OperationSettlePath = "/v1/fleet/operation_settle"

// operatorSettleAge: how old a start must be before a person may settle it.
var operatorSettleAge = 24 * time.Hour

func (s *Server) handleOperationSettle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST {operation_id, reason}")
		return
	}
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		httpError(w, http.StatusUnsupportedMediaType, "send the arguments as application/json")
		return
	}
	var args struct {
		OperationID string `json:"operation_id"`
		Reason      string `json:"reason"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&args); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object {operation_id, reason}")
		return
	}
	out, err := s.OperationSettle(r, args.OperationID, args.Reason)
	writeFleetResult(w, r, out, err)
}

// OperationSettle is operation_settle's work; see OperationSettlePath.
func (s *Server) OperationSettle(r *http.Request, opID, reason string) (map[string]any, error) {
	p, err := s.FleetPrincipal(r)
	if err != nil {
		return nil, err
	}
	if !p.All() {
		return nil, fault("FORBIDDEN", "only an admin may settle an operation")
	}
	reason = strings.TrimSpace(reason)
	if !fleetid.IsUUID(opID) {
		return nil, fault("INVALID_ARGUMENT", "operation_id must be a canonical UUID")
	}
	if reason == "" || len(reason) > 500 {
		return nil, fault("INVALID_ARGUMENT", "reason must say why, in at most 500 bytes")
	}
	o, err := s.Store.FleetOperation(opID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fault("NOT_FOUND", "Unknown operation")
	}
	if err != nil {
		return nil, err
	}
	var res struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal([]byte(o.Result), &res)
	sw := startWorkerOf(o.Request, res.Error.Message)
	now := time.Now()
	result := func(priorStatus, priorResult string) string {
		var prior any
		if priorResult != "" {
			prior = json.RawMessage(priorResult)
		}
		b, _ := json.Marshal(map[string]any{"error": map[string]any{"code": "SETTLED_BY_OPERATOR",
			"message": "settled by " + p.Actor + ": " + reason + " — the hub could not check this start's worker",
			"actor":   p.Actor, "reason": reason, "prior_status": priorStatus, "prior_result": prior}})
		return string(b)
	}
	fleetID, why, err := s.Store.SettleStartByOperator(opID, sw, operatorSettleAge, result, now)
	if err != nil {
		return nil, err
	}
	if why != "" {
		return nil, fault("INVALID_STATE", why)
	}
	if aerr := s.Store.FleetAudit(p.Actor, "operation_settle", fleetID, "SETTLED: "+reason, opID, now); aerr != nil {
		log.Printf("fleet audit: %v", aerr)
	}
	fresh, err := s.Store.FleetOperation(opID)
	if err != nil {
		return nil, err
	}
	s.progressOp(fresh)
	return operationView(fresh), nil
}
