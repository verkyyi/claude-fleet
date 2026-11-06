package store

import (
	"database/sql"
	"strings"
	"time"
)

const obsStartFailure = "start_failed:"

// A failed placement is not a work outcome. Keep the accepted request and its
// generation; a delayed failure can never replace an execution or cancellation.
func (t FleetTask) StartFailure() string {
	if strings.HasPrefix(t.Observation, obsStartFailure) {
		return strings.TrimPrefix(t.Observation, obsStartFailure)
	}
	return ""
}

func taskHasNoStartBinding(t FleetTask) bool {
	if t.AuthorityVersion != 1 || t.State != TaskAccepted || t.Outcome != "" || t.CancelRequest != "" ||
		t.WorkerID != "" || t.SessionKey != "" || t.OperationID != "" || t.ExecutionEndpoint != "" || t.ExecutionOwner != "" {
		return false
	}
	return true
}

func (s *Store) taskStartRetryableTx(tx *sql.Tx, t FleetTask) (bool, error) {
	if !taskHasNoStartBinding(t) {
		return false, nil
	}
	if prior, err := taskPriorStartTx(tx, t); err != nil || prior {
		return false, err
	}
	why, err := s.taskLiveWhy(tx, t)
	return why == "" && err == nil, err
}

func (s *Store) TaskStartRetryable(t FleetTask) (bool, error) {
	if !taskHasNoStartBinding(t) {
		return false, nil
	}
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	current, err := s.taskInTx(tx, t.ID)
	if err != nil {
		return false, err
	}
	if current.Owner != t.Owner || current.Generation != t.Generation {
		return false, nil
	}
	return s.taskStartRetryableTx(tx, current)
}

func (s *Store) RecordTaskStartFailure(id int64, owner string, generation int64, reason string, now time.Time) (FleetTask, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > 8000 {
		return FleetTask{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, err
	}
	defer tx.Rollback()
	if err = s.d.claimWrites(tx, "fleet_tasks"); err != nil {
		return FleetTask{}, err
	}
	t, err := s.taskInTx(tx, id)
	if err != nil {
		return FleetTask{}, err
	}
	if t.Owner != owner || t.Generation != generation {
		return FleetTask{}, ErrTaskFence
	}
	ok, err := s.taskStartRetryableTx(tx, t)
	if err != nil {
		return FleetTask{}, err
	}
	if !ok {
		return FleetTask{}, ErrTaskConflict
	}
	t.Observation, t.UpdatedAt = obsStartFailure+reason, now.UTC()
	if _, err = tx.Exec(`UPDATE fleet_tasks SET observation = ?, updated_at = ? WHERE id = ?`, t.Observation, now.UTC().Format(rfc), id); err != nil {
		return FleetTask{}, err
	}
	return t, tx.Commit()
}
