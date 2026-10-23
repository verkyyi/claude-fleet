package store

import (
	"database/sql"
	"encoding/json"
	"errors"
)

// TaskContinuation names exactly one immutable proof. A never-claimed stop is
// not a native exit; its workspace ancestry is read separately from the Hub.
type TaskContinuation struct {
	Version         int    `json:"version"`
	ExitOperationID string `json:"exit_operation_id,omitempty"`
	StopOperationID string `json:"stop_operation_id,omitempty"`
}

// TaskContinuationIntent is immutable journal metadata, not a node argument.
// A nil RequestedAgent means "use the preceding start's provider", not the
// user's possibly changed default. Preserve this distinction on replay.
type TaskContinuationIntent struct {
	Task                    string  `json:"task"`
	ExpectedStopOperationID string  `json:"expected_stop_operation_id"`
	ExpectedGeneration      int64   `json:"expected_generation"`
	RequestedAgent          *string `json:"requested_agent"`
}

type TaskStartMetadata struct {
	OperationID  string            `json:"operation_id"`
	Agent        string            `json:"agent"`
	Repo         string            `json:"repo"`
	NoRepo       bool              `json:"no_repo"`
	Continuation *TaskContinuation `json:"continuation,omitempty"`
}

type TaskExecutionStart struct {
	Version       int                   `json:"control_version"`
	TaskExecution TaskExecutionSnapshot `json:"task_execution"`
	Start         TaskStartMetadata     `json:"start"`
	// LOCAL starts may never enter the node control journal. This is the
	// immediate immutable start selected by the stop or accepted exit proof.
	SourceStart     *TaskStartMetadata     `json:"source_start,omitempty"`
	SourceStop      *TaskExecutionSnapshot `json:"source_stop,omitempty"`
	WorkspaceSource *TaskWorkspaceSource   `json:"workspace_source,omitempty"`
}

type TaskWorkspaceSource struct {
	// Workspace/history provenance only; never this generation's exit proof.
	ExitOperationID string            `json:"exit_operation_id"`
	Start           TaskStartMetadata `json:"start"`
}

type TaskContinuationSource struct {
	Task            FleetTask
	ExitOperationID string
	StopOperationID string
	Endpoint        string
	Receipt         TaskSessionExitReceipt
	Start           FleetOperation
	Agent           string
}

func taskStartMetadata(o FleetOperation) (TaskStartMetadata, *TaskContinuationIntent, error) {
	var r struct {
		Intent *TaskContinuationIntent `json:"continuation_intent"`
		Params struct {
			Repo     string `json:"repo"`
			NoRepo   bool   `json:"no_repo"`
			Agent    string `json:"agent"`
			Dispatch struct {
				Agent string `json:"resolved_agent"`
			} `json:"dispatch"`
			Continuation json.RawMessage `json:"continuation"`
		} `json:"params"`
	}
	var m TaskStartMetadata
	if o.Action != "worker_start" || !taskExecutionVersion(o.Request) || json.Unmarshal([]byte(o.Request), &r) != nil ||
		(r.Params.Agent != "claude" && r.Params.Agent != "codex") || r.Params.Agent != r.Params.Dispatch.Agent || r.Params.NoRepo && r.Params.Repo != "" {
		return m, nil, ErrTaskFence
	}
	var continuation *TaskContinuation
	if len(r.Params.Continuation) != 0 {
		var c TaskContinuation
		if json.Unmarshal(r.Params.Continuation, &c) != nil {
			return m, nil, ErrTaskFence
		}
		continuation = &c
	}
	if continuation == nil && r.Intent != nil {
		return m, nil, ErrTaskFence
	}
	m = TaskStartMetadata{OperationID: o.ID, Agent: r.Params.Agent, Repo: r.Params.Repo, NoRepo: r.Params.NoRepo, Continuation: continuation}
	return m, r.Intent, nil
}

// TaskContinuationSource reads the last stopped binding in one transaction.
// ContinueTaskExecution repeats this check while committing the new start.
func (s *Store) TaskContinuationSource(taskID int64, owner string) (TaskContinuationSource, error) {
	var source TaskContinuationSource
	tx, err := s.write.Begin()
	if err != nil {
		return source, err
	}
	defer tx.Rollback()
	t, err := s.taskInTx(tx, taskID)
	if err != nil {
		return source, err
	}
	// Historical State/Outcome do not authorize or forbid explicit continuation.
	// The exact stopped binding and its immutable proof chain below do.
	if owner == "" || t.Owner != owner {
		return source, ErrTaskFence
	}
	source, err = taskContinuationSourceTx(tx, t)
	if err != nil {
		return source, err
	}
	m, _, err := taskStartMetadata(source.Start)
	if err != nil {
		return source, err
	}
	source.Agent = m.Agent
	return source, tx.Commit()
}

// ContinueTaskExecution is the user's first, same-endpoint continuation slice.
// The general ResumeTaskExecution contract (including cross-node callers) is
// unchanged. This method requires an explicit immutable continuation intent.
func (s *Store) ContinueTaskExecution(o FleetOperation, endpoint string) (FleetTask, error) {
	m, intent, err := taskStartMetadata(o)
	if err != nil || o.Actor == "" || o.Actor != o.TaskOwner || o.WorkerID != "" || m.Continuation == nil || intent == nil || intent.Task == "" ||
		intent.ExpectedStopOperationID == "" || intent.ExpectedGeneration < 2 ||
		intent.RequestedAgent != nil && *intent.RequestedAgent != m.Agent {
		return FleetTask{}, ErrTaskInvalid
	}
	return s.authorizeTaskExecution(o, endpoint, m.Continuation.ExitOperationID, intent)
}

func validateTaskContinuationTx(tx *sql.Tx, t FleetTask, o FleetOperation, endpoint string, intent TaskContinuationIntent) error {
	if intent.Task != t.Ref || intent.ExpectedGeneration != t.Generation || intent.ExpectedStopOperationID != t.CancelRequest {
		return ErrTaskFence
	}
	source, err := taskContinuationSourceTx(tx, t)
	if err != nil {
		return err
	}
	if source.Endpoint != endpoint || source.Start.FleetID != o.FleetID {
		return ErrTaskFence
	}
	previous, _, err := taskStartMetadata(source.Start)
	if err != nil {
		return err
	}
	next, _, err := taskStartMetadata(o)
	if err != nil {
		return err
	}
	if next.Continuation == nil || next.Continuation.ExitOperationID != source.ExitOperationID || next.Continuation.StopOperationID != source.StopOperationID {
		return ErrTaskFence
	}
	if next.Repo != previous.Repo || next.NoRepo != previous.NoRepo || intent.RequestedAgent == nil && next.Agent != previous.Agent {
		return ErrTaskFence
	}
	return nil
}

// TaskExecutionStart keeps the existing bare snapshot schema intact. Endpoint
// authentication is checked in this transaction too, not only by the API's
// preceding lookup; no cross-node change can leak the new binding's metadata.
func (s *Store) TaskExecutionStart(taskID int64, owner, endpoint string) (TaskExecutionStart, error) {
	var result TaskExecutionStart
	tx, err := s.write.Begin()
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	t, err := s.taskInTx(tx, taskID)
	if errors.Is(err, sql.ErrNoRows) {
		return result, ErrTaskFence
	}
	if err != nil {
		return result, err
	}
	if endpoint == "" || t.ExecutionEndpoint != endpoint {
		return result, ErrTaskFence
	}
	result.TaskExecution, err = taskExecutionSnapshotTx(tx, t, owner)
	if err != nil {
		return result, err
	}
	op, _, _, _, err := executionOperationTx(tx, t.OperationID)
	if err != nil {
		return result, err
	}
	result.Start, _, err = taskStartMetadata(op)
	if err != nil {
		return result, err
	}
	if result.Start.Continuation != nil || result.TaskExecution.BindingGeneration > 1 {
		chain, e := taskContinuationChainTx(tx, t, op, endpoint)
		if e != nil {
			return result, e
		}
		result.SourceStart, result.SourceStop, result.WorkspaceSource = chain.SourceStart, chain.SourceStop, chain.WorkspaceSource
	}
	result.Version = 1
	return result, tx.Commit()
}
