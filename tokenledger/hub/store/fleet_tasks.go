package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// The task record (claude-fleet#3325, EPIC #3178): ONE row per thing a person
// asked for — ⌘P's words — kept on the hub as T<id>. The record comes first:
// the hub writes it, then picks the machine and opens the session; only a task
// that chose a repo (a change that ends in a PR) also gets a GitHub issue, which
// hangs on the record as an attachment. A task with no repo is the record alone
// — the desk ticket that used to stand in for it is retired.
//
// The row holds who asked, from where, where it landed and what hangs on it;
// how the session is doing right now (the agent's own state, its context left)
// is read live off the inventory by worker_id for legacy records. Version 1
// records own their lifecycle explicitly (fleet_task_lifecycle.go).
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetTasksSchema = `
CREATE TABLE IF NOT EXISTS fleet_tasks (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  token        TEXT NOT NULL UNIQUE,
  owner        TEXT NOT NULL,
  title        TEXT NOT NULL,
  via          TEXT NOT NULL DEFAULT '',
  device       TEXT NOT NULL DEFAULT '',
  repo         TEXT NOT NULL DEFAULT '',
  agent        TEXT NOT NULL DEFAULT '',
  machine      TEXT NOT NULL DEFAULT '',
  login        TEXT NOT NULL DEFAULT '',
  worker_id    TEXT NOT NULL DEFAULT '',
  session_key  TEXT NOT NULL DEFAULT '',
  operation_id TEXT NOT NULL DEFAULT '',
  state        TEXT NOT NULL DEFAULT 'placing',
  note         TEXT NOT NULL DEFAULT '',
  issue        TEXT NOT NULL DEFAULT '',
  pr           TEXT NOT NULL DEFAULT '',
  asked        TEXT NOT NULL DEFAULT '',
  parked       TEXT NOT NULL DEFAULT '',
  rule         TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_tasks_owner ON fleet_tasks(owner, id);
CREATE INDEX IF NOT EXISTS fleet_tasks_op ON fleet_tasks(operation_id);`

// Task states — where the record's session stands as the hub saw its start.
// The session's own state afterwards is the inventory's, not one of these.
const (
	TaskPlacing = "placing" // the record is written, the start is on its way
	TaskOpen    = "open"    // a machine opened its session
	TaskRefused = "refused" // no machine took it, or the one chosen said no
	TaskUnknown = "unknown" // the start has no final word yet
)

// FleetTask is one task record.
type FleetTask struct {
	ID          int64  `json:"-"`
	Ref         string `json:"id"` // T<id>
	Owner       string `json:"owner"`
	Title       string `json:"title"`
	Via         string `json:"via"`
	Device      string `json:"device"`
	Repo        string `json:"repo"`
	Agent       string `json:"agent"`
	Machine     string `json:"machine"`
	Login       string `json:"login"`
	WorkerID    string `json:"worker_id"`
	SessionKey  string `json:"session_key"`
	OperationID string `json:"operation_id"`
	State       string `json:"state"`
	Note        string `json:"note"`
	Issue       string `json:"issue"`
	PR          string `json:"pr"`
	Asked       string `json:"asked"`
	Parked      string `json:"parked"`
	// Rule is the dispatch rule a coordinator's record was given under
	// (claude-fleet#3330): `n=<N> v=<version>`, the issue body's marker's words.
	Rule string `json:"rule,omitempty"`
	// AuthorityVersion 0 keeps the legacy placement record. Version 1 is a
	// dispatched task's ticket; its end is its window's ID's result (EPIC T497
	// C8). Inventory is only an observation, never an outcome.
	AuthorityVersion int    `json:"authority_version,omitempty"`
	AttemptID        string `json:"attempt_id,omitempty"`
	Generation       int64  `json:"generation,omitempty"`
	// The execution owner / endpoint a launch proof claimed, before EPIC T497
	// C8: archive fields of a pre-C8 record, read for its migration and
	// shown as they were; nothing writes them.
	ExecutionOwner    string `json:"execution_owner,omitempty"`
	ExecutionEndpoint string `json:"execution_endpoint,omitempty"`
	RequestedAgent    string `json:"requested_agent,omitempty"`
	ResolvedAgent     string `json:"resolved_agent,omitempty"`
	ActualAgent       string `json:"actual_agent,omitempty"`
	ParentTask        string `json:"parent_task,omitempty"`
	ParentSession     string `json:"parent_session,omitempty"`
	ParentGeneration  int64  `json:"parent_generation,omitempty"`
	CancelRequest     string `json:"cancel_request,omitempty"`
	TicketRef         string `json:"ticket_ref,omitempty"`
	LeaseRef          string `json:"lease_ref,omitempty"`
	Outcome           string `json:"outcome,omitempty"`
	Evidence          string `json:"evidence,omitempty"`
	Observation       string `json:"observation,omitempty"`
	// RequestPayload is the accepted dispatch input (JSON). It is immutable;
	// subsequent generations retain their inputs in the operation journal.
	RequestPayload  string `json:"request_payload,omitempty"`
	acceptedRequest string
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
	token           string
}

// TaskRef is a record's number as people write it: T218.
func TaskRef(id int64) string { return "T" + strconv.FormatInt(id, 10) }

// ParseTaskRef reads T218 (or a bare 218) back; 0 when it is not one.
func ParseTaskRef(ref string) int64 {
	ref = strings.TrimPrefix(strings.TrimSpace(ref), "T")
	n, err := strconv.ParseInt(ref, 10, 64)
	if err != nil || n <= 0 || strconv.FormatInt(n, 10) != ref {
		return 0
	}
	return n
}

func (s *Store) ensureFleetTasks() error {
	if _, err := s.write.Exec(s.d.ddl(fleetTasksSchema)); err != nil {
		return fmt.Errorf("create fleet_tasks table: %w", err)
	}
	// claude-fleet#3330: the rule a coordinator dispatched it under.
	if err := s.addColumn("fleet_tasks", "rule", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	for _, col := range []string{"attempt_id", "execution_owner", "execution_endpoint", "requested_agent", "resolved_agent", "actual_agent",
		"parent_task", "parent_session", "ticket_ref", "lease_ref", "outcome", "evidence", "observation", "request_payload", "accepted_request", "cancel_request"} {
		if err := s.addColumn("fleet_tasks", col, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	for _, col := range []string{"authority_version", "generation", "parent_generation"} {
		if err := s.addColumn("fleet_tasks", col, "INTEGER NOT NULL DEFAULT 0"); err != nil {
			return err
		}
	}
	return nil
}

const fleetTaskCols = `id, token, owner, title, via, device, repo, agent, machine, login, worker_id,
	session_key, operation_id, state, note, issue, pr, asked, parked, rule, created_at, updated_at,
	authority_version, generation, attempt_id, execution_owner, execution_endpoint, requested_agent, resolved_agent, actual_agent,
	parent_task, parent_session, ticket_ref, lease_ref, outcome, evidence, observation, request_payload, accepted_request, parent_generation, cancel_request`

// CreateFleetTask writes a new record and returns it with its number. token is
// the caller's one-time key (the place's idempotency key): writing the same
// token twice returns the first record, never a second one.
func (s *Store) CreateFleetTask(t FleetTask, token string, now time.Time) (FleetTask, error) {
	if t.AuthorityVersion != 0 {
		return s.acceptFleetTask(t, token, now)
	}
	if token == "" || t.Owner == "" || t.Title == "" {
		return FleetTask{}, errors.New("a task needs a token, an owner and a title")
	}
	if old, err := s.fleetTaskBy(`token = ?`, token); err == nil {
		if old.AuthorityVersion != 0 {
			return FleetTask{}, ErrTaskFence
		}
		return old, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return FleetTask{}, err
	}
	ts := now.UTC().Format(rfc)
	state := t.State
	if state == "" {
		state = TaskPlacing
	}
	if _, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_tasks (token, owner, title, via, device, repo, agent,
		machine, login, worker_id, session_key, operation_id, state, note, issue, pr, asked, parked, rule, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`),
		token, t.Owner, t.Title, t.Via, t.Device, t.Repo, t.Agent, t.Machine, t.Login, t.WorkerID, t.SessionKey,
		t.OperationID, state, t.Note, t.Issue, t.PR, t.Asked, t.Parked, t.Rule, ts, ts); err != nil {
		return FleetTask{}, err
	}
	rec, err := s.fleetTaskBy(`token = ?`, token)
	if err == nil && rec.AuthorityVersion != 0 {
		return FleetTask{}, ErrTaskFence
	}
	return rec, err
}

// FleetTaskUpdate is what a start's answer (or a later step) adds to a record;
// an empty field is left as it is, and a column named in Clear is emptied (a
// question answered, a park lifted — claude-fleet#3330).
type FleetTaskUpdate struct {
	Machine, Login, WorkerID, SessionKey, OperationID, State, Note, Issue, PR, Asked, Parked, Rule string
	Clear                                                                                          []string
}

// taskClearable are the columns a FleetTaskUpdate may empty.
var taskClearable = map[string]bool{"asked": true, "parked": true, "note": true}

// UpdateFleetTask fills the record's non-empty fields from u and returns it.
func (s *Store) UpdateFleetTask(id int64, u FleetTaskUpdate, now time.Time) (FleetTask, error) {
	old, err := s.FleetTask(id)
	if err != nil {
		return FleetTask{}, err
	}
	if old.AuthorityVersion != 0 {
		return FleetTask{}, ErrTaskFence
	}
	if old.State == TaskClosed {
		u.State = "" // settled on evidence (claude-fleet#4867): a late word never reopens it
	}
	sets, args := []string{}, []any{}
	for _, f := range []struct {
		col, v string
	}{{"machine", u.Machine}, {"login", u.Login}, {"worker_id", u.WorkerID}, {"session_key", u.SessionKey},
		{"operation_id", u.OperationID}, {"state", u.State}, {"note", u.Note}, {"issue", u.Issue}, {"pr", u.PR},
		{"asked", u.Asked}, {"parked", u.Parked}, {"rule", u.Rule}} {
		if f.v != "" {
			sets, args = append(sets, f.col+" = ?"), append(args, f.v)
		}
	}
	for _, c := range u.Clear {
		if !taskClearable[c] {
			return FleetTask{}, fmt.Errorf("a task's %q cannot be cleared", c)
		}
		sets, args = append(sets, c+" = ?"), append(args, "")
	}
	if len(sets) > 0 {
		sets, args = append(sets, "updated_at = ?"), append(args, now.UTC().Format(rfc))
		res, err := s.write.Exec(`UPDATE fleet_tasks SET `+strings.Join(sets, ", ")+` WHERE id = ? AND authority_version = 0`, append(args, id)...)
		if err != nil {
			return FleetTask{}, err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return FleetTask{}, sql.ErrNoRows
		}
	}
	return s.FleetTask(id)
}

// FleetTask reads one record; sql.ErrNoRows when there is none.
func (s *Store) FleetTask(id int64) (FleetTask, error) { return s.fleetTaskBy(`id = ?`, id) }

// FleetTaskByOperation is the record a start's operation belongs to.
func (s *Store) FleetTaskByOperation(opID string) (FleetTask, error) {
	if opID == "" {
		return FleetTask{}, sql.ErrNoRows
	}
	return s.fleetTaskBy(`operation_id = ?`, opID)
}

// FleetTasksFor lists one person's records, newest first; owner "" lists
// everyone's (the operator's door).
func (s *Store) FleetTasksFor(owner string, limit int) ([]FleetTask, error) {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	q, args := `SELECT `+fleetTaskCols+` FROM fleet_tasks`, []any{}
	if owner != "" {
		q, args = q+` WHERE owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(q+` ORDER BY id DESC LIMIT `+strconv.Itoa(limit), args...)
	if err != nil {
		return nil, err
	}
	return scanFleetTasks(rows)
}

func (s *Store) fleetTaskBy(where string, arg any) (FleetTask, error) {
	rows, err := s.read.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE `+where+` ORDER BY id LIMIT 1`, arg)
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

func scanFleetTasks(rows *sql.Rows) ([]FleetTask, error) {
	defer rows.Close()
	var out []FleetTask
	for rows.Next() {
		var t FleetTask
		var created, updated string
		if err := rows.Scan(&t.ID, &t.token, &t.Owner, &t.Title, &t.Via, &t.Device, &t.Repo, &t.Agent, &t.Machine,
			&t.Login, &t.WorkerID, &t.SessionKey, &t.OperationID, &t.State, &t.Note, &t.Issue, &t.PR, &t.Asked,
			&t.Parked, &t.Rule, &created, &updated,
			&t.AuthorityVersion, &t.Generation, &t.AttemptID, &t.ExecutionOwner, &t.ExecutionEndpoint, &t.RequestedAgent, &t.ResolvedAgent,
			&t.ActualAgent, &t.ParentTask, &t.ParentSession, &t.TicketRef, &t.LeaseRef, &t.Outcome, &t.Evidence,
			&t.Observation, &t.RequestPayload, &t.acceptedRequest, &t.ParentGeneration, &t.CancelRequest); err != nil {
			return nil, err
		}
		t.Ref = TaskRef(t.ID)
		t.CreatedAt, _ = time.Parse(rfc, created)
		t.UpdatedAt, _ = time.Parse(rfc, updated)
		out = append(out, t)
	}
	return out, rows.Err()
}
