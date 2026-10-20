package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// Migrating the old T records onto IDs, and the switch (EPIC T497 C6; design
// page §5, §5.1). Every hub task record (fleet_tasks) is settled ONCE by one
// rule, read off the record and — for one that names a worker — the worker's
// machine's own answer to «is a window carrying this @fleet_id there?»:
//
//	已终态（不管 execution_owner）           → 照抄结果、已关闭
//	有 worker，节点答窗口在                  → 活着 = 那个窗口的 ID（旧 T 号记成它的别名）
//	有 worker，节点答 tmux 正常、没有窗口带它 → 已退出（有 cancel_request 记已取消）、已关闭
//	从未认领（没有 worker）                  → 已关闭 · 没开起来
//	节点不回答（失联、tmux 没起、旧 agent）   → 不迁，下次再跑
//
// A record with a worker waits for its machine even when it already ended: the
// counter-example «stop one machine's node: none of its records move» is the
// rule. Silence is never evidence. The record itself is the read-only archive:
// apply writes its end (outcome, state closed) only where it had none, and one
// fleet_operations row per record (action id_migrate, idem `id_migrate:T<n>`:
// the record before, the verdict, the evidence word for word, the operator) —
// a record that has its row is migrated and is not listed again.
//
// The switch (`fleet.id_switch`, IDSwitchSetting) is the hub's: off — or unset
// — every old road behaves as before, byte for byte; on, the execution-authority
// writes (claim, the launch contract's binding, transitions, fenced reports) are
// refused with ErrIDSwitch and a record's end is read off the ID that carries
// its number (IDTaskOutcome). Flipping it back is the way back: nothing is
// deleted either way.

// IDSwitchSetting is the fleet setting that holds the switch: "on", else off.
const IDSwitchSetting = "fleet.id_switch"

// ErrIDSwitch refuses an execution-authority write while the switch is on.
var ErrIDSwitch = errors.New("ID_SWITCH: the hub reads sessions by ID now — task claims, launch contracts and fenced reports are no longer taken (report on the window's ID)")

// IDSwitchOn reads the switch; an unreadable setting is off (the old road).
func (s *Store) IDSwitchOn() bool {
	var v string
	if err := s.read.QueryRow(`SELECT value FROM fleet_settings WHERE key = ?`, IDSwitchSetting).Scan(&v); err != nil {
		return false
	}
	return v == "on"
}

// SetIDSwitch turns it on or off (off deletes the setting: the default again).
func (s *Store) SetIDSwitch(on bool, at time.Time) error {
	v := ""
	if on {
		v = "on"
	}
	return s.SetFleetSetting(IDSwitchSetting, v, at)
}

// Verdicts a record is settled to.
const (
	IDMigSucceeded  = "succeeded"   // 已完成、已关闭
	IDMigFailed     = "failed"      // 失败、已关闭
	IDMigCancelled  = "cancelled"   // 已取消、已关闭
	IDMigExited     = "exited"      // 已退出、已关闭
	IDMigNotStarted = "not_started" // 已关闭 · 没开起来
	IDMigClosed     = "closed"      // 已关闭（旧记录早已结过）
	IDMigLive       = "live"        // 活着 → 窗口的 ID
	IDMigWait       = "wait"        // 等节点回答：不迁
)

// IDPresence is one machine's answer for one fleet: Answered is false when the
// machine did not answer, or answered that the fleet's tmux is not up (no
// evidence either way); Gone is the machine saying it no longer runs that
// fleet at all; Windows maps each live window's @fleet_id (and key) to where
// it is. Evidence is what the answer was, kept word for word in the audit row.
type IDPresence struct {
	Answered bool
	Gone     bool
	Windows  map[string]string
	Evidence string
}

// IDMigrateItem is one record's line of the migration.
type IDMigrateItem struct {
	Task     string `json:"task"`
	Owner    string `json:"owner"`
	Title    string `json:"title,omitempty"`
	Before   string `json:"before"`
	Verdict  string `json:"verdict"`
	Label    string `json:"label"`
	ID       string `json:"id,omitempty"`
	Short    string `json:"short,omitempty"`
	Result   string `json:"result,omitempty"`
	Evidence string `json:"evidence"`
	Applied  bool   `json:"applied,omitempty"`
}

var idMigLabels = map[string]string{
	IDMigSucceeded: "已完成、已关闭", IDMigFailed: "失败、已关闭", IDMigCancelled: "已取消、已关闭",
	IDMigExited: "已退出、已关闭", IDMigNotStarted: "已关闭 · 没开起来", IDMigClosed: "已关闭",
	IDMigLive: "活着", IDMigWait: "等节点回答（不迁）",
}

// IDMigWorker is the session a record names — the claim's execution owner,
// else the legacy worker — as (fleet UUID, its window's key or @fleet_id).
func IDMigWorker(t FleetTask) (fleet, session string) {
	for _, w := range []string{t.ExecutionOwner, t.WorkerID} {
		if f, k, err := fleetid.ParseWorkerID(w); err == nil {
			return f, k
		}
	}
	return "", ""
}

// idMigTerminal is the end the record already holds, "" when it holds none.
func idMigTerminal(t FleetTask) string {
	switch t.Outcome {
	case TaskSucceeded, TaskFailed, TaskCancelled:
		return t.Outcome
	case TaskRefused:
		return IDMigNotStarted
	}
	switch t.State {
	case TaskSucceeded, TaskFailed, TaskCancelled:
		return t.State
	case TaskRefused:
		return IDMigNotStarted
	case TaskClosed:
		return IDMigClosed
	}
	return ""
}

// ClassifyIDMigration settles one record by the §5 table. pres is its worker's
// machine's answer for the worker's fleet (nil: nobody was asked or nobody
// answered); a record that names no worker needs none.
func ClassifyIDMigration(t FleetTask, pres *IDPresence) IDMigrateItem {
	it := IDMigrateItem{Task: t.Ref, Owner: t.Owner, Title: t.Title, Before: idMigBefore(t)}
	set := func(v, ev string) IDMigrateItem {
		it.Verdict, it.Label, it.Evidence = v, idMigLabels[v], ev
		return it
	}
	end := idMigTerminal(t)
	fleet, sess := IDMigWorker(t)
	if fleet == "" {
		if end != "" {
			return set(end, "记录本身：已终态（"+orDash(t.Outcome, t.State)+"），没有 worker")
		}
		return set(IDMigNotStarted, "记录本身：从未认领（没有 worker），state "+t.State)
	}
	if pres == nil || !pres.Answered {
		why := "没有问到"
		if pres != nil && pres.Evidence != "" {
			why = pres.Evidence
		}
		return set(IDMigWait, "worker "+fleet+"/"+sess+" 的机器没有回答："+why)
	}
	if !pres.Gone {
		if w := pres.Windows[sess]; w != "" {
			it.ID = sess
			if !IsFleetID(sess) {
				it.ID = "" // an old key-named worker: alive, its window has no ID yet
			} else {
				it.Short = "T-" + FleetIDCode(sess)[:IDShortMin]
			}
			if end != "" && end != IDMigClosed && end != IDMigNotStarted {
				it.Result = end
			}
			return set(IDMigLive, "节点回答：窗口在（"+w+"）；"+pres.Evidence)
		}
	}
	if end != "" {
		return set(end, "记录本身：已终态（"+orDash(t.Outcome, t.State)+"）；节点回答窗口不在："+pres.Evidence)
	}
	if t.CancelRequest != "" {
		return set(IDMigCancelled, "节点回答没有窗口带 "+sess+"："+pres.Evidence+"；记录有 cancel_request "+t.CancelRequest)
	}
	return set(IDMigExited, "节点回答没有窗口带 "+sess+"："+pres.Evidence)
}

func orDash(a, b string) string {
	if a != "" {
		return a
	}
	if b != "" {
		return b
	}
	return "-"
}

// idMigBefore is the record as one line: what the table's 「今天」 column says.
func idMigBefore(t FleetTask) string {
	parts := []string{"v" + strconv.Itoa(t.AuthorityVersion), "state " + orDash(t.State, "")}
	if t.Outcome != "" {
		parts = append(parts, "outcome "+t.Outcome)
	}
	if t.Agent != "" {
		parts = append(parts, t.Agent)
	}
	if t.CancelRequest != "" {
		parts = append(parts, "cancel_request")
	}
	if t.ExecutionOwner != "" {
		parts = append(parts, "execution_owner 挂着")
	} else if t.WorkerID != "" {
		parts = append(parts, "worker "+t.WorkerID)
	}
	return strings.Join(parts, " · ")
}

// IDMigrateCandidates lists the old records not yet migrated, oldest first: owner
// "" is everyone's (the operator's door); only, when given, narrows to those
// refs (T<n>).
func (s *Store) IDMigrateCandidates(owner string, only []string) ([]FleetTask, error) {
	q, args := `SELECT `+fleetTaskCols+` FROM fleet_tasks t WHERE NOT EXISTS (
		SELECT 1 FROM fleet_operations o WHERE o.actor = 'id_migrate' AND o.idem = 'id_migrate:T' || CAST(t.id AS TEXT))`, []any{}
	if owner != "" {
		q, args = q+` AND t.owner = ?`, append(args, owner)
	}
	if len(only) > 0 {
		ph := []string{}
		for _, ref := range only {
			if id := ParseTaskRef(ref); id > 0 {
				ph, args = append(ph, "?"), append(args, id)
			}
		}
		if len(ph) == 0 {
			return nil, nil
		}
		q += ` AND t.id IN (` + strings.Join(ph, ",") + `)`
	}
	rows, err := s.read.Query(q+` ORDER BY t.id`, args...)
	if err != nil {
		return nil, err
	}
	all, err := scanFleetTasks(rows)
	if err != nil {
		return nil, err
	}
	// Only OLD records are migrated (C13). One written after the switch went
	// on, or never claimed yet carried by an ID, is the ID world's: its window
	// never claims, so «no worker» is no evidence it did not start — its end is
	// read off the ID, and a dead one is closed by a cancel.
	since := s.idSwitchSince()
	out := all[:0]
	for _, t := range all {
		if !since.IsZero() && !t.CreatedAt.Before(since) {
			continue
		}
		if f, _ := IDMigWorker(t); f == "" {
			carried, _, err := idCarrying(s.read, "", t.Ref)
			if err != nil {
				return nil, err
			}
			if carried {
				continue
			}
		}
		out = append(out, t)
	}
	return out, nil
}

// ApplyIDMigration writes one record's verdict: its audit row, its end where it
// had none, and — a live one — its number as an alias of the ID. A wait is never
// applied; a record already migrated is ErrTaskConflict (the first one stands).
func (s *Store) ApplyIDMigration(t FleetTask, it IDMigrateItem, operator string, now time.Time) error {
	if it.Verdict == IDMigWait || it.Verdict == "" || it.Task != t.Ref {
		return ErrTaskConflict
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	before, _ := json.Marshal(t)
	req, _ := json.Marshal(map[string]any{"before": json.RawMessage(before), "verdict": it.Verdict, "label": it.Label,
		"id": it.ID, "evidence": it.Evidence, "operator": operator})
	fleet, _ := IDMigWorker(t)
	ts := now.UTC().Format(rfc)
	res, err := tx.Exec(`INSERT INTO fleet_operations
		(id, fleet_id, action, request, actor, idem, status, created, updated, result, placement, worker_id, task_owner, task_ref)
		VALUES (?, ?, 'id_migrate', ?, 'id_migrate', ?, 'succeeded', ?, ?, NULL, '', ?, ?, ?)
		ON CONFLICT(actor, idem) DO NOTHING`,
		"idmig-"+t.Ref, fleet, string(req), "id_migrate:"+t.Ref, ts, ts, orDash(t.ExecutionOwner, t.WorkerID), t.Owner, t.Ref)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrTaskConflict
	}
	switch it.Verdict {
	case IDMigCancelled, IDMigExited, IDMigNotStarted, IDMigSucceeded, IDMigFailed:
		if idMigTerminal(t) == "" {
			out := it.Verdict
			if out == IDMigNotStarted {
				out = TaskRefused
			}
			if _, err = tx.Exec(`UPDATE fleet_tasks SET state = ?, outcome = ?, updated_at = ? WHERE id = ?`,
				TaskClosed, out, ts, ParseTaskRef(t.Ref)); err != nil {
				return err
			}
		}
	case IDMigLive:
		if it.ID != "" {
			var raw string
			err = tx.QueryRow(`SELECT aliases FROM fleet_ids WHERE id = ?`, it.ID).Scan(&raw)
			if err == nil {
				var al []string
				_ = json.Unmarshal([]byte(raw), &al)
				have := false
				for _, a := range al {
					have = have || a == t.Ref
				}
				if !have {
					b, _ := json.Marshal(append(al, t.Ref))
					if _, err = tx.Exec(`UPDATE fleet_ids SET aliases = ?, updated_at = ? WHERE id = ?`, string(b), ts, it.ID); err != nil {
						return err
					}
				}
			} else if !errors.Is(err, sql.ErrNoRows) {
				return err
			}
		}
	}
	return tx.Commit()
}

// IDMigrated reads a record's migration row: the verdict it was settled to,
// "" when it has none.
func (s *Store) IDMigrated(ref string) (string, error) {
	var req string
	err := s.read.QueryRow(`SELECT request FROM fleet_operations WHERE actor = 'id_migrate' AND idem = ?`, "id_migrate:"+ref).Scan(&req)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	var r struct {
		Verdict string `json:"verdict"`
	}
	_ = json.Unmarshal([]byte(req), &r)
	return r.Verdict, nil
}

// IDTaskOutcome is, with the switch on, a record's end read off the ID that
// carries its number — the window opened for it (`task`), or the alias the
// migration gave a live one: its newest result that ends work (merged /
// succeeded → succeeded, failed → failed); "" while it has none, or no ID
// answers to the number. id is the ID found.
func (s *Store) IDTaskOutcome(owner, ref string) (outcome, id string, err error) {
	q, args := `SELECT id FROM fleet_ids WHERE (task = ? OR aliases LIKE ?)`, []any{ref, `%"` + ref + `"%`}
	if owner != "" {
		q, args = q+` AND owner = ?`, append(args, owner)
	}
	err = s.read.QueryRow(q+` ORDER BY opened_at DESC LIMIT 1`, args...).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", nil
	}
	if err != nil {
		return "", "", err
	}
	var st string
	err = s.read.QueryRow(`SELECT state FROM fleet_id_results WHERE id = ? AND state IN ('merged', 'succeeded', 'done', 'failed')
		ORDER BY seq DESC LIMIT 1`, id).Scan(&st)
	if errors.Is(err, sql.ErrNoRows) {
		return "", id, nil
	}
	if err != nil {
		return "", id, err
	}
	if st == "failed" {
		return TaskFailed, id, nil
	}
	return TaskSucceeded, id, nil
}

// idSwitchSince is when the switch was last turned on; zero while it is off.
func (s *Store) idSwitchSince() time.Time {
	var v, at string
	if err := s.read.QueryRow(`SELECT value, updated FROM fleet_settings WHERE key = ?`, IDSwitchSetting).Scan(&v, &at); err != nil || v != "on" {
		return time.Time{}
	}
	t, _ := time.Parse(rfc, at)
	return t
}

// idCarrying answers which IDs carry a record's number (the window opened for
// it, or a live migration's alias): open is true when one of them is not yet
// closed. owner "" is anyone's.
func idCarrying(q querier, owner, ref string) (carried, open bool, err error) {
	sq, args := `SELECT closed_at FROM fleet_ids WHERE (task = ? OR aliases LIKE ?)`, []any{ref, `%"` + ref + `"%`}
	if owner != "" {
		sq, args = sq+` AND owner = ?`, append(args, owner)
	}
	rows, err := q.Query(sq, args...)
	if err != nil {
		return false, false, err
	}
	defer rows.Close()
	for rows.Next() {
		var closed int64
		if err = rows.Scan(&closed); err != nil {
			return false, false, err
		}
		carried, open = true, open || closed == 0
	}
	return carried, open, rows.Err()
}

// idSwitchCancel is the one task mutation the switch still takes (EPIC T497
// C13): a person's cancel of a record nobody ever claimed — the unclaimed
// transition to cancelled fleet_task_control.py's cancel sends. It is not an
// execution-authority write: there is no owner to fence and nothing to stop.
func idSwitchCancel(m TaskMutation) bool {
	return m.Kind == "transition" && m.State == TaskCancelled && m.ExpectedWorker == ""
}

// idSwitchCancelAllowed checks, inside the mutation's transaction, that the
// record is one with no window left to read its end off: accepted, never
// claimed, no outcome, and no open ID carrying its number. A record whose ID is
// still open is that window's (ErrIDSwitch: cancel it there); one whose closed
// ID left a result has ended on it (ErrTaskConflict).
func (s *Store) idSwitchCancelAllowed(tx querier, t FleetTask) error {
	if t.State != TaskAccepted || t.ExecutionOwner != "" || t.Outcome != "" {
		return ErrIDSwitch
	}
	carried, open, err := idCarrying(tx, t.Owner, t.Ref)
	if err != nil {
		return err
	}
	if open {
		return ErrIDSwitch
	}
	if carried {
		if out, _, err := s.IDTaskOutcome(t.Owner, t.Ref); err != nil {
			return err
		} else if out != "" {
			return ErrTaskConflict
		}
	}
	return nil
}
