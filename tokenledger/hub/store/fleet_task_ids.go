package store

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// A task's ID (EPIC T644 C1 «任务一建好就有编号»). The moment the hub writes a
// task record it mints the task's ID — a fleet_ids UUID, the same kind of ID a
// window carries — and keeps it on the record (fleet_tasks.fid). From then on
// that ID is the task's number: people read its code (FleetIDCode's prefix, the
// "written" short — unique in the owner's whole history, ≥ 4), and T<n> is only
// a read-only alias of the record (compat-1v: 下一批删).
//
// The minted ID is a RESERVED fleet_ids row: the owner's, no machine
// (endpoint_id ''), seq 0, `task` empty and `task_id` its own UUID. Reserving it
// keeps its code apart from every other ID of the owner's (shortFor) and lets a
// node's resolver find it; leaving `task` empty keeps every reader that counts
// «a window carries T<n>» (idCarrying, IDTaskOutcome) blind to it until a window
// really opens on it. The owner's first machine to push events for that ID takes
// it (ApplyFleetIDEvents) — the road a window opened for the task follows (C2).
//
// A record from before C1 gets its ID from BackfillTaskIDs: the earliest ID that
// already carries its number (fleet_ids.task = T<n>, or a migration's alias),
// else a freshly minted reserved one. Dry by default; applying it twice is a
// no-op; nothing is deleted (fleet_tasks.id and fleet_ids.task stay).

// ErrTaskAmbiguous: a code names more than one task (Candidates lists them).
var ErrTaskAmbiguous = errors.New("this code names more than one task — name it longer")

// TaskCandidate is one task a code could mean.
type TaskCandidate struct {
	ID    string `json:"id"`
	Short string `json:"short"`
	Task  string `json:"task"` // T<n> — compat-1v: 下一批删
	Title string `json:"title"`
	State string `json:"state"`
}

// TaskAmbiguity carries the candidates of an ErrTaskAmbiguous.
type TaskAmbiguity struct{ Candidates []TaskCandidate }

func (a *TaskAmbiguity) Error() string { return ErrTaskAmbiguous.Error() }
func (a *TaskAmbiguity) Unwrap() error { return ErrTaskAmbiguous }

// TaskCodeMin is the shortest code a person may type for a task: two places,
// what the panel shows (the shared rule's «displayed» length, EPIC T644 §2).
const TaskCodeMin = 2

// NormTaskCode is a typed task code (`K5`, `#k5f9`, any case; I/L read 1, O
// read 0; a letter first) in its canonical uppercase form, at least
// TaskCodeMin long; "" when it is not one.
func NormTaskCode(s string) string {
	s = strings.TrimPrefix(strings.TrimSpace(s), "#")
	s = strings.NewReplacer("I", "1", "L", "1", "O", "0").Replace(strings.ToUpper(s))
	if len(s) < TaskCodeMin || len(s) > 26 || !strings.ContainsRune(idLetters, rune(s[0])) {
		return ""
	}
	for _, c := range s {
		if !strings.ContainsRune(idDigits, c) {
			return ""
		}
	}
	return s
}

// taskFinished is the one reader of «this task has ended» on the record itself
// (EPIC T644 §3): succeeded, failed, cancelled, refused, or a legacy record
// settled closed. Everything else — placing, accepted, running, waiting, parked
// — is unfinished.
func taskFinished(state string) bool { return taskTerminal(state) || state == TaskClosed }

// newFleetID is a fresh lowercase UUIDv4, the form fleet_fid_mint writes.
func newFleetID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

// taskIDTx gives t its ID inside tx: fid (an existing ID of the owner's that
// already carries the record's number) or, when fid is "", a freshly minted
// reserved one. A record that already has an ID is left as it is. t's FID and
// Short are filled.
func (s *Store) taskIDTx(tx *sql.Tx, t *FleetTask, fid string, now time.Time) error {
	if t.FID != "" {
		return nil
	}
	if err := s.d.lockKey(tx, "fleet_ids", "fleet_ids:"+t.Owner); err != nil {
		return err
	}
	if fid != "" {
		if err := tx.QueryRow(`SELECT short FROM fleet_ids WHERE id = ? AND owner = ?`, fid, t.Owner).Scan(&t.Short); err != nil {
			return fmt.Errorf("task %s's ID %s: %w", t.Ref, fid, err)
		}
	} else {
		for try := 0; ; try++ {
			id, err := newFleetID()
			if err != nil {
				return err
			}
			var n int
			if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_ids WHERE id = ?`, id).Scan(&n); err != nil {
				return err
			}
			if n > 0 && try < 3 {
				continue // 2^-122: never, but never a duplicate either
			}
			code := FleetIDCode(id)
			short, err := shortFor(tx, t.Owner, id, code, IDShortMin)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(`INSERT INTO fleet_ids (id, owner, code, short, endpoint_id, title, repo, task_id, opened_at, updated_at)
				VALUES (?,?,?,?,'',?,?,?,?,?)`, id, t.Owner, code, short, t.Title, t.Repo, id, t.CreatedAt.Unix(),
				now.UTC().Format(rfc)); err != nil {
				return fmt.Errorf("mint task %s's ID: %w", t.Ref, err)
			}
			fid, t.Short = id, short
			break
		}
	}
	res, err := tx.Exec(`UPDATE fleet_tasks SET fid = ? WHERE id = ? AND fid = ''`, fid, t.ID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("task %s already has an ID", t.Ref)
	}
	// every ID that carries the record's number now names the task by its ID too
	if _, err := tx.Exec(`UPDATE fleet_ids SET task_id = ? WHERE owner = ? AND task_id = '' AND (task = ? OR aliases LIKE ?)`,
		fid, t.Owner, t.Ref, `%"`+t.Ref+`"%`); err != nil {
		return err
	}
	t.FID = fid
	return nil
}

// giveTaskID mints a new record's ID in a transaction of its own (the legacy
// create road writes the row outside one).
func (s *Store) giveTaskID(t FleetTask, now time.Time) (FleetTask, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, err
	}
	defer tx.Rollback()
	cur, err := s.taskInTx(tx, t.ID)
	if err != nil {
		return FleetTask{}, err
	}
	if err := s.taskIDTx(tx, &cur, "", now); err != nil {
		return FleetTask{}, err
	}
	if err := tx.Commit(); err != nil {
		return FleetTask{}, err
	}
	return cur, nil
}

// ResolveFleetTask is the ONE reader of a task reference (EPIC T644 §4): a
// code (≥ 2 places, NormTaskCode), the task's full ID, or the alias T<n> (a bare
// number too). A code is matched among owner's UNFINISHED tasks first; one ⇒
// that task, several ⇒ *TaskAmbiguity (ErrTaskAmbiguous) with them; none
// unfinished ⇒ the same over the whole history. Never a guess. owner "" reads
// anyone's (the operator's door). A full ID that is a window's, not a task's,
// answers the task it belongs to (fleet_ids.task_id). sql.ErrNoRows when
// nothing answers. T followed by digits is the alias when such a record exists,
// else it is read as a code.
func (s *Store) ResolveFleetTask(owner, ref string) (FleetTask, error) {
	ref = strings.TrimSpace(ref)
	if n := ParseTaskRef(ref); n > 0 {
		t, err := s.FleetTask(n)
		if err == nil || !errors.Is(err, sql.ErrNoRows) || NormTaskCode(ref) == "" {
			return t, err
		}
	}
	if IsFleetID(ref) {
		q, args := `fid = ?`, []any{ref}
		if t, err := s.fleetTaskByOwner(q, args, owner); err == nil || !errors.Is(err, sql.ErrNoRows) {
			return t, err
		}
		var fid string
		qq, aa := `SELECT task_id FROM fleet_ids WHERE id = ? AND task_id <> ''`, []any{ref}
		if owner != "" {
			qq, aa = qq+` AND owner = ?`, append(aa, owner)
		}
		if err := s.read.QueryRow(qq, aa...).Scan(&fid); err != nil {
			return FleetTask{}, err
		}
		return s.fleetTaskByOwner(`fid = ?`, []any{fid}, owner)
	}
	code := NormTaskCode(ref)
	if code == "" {
		return FleetTask{}, sql.ErrNoRows
	}
	q, args := `SELECT t.id, f.short, t.title, t.state FROM fleet_tasks t JOIN fleet_ids f ON f.id = t.fid
		WHERE t.fid <> '' AND substr(f.code, 1, ?) = ?`, []any{len(code), code}
	if owner != "" {
		q, args = q+` AND t.owner = ? AND f.owner = ?`, append(args, owner, owner)
	}
	rows, err := s.read.Query(q+` ORDER BY t.id`, args...)
	if err != nil {
		return FleetTask{}, err
	}
	type hit struct {
		id int64
		c  TaskCandidate
	}
	var open, all []hit
	for rows.Next() {
		var h hit
		if err := rows.Scan(&h.id, &h.c.Short, &h.c.Title, &h.c.State); err != nil {
			rows.Close()
			return FleetTask{}, err
		}
		h.c.Task = TaskRef(h.id)
		all = append(all, h)
		if !taskFinished(h.c.State) {
			open = append(open, h)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return FleetTask{}, err
	}
	pick := open
	if len(pick) == 0 {
		pick = all
	}
	switch len(pick) {
	case 0:
		return FleetTask{}, sql.ErrNoRows
	case 1:
		return s.FleetTask(pick[0].id)
	}
	amb := &TaskAmbiguity{}
	for _, h := range pick {
		t, err := s.FleetTask(h.id)
		if err != nil {
			return FleetTask{}, err
		}
		h.c.ID = t.FID
		amb.Candidates = append(amb.Candidates, h.c)
	}
	return FleetTask{}, amb
}

func (s *Store) fleetTaskByOwner(where string, args []any, owner string) (FleetTask, error) {
	if owner != "" {
		where, args = where+` AND owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE `+where+` ORDER BY id LIMIT 1`, args...)
	if err != nil {
		return FleetTask{}, err
	}
	out, err := scanFleetTasks(rows)
	if err != nil {
		return FleetTask{}, err
	}
	if len(out) == 0 {
		return FleetTask{}, sql.ErrNoRows
	}
	return out[0], nil
}

// TaskIDBackfill is what BackfillTaskIDs found (dry) or did (apply).
type TaskIDBackfill struct {
	Apply   bool `json:"apply"`
	Total   int  `json:"total"`   // the owner's records
	Already int  `json:"already"` // records that had an ID
	Linked  int  `json:"linked"`  // records given the earliest ID already carrying their number
	Minted  int  `json:"minted"`  // records given a freshly minted (reserved) ID
	// Items: one line per record moved (or that would move): T<n> → ID (code).
	Items []TaskIDBackfillItem `json:"items"`
}

// TaskIDBackfillItem is one record's ID.
type TaskIDBackfillItem struct {
	Task  string `json:"task"`
	ID    string `json:"id,omitempty"` // empty on a dry run's mint
	Short string `json:"short,omitempty"`
	How   string `json:"how"` // linked | minted
}

// BackfillTaskIDs gives every record of owner's ("" = everyone's) that has no
// ID yet its ID, oldest first: the earliest ID (by opened_at) already carrying
// its number — `task` = T<n>, or a migration's alias — that no other record
// took, else a freshly minted reserved one. apply false changes nothing and
// says what it would do. Idempotent: a record with an ID is only counted.
func (s *Store) BackfillTaskIDs(owner string, apply bool, now time.Time) (TaskIDBackfill, error) {
	out := TaskIDBackfill{Apply: apply, Items: []TaskIDBackfillItem{}}
	q, args := `SELECT id, owner, fid FROM fleet_tasks`, []any{}
	if owner != "" {
		q, args = q+` WHERE owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(q+` ORDER BY id`, args...)
	if err != nil {
		return out, err
	}
	type rec struct {
		id         int64
		owner, fid string
	}
	var todo []rec
	for rows.Next() {
		var r rec
		if err := rows.Scan(&r.id, &r.owner, &r.fid); err != nil {
			rows.Close()
			return out, err
		}
		out.Total++
		if r.fid != "" {
			out.Already++
			continue
		}
		todo = append(todo, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	taken := map[string]bool{} // a dry run's own picks, so two records never share one
	for _, r := range todo {
		ref := TaskRef(r.id)
		ids, err := s.read.Query(`SELECT id FROM fleet_ids WHERE owner = ? AND (task = ? OR aliases LIKE ?)
			AND id NOT IN (SELECT fid FROM fleet_tasks WHERE fid <> '') ORDER BY opened_at, id`, r.owner, ref, `%"`+ref+`"%`)
		if err != nil {
			return out, err
		}
		fid := ""
		for ids.Next() {
			var id string
			if err := ids.Scan(&id); err != nil {
				ids.Close()
				return out, err
			}
			if fid == "" && !taken[id] {
				fid = id
			}
		}
		ids.Close()
		item := TaskIDBackfillItem{Task: ref, ID: fid, How: "linked"}
		if fid == "" {
			item.How = "minted"
			out.Minted++
		} else {
			taken[fid] = true
			out.Linked++
		}
		if apply {
			tx, err := s.write.Begin()
			if err != nil {
				return out, err
			}
			t, err := s.taskInTx(tx, r.id)
			if err == nil {
				err = s.taskIDTx(tx, &t, fid, now)
			}
			if err == nil {
				err = tx.Commit()
			}
			if err != nil {
				tx.Rollback()
				return out, fmt.Errorf("backfill %s: %w", ref, err)
			}
			item.ID, item.Short = t.FID, t.Short
		} else if fid != "" {
			_ = s.read.QueryRow(`SELECT short FROM fleet_ids WHERE id = ?`, fid).Scan(&item.Short)
		}
		out.Items = append(out.Items, item)
	}
	return out, nil
}
