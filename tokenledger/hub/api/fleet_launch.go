package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// launchContract binds observed execution to the already accepted request.
// Worker identity is minted by the operation, before any native process starts.
type launchContract struct {
	Version     int    `json:"version"`
	OperationID string `json:"operation_id"`
	Task        string `json:"task"`
	Owner       string `json:"owner"`
	Generation  int64  `json:"generation"`
	WorkerID    string `json:"worker_id"`
	Provider    string `json:"provider"`
	AttemptID   string `json:"attempt_id"`
}

func (s *Server) canLaunch(ctx context.Context, endpoint string) bool {
	if c := s.nodes.get(endpoint); c != nil {
		return c.canLaunch
	}
	if p, ok := s.peerOf(ctx, endpoint); ok {
		return p.HasCap(control.CapLaunch)
	}
	return false
}

func acceptedLaunch(w writeRequest) *dispatchChoice {
	if _, draft := w.params["draft"]; draft {
		return nil
	}
	d, _ := resolveDispatch("", "", w.params["dispatch"], "")
	if d == nil || d.Task == "" {
		return nil
	}
	return d
}

func (s *Server) launchContract(op store.FleetOperation) (launchContract, bool, error) {
	var request struct {
		Params map[string]any `json:"params"`
	}
	if op.Action != "worker_start" || json.Unmarshal([]byte(op.Request), &request) != nil {
		return launchContract{}, false, nil
	}
	d := acceptedLaunch(writeRequest{params: request.Params})
	if d == nil {
		return launchContract{}, false, nil
	}
	t, err := s.Store.FleetTask(store.ParseTaskRef(d.Task))
	if err != nil {
		return launchContract{}, true, err
	}
	return launchContract{1, op.ID, d.Task, t.Owner, d.Generation, op.FleetID + "/" + op.ID, d.ResolvedAgent, d.AttemptID}, true, nil
}

func (s *Server) claimLaunch(op store.FleetOperation, target store.FleetRow) (*launchContract, error) {
	c, yes, err := s.launchContract(op)
	if err != nil || !yes {
		return nil, err
	}
	_, err = s.Store.MutateFleetTask(store.ParseTaskRef(c.Task), c.Owner, store.TaskMutation{
		Key: "launch-claim:" + op.ID, Kind: "claim", Generation: c.Generation,
		WorkerID: c.WorkerID, EndpointID: target.EndpointID, FleetID: target.FleetID,
	}, time.Now())
	if err != nil {
		return nil, fault("INVALID_STATE", "accepted task already has an owner or changed generation")
	}
	return &c, nil
}

// A successful adapter exit/window label cannot move the task to running.
// Only the authenticated node's complete, current operation receipt can.
func (s *Server) verifyLaunchResult(op store.FleetOperation, target store.FleetRow, status, result string) (string, string) {
	c, yes, err := s.launchContract(op)
	if !yes || status != "succeeded" {
		return status, result
	}
	var body struct {
		Receipt struct {
			launchContract
			ActualProvider string  `json:"actual_provider"`
			NativeSession  string  `json:"native_session"`
			PID            int     `json:"pid"`
			Birth          string  `json:"birth"`
			Executable     string  `json:"executable"`
			Phase          string  `json:"phase"`
			ObservedAt     float64 `json:"observed_at"`
		} `json:"launch_receipt"`
	}
	bad := func(why string) (string, string) {
		b, _ := json.Marshal(map[string]any{"error": map[string]string{"code": "UNKNOWN_OUTCOME", "message": why}})
		return "unknown", string(b)
	}
	if err != nil || json.Unmarshal([]byte(result), &body) != nil {
		return bad("launch receipt unavailable")
	}
	r := body.Receipt
	if r.launchContract != c || r.ActualProvider != c.Provider || !fleetid.IsUUID(r.NativeSession) || r.PID <= 0 || r.Birth == "" || r.Executable == "" || r.ObservedAt <= 0 ||
		(r.Phase != "delivered" && r.Phase != "ready" && r.Phase != "resumed") {
		return bad("launch receipt does not prove accepted process/native session identity")
	}
	current, err := s.Store.FleetTask(store.ParseTaskRef(c.Task))
	if err != nil || current.Generation != c.Generation || current.ExecutionOwner != c.WorkerID || current.ExecutionEndpoint != target.EndpointID {
		return bad("launch receipt belongs to an old owner/generation")
	}
	// A launch receipt never changes a terminal task outcome.
	if current.Outcome != "" {
		return status, result
	}
	proof, _ := json.Marshal(r)
	digest := sha256.Sum256(proof)
	_, err = s.Store.MutateFleetTask(store.ParseTaskRef(c.Task), c.Owner, store.TaskMutation{
		Key: fmt.Sprintf("launch-verified:%s:%x", op.ID, digest[:8]), Kind: "transition", ExpectedWorker: c.WorkerID,
		Generation: c.Generation, EndpointID: target.EndpointID, FleetID: target.FleetID,
		State: store.TaskRunning, ActualAgent: r.ActualProvider, Evidence: string(proof),
	}, time.Now())
	if err != nil {
		return bad(fmt.Sprintf("launch receipt fenced: %v", err))
	}
	return status, result
}
