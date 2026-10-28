package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

var ErrScheduleConflict = errors.New("schedule changed; reload before editing")
var ErrScheduleLimit = errors.New("schedule limit reached")

type Schedule struct {
	Spec      schedule.Spec   `json:"spec"`
	Owner     string          `json:"-"`
	Endpoint  string          `json:"-"`
	Hostname  string          `json:"machine"`
	Login     string          `json:"login"`
	SyncState string          `json:"sync_state"`
	SyncNote  string          `json:"sync_note"`
	Observed  json.RawMessage `json:"observed"`
	Updated   int64           `json:"updated"`
	Created   int64           `json:"created"`
}

const scheduleCols = `owner, endpoint, hostname, login, spec, sync_state, sync_note, observed, updated, created`

func scanSchedule(row interface{ Scan(...any) error }) (Schedule, error) {
	var s Schedule
	var raw, observed string
	err := row.Scan(&s.Owner, &s.Endpoint, &s.Hostname, &s.Login, &raw, &s.SyncState, &s.SyncNote, &observed, &s.Updated, &s.Created)
	if err == nil {
		err = json.Unmarshal([]byte(raw), &s.Spec)
		s.Observed = json.RawMessage(observed)
	}
	return s, err
}
func (s *Store) Schedule(owner, id string) (Schedule, error) {
	return scanSchedule(s.read.QueryRow(`SELECT `+scheduleCols+` FROM fleet_schedules WHERE owner=? AND id=?`, owner, id))
}
func (s *Store) Schedules(owner string) ([]Schedule, error) {
	rows, e := s.read.Query(`SELECT `+scheduleCols+` FROM fleet_schedules WHERE owner=? AND deleted=0 ORDER BY created,id`, owner)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Schedule{}
	for rows.Next() {
		r, e := scanSchedule(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Lock one principal in the transaction: SQLite and PostgreSQL both serialize
// concurrent registrations and admissions across all that person's machines.
func scheduleLock(tx *sql.Tx, owner string) error {
	if _, e := tx.Exec(`INSERT INTO fleet_schedule_owners(owner,revision) VALUES (?,0) ON CONFLICT(owner) DO NOTHING`, owner); e != nil {
		return e
	}
	_, e := tx.Exec(`UPDATE fleet_schedule_owners SET revision=revision+1 WHERE owner=?`, owner)
	return e
}
func (s *Store) SaveSchedule(owner, key, request string, next Schedule, expected int64, now time.Time) (Schedule, error) {
	slots, e := schedule.Validate(next.Spec)
	if e != nil {
		return Schedule{}, e
	}
	tx, e := s.write.Begin()
	if e != nil {
		return Schedule{}, e
	}
	defer tx.Rollback()
	if e = scheduleLock(tx, owner); e != nil {
		return Schedule{}, e
	}
	var previous, id string
	e = tx.QueryRow(`SELECT request,schedule_id FROM fleet_schedule_changes WHERE owner=? AND idem=?`, owner, key).Scan(&previous, &id)
	if e == nil {
		if request != previous {
			return Schedule{}, ErrScheduleConflict
		}
		out, e := scanSchedule(tx.QueryRow(`SELECT `+scheduleCols+` FROM fleet_schedules WHERE owner=? AND id=?`, owner, id))
		return out, e
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return Schedule{}, e
	}
	old, e := scanSchedule(tx.QueryRow(`SELECT `+scheduleCols+` FROM fleet_schedules WHERE owner=? AND id=?`, owner, next.Spec.ID))
	if expected == 0 {
		if e == nil {
			return Schedule{}, ErrScheduleConflict
		}
		if !errors.Is(e, sql.ErrNoRows) {
			return Schedule{}, e
		}
		next.Created = now.Unix()
	} else {
		if e != nil {
			return Schedule{}, e
		}
		// A one-shot identity cannot become a different occurrence, including
		// after its history has been pruned. Create a new job intentionally.
		if old.Spec.OnceAt != next.Spec.OnceAt {
			return Schedule{}, ErrScheduleConflict
		}
		if old.Spec.Revision != expected || old.Spec.Deleted {
			return Schedule{}, ErrScheduleConflict
		}
		next.Endpoint, next.Hostname, next.Login, next.Created = old.Endpoint, old.Hostname, old.Login, old.Created
	}
	if next.Spec.Revision != expected+1 {
		return Schedule{}, ErrScheduleConflict
	}
	var count, total int
	e = tx.QueryRow(`SELECT COUNT(*),COALESCE(SUM(slots),0) FROM fleet_schedules WHERE owner=? AND deleted=0 AND id<>?`, owner, next.Spec.ID).Scan(&count, &total)
	if e != nil {
		return Schedule{}, e
	}
	if !next.Spec.Enabled || next.Spec.Deleted {
		slots = 0
	}
	if !next.Spec.Deleted && (count >= schedule.MaxTasks || total+slots > schedule.MaxDailySlots) {
		return Schedule{}, ErrScheduleLimit
	}
	raw, _ := json.Marshal(next.Spec)
	deleted := 0
	if next.Spec.Deleted {
		deleted = 1
	}
	_, e = tx.Exec(`INSERT INTO fleet_schedules(id,owner,endpoint,hostname,login,revision,spec,slots,deleted,sync_state,sync_note,observed,updated,created)
 VALUES (?,?,?,?,?,?,?,?,?,'pending','','{}',?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,spec=excluded.spec,slots=excluded.slots,deleted=excluded.deleted,sync_state='pending',sync_note='',updated=excluded.updated`,
		next.Spec.ID, owner, next.Endpoint, next.Hostname, next.Login, next.Spec.Revision, string(raw), slots, deleted, now.Unix(), next.Created)
	if e != nil {
		return Schedule{}, e
	}
	_, e = tx.Exec(`INSERT INTO fleet_schedule_changes(owner,idem,request,schedule_id) VALUES (?,?,?,?)`, owner, key, request, next.Spec.ID)
	if e != nil {
		return Schedule{}, e
	}
	if e = tx.Commit(); e != nil {
		return Schedule{}, e
	}
	return s.Schedule(owner, next.Spec.ID)
}
func (s *Store) PendingSchedules() ([]Schedule, error) {
	rows, e := s.read.Query(`SELECT ` + scheduleCols + ` FROM fleet_schedules WHERE sync_state='pending' ORDER BY last_install,id LIMIT 50`)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Schedule{}
	for rows.Next() {
		r, e := scanSchedule(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *Store) BindSchedule(r Schedule, endpoint, host, login string) error {
	_, e := s.write.Exec(`UPDATE fleet_schedules SET endpoint=?,hostname=?,login=? WHERE id=? AND owner=? AND endpoint='' AND revision=?`, endpoint, host, login, r.Spec.ID, r.Owner, r.Spec.Revision)
	return e
}
func (s *Store) ScheduleSynced(r Schedule, state, note, observed string) error {
	if observed == "" {
		observed = "{}"
	}
	_, e := s.write.Exec(`UPDATE fleet_schedules SET sync_state=?,sync_note=?,observed=?,last_install=? WHERE owner=? AND id=? AND revision=?`, state, note, observed, time.Now().Unix(), r.Owner, r.Spec.ID, r.Spec.Revision)
	return e
}

type ScheduleRun struct {
	ID         string          `json:"id"`
	ScheduleID string          `json:"schedule_id"`
	Owner      string          `json:"-"`
	Endpoint   string          `json:"-"`
	Revision   int64           `json:"revision"`
	Slot       string          `json:"slot"`
	Attempt    int             `json:"attempt"`
	Day        string          `json:"day"`
	State      string          `json:"state"`
	Started    int64           `json:"started"`
	Ended      int64           `json:"ended"`
	Summary    string          `json:"summary"`
	Error      string          `json:"error"`
	SessionID  string          `json:"session_id"`
	Delivery   json.RawMessage `json:"delivery"`
}

const scheduleRunCols = `id,schedule_id,owner,endpoint,revision,slot,attempt,day,state,started,ended,summary,error,session_id,delivery`

func scanScheduleRun(row interface{ Scan(...any) error }) (ScheduleRun, error) {
	var r ScheduleRun
	var d string
	e := row.Scan(&r.ID, &r.ScheduleID, &r.Owner, &r.Endpoint, &r.Revision, &r.Slot, &r.Attempt, &r.Day, &r.State, &r.Started, &r.Ended, &r.Summary, &r.Error, &r.SessionID, &d)
	r.Delivery = json.RawMessage(d)
	return r, e
}
func (s *Store) ScheduleRuns(owner, id string) ([]ScheduleRun, error) {
	rows, e := s.read.Query(`SELECT `+scheduleRunCols+` FROM fleet_schedule_runs WHERE owner=? AND schedule_id=? AND started>=? ORDER BY started DESC,id DESC LIMIT 60`, owner, id, time.Now().Add(-30*24*time.Hour).Unix())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []ScheduleRun{}
	for rows.Next() {
		r, e := scanScheduleRun(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *Store) ScheduleRun(owner, id string) (ScheduleRun, error) {
	return scanScheduleRun(s.read.QueryRow(`SELECT `+scheduleRunCols+` FROM fleet_schedule_runs WHERE owner=? AND id=?`, owner, id))
}
func (s *Store) ScheduleManual(owner, id, run string, now time.Time) error {
	_, e := s.write.Exec(`INSERT INTO fleet_schedule_manual(id,schedule_id,owner,created) VALUES (?,?,?,?) ON CONFLICT(id) DO NOTHING`, run, id, owner, now.Unix())
	if e != nil {
		return e
	}
	var savedOwner, savedID string
	if e = s.read.QueryRow(`SELECT owner,schedule_id FROM fleet_schedule_manual WHERE id=?`, run).Scan(&savedOwner, &savedID); e != nil {
		return e
	}
	if savedOwner != owner || savedID != id {
		return ErrScheduleConflict
	}
	return nil
}

// Admission is a persisted spend reservation, not a timer. Only the existing
// daemon asks when it has a due slot. Replaying an admitted attempt cannot spend
// twice or release another run's concurrency slot.
func (s *Store) AdmitSchedule(owner, endpoint, id, slot string, revision int64, attempt int, manual bool, now time.Time) (ScheduleRun, error) {
	tx, e := s.write.Begin()
	if e != nil {
		return ScheduleRun{}, e
	}
	defer tx.Rollback()
	if e = scheduleLock(tx, owner); e != nil {
		return ScheduleRun{}, e
	}
	spec, e := scanSchedule(tx.QueryRow(`SELECT `+scheduleCols+` FROM fleet_schedules WHERE owner=? AND id=? AND endpoint=?`, owner, id, endpoint))
	if e != nil {
		return ScheduleRun{}, e
	}
	rid := fmt.Sprintf("%s-%s-%d", id, slot, attempt)
	prev, e := scanScheduleRun(tx.QueryRow(`SELECT `+scheduleRunCols+` FROM fleet_schedule_runs WHERE id=? AND owner=?`, rid, owner))
	if e == nil {
		return prev, nil
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return ScheduleRun{}, e
	}
	if spec.Spec.Deleted || spec.Spec.Revision != revision || spec.SyncState != "synced" || (!spec.Spec.Enabled && !manual) {
		return ScheduleRun{}, ErrScheduleConflict
	}
	_, retries, delay := spec.Spec.Policy()
	if attempt < 1 || attempt > 1+retries {
		return ScheduleRun{}, ErrScheduleLimit
	}
	if spec.Spec.OnceAt != 0 && (manual || slot != strconv.FormatInt(spec.Spec.OnceAt, 10) || now.Unix() < spec.Spec.OnceAt) {
		return ScheduleRun{}, ErrScheduleConflict
	}
	if manual {
		var one int
		e = tx.QueryRow(`SELECT 1 FROM fleet_schedule_manual WHERE id=? AND owner=? AND schedule_id=?`, slot, owner, id).Scan(&one)
		if e != nil {
			return ScheduleRun{}, e
		}
	}
	if attempt > 1 {
		var state string
		var ended int64
		e = tx.QueryRow(`SELECT state,ended FROM fleet_schedule_runs WHERE schedule_id=? AND slot=? AND attempt=?`, id, slot, attempt-1).Scan(&state, &ended)
		if e != nil || state != "failed" {
			return ScheduleRun{}, ErrScheduleConflict
		}
		if spec.Spec.Execution != nil && now.Unix() < ended+int64(delay) {
			return ScheduleRun{}, ErrScheduleLimit // defer this attempt, do not cancel it
		}
	}
	loc, _ := time.LoadLocation("Asia/Shanghai")
	day := now.In(loc).Format("2006-01-02")
	var count, running int
	e = tx.QueryRow(`SELECT COUNT(*),COALESCE(SUM(CASE WHEN state='running' THEN 1 ELSE 0 END),0) FROM fleet_schedule_runs WHERE owner=? AND (day=? OR state='running')`, owner, day).Scan(&count, &running)
	if e != nil {
		return ScheduleRun{}, e
	}
	if running > 0 || count >= schedule.MaxDailyStarts {
		return ScheduleRun{}, ErrScheduleLimit
	}
	if attempt == 1 && !manual {
		var last int64
		e = tx.QueryRow(`SELECT COALESCE(MAX(started),0) FROM fleet_schedule_runs WHERE schedule_id=? AND attempt=1`, id).Scan(&last)
		if e != nil {
			return ScheduleRun{}, e
		}
		if last > 0 && now.Unix()-last < 3600 {
			return ScheduleRun{}, ErrScheduleLimit
		}
	}
	if spec.Spec.OnceAt != 0 && attempt == 1 {
		res, err := tx.Exec(`INSERT INTO fleet_schedule_once(schedule_id,slot,started) VALUES (?,?,?) ON CONFLICT(schedule_id) DO NOTHING`, id, slot, now.Unix())
		if err != nil {
			return ScheduleRun{}, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return ScheduleRun{}, err
		}
		if n != 1 {
			return ScheduleRun{}, ErrScheduleConflict
		}
	}
	if spec.Spec.OnceAt != 0 && attempt > 1 {
		if _, e = tx.Exec(`UPDATE fleet_schedule_once SET state='running',ended=0,attempt=? WHERE schedule_id=?`, attempt, id); e != nil {
			return ScheduleRun{}, e
		}
	}
	// Same UUID5 as fleet_schedule_run.py; admission persists it before launch.
	sessionID := uuid.NewSHA1(uuid.NameSpaceURL, []byte(fmt.Sprintf("%s:%s:%d", id, slot, attempt))).String()
	zone, _ := time.LoadLocation(spec.Spec.Timezone)
	title := spec.Spec.Name + " " + now.In(zone).Format("2006-01-02")
	consent, _ := json.Marshal(map[string]any{"consent": spec.Spec.Delivery, "consent_at": spec.Updated, "session_title": title})
	_, e = tx.Exec(`INSERT INTO fleet_schedule_runs(id,schedule_id,owner,endpoint,revision,slot,attempt,day,state,started,session_id,delivery) VALUES (?,?,?,?,?,?,?,?,'running',?,?,?)`, rid, id, owner, endpoint, revision, slot, attempt, day, now.Unix(), sessionID, string(consent))
	if e != nil {
		return ScheduleRun{}, e
	}
	if e = tx.Commit(); e != nil {
		return ScheduleRun{}, e
	}
	return s.ScheduleRun(owner, rid)
}
func (s *Store) FinishSchedule(owner, endpoint, id, state, summary, why, session string, now time.Time) (ScheduleRun, error) {
	if state != "succeeded" && state != "failed" {
		return ScheduleRun{}, ErrScheduleConflict
	}
	if state == "succeeded" && summary == "" {
		return ScheduleRun{}, errors.New("completed run requires a final answer")
	}
	_, e := s.write.Exec(`UPDATE fleet_schedule_runs SET state=?,summary=?,error=?,session_id=CASE WHEN session_id='' THEN ? ELSE session_id END,ended=? WHERE owner=? AND endpoint=? AND id=? AND state='running'`, state, summary, why, session, now.Unix(), owner, endpoint, id)
	if e != nil {
		return ScheduleRun{}, e
	}
	r, e := s.ScheduleRun(owner, id)
	if e != nil {
		return r, e
	}
	if r.Endpoint != endpoint || r.State != state || r.Summary != summary || r.Error != why {
		return r, ErrScheduleConflict
	}
	// Keep the one-shot terminal state even when detailed run history expires.
	// Retried finish requests also repair this projection after a transient error.
	_, e = s.write.Exec(`UPDATE fleet_schedule_once SET state=?,ended=? WHERE schedule_id=? AND attempt=?`, state, r.Ended, r.ScheduleID, r.Attempt)
	if e != nil {
		return r, e
	}
	return r, nil
}

func (s *Store) ScheduleOnce(owner, id string) (state string, started, ended int64, err error) {
	err = s.read.QueryRow(`SELECT o.state,o.started,o.ended FROM fleet_schedule_once o JOIN fleet_schedules s ON s.id=o.schedule_id WHERE s.owner=? AND s.id=?`, owner, id).Scan(&state, &started, &ended)
	return
}

func (s *Store) ScheduleDelivery(owner, id string, d json.RawMessage) error {
	_, e := s.write.Exec(`UPDATE fleet_schedule_runs SET delivery=? WHERE owner=? AND id=?`, string(d), owner, id)
	return e
}
func (s *Store) SchedulePage(owner, id string) (string, string, error) {
	var page, url string
	e := s.read.QueryRow(`SELECT proposal_id,url FROM fleet_schedule_pages WHERE owner=? AND schedule_id=?`, owner, id).Scan(&page, &url)
	if errors.Is(e, sql.ErrNoRows) {
		return "", "", nil
	}
	return page, url, e
}
func (s *Store) SaveSchedulePage(owner, id, page, url string) error {
	_, e := s.write.Exec(`INSERT INTO fleet_schedule_pages(schedule_id,owner,proposal_id,url) VALUES (?,?,?,?) ON CONFLICT(schedule_id) DO UPDATE SET proposal_id=excluded.proposal_id,url=excluded.url`, id, owner, page, url)
	return e
}
func (s *Store) ScheduleUnread(owner string) ([]ScheduleRun, error) {
	rows, e := s.read.Query(`SELECT `+scheduleRunCols+` FROM fleet_schedule_runs WHERE owner=? AND notified=0 AND state<>'running' AND started>=? ORDER BY started DESC LIMIT 30`, owner, time.Now().Add(-30*24*time.Hour).Unix())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []ScheduleRun{}
	for rows.Next() {
		r, e := scanScheduleRun(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *Store) ScheduleRead(owner, id string) error {
	_, e := s.write.Exec(`UPDATE fleet_schedule_runs SET notified=1 WHERE owner=? AND schedule_id=?`, owner, id)
	return e
}

// Outbox recovery after a finish committed but its response/notification did not.
func (s *Store) ScheduleUnqueued() ([]ScheduleRun, error) {
	rows, e := s.read.Query(`SELECT ` + scheduleRunCols + ` FROM fleet_schedule_runs WHERE state<>'running' AND delivery_queued=0 ORDER BY started LIMIT 50`)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []ScheduleRun{}
	for rows.Next() {
		r, e := scanScheduleRun(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *Store) ScheduleQueued(owner, id string) error {
	_, e := s.write.Exec(`UPDATE fleet_schedule_runs SET delivery_queued=1 WHERE owner=? AND id=?`, owner, id)
	return e
}
func (s *Store) PruneScheduleRuns(now time.Time) error {
	cutoff := now.Add(-30 * 24 * time.Hour).Unix()
	if _, e := s.write.Exec(`DELETE FROM fleet_schedule_runs WHERE state<>'running' AND started<?`, cutoff); e != nil {
		return e
	}
	_, e := s.write.Exec(`DELETE FROM fleet_schedule_manual WHERE created<?`, cutoff)
	return e
}

// ScheduleSession carries only list metadata, never every run's full conclusion.
type ScheduleSession struct {
	ID         string `json:"id"`
	ScheduleID string `json:"schedule_id"`
	SessionID  string `json:"session_id"`
	Title      string `json:"title"`
	Endpoint   string `json:"-"`
}

// ScheduleSessions is owner-scoped provenance for the existing conversation list.
// Deleted schedules retain associations for the result retention period.
func (s *Store) ScheduleSessions(owner string) (map[string]ScheduleSession, error) {
	rows, err := s.read.Query(`SELECT id,schedule_id,session_id,endpoint,delivery FROM fleet_schedule_runs WHERE owner=? AND session_id<>'' AND started>=?`, owner, time.Now().Add(-30*24*time.Hour).Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]ScheduleSession{}
	for rows.Next() {
		var r ScheduleSession
		var delivery string
		if err := rows.Scan(&r.ID, &r.ScheduleID, &r.SessionID, &r.Endpoint, &delivery); err != nil {
			return nil, err
		}
		var snapshot struct {
			Title string `json:"session_title"`
		}
		_ = json.Unmarshal([]byte(delivery), &snapshot)
		r.Title = snapshot.Title
		out[r.SessionID] = r
	}
	return out, rows.Err()
}
