package store

import (
	"database/sql"
	"errors"
	"strings"
)

// ID events have no execution generation. Keep their history, but never use
// them as authority over a controlled Task, even when its worker ID matches.
// Released bindings remain protected by their immutable start operation.
func taskProjectionProtected(q querier, t FleetTask) (bool, error) {
	if t.ExecutionEndpoint != "" || t.ExecutionOwner != "" {
		return true, nil
	}
	if t.OperationID == "" {
		return false, nil
	}
	var request string
	err := q.QueryRow(`SELECT request FROM fleet_operations WHERE id = ?`, t.OperationID).Scan(&request)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return taskExecutionVersion(request), err
}

// Replace a broad historical ID/alias match with exact non-controlled
// snapshots. The final UPDATE compares bindings too: concurrent control
// admission after this read must win over projection.
func legacyTaskProjection(tx *sql.Tx, owner, where string, args []any) (string, []any, error) {
	rows, err := tx.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE owner = ? AND (`+where+`)`, append([]any{owner}, args...)...)
	if err != nil {
		return "", nil, err
	}
	tasks, err := scanFleetTasks(rows)
	if err != nil {
		return "", nil, err
	}
	clauses, values := []string{}, []any{}
	for _, t := range tasks {
		protected, err := taskProjectionProtected(tx, t)
		if err != nil {
			return "", nil, err
		}
		if protected {
			continue
		}
		clauses = append(clauses, `(id = ? AND generation = ? AND operation_id = ? AND attempt_id = ? AND execution_owner = ? AND execution_endpoint = ? AND cancel_request = ? AND state = ? AND outcome = ? AND observation = ?)`)
		values = append(values, t.ID, t.Generation, t.OperationID, t.AttemptID, t.ExecutionOwner, t.ExecutionEndpoint, t.CancelRequest, t.State, t.Outcome, t.Observation)
	}
	if len(clauses) == 0 {
		return "1 = 0", nil, nil
	}
	return "(" + strings.Join(clauses, " OR ") + ")", values, nil
}

func sameTaskProjection(a, b FleetTask) bool {
	return a.Generation == b.Generation && a.OperationID == b.OperationID && a.AttemptID == b.AttemptID &&
		a.ExecutionOwner == b.ExecutionOwner && a.ExecutionEndpoint == b.ExecutionEndpoint && a.CancelRequest == b.CancelRequest &&
		a.State == b.State && a.Outcome == b.Outcome && a.Observation == b.Observation
}
