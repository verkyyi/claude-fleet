package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"
)

const historyPendingOperation = `SELECT 1 FROM fleet_operation_sessions WHERE session_id = ? AND status NOT IN ('succeeded','failed','expired')`

const historyHideSchema = `
CREATE TABLE IF NOT EXISTS fleet_history_hides (
 owner TEXT NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL, hidden INTEGER NOT NULL,
 PRIMARY KEY(owner,id)
);
CREATE TABLE IF NOT EXISTS fleet_history_hide_audit (
 id INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL, fid TEXT NOT NULL,
 actor TEXT NOT NULL, action TEXT NOT NULL, manifest TEXT NOT NULL, at INTEGER NOT NULL
);`

// HistoryHideManifest is a reviewed, per-FID absence attestation, never a sweep.
// The operator checks ALL native segments, input queues and recovery copies on
// every recorded placement. Unknown/offline are deliberately not absence.
// Hub state is rechecked transactionally at apply; dry-run is the default.
type HistoryHideManifest struct {
	Owner          string   `json:"owner"`
	ID             string   `json:"id"`
	Seq            int      `json:"seq"`
	Machine        string   `json:"machine"`
	Login          string   `json:"login"`
	CheckedAt      int64    `json:"checked_at"`
	Online         bool     `json:"online"`
	Complete       bool     `json:"complete"`
	Natives        []string `json:"natives"`
	NativeEvidence string   `json:"native_evidence"`
	Backups        string   `json:"backups"`
	Inputs         string   `json:"inputs"`
	Evidence       string   `json:"evidence"`
}

var ErrHistoryEvidence = errors.New("history hide refused: closed identity, fresh complete online absence evidence, no cache and no pending work required")

// HistoryHideError reports only a fixed reason code, never record contents.
type HistoryHideError struct{ Reason string }

func (e *HistoryHideError) Error() string    { return "history hide refused: " + e.Reason }
func (e *HistoryHideError) Unwrap() error    { return ErrHistoryEvidence }
func historyHideRefusal(reason string) error { return &HistoryHideError{Reason: reason} }

func (s *Store) HideHistory(m HistoryHideManifest, actor string, undo, apply bool, now time.Time, decode ChatMirrorSession) error {
	if actor == "" {
		return historyHideRefusal("actor_missing")
	}
	if m.Owner == "" || !IsFleetID(m.ID) {
		return historyHideRefusal("invalid_identity")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Same serialization as native/result/close events.
	if err := s.d.lockKey(tx, "fleet_ids", "fleet_ids:"+m.Owner); err != nil {
		return err
	}
	var seq int
	var closed int64
	var machine, login, taskID, task, key, asked, parked string
	err = tx.QueryRow(`SELECT seq, closed_at, machine, login, task_id, task, key, asked, parked FROM fleet_ids WHERE owner = ? AND id = ?`+s.d.forUpdate(), m.Owner, m.ID).Scan(&seq, &closed, &machine, &login, &taskID, &task, &key, &asked, &parked)
	if errors.Is(err, sql.ErrNoRows) {
		return historyHideRefusal("identity_not_found")
	}
	if err != nil {
		return err
	}
	if !undo {
		if closed == 0 || seq != m.Seq || machine != m.Machine || login != m.Login {
			return historyHideRefusal("ledger_mismatch")
		}
		if !m.Online || !m.Complete || m.NativeEvidence != "absent_verified" || m.Backups != "absent_verified" || m.Inputs != "empty_verified" || strings.TrimSpace(m.Evidence) == "" {
			return historyHideRefusal("evidence_incomplete")
		}
		if now.Unix()-m.CheckedAt < 0 || now.Unix()-m.CheckedAt > 300 {
			return historyHideRefusal("evidence_stale")
		}
		if asked != "" || parked != "" {
			return historyHideRefusal("pending_gate")
		}
		rows, err := tx.Query(`SELECT native FROM fleet_id_natives WHERE id = ? ORDER BY n`, m.ID)
		if err != nil {
			return err
		}
		var natives []string
		for rows.Next() {
			var sid string
			if err := rows.Scan(&sid); err != nil {
				rows.Close()
				return err
			}
			natives = append(natives, sid)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		if len(natives) != len(m.Natives) {
			return historyHideRefusal("natives_mismatch")
		}
		for i, sid := range natives {
			if sid != m.Natives[i] {
				return historyHideRefusal("natives_mismatch")
			}
		}
		liveRows, err := tx.Query(`SELECT workers_json FROM fleet_fleets WHERE present=1`)
		if err != nil {
			return err
		}
		live := false
		for liveRows.Next() {
			var raw string
			if err := liveRows.Scan(&raw); err != nil {
				liveRows.Close()
				return err
			}
			var workers []map[string]any
			if json.Unmarshal([]byte(raw), &workers) != nil {
				liveRows.Close()
				return historyHideRefusal("live_inventory_unknown")
			}
			for _, w := range workers {
				wid, _ := w["worker_id"].(string)
				if w["identity"] == m.ID || w["fleet_id"] == m.ID || strings.HasSuffix(wid, "/"+m.ID) {
					live = true
				}
			}
		}
		liveRows.Close()
		if err := liveRows.Err(); err != nil {
			return err
		}
		if live {
			return historyHideRefusal("live_identity")
		}
		var queued bool
		err = tx.QueryRow(`SELECT EXISTS (`+historyPendingOperation+`)`, m.ID).Scan(&queued)
		if err != nil {
			return err
		}
		if queued {
			return historyHideRefusal("pending_operation")
		}
		// No limit/window here: old tasks and blocked backlog must also survive.
		// Empty legacy task FIDs are not identities. Build optional joins only
		// from a recorded task UUID or valid positive T<n>/numeric reference.
		bindings := []string{"fid = ?", "worker_id LIKE ?"}
		args := []any{m.Owner, m.ID, "%/" + m.ID}
		if IsFleetID(taskID) {
			bindings = append(bindings, "fid = ?")
			args = append(args, taskID)
		} else if taskID != "" {
			return historyHideRefusal("task_identity_unknown")
		}
		if n := ParseTaskRef(task); n > 0 {
			bindings = append(bindings, "id = ?")
			args = append(args, n)
		} else if task != "" {
			return historyHideRefusal("task_reference_unknown")
		}
		var pending int
		err = tx.QueryRow(`SELECT COUNT(*) FROM fleet_tasks WHERE owner = ? AND
          (`+strings.Join(bindings, " OR ")+`) AND
          (asked != '' OR parked != '' OR state IN ('accepted','starting','blocked','open','placing','unknown') OR (state NOT IN ('closed','refused') AND outcome NOT IN ('succeeded','failed','cancelled','refused')))`, args...).Scan(&pending)
		if err != nil {
			return err
		}
		if pending != 0 {
			return historyHideRefusal("pending_task")
		}

		// Read and decrypt a fresh cache snapshot under the same owner lock as
		// PutChatMirrorOf and identity events. Never trust dry-run evidence at apply.
		copies, unknown, err := historyViewCopies(tx, m.Owner, decode)
		if err != nil {
			return err
		}
		if unknown {
			return historyHideRefusal("cache_identity_unknown")
		}
		if len(copies[m.ID]) != 0 {
			return historyHideRefusal("native_cache_present")
		}
	}
	if !apply {
		return nil
	}
	hidden, action := 1, "hide"
	if undo {
		hidden, action = 0, "undo"
	}
	if _, err = tx.Exec(`INSERT INTO fleet_history_hides(owner,id,seq,hidden) VALUES(?,?,?,?) ON CONFLICT(owner,id) DO UPDATE SET seq=excluded.seq,hidden=excluded.hidden`, m.Owner, m.ID, seq, hidden); err != nil {
		return err
	}
	raw, _ := json.Marshal(m)
	if _, err = tx.Exec(`INSERT INTO fleet_history_hide_audit(owner,fid,actor,action,manifest,at) VALUES(?,?,?,?,?,?)`, m.Owner, m.ID, actor, action, string(raw), now.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func hiddenHistoryCandidatesSQL() string {
	return `SELECT h.id,h.owner FROM fleet_history_hides h JOIN fleet_ids i ON i.id=h.id AND i.owner=h.owner WHERE h.hidden=1 AND h.seq=i.seq AND i.closed_at>0
 AND NOT EXISTS (` + strings.Replace(historyPendingOperation, "?", "h.id", 1) + `)`
}

// HiddenHistory only hides the exact closed ledger version reviewed. A later
// event (including reopen) automatically exposes it again; no ID/task is edited.
func (s *Store) HiddenHistory(owner string, decode ChatMirrorSession) (map[string]bool, error) {
	q := hiddenHistoryCandidatesSQL()
	args := []any{}
	if owner != "" {
		q += ` AND h.owner=?`
		args = append(args, owner)
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	// Discover owners first, then lock them in a stable order before reading
	// ledger versions and caches. The post-lock read also covers a hide changed
	// while this request waited (PostgreSQL replicas share these advisory locks).
	ownerQuery := `SELECT DISTINCT owner FROM fleet_history_hides WHERE hidden=1`
	if owner != "" {
		ownerQuery += ` AND owner=?`
	}
	rows, err := tx.Query(ownerQuery, args...)
	if err != nil {
		return nil, err
	}
	var owners []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			rows.Close()
			return nil, err
		}
		owners = append(owners, pid)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Strings(owners)
	for _, pid := range owners {
		if err := s.d.lockKey(tx, "fleet_ids", "fleet_ids:"+pid); err != nil {
			return nil, err
		}
	}
	rows, err = tx.Query(q, args...)
	if err != nil {
		return nil, err
	}
	candidates := map[string][]string{}
	for rows.Next() {
		var id, pid string
		if err := rows.Scan(&id, &pid); err != nil {
			rows.Close()
			return nil, err
		}
		candidates[pid] = append(candidates[pid], id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, pid := range owners {
		ids := candidates[pid]
		// Cache arrivals after apply restore visibility. Unrelated verified native
		// conversations do not cancel a hide; uncertain attribution always does.
		copies, unknown, err := historyViewCopies(tx, pid, decode)
		if err != nil {
			return nil, err
		}
		if unknown {
			continue
		}
		for _, id := range ids {
			if len(copies[id]) == 0 {
				out[id] = true
			}
		}
	}
	return out, nil
}
