package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// A record ends when its session ends (claude-fleet A4G2). Before this a
// record ended only through its ID's RESULT (writeTaskResult): a session that
// was reaped, exited and was put away, or never reported closed its ID and
// left the record open for good — 「排着」 on the console until a person
// cleaned it by hand (20 on 2026-10-21). Now:
//
//   - write-through: the moment an ID closes (ApplyFleetIDEvents `closed`) with
//     no ending result, the version-1 records it carries end in the same
//     transaction — cancelled, evidence 「结束·没交回结果（<reason>）」,
//     `observation = id_closed:<id>:<old state>`. A later result still wins
//     (writeTaskResult overwrites an id_closed end), and the ID reopening
//     (`reopened`, or a hub-closed ID taken after all) puts the record back.
//   - ReconcileClosedTasks (the hub's sweep, every taskReconcileEvery): what the
//     write-through did not see — IDs closed before it existed or closed by the
//     hub's own reconcile (hub:gone), and records whose session never came up
//     within TaskNeverStartedAfter (`observation = never_started:<old state>`).
//
// Only version-1 records: an old record's end is its placement's, never read
// off an ID here.

// ObsIDClosed marks a record ended because its session's ID closed with no
// result: id_closed:<id>:<old state>.
const ObsIDClosed = "id_closed:"

// ObsNeverStarted marks a record ended because its session never came up:
// never_started:<old state>.
const ObsNeverStarted = "never_started:"

// TaskNeverStartedAfter is how long a record may wait for its session's ID to
// be taken by a machine before the sweep ends it.
const TaskNeverStartedAfter = 24 * time.Hour

// TaskEndedNoResult is the evidence an ended-without-result record carries.
const TaskEndedNoResult = "结束·没交回结果"

// taskCarryWhere is the WHERE clause naming the records an ID carries: its own
// (fid), the one it is linked to (task_id) and the numbers it names.
func taskCarryWhere(id, taskID string, refs []int64) (string, []any) {
	where, args := []string{"fid = ?"}, []any{id}
	if taskID != "" {
		where, args = append(where, "fid = ?"), append(args, taskID)
	}
	for _, n := range refs {
		where, args = append(where, "id = ?"), append(args, n)
	}
	return "(" + strings.Join(where, " OR ") + ")", args
}

// endTasksOnIDClose ends the unfinished version-1 records an ID carries when it
// closes with no ending result. It returns how many it ended.
func endTasksOnIDClose(tx *sql.Tx, owner, id, taskID string, refs []int64, reason string, now time.Time) (int64, error) {
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_id_results WHERE id = ? AND state IN ('merged', 'succeeded', 'done', 'failed')`,
		id).Scan(&n); err != nil {
		return 0, err
	}
	if n > 0 {
		return 0, nil // its result already ended the record (writeTaskResult)
	}
	where, args := taskCarryWhere(id, taskID, refs)
	return endTasks(tx, owner, where, args, ObsIDClosed+id+":", noResultEvidence(reason), now)
}

func noResultEvidence(reason string) string {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return TaskEndedNoResult
	}
	if len(reason) > 120 {
		reason = reason[:120]
	}
	return TaskEndedNoResult + "（" + reason + "）"
}

// endTasks cancels owner's unfinished version-1 records matching where, each
// with observation prefix + its old state and evidence when it had none.
func endTasks(tx *sql.Tx, owner, where string, args []any, prefix, evidence string, now time.Time) (int64, error) {
	q := `UPDATE fleet_tasks SET observation = CAST(? AS TEXT) || state, state = ?, outcome = ?,
		evidence = CASE WHEN evidence = '' THEN ? ELSE evidence END, updated_at = ?
		WHERE owner = ? AND authority_version = ? AND outcome = '' AND state NOT IN (?, ?, ?, ?, ?) AND ` + where
	res, err := tx.Exec(q, append([]any{prefix, TaskCancelled, TaskCancelled, evidence, now.UTC().Format(rfc), owner,
		TaskAuthorityVersion, TaskSucceeded, TaskFailed, TaskCancelled, TaskRefused, TaskClosed}, args...)...)
	if err != nil {
		return 0, fmt.Errorf("end the record its session left: %w", err)
	}
	return res.RowsAffected()
}

// reopenTasksOnID puts back the records an ID's close ended, when the same ID
// goes on (`reopened`, or a hub-closed ID taken after all).
func reopenTasksOnID(tx *sql.Tx, owner, id string, now time.Time) error {
	_, err := tx.Exec(`UPDATE fleet_tasks SET state = SUBSTR(observation, CAST(? AS INTEGER)), outcome = '',
		evidence = CASE WHEN evidence LIKE ? THEN '' ELSE evidence END, observation = '', updated_at = ?
		WHERE owner = ? AND observation LIKE ? AND state = ?`,
		len(ObsIDClosed+id+":")+1, TaskEndedNoResult+"%", now.UTC().Format(rfc), owner, ObsIDClosed+id+":%", TaskCancelled)
	return err
}

// TaskCloseSweep is what one ReconcileClosedTasks did.
type TaskCloseSweep struct {
	Unfinished   int                 `json:"unfinished"`
	Closed       int                 `json:"closed"`
	NeverStarted int                 `json:"never_started"`
	Items        []TaskReconcileItem `json:"items"`
}

// ReconcileClosedTasks ends every unfinished version-1 record (owner's; ""
// everyone's) whose session is over: every ID carrying it has closed with no
// ending result (an ID's result is writeTaskResult's), or none was ever taken
// by a machine within TaskNeverStartedAfter of the record. apply false writes
// nothing. Idempotent.
func (s *Store) ReconcileClosedTasks(owner string, apply bool, now time.Time) (TaskCloseSweep, error) {
	out := TaskCloseSweep{Items: []TaskReconcileItem{}}
	q := `SELECT ` + fleetTaskCols + ` FROM fleet_tasks WHERE authority_version = ? AND outcome = ''`
	args := []any{TaskAuthorityVersion}
	if owner != "" {
		q, args = q+` AND owner = ?`, append(args, owner)
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
		if taskFinished(t.State) {
			continue
		}
		out.Unfinished++
		ids, err := s.idsCarrying(t)
		if err != nil {
			return out, err
		}
		opened, open, closedID, reason, last := 0, 0, "", "", int64(0)
		for _, i := range ids {
			if i.seq == 0 {
				continue
			}
			opened++
			if i.closedAt == 0 {
				open++
			} else if i.closedAt >= last {
				closedID, reason, last = i.id, i.reason, i.closedAt
			}
		}
		switch {
		case open > 0:
			continue
		case opened > 0:
			res, err := s.taskEndingResult(t)
			if err != nil {
				return out, err
			}
			if res.outcome != "" {
				continue // ReconcileTaskStates' half: the result is the end
			}
			out.Closed++
			out.Items = append(out.Items, TaskReconcileItem{Task: t.Ref, Short: t.Short, From: t.State, To: TaskCancelled,
				Why: "会话已结束（" + reason + "），没交回结果"})
			if apply {
				id := closedID
				if err := s.reconcileWrite(t, func(tx *sql.Tx) (int64, error) {
					return endTasks(tx, t.Owner, "id = ?", []any{t.ID}, ObsIDClosed+id+":", noResultEvidence(reason), now)
				}); err != nil {
					return out, err
				}
			}
		case now.Sub(t.CreatedAt) > TaskNeverStartedAfter:
			out.NeverStarted++
			out.Items = append(out.Items, TaskReconcileItem{Task: t.Ref, Short: t.Short, From: t.State, To: TaskCancelled,
				Why: "开了 24 小时会话还没起来"})
			if apply {
				if err := s.reconcileWrite(t, func(tx *sql.Tx) (int64, error) {
					return endTasks(tx, t.Owner, "id = ?", []any{t.ID}, ObsNeverStarted, "会话一直没起来", now)
				}); err != nil {
					return out, err
				}
			}
		}
	}
	return out, nil
}

type idState struct {
	id, reason string
	seq        int
	closedAt   int64
}

// idsCarrying lists the IDs that carry t: its own (fid), one linked to it
// (task_id), one naming its number.
func (s *Store) idsCarrying(t FleetTask) ([]idState, error) {
	q := `SELECT id, seq, closed_at, close_reason FROM fleet_ids WHERE owner = ? AND (task = ?`
	args := []any{t.Owner, t.Ref}
	if t.FID != "" {
		q, args = q+` OR id = ? OR task_id = ?`, append(args, t.FID, t.FID)
	}
	rows, err := s.read.Query(q+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []idState
	for rows.Next() {
		var i idState
		if err := rows.Scan(&i.id, &i.seq, &i.closedAt, &i.reason); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

// BoardID is one ID as the session list needs it (A4G2, api/fleet_board.go).
type BoardID struct {
	ID, Short, Machine, Login, Title, Task, TaskID, Repo, Reason string
	TitleSource                                                  string
	Agent                                                        string
	Seq                                                          int
	Opened, Closed                                               int64
}

// BoardIDs lists owner's IDs ("" = everyone's) that are open, or closed at or
// after since (epoch seconds).
func (s *Store) BoardIDs(owner string, since int64) ([]BoardID, error) {
	q := `SELECT id, short, machine, login, title, task, task_id, repo, close_reason, seq, opened_at, closed_at,
 COALESCE((SELECT agent FROM fleet_id_natives n WHERE n.id = fleet_ids.id AND native != '' ORDER BY n.n DESC LIMIT 1), ''), title_source
		FROM fleet_ids WHERE (closed_at = 0 OR closed_at >= ?)`
	args := []any{since}
	if owner != "" {
		q, args = q+` AND owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BoardID
	for rows.Next() {
		var b BoardID
		if err := rows.Scan(&b.ID, &b.Short, &b.Machine, &b.Login, &b.Title, &b.Task, &b.TaskID, &b.Repo, &b.Reason,
			&b.Seq, &b.Opened, &b.Closed, &b.Agent, &b.TitleSource); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}
