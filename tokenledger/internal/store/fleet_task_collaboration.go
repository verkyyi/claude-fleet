package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// The task graph and result history extend T records and the operation journal.
// Neither a local issue key nor a transport acknowledgement is a task result.
func (s *Store) bindTaskParentTx(tx *sql.Tx, child *FleetTask) error {
	var parent FleetTask
	var err error
	if child.ParentTask != "" {
		parent, err = s.taskInTx(tx, ParseTaskRef(child.ParentTask))
	} else if child.ParentSession != "" {
		var id int64
		err = tx.QueryRow(`SELECT id FROM fleet_tasks WHERE owner = ? AND authority_version = 1 AND execution_owner = ? ORDER BY id DESC LIMIT 1`, child.Owner, child.ParentSession).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		} // a pinned legacy parent
		if err == nil {
			parent, err = s.taskInTx(tx, id)
		}
	} else {
		return nil
	}
	if err != nil {
		return err
	}
	if parent.Owner != child.Owner {
		return ErrTaskFence
	}
	if parent.AuthorityVersion == 0 {
		return nil
	}
	if parent.ExecutionOwner == "" || taskTerminal(parent.State) || (child.ParentSession != "" && child.ParentSession != parent.ExecutionOwner) {
		return ErrTaskFence
	}
	child.ParentTask, child.ParentSession, child.ParentGeneration = parent.Ref, parent.ExecutionOwner, parent.Generation
	return nil
}

func (s *Store) FleetTaskChildren(owner, parent, session string, generation int64) ([]FleetTask, error) {
	rows, err := s.read.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE owner = ? AND authority_version = 1 AND parent_task = ? AND parent_session = ? AND parent_generation = ? ORDER BY id`, owner, parent, session, generation)
	if err != nil {
		return nil, err
	}
	out, err := scanFleetTasks(rows)
	if out == nil {
		out = []FleetTask{}
	}
	return out, err
}

// TaskReport is the node's explicit result, independently scoped to the child
// and to its accepted parent. Success/failure finalize work even while the native
// session is retained. ExecutionStopped confirms runtime stop/fencing: cancellation
// requires it; success/failure only release the execution lease when it is present.
type TaskReport struct {
	EventID          string `json:"event_id"`
	Task             string `json:"task"`
	Owner            string `json:"owner"`
	TicketRef        string `json:"ticket_ref"`
	Generation       int64  `json:"generation"`
	WorkerID         string `json:"worker_id"`
	ParentTask       string `json:"parent_task"`
	ParentSession    string `json:"parent_session"`
	ParentGeneration int64  `json:"parent_generation"`
	Outcome          string `json:"outcome"`
	Status           string `json:"status,omitempty"`
	Evidence         string `json:"evidence"`
	Summary          string `json:"summary,omitempty"`
	ExecutionStopped bool   `json:"execution_stopped"`
	CancelRequest    string `json:"cancel_request,omitempty"`
}

type TaskReportReceipt struct {
	Report      TaskReport `json:"report"`
	Task        FleetTask  `json:"task"`
	Disposition string     `json:"disposition"` // progress | committed | historical
}

func (s *Store) RecordFleetTaskReport(owner, endpoint string, r TaskReport, now time.Time) (TaskReportReceipt, error) {
	empty := TaskReportReceipt{}
	if r.EventID == "" || len(r.EventID) > 200 || ParseTaskRef(r.Task) == 0 || r.Generation < 1 || r.Evidence == "" || endpoint == "" ||
		(r.Outcome != "" && r.Outcome != TaskSucceeded && r.Outcome != TaskFailed && r.Outcome != TaskCancelled) {
		return empty, ErrTaskInvalid
	}
	if r.Outcome == "" && (r.Status == "" || r.ExecutionStopped) {
		return empty, ErrTaskInvalid
	}
	if r.Owner != owner {
		return empty, ErrTaskFence
	}
	tx, err := s.write.Begin()
	if err != nil {
		return empty, err
	}
	defer tx.Rollback()
	if err = s.d.claimWrites(tx, "fleet_tasks"); err != nil {
		return empty, err
	}
	t, err := s.taskInTx(tx, ParseTaskRef(r.Task))
	if err != nil {
		return empty, err
	}
	if t.Owner != owner || t.AuthorityVersion != 1 {
		return empty, ErrTaskFence
	}
	// Validate against the ORIGINAL attempt even for a stale report. A foreign
	// endpoint or guessed task cannot pollute another owner's history.
	attempt := t
	if t.Generation != r.Generation {
		var raw string
		if err = tx.QueryRow(`SELECT result FROM fleet_operations WHERE id = ? AND action = 'task_attempt'`, taskAttemptID(t.ID, r.Generation)).Scan(&raw); err != nil {
			return empty, ErrTaskFence
		}
		if err = json.Unmarshal([]byte(raw), &attempt); err != nil {
			return empty, err
		}
	}
	if attempt.ExecutionOwner == "" || attempt.ExecutionOwner != r.WorkerID || attempt.ExecutionEndpoint != endpoint || attempt.TicketRef != r.TicketRef ||
		attempt.ParentTask != r.ParentTask || attempt.ParentSession != r.ParentSession || attempt.ParentGeneration != r.ParentGeneration {
		return empty, ErrTaskFence
	}
	raw, _ := json.Marshal(struct {
		Report   TaskReport
		Endpoint string
	}{r, endpoint})
	idem := "task-report:" + r.Task + ":" + r.EventID
	var oldRequest, oldResult string
	err = tx.QueryRow(`SELECT request, result FROM fleet_operations WHERE actor = ? AND idem = ?`, owner, idem).Scan(&oldRequest, &oldResult)
	if err == nil {
		if oldRequest != string(raw) {
			return empty, ErrTaskConflict
		}
		var old TaskReportReceipt
		if err = json.Unmarshal([]byte(oldResult), &old); err != nil {
			return empty, err
		}
		return old, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return empty, err
	}
	disposition := "progress"
	if t.Generation != r.Generation || taskTerminal(t.State) {
		disposition = "historical"
	} else if r.Outcome != "" {
		if !taskTransition(t.State, r.Outcome) {
			return empty, ErrTaskConflict
		}
		if r.Outcome == TaskCancelled && (!r.ExecutionStopped || t.CancelRequest == "" || r.CancelRequest != t.CancelRequest) {
			return empty, ErrTaskConflict
		}
		t.State, t.Outcome, t.Evidence, t.UpdatedAt = r.Outcome, r.Outcome, r.Evidence, now.UTC()
		if r.ExecutionStopped {
			if err = releaseTaskLeaseTx(tx, t); err != nil {
				return empty, err
			}
		}
		if err = s.saveTaskTx(tx, t, now); err != nil {
			return empty, err
		}
		if err = taskAttemptResultTx(tx, t, now); err != nil {
			return empty, err
		}
		disposition = "committed"
	}
	receipt := TaskReportReceipt{r, t, disposition}
	result, _ := json.Marshal(receipt)
	id := fmt.Sprintf("task-report:%x", sha256.Sum256([]byte(owner+"\x00"+idem)))
	ts := now.UTC().Format(rfc)
	_, err = tx.Exec(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated, result, worker_id)
        VALUES (?, '', 'task_report', ?, ?, ?, 'recorded', ?, ?, ?, ?)`, id, string(raw), owner, idem, ts, ts, string(result), r.WorkerID)
	if err != nil {
		return empty, err
	}
	return receipt, tx.Commit()
}

// Recheck at delivery, too: an accepted relay can wait across a parent transfer.
// Generation is distinct from the lifelong session ID retained by that transfer.
func (s *Store) TaskReportDeliverable(r TaskReport) (bool, error) {
	t, err := s.FleetTask(ParseTaskRef(r.Task))
	if err != nil {
		return false, err
	}
	if t.Owner != r.Owner || t.Generation != r.Generation || t.ExecutionOwner != r.WorkerID || t.Outcome != r.Outcome || t.ParentSession != r.ParentSession || t.ParentTask != r.ParentTask || t.ParentGeneration != r.ParentGeneration {
		return false, nil
	}
	if r.ParentTask == "" {
		return r.ParentSession != "", nil
	}
	p, err := s.FleetTask(ParseTaskRef(r.ParentTask))
	if err != nil {
		return false, err
	}
	return p.Owner == r.Owner && p.Generation == r.ParentGeneration && p.ExecutionOwner == r.ParentSession && !taskTerminal(p.State), nil
}

// A downlevel relay from an accepted execution cannot bypass task fencing.
// Attempt history keeps this true after transfer, too; legacy sessions have no
// entry here and continue through their existing report route.
func (s *Store) TaskExecutionKnown(owner, worker string) (bool, error) {
	var count int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_attempt' AND actor = ? AND worker_id = ?`, owner, worker).Scan(&count)
	return count > 0, err
}
