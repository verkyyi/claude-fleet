package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// Proof includes prior native epochs; unlike a claim/stop it is not a small
// command. Keep it bounded without the 16 KiB limit truncating ordinary history.
const taskSessionExitBodyLimit = 1 << 20

type taskExitProcess struct {
	PID   int64  `json:"pid"`
	Birth string `json:"birth"`
}

type taskExitRoot struct {
	taskExitProcess
	Component           string `json:"component"`
	Evidence            string `json:"evidence"`
	ObservedKernelBirth string `json:"observed_kernel_birth,omitempty"`
	KernelState         string `json:"kernel_state,omitempty"`
}

// This is the transport shape returned by prove_native_session_exit. The node
// verifies kernel identity, registration barriers and all registered epochs;
// Hub preserves that attestation, never pretends to inspect a remote kernel.
type taskNativeExitProof struct {
	Scope    string                      `json:"scope"`
	Snapshot store.TaskExecutionSnapshot `json:"snapshot"`
	Provider string                      `json:"provider"`
	LaunchID string                      `json:"launch_id"`
	Launches []struct {
		LaunchID string         `json:"launch_id"`
		Roots    []taskExitRoot `json:"roots"`
	} `json:"launches"`
	Wrapper    taskExitProcess `json:"wrapper"`
	ObservedAt float64         `json:"observed_at"`
}

func (p taskNativeExitProof) validShape() bool {
	if p.Scope != "native_session" || !codingAgentOK(p.Provider) || p.LaunchID == "" || len(p.Launches) == 0 ||
		p.Launches[len(p.Launches)-1].LaunchID != p.LaunchID || p.Wrapper.PID <= 1 || p.Wrapper.Birth == "" || p.ObservedAt <= 0 {
		return false
	}
	launchIDs := make(map[string]bool, len(p.Launches))
	for i, launch := range p.Launches {
		if launch.LaunchID == "" || launchIDs[launch.LaunchID] || len(launch.Roots) == 0 {
			return false
		}
		launchIDs[launch.LaunchID] = true
		components := make(map[string]bool, len(launch.Roots))
		for _, root := range launch.Roots {
			if root.PID <= 1 || root.Birth == "" || components[root.Component] {
				return false
			}
			switch root.Component {
			case "supervisor", "child", "agent", "server", "client":
			default:
				return false
			}
			components[root.Component] = true
			switch root.Evidence {
			case "pid_absent":
			case "pid_reused":
				if root.ObservedKernelBirth == "" {
					return false
				}
			case "kernel_zombie":
				if root.ObservedKernelBirth == "" || root.KernelState != "Z" {
					return false
				}
			default:
				return false
			}
		}
		// Historical epochs can stop before native registration finishes, or
		// belong to a previous provider. Their supervisor and child are still
		// mandatory, and a single epoch cannot mix native provider components.
		if !components["supervisor"] || !components["child"] ||
			components["agent"] && (components["server"] || components["client"]) {
			return false
		}
		if i == len(p.Launches)-1 {
			switch p.Provider {
			case "claude":
				if components["server"] || components["client"] {
					return false
				}
			case "codex":
				if components["agent"] {
					return false
				}
			}
		}
	}
	return true
}

// POST /v1/node/tasks/<ref>/execution/exit. Only handleNodeTasks' authenticated
// node road reaches here. Owner and endpoint are derived from that credential;
// the snapshot is an asserted historical context, never a bearer grant.
func (s *Server) nodeTaskSessionExit(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner string, t store.FleetTask) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var in struct {
		Version int                 `json:"control_version"`
		Key     string              `json:"idempotency_key"`
		Proof   taskNativeExitProof `json:"proof"`
	}
	if !taskExecutionBodyLimit(w, r, &in, taskSessionExitBodyLimit) {
		return
	}
	if in.Version != 1 || !idemRE.MatchString(in.Key) || !in.Proof.validShape() {
		httpError(w, http.StatusBadRequest, "a bounded native_session exit proof and idempotency_key are required")
		return
	}
	proof := in.Proof
	snapshot := proof.Snapshot
	if snapshot.ExecutionEndpoint != ep.ID {
		httpError(w, http.StatusNotFound, "no task execution on this node")
		return
	}
	if snapshot.TaskRef != t.Ref || snapshot.TaskFID != t.FID || snapshot.BindingGeneration < 1 ||
		snapshot.Generation <= snapshot.BindingGeneration || snapshot.Generation-1 != snapshot.BindingGeneration || snapshot.CancelRequest == "" {
		taskWriteError(w, store.ErrTaskFence)
		return
	}
	_, session, err := fleetid.ParseWorkerID(snapshot.ExecutionOwner)
	if err != nil || !fleetid.IsUUID(session) {
		taskWriteError(w, store.ErrTaskInvalid)
		return
	}
	// Store authenticates the endpoint against the exact binding and immutable
	// start/stop history. Current inventory may have moved or disappeared, and
	// must neither revoke an original receipt nor grant it to a new endpoint.
	evidence, err := json.Marshal(proof)
	if err != nil {
		taskWriteError(w, store.ErrTaskInvalid)
		return
	}
	receipt := store.TaskSessionExitReceipt{TaskFID: t.FID, Task: t.Ref, Owner: owner,
		ExecutionOwner: snapshot.ExecutionOwner, ExecutionEndpoint: ep.ID,
		Generation: snapshot.BindingGeneration, AttemptID: snapshot.AttemptID,
		StartOperationID: snapshot.OperationID, StopOperationID: snapshot.CancelRequest,
		LaunchID: proof.LaunchID, Scope: proof.Scope, Evidence: evidence}
	_, op, err := s.Store.RecordTaskSessionExit(receipt, in.Key, time.Now())
	if err != nil {
		taskWriteError(w, err)
		return
	}
	// Return the immutable receipt, not the task's possibly newer binding.
	writeJSON(w, http.StatusOK, map[string]any{"control_version": 1, "scope": "native_session",
		"execution_exit_confirmed": true, "operation": operationView(op)})
}
