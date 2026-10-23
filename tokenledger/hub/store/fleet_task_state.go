package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// A task record's state is what it is (EPIC T644 C6 «记录的状态和实际一致»).
// Before C6 a record's end lived only on its ID: the hub projected it onto the
// record at read time (taskViews off IDTaskOutcome), so every reader that read
// the row — a list query, a count, the 「没结束」 set — saw an ended task as
// still going (T622). Now the record's columns are the one source:
//
//   - write-through: the moment an ID's ending result lands (fleet_id_results,
//     ApplyFleetIDEvents), the same transaction writes the record that ID carries
//     — its state and outcome (merged / succeeded / done → succeeded, failed →
//     failed), its pr when it had none, and `observation = id_result:<id>#<seq>`.
//     A newer ending result of the same task replaces one written this way (a
//     retry that succeeds after a failure); an end written by anything else (a
//     cancel, a refusal, a pre-switch report) is never overwritten.
//   - ReconcileTaskStates: what the write-through did not see — records ended
//     before it existed (their result is already on the ID), and the unfinished
//     records left from before the switch with no live session (cancelled,
//     `observation = reconcile_cancel:<old state>`, undoable). Dry by default,
//     idempotent, nothing deleted.
//
// IDTaskOutcome stays as the cancel check's reader (unopenedCancelAllowed) and the
// migration's; no view projects it any more.

// ObsIDResult marks an end written through from an ID's result.
const ObsIDResult = "id_result:"

// ObsReconcileCancel marks a legacy record the reconcile cancelled; the old
// state follows the colon (the undo puts it back).
const ObsReconcileCancel = "reconcile_cancel:"

// idResultOutcome maps an ID result's state to the task outcome it ends with;
// "" for a result that does not end work (blocked, waiting, …).
func idResultOutcome(state string) string {
	switch state {
	case "merged", "succeeded", "done":
		return TaskSucceeded
	case "failed":
		return TaskFailed
	}
	return ""
}

// taskRefsOf lists the record numbers an ID carries by name: its `task` (T<n>)
// and a migration's aliases.
func taskRefsOf(task string, aliases []string) []int64 {
	var out []int64
	for _, ref := range append([]string{task}, aliases...) {
		if n := ParseTaskRef(ref); n > 0 {
			out = append(out, n)
		}
	}
	return out
}

// writeTaskResult writes an ID's ending result onto the records it carries —
// owner's, whose ID is fid (the task's own, C1) or whose number the ID names —
// unless one already ended by other means. It returns how many it wrote.
func writeTaskResult(tx *sql.Tx, owner, id, taskID string, refs []int64, state, pr string, seq int, now time.Time) (int64, error) {
	out := idResultOutcome(state)
	if out == "" {
		return 0, nil
	}
	where, args := []string{"fid = ?"}, []any{id}
	if taskID != "" {
		where, args = append(where, "fid = ?"), append(args, taskID)
	}
	for _, n := range refs {
		where, args = append(where, "id = ?"), append(args, n)
	}
	projection, args, err := legacyTaskProjection(tx, owner, strings.Join(where, " OR "), args)
	if err != nil {
		return 0, err
	}
	q := `UPDATE fleet_tasks SET state = ?, outcome = ?, pr = CASE WHEN pr = '' THEN ? ELSE pr END,
		observation = ?, evidence = CASE WHEN evidence LIKE ? THEN '' ELSE evidence END, updated_at = ? WHERE owner = ? AND (` + projection + `)
		AND (((outcome = '' OR observation LIKE ?) AND state NOT IN (?, ?, ?)) OR observation LIKE ? OR observation LIKE ?)`
	// an end its session's close wrote (A4G2: id_closed / never_started) gives way to a real result
	res, err := tx.Exec(q, append([]any{out, out, pr, ObsIDResult + id + "#" + strconv.Itoa(seq), TaskEndedNoResult + "%",
		now.UTC().Format(rfc), owner},
		append(args, ObsIDResult+"%", TaskCancelled, TaskRefused, TaskClosed, ObsIDClosed+"%", ObsNeverStarted+"%")...)...)
	if err != nil {
		return 0, fmt.Errorf("write the result onto its task: %w", err)
	}
	return res.RowsAffected()
}

// TaskReconcile is what ReconcileTaskStates did (or, dry, would do).
type TaskReconcile struct {
	Apply bool `json:"apply"`
	// Before is the cutoff of the legacy half: records numbered below it
	// (T<n>); 0 when that half did not run.
	Before int64 `json:"before"`
	// Unfinished is how many of owner's records were unfinished before, and
	// Left how many are (would be) after.
	Unfinished int `json:"unfinished"`
	Left       int `json:"left"`
	// Ended: records whose ID already carries an ending result.
	Ended int `json:"ended"`
	// Cancelled: legacy records with no live session.
	Cancelled int `json:"cancelled"`
	// Kept: legacy records still held by something (reason → count).
	Kept  map[string]int      `json:"kept"`
	Items []TaskReconcileItem `json:"items"`
}

// TaskReconcileItem is one record that moved (or would).
type TaskReconcileItem struct {
	Task  string `json:"task"`
	Short string `json:"short,omitempty"`
	From  string `json:"from"`
	To    string `json:"to"`
	Why   string `json:"why"`
}

// ReconcileTaskStates brings owner's records ("" = everyone's) in line with
// what happened: every unfinished record whose ID already carries an ending
// result takes it (as the write-through would have), then — before > 0 — every
// unfinished record numbered below T<before> that no live session holds is
// cancelled. Live = an open ID carrying it, or (for one with a worker) a lease,
// an unclosed local start or a row in its fleet's inventory (fleet_task_settle's
// worker half). apply false writes nothing. Running it twice changes nothing
// the second time.
func (s *Store) ReconcileTaskStates(owner string, before int64, apply bool, now time.Time) (TaskReconcile, error) {
	out := TaskReconcile{Apply: apply, Before: before, Kept: map[string]int{}, Items: []TaskReconcileItem{}}
	q, args := `SELECT `+fleetTaskCols+` FROM fleet_tasks`, []any{}
	if owner != "" {
		q, args = q+` WHERE owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(q+` ORDER BY id`, args...)
	if err != nil {
		return out, err
	}
	all, err := scanFleetTasks(rows)
	if err != nil {
		return out, err
	}
	for _, t := range all {
		protected, err := taskProjectionProtected(s.read, t)
		if err != nil {
			return out, err
		}
		if protected {
			continue
		}
		if taskFinished(t.State) {
			continue
		}
		out.Unfinished++
		res, err := s.taskEndingResult(t)
		if err != nil {
			return out, err
		}
		if res.outcome != "" {
			out.Ended++
			out.Items = append(out.Items, TaskReconcileItem{Task: t.Ref, Short: t.Short, From: t.State, To: res.outcome,
				Why: "编号 " + res.id + " 已有结果 " + res.state})
			if apply {
				if err := s.reconcileWrite(t, func(tx *sql.Tx) (int64, error) {
					return writeTaskResult(tx, t.Owner, res.id, "", []int64{t.ID}, res.state, res.pr, res.seq, now)
				}); err != nil {
					return out, err
				}
			}
			continue
		}
		if before <= 0 || t.ID >= before {
			out.Left++
			continue
		}
		why, err := s.taskLiveWhy(s.read, t)
		if err != nil {
			return out, err
		}
		if why != "" {
			out.Kept[why]++
			out.Left++
			continue
		}
		out.Cancelled++
		out.Items = append(out.Items, TaskReconcileItem{Task: t.Ref, Short: t.Short, From: t.State, To: TaskCancelled,
			Why: "切换前的旧记录，没有活会话"})
		if apply {
			if err := s.reconcileWrite(t, func(tx *sql.Tx) (int64, error) {
				if why, err := s.taskLiveWhy(tx, t); err != nil || why != "" {
					return 0, err // came alive meanwhile: leave it
				}
				res, err := tx.Exec(`UPDATE fleet_tasks SET state = ?, outcome = ?, observation = ?, updated_at = ?
					WHERE id = ? AND state = ? AND outcome = ''`, TaskCancelled, TaskCancelled,
					ObsReconcileCancel+t.State, now.UTC().Format(rfc), t.ID, t.State)
				if err != nil {
					return 0, err
				}
				return res.RowsAffected()
			}); err != nil {
				return out, err
			}
		}
	}
	return out, nil
}

// UndoReconcileCancel puts back every record of owner's ("" = everyone's) the
// reconcile cancelled: its old state, no outcome. It returns how many.
func (s *Store) UndoReconcileCancel(owner string, now time.Time) (int64, error) {
	q, args := `SELECT id, observation FROM fleet_tasks WHERE observation LIKE ? AND state = ?`, []any{ObsReconcileCancel + "%", TaskCancelled}
	if owner != "" {
		q, args = q+` AND owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return 0, err
	}
	type undo struct {
		id  int64
		obs string
	}
	var todo []undo
	for rows.Next() {
		var u undo
		if err := rows.Scan(&u.id, &u.obs); err != nil {
			rows.Close()
			return 0, err
		}
		todo = append(todo, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	var n int64
	for _, u := range todo {
		task, err := s.FleetTask(u.id)
		if err != nil {
			return n, err
		}
		var changed int64
		err = s.reconcileWrite(task, func(tx *sql.Tx) (int64, error) {
			res, err := tx.Exec(`UPDATE fleet_tasks SET state = ?, outcome = '', observation = '', updated_at = ?
				WHERE id = ? AND observation = ? AND state = ?`, strings.TrimPrefix(u.obs, ObsReconcileCancel),
				now.UTC().Format(rfc), u.id, u.obs, TaskCancelled)
			if err != nil {
				return 0, err
			}
			k, err := res.RowsAffected()
			changed = k
			return k, err
		})
		if err != nil {
			return n, err
		}
		n += changed
	}
	return n, nil
}

func (s *Store) reconcileWrite(t FleetTask, write func(*sql.Tx) (int64, error)) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "fleet_tasks"); err != nil {
		return err
	}
	current, err := s.taskInTx(tx, t.ID)
	if err != nil {
		return err
	}
	protected, err := taskProjectionProtected(tx, current)
	if err != nil {
		return err
	}
	if protected || !sameTaskProjection(t, current) {
		return nil
	}
	if _, err := write(tx); err != nil {
		return fmt.Errorf("reconcile %s: %w", t.Ref, err)
	}
	return tx.Commit()
}

// taskResult is the ending result a record's IDs carry.
type taskResult struct {
	id, state, outcome, pr string
	seq                    int
}

// taskEndingResult reads the newest ending result of the IDs that carry t —
// its own ID (fid), an ID linked to it (task_id), or one naming its number
// (task, a migration's alias); zero when none has one.
func (s *Store) taskEndingResult(t FleetTask) (taskResult, error) {
	var r taskResult
	q := `SELECT r.id, r.state, r.pr, r.seq FROM fleet_id_results r JOIN fleet_ids i ON i.id = r.id
		WHERE i.owner = ? AND (i.task = ? OR i.aliases LIKE ?`
	args := []any{t.Owner, t.Ref, `%"` + t.Ref + `"%`}
	if t.FID != "" {
		q, args = q+` OR i.id = ? OR i.task_id = ?`, append(args, t.FID, t.FID)
	}
	q += `) AND r.state IN ('merged', 'succeeded', 'done', 'failed') ORDER BY r.at DESC, r.seq DESC LIMIT 1`
	err := s.read.QueryRow(q, args...).Scan(&r.id, &r.state, &r.pr, &r.seq)
	if errors.Is(err, sql.ErrNoRows) {
		return taskResult{}, nil
	}
	if err != nil {
		return taskResult{}, err
	}
	r.outcome = idResultOutcome(r.state)
	return r, nil
}

// taskLiveWhy says what still holds t's session; "" when nothing does: an
// open ID carrying it, else its worker's lease / local start / inventory row.
func (s *Store) taskLiveWhy(q querier, t FleetTask) (string, error) {
	_, open, err := idCarrying(q, t.Owner, t.Ref)
	if err != nil {
		return "", err
	}
	if !open && t.FID != "" {
		var n int
		if err := q.QueryRow(`SELECT COUNT(*) FROM fleet_ids WHERE (id = ? OR task_id = ?) AND seq > 0 AND closed_at = 0`,
			t.FID, t.FID).Scan(&n); err != nil {
			return "", err
		}
		open = n > 0
	}
	if open {
		return "open ID", nil
	}
	if t.WorkerID == "" {
		return "", nil
	}
	return legacyWorkerLive(q, NormRepo(t.Repo), t.WorkerID)
}
