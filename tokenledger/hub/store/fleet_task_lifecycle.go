package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Version 1 is a dispatched task's record: its ticket — who asked, for what, in
// which repo, by which agent. It holds no execution (EPIC T497 C8): the session
// is its window's ID, and the record's end is that ID's result.
const TaskAuthorityVersion = 1
const (
	TaskAccepted  = "accepted"
	TaskStarting  = "starting"
	TaskRunning   = "running"
	TaskWaiting   = "waiting"
	TaskSucceeded = "succeeded"
	TaskFailed    = "failed"
	TaskCancelled = "cancelled"
)

var (
	ErrTaskConflict = errors.New("task request conflicts with its accepted payload or current state")
	ErrTaskFence    = errors.New("task owner or generation does not match")
	ErrTaskInvalid  = errors.New("invalid authoritative task request")
)

func taskTerminal(state string) bool {
	return state == TaskSucceeded || state == TaskFailed || state == TaskCancelled || state == TaskRefused
}

// TicketGitHub is the one backend a task's ticket_ref names: a GitHub issue,
// `gh:<repo>#<N>`. The hub's own tickets are gone (claude-fleet#4898, T477).
const TicketGitHub = "gh"

// taskTicket parses a fully qualified backlog reference; never a bare number.
// It retains the issue's lease key so legacy claimants cannot bypass a task.
func taskTicket(ref string) (repo string, number int64, err error) {
	backend, rest, ok := strings.Cut(ref, ":")
	r, n, has := strings.Cut(rest, "#")
	num, e := strconv.ParseInt(n, 10, 64)
	if !ok || !has || e != nil || num <= 0 || strconv.FormatInt(num, 10) != n || r == "" || strings.ContainsAny(r, "# \t\n:") || backend != TicketGitHub {
		return "", 0, ErrTaskInvalid
	}
	r = NormRepo(r)

	return r, num, nil
}

// acceptedTaskInput is immutable even after a later generation or result.
// The opaque payload carries the complete dispatch input for later consumers.
type acceptedTaskInput struct {
	Title, Via, Device, Repo, Agent, RequestedAgent, ResolvedAgent string
	TicketRef, ParentTask, ParentSession                           string
	Payload                                                        json.RawMessage
}

func taskAcceptedInput(t *FleetTask) (string, error) {
	if t.AuthorityVersion != TaskAuthorityVersion || t.Owner == "" || t.Title == "" || t.RequestedAgent == "" || t.ResolvedAgent == "" ||
		(t.State != "" && t.State != TaskAccepted) || t.WorkerID != "" || t.ActualAgent != "" || t.Generation != 0 {
		return "", ErrTaskInvalid
	}
	if t.TicketRef != "" {
		r, _, err := taskTicket(t.TicketRef)
		if err != nil {
			return "", err
		}
		t.TicketRef = strings.ToLower(t.TicketRef)
		r = strings.TrimPrefix(r, "hub:")
		if t.Repo != "" && NormRepo(t.Repo) != r {
			return "", ErrTaskInvalid
		}
		t.Repo = r
	}
	if t.ParentTask != "" && ParseTaskRef(t.ParentTask) == 0 {
		return "", ErrTaskInvalid
	}
	if t.RequestPayload == "" {
		t.RequestPayload = "{}"
	}
	var payload any
	if !json.Valid([]byte(t.RequestPayload)) {
		return "", ErrTaskInvalid
	}
	decoder := json.NewDecoder(strings.NewReader(t.RequestPayload))
	decoder.UseNumber()
	if decoder.Decode(&payload) != nil {
		return "", ErrTaskInvalid
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	t.RequestPayload = string(b)
	input := acceptedTaskInput{t.Title, t.Via, t.Device, t.Repo, t.Agent, t.RequestedAgent, t.ResolvedAgent,
		t.TicketRef, t.ParentTask, t.ParentSession, b}
	b, err = json.Marshal(input)
	return string(b), err
}

func (s *Store) taskInTx(tx *sql.Tx, id int64) (FleetTask, error) {
	rows, err := tx.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE id = ?`+s.d.forUpdate(), id)
	if err != nil {
		return FleetTask{}, err
	}
	ts, err := scanFleetTasks(rows)
	if err != nil {
		return FleetTask{}, err
	}
	if len(ts) != 1 {
		return FleetTask{}, sql.ErrNoRows
	}
	return ts[0], nil
}

func (s *Store) acceptFleetTask(t FleetTask, token string, now time.Time) (FleetTask, error) {
	if token == "" {
		return FleetTask{}, ErrTaskInvalid
	}
	input, err := taskAcceptedInput(&t)
	if err != nil {
		return FleetTask{}, err
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, err
	}
	defer tx.Rollback()
	if err = s.d.claimWrites(tx, "fleet_tasks"); err != nil {
		return FleetTask{}, err
	}
	if err = s.ownerStartTx(tx, t.Owner, true); err != nil {
		return FleetTask{}, err
	}
	if t.ParentTask != "" {
		var owner string
		if err = tx.QueryRow(`SELECT owner FROM fleet_tasks WHERE id = ?`, ParseTaskRef(t.ParentTask)).Scan(&owner); err != nil || owner != t.Owner {
			return FleetTask{}, ErrTaskFence
		}
	}
	ts := now.UTC().Format(rfc)
	res, err := tx.Exec(`INSERT INTO fleet_tasks (token, owner, title, via, device, repo, agent, state,
  authority_version, generation, requested_agent, resolved_agent, parent_task, parent_session, ticket_ref,
  request_payload, accepted_request, created_at, updated_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(token) DO NOTHING`, token, t.Owner, t.Title, t.Via, t.Device, t.Repo, t.Agent, TaskAccepted,
		t.RequestedAgent, t.ResolvedAgent, t.ParentTask, t.ParentSession, t.TicketRef, t.RequestPayload, input, ts, ts)
	if err != nil {
		return FleetTask{}, err
	}
	var id int64
	if err = tx.QueryRow(`SELECT id FROM fleet_tasks WHERE token = ?`, token).Scan(&id); err != nil {
		return FleetTask{}, err
	}
	rec, err := s.taskInTx(tx, id)
	if err != nil {
		return FleetTask{}, err
	}
	if rec.Owner != t.Owner {
		return FleetTask{}, ErrTaskFence
	}
	if rec.acceptedRequest != input || rec.AuthorityVersion != TaskAuthorityVersion {
		return FleetTask{}, ErrTaskConflict
	}
	n, err := res.RowsAffected()
	if err != nil {
		return FleetTask{}, err
	}
	if n == 0 {
		// The same token again: the same record, as it stands now.
		return rec, tx.Commit()
	}
	// The parent named on the first acceptance only: replaying the request never
	// re-parents the child.
	if err = s.bindTaskParentTx(tx, &rec); err != nil {
		return FleetTask{}, err
	}
	// attempt_id names the one dispatch the envelope carries (`task:T<n>:g1`) —
	// a name a node's dispatch check still reads, not an attempt journal.
	rec.AttemptID = fmt.Sprintf("task:%s:g%d", rec.Ref, rec.Generation)
	if _, err = tx.Exec(`UPDATE fleet_tasks SET parent_task = ?, parent_session = ?, parent_generation = ?, attempt_id = ? WHERE id = ?`,
		rec.ParentTask, rec.ParentSession, rec.ParentGeneration, rec.AttemptID, rec.ID); err != nil {
		return FleetTask{}, err
	}
	// EPIC T644 C1: the task's ID, minted with the record — one transaction.
	if err = s.taskIDTx(tx, &rec, "", now); err != nil {
		return FleetTask{}, err
	}
	return rec, tx.Commit()
}

// CancelUnopenedTask ends a record no window ever opened (EPIC T497 C13, kept by
// C8): accepted, no outcome, and no open ID carrying its number. It is the one
// change the hub still takes on a task record — a session's end is its ID's
// result (IDTaskOutcome). A record already cancelled answers itself.
func (s *Store) CancelUnopenedTask(id int64, owner, evidence string, now time.Time) (FleetTask, error) {
	if evidence == "" {
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
	if t.AuthorityVersion != TaskAuthorityVersion || t.Owner != owner {
		return FleetTask{}, ErrTaskFence
	}
	if t.Outcome == TaskCancelled {
		return t, tx.Commit()
	}
	if err = s.unopenedCancelAllowed(tx, t); err != nil {
		return FleetTask{}, err
	}
	t.State, t.Outcome, t.Evidence, t.UpdatedAt = TaskCancelled, TaskCancelled, evidence, now.UTC()
	if _, err = tx.Exec(`UPDATE fleet_tasks SET state = ?, outcome = ?, evidence = ?, updated_at = ? WHERE id = ? AND owner = ? AND authority_version = 1`,
		t.State, t.Outcome, t.Evidence, now.UTC().Format(rfc), t.ID, t.Owner); err != nil {
		return FleetTask{}, err
	}
	return t, tx.Commit()
}

// RetitleTask renames an authoritative record ONCE (claude-fleet T652, EPIC T651
// C1): a blank new session opens on a placeholder title (「新会话」) and its first
// prompt's first line replaces it. Compare-and-set on `from` — the title the
// record still has to carry — so the rename happens once and a later prompt, or
// another writer, changes nothing (the record answers itself unchanged).
func (s *Store) RetitleTask(id int64, owner, from, to string, now time.Time) (FleetTask, error) {
	if strings.TrimSpace(from) == "" || strings.TrimSpace(to) == "" {
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
	if t.AuthorityVersion != TaskAuthorityVersion || t.Owner != owner {
		return FleetTask{}, ErrTaskFence
	}
	if t.Title != from {
		return t, tx.Commit()
	}
	t.Title, t.UpdatedAt = to, now.UTC()
	if _, err = tx.Exec(`UPDATE fleet_tasks SET title = ?, updated_at = ? WHERE id = ? AND owner = ? AND title = ? AND authority_version = 1`,
		t.Title, now.UTC().Format(rfc), t.ID, t.Owner, from); err != nil {
		return FleetTask{}, err
	}
	return t, tx.Commit()
}
