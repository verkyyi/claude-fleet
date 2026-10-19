package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Version 1 is additive and opt-in. No existing record is adopted implicitly.
// Account owner authorizes the request; execution owner is a worker identity.
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

// taskTicket parses a fully qualified backlog reference; never a bare number.
// Both backends retain the existing lease key so legacy claimants cannot
// bypass a task. The full backend reference stays on the task; a collision
// with a registered local ticket is refused, never reinterpreted. Explicit
// repo migration must allocate distinct local ticket numbers (C5).
func taskTicket(ref string) (repo string, number int64, err error) {
	backend, rest, ok := strings.Cut(ref, ":")
	r, n, has := strings.Cut(rest, "#")
	num, e := strconv.ParseInt(n, 10, 64)
	if !ok || !has || e != nil || num <= 0 || strconv.FormatInt(num, 10) != n || r == "" || strings.ContainsAny(r, "# \t\n:") || (backend != TicketHub && backend != TicketGitHub) {
		return "", 0, ErrTaskInvalid
	}
	r = NormRepo(r)

	return r, num, nil
}

func taskLeaseKey(t FleetTask) (string, int64) {
	if t.TicketRef == "" {
		return "task:" + t.Ref, 0
	}
	r, n, _ := taskTicket(t.TicketRef)
	return r, n
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
		(t.State != "" && t.State != TaskAccepted) || t.ExecutionOwner != "" || t.WorkerID != "" || t.ActualAgent != "" || t.Generation != 0 {
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
	if t.TicketRef != "" {
		backend, _, _ := strings.Cut(t.TicketRef, ":")
		r, n, _ := taskTicket(t.TicketRef)
		var ticketOwner, ticketBackend string
		err = tx.QueryRow(`SELECT owner, backend FROM fleet_tickets WHERE repo = ? AND num = ? AND backend = ?`, strings.TrimPrefix(r, "hub:"), n, backend).Scan(&ticketOwner, &ticketBackend)
		if errors.Is(err, sql.ErrNoRows) && backend == TicketGitHub {
			// A colliding hub number cannot hide the original GH reference's
			// owner in the full-ID registry retained by selective adoption.
			err = tx.QueryRow(`SELECT owner, backend FROM fleet_ticket_index WHERE id = ?`, t.TicketRef).Scan(&ticketOwner, &ticketBackend)
		}
		if err == nil && (ticketOwner != t.Owner || ticketBackend != backend) {
			return FleetTask{}, ErrTaskFence
		}
		if errors.Is(err, sql.ErrNoRows) && backend == TicketHub {
			return FleetTask{}, ErrTaskInvalid
		}
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return FleetTask{}, err
		}
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
		// The original accepted result, even if the current row has since advanced.
		var raw string
		err = tx.QueryRow(`SELECT request FROM fleet_operations WHERE id = ?`, taskAttemptID(id, 1)).Scan(&raw)
		if err != nil {
			return FleetTask{}, err
		}
		// Fields omitted from the accepted JSON must not retain the current
		// row's later ticket/native/result values when replaying acceptance.
		rec = FleetTask{}
		if err = json.Unmarshal([]byte(raw), &rec); err != nil {
			return FleetTask{}, err
		}
		rec.ID = id
		return rec, tx.Commit()
	}
	// Snapshot the parent generation only on the first acceptance. Replaying
	// the original request after a parent restart never re-parents the child.
	if err = s.bindTaskParentTx(tx, &rec); err != nil {
		return FleetTask{}, err
	}
	rec.AttemptID = taskAttemptID(id, 1)
	if err = s.saveTaskTx(tx, rec, now); err != nil {
		return FleetTask{}, err
	}
	if err = taskAttemptTx(tx, rec, now); err != nil {
		return FleetTask{}, err
	}
	return rec, tx.Commit()
}

func taskAttemptID(id, generation int64) string {
	return fmt.Sprintf("task:%s:g%d", TaskRef(id), generation)
}

// TaskMutation is one fenced, idempotent command. A retry is allowed only
// after a terminal result and release of its pinned execution lease. A transfer
// requires explicit stopped evidence from the current executor; lease expiry
// alone never authorizes either command. stop_ack releases a retained terminal
// execution without changing its task outcome.
// EndpointID is the authenticated node, not a field to accept from JSON.
type TaskMutation struct {
	Key              string              `json:"idempotency_key"`
	Kind             string              `json:"kind"` // claim | transition | retry | transfer | cancel_request | cancel_ack | stop_ack | blocker
	ExpectedWorker   string              `json:"expected_worker"`
	Generation       int64               `json:"generation"`
	WorkerID         string              `json:"worker_id,omitempty"`
	EndpointID       string              `json:"-"`
	FleetID          string              `json:"-"`
	State            string              `json:"state,omitempty"`
	ActualAgent      string              `json:"actual_agent,omitempty"`
	RequestedAgent   string              `json:"requested_agent,omitempty"`
	ResolvedAgent    string              `json:"resolved_agent,omitempty"`
	Evidence         string              `json:"evidence,omitempty"`
	ExecutionStopped bool                `json:"execution_stopped,omitempty"`
	Observation      string              `json:"observation,omitempty"`
	SessionKey       string              `json:"session_key,omitempty"`
	CancelRequest    string              `json:"cancel_request,omitempty"`
	Blocker          *TaskBlockerCommand `json:"blocker,omitempty"`
	TicketRef        string              `json:"ticket_ref,omitempty"` // ticket_link only; accepted input remains immutable
	FilingID         string              `json:"filing_id,omitempty"`  // durable local filing incarnation, prepare/link only
}

func (s *Store) MutateFleetTask(id int64, owner string, m TaskMutation, now time.Time) (FleetTask, error) {
	// A start is its owner's (claude-fleet#4896): take that person's authority
	// lock before the task row lock, in the same order as acceptance/cutover;
	// lifecycle reports remain open. The row's owner is fenced below.
	starts := m.Kind == "claim" || m.Kind == "retry" || m.Kind == "transfer" || m.Kind == "ticket_prepare" || m.Kind == "ticket_link"
	// Refuse fields that this command cannot apply, rather than silently
	// accepting a requested provider/owner change on a transition.
	if m.CancelRequest != "" && m.Kind != "cancel_ack" {
		return FleetTask{}, ErrTaskInvalid
	}
	if (m.Kind == "blocker") != (m.Blocker != nil) {
		return FleetTask{}, ErrTaskInvalid
	}
	if m.TicketRef != "" && m.Kind != "ticket_link" {
		return FleetTask{}, ErrTaskInvalid
	}
	if m.FilingID != "" && m.Kind != "ticket_prepare" && m.Kind != "ticket_link" {
		return FleetTask{}, ErrTaskInvalid
	}
	switch m.Kind {
	case "ticket_prepare", "ticket_link":
		if !taskFilingIDRE.MatchString(m.FilingID) {
			return FleetTask{}, ErrTaskInvalid
		}
		if m.ExpectedWorker != "" || m.WorkerID != "" || m.State != "" || m.ActualAgent != "" || m.RequestedAgent != "" || m.ResolvedAgent != "" || m.Observation != "" || m.SessionKey != "" || m.ExecutionStopped || m.Evidence != "" {
			return FleetTask{}, ErrTaskInvalid
		}
		key := fmt.Sprintf("ticket-file:g%d", m.Generation)
		if m.Kind == "ticket_link" {
			key = fmt.Sprintf("ticket-link:g%d", m.Generation)
			if m.TicketRef == "" {
				return FleetTask{}, ErrTaskInvalid
			}
		}
		if m.Key != key {
			return FleetTask{}, ErrTaskInvalid
		}
	case "blocker":
		if m.WorkerID != "" || m.State != "" || m.ActualAgent != "" || m.RequestedAgent != "" || m.ResolvedAgent != "" || m.Observation != "" || m.SessionKey != "" || m.ExecutionStopped || m.Evidence != "" {
			return FleetTask{}, ErrTaskInvalid
		}
	case "cancel_request", "cancel_ack", "stop_ack":
		if m.WorkerID != "" || m.State != "" || m.ActualAgent != "" || m.RequestedAgent != "" || m.ResolvedAgent != "" || m.Observation != "" || m.SessionKey != "" || m.Evidence == "" {
			return FleetTask{}, ErrTaskInvalid
		}
		if m.Kind == "cancel_request" && m.ExecutionStopped {
			return FleetTask{}, ErrTaskInvalid
		}
	case "claim":
		if m.State != "" || m.ActualAgent != "" || m.RequestedAgent != "" || m.ResolvedAgent != "" || m.Evidence != "" || m.ExecutionStopped || m.Observation != "" {
			return FleetTask{}, ErrTaskInvalid
		}
	case "transition":
		if m.WorkerID != "" || m.RequestedAgent != "" || m.ResolvedAgent != "" {
			return FleetTask{}, ErrTaskInvalid
		}
	case "retry", "transfer":
		if m.WorkerID != "" || m.State != "" || m.ActualAgent != "" || m.Observation != "" || m.SessionKey != "" {
			return FleetTask{}, ErrTaskInvalid
		}
	default:
		return FleetTask{}, ErrTaskInvalid
	}
	if m.Key == "" || m.Generation < 1 || m.EndpointID == "" || (m.Observation != "" && m.Observation != "unknown" && m.Observation != "stale") {
		return FleetTask{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, err
	}
	defer tx.Rollback()
	if starts {
		if err = s.ownerStartTx(tx, owner, true); err != nil {
			return FleetTask{}, err
		}
	}
	if err = s.d.claimWrites(tx, "fleet_tasks"); err != nil {
		return FleetTask{}, err
	}
	if err = s.d.lockKey(tx, "fleet_tasks", "task-blockers:"+owner); err != nil {
		return FleetTask{}, err
	}
	t, err := s.taskInTx(tx, id)
	if err != nil {
		return FleetTask{}, err
	}
	if t.AuthorityVersion != TaskAuthorityVersion || t.Owner != owner {
		return FleetTask{}, ErrTaskFence
	}
	// Include server-authenticated identities in the idempotency payload too.
	raw, _ := json.Marshal(struct {
		Task            string
		Command         TaskMutation
		Endpoint, Fleet string
	}{t.Ref, m, m.EndpointID, m.FleetID})
	idem := "task-event:" + t.Ref + ":" + m.Key
	var request, result string
	err = tx.QueryRow(`SELECT request, result FROM fleet_operations WHERE actor = ? AND idem = ?`, owner, idem).Scan(&request, &result)
	if err == nil {
		if request != string(raw) {
			return FleetTask{}, ErrTaskConflict
		}
		var old FleetTask
		if err = json.Unmarshal([]byte(result), &old); err != nil {
			return FleetTask{}, err
		}
		old.ID = id
		return old, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return FleetTask{}, err
	}
	if t.Generation != m.Generation || t.ExecutionOwner != m.ExpectedWorker ||
		(m.Kind != "cancel_request" && t.ExecutionEndpoint != "" && t.ExecutionEndpoint != m.EndpointID) {
		return FleetTask{}, ErrTaskFence
	}
	eventID := fmt.Sprintf("task-event:%x", sha256.Sum256([]byte(owner+"\x00"+idem)))
	switch m.Kind {
	case "ticket_prepare", "ticket_link":
		if err = s.linkTaskTicketTx(tx, &t, m); err != nil {
			return FleetTask{}, err
		}
	case "blocker":
		if err = s.applyTaskBlockerTx(tx, t, m.EndpointID, eventID, *m.Blocker, now); err != nil {
			return FleetTask{}, err
		}
	case "stop_ack":
		if !taskTerminal(t.State) || t.ExecutionOwner == "" || !m.ExecutionStopped {
			return FleetTask{}, ErrTaskConflict
		}
		if err = releaseTaskLeaseTx(tx, t); err != nil {
			return FleetTask{}, err
		}
	case "cancel_request":
		if taskTerminal(t.State) || t.CancelRequest != "" {
			return FleetTask{}, ErrTaskConflict
		}
		t.CancelRequest = m.Key // Intent only: retain execution owner and lease.
	case "cancel_ack":
		if taskTerminal(t.State) || t.CancelRequest == "" || t.CancelRequest != m.CancelRequest || !m.ExecutionStopped {
			return FleetTask{}, ErrTaskConflict
		}
		t.State, t.Outcome, t.Evidence = TaskCancelled, TaskCancelled, m.Evidence
		if err = releaseTaskLeaseTx(tx, t); err != nil {
			return FleetTask{}, err
		}
	case "claim":
		if t.State != TaskAccepted || t.ExecutionOwner != "" || m.WorkerID == "" || m.FleetID == "" {
			return FleetTask{}, ErrTaskConflict
		}
		if err = s.claimTaskLeaseTx(tx, t, m, now); err != nil {
			return FleetTask{}, err
		}
		t.ExecutionOwner, t.WorkerID, t.ExecutionEndpoint = m.WorkerID, m.WorkerID, m.EndpointID
		t.State, t.LeaseRef, t.SessionKey = TaskStarting, t.TicketRef, m.SessionKey
		if t.LeaseRef == "" {
			t.LeaseRef = "task:" + t.Ref
		}
	case "transition":
		if m.State == TaskCancelled && t.ExecutionOwner != "" {
			return FleetTask{}, ErrTaskConflict
		}
		if taskTerminal(t.State) {
			return FleetTask{}, ErrTaskConflict
		}
		if t.ExecutionOwner == "" && m.State != TaskRefused && m.State != TaskCancelled && m.State != "" {
			return FleetTask{}, ErrTaskConflict
		}
		if m.ActualAgent != "" {
			if t.ExecutionOwner == "" || m.ActualAgent != t.ResolvedAgent || (t.ActualAgent != "" && t.ActualAgent != m.ActualAgent) || m.Evidence == "" {
				return FleetTask{}, ErrTaskConflict
			}
			t.ActualAgent = m.ActualAgent
		}
		if m.State != "" && m.State != t.State {
			if !taskTransition(t.State, m.State) {
				return FleetTask{}, ErrTaskConflict
			}
			if m.State == TaskRunning && t.ActualAgent == "" {
				return FleetTask{}, ErrTaskConflict
			}
			if taskTerminal(m.State) {
				if m.Evidence == "" || (m.State == TaskRefused && t.ExecutionOwner != "" && !m.ExecutionStopped) {
					return FleetTask{}, ErrTaskConflict
				}
				if m.State == TaskRefused && t.ActualAgent != "" {
					return FleetTask{}, ErrTaskConflict
				}
				t.Outcome = m.State
				if m.ExecutionStopped {
					if err = releaseTaskLeaseTx(tx, t); err != nil {
						return FleetTask{}, err
					}
				}
			}
			t.State = m.State
		}
		if m.Evidence != "" {
			t.Evidence = m.Evidence
		}
		if m.Observation != "" {
			t.Observation = m.Observation
		}
		if m.SessionKey != "" {
			t.SessionKey = m.SessionKey
		}
	case "retry", "transfer":
		if m.RequestedAgent == "" || m.ResolvedAgent == "" || m.Evidence == "" {
			return FleetTask{}, ErrTaskInvalid
		}
		if m.Kind == "retry" && !taskTerminal(t.State) {
			return FleetTask{}, ErrTaskConflict
		}
		if m.Kind == "retry" && !m.ExecutionStopped {
			// A terminal result alone does not retire the native executor.
			// Old terminal records already released their lease with stop proof.
			var held int
			if err = tx.QueryRow(`SELECT COUNT(*) FROM fleet_leases WHERE task_id = ? AND generation = ?`, t.ID, t.Generation).Scan(&held); err != nil {
				return FleetTask{}, err
			}
			if held != 0 {
				return FleetTask{}, ErrTaskConflict
			}
		}
		if m.Kind == "transfer" && (t.ExecutionOwner == "" || taskTerminal(t.State) || !m.ExecutionStopped) {
			return FleetTask{}, ErrTaskConflict
		}
		if err = releaseTaskLeaseTx(tx, t); err != nil {
			return FleetTask{}, err
		}
		// Preserve the old attempt before clearing any execution/provider fields.
		if err = taskAttemptResultTx(tx, t, now); err != nil {
			return FleetTask{}, err
		}
		t.Generation++
		t.UpdatedAt = now.UTC()
		t.State, t.RequestedAgent, t.ResolvedAgent = TaskAccepted, m.RequestedAgent, m.ResolvedAgent
		t.ExecutionOwner, t.ExecutionEndpoint, t.WorkerID, t.ActualAgent, t.LeaseRef = "", "", "", "", ""
		t.Outcome, t.Evidence, t.Observation, t.SessionKey, t.CancelRequest = "", "", "", "", ""
		t.AttemptID = taskAttemptID(t.ID, t.Generation)
		if err = taskAttemptTx(tx, t, now); err != nil {
			return FleetTask{}, err
		}
	default:
		return FleetTask{}, ErrTaskInvalid
	}
	t.UpdatedAt = now.UTC()
	if err = s.saveTaskTx(tx, t, now); err != nil {
		return FleetTask{}, err
	}
	if err = taskAttemptResultTx(tx, t, now); err != nil {
		return FleetTask{}, err
	}
	if err = projectTaskBlockers(tx, &t); err != nil {
		return FleetTask{}, err
	}
	resultJSON, err := json.Marshal(t)
	if err != nil {
		return FleetTask{}, err
	}
	ts := now.UTC().Format(rfc)
	eventWorker := m.WorkerID
	if eventWorker == "" {
		eventWorker = m.ExpectedWorker
	}
	_, err = tx.Exec(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated, result, worker_id)
  VALUES (?, ?, 'task_event', ?, ?, ?, 'recorded', ?, ?, ?, ?)`, eventID, m.FleetID, string(raw), owner, idem, ts, ts, string(resultJSON), eventWorker)
	if err != nil {
		return FleetTask{}, err
	}
	if (m.Kind == "transition" || m.Kind == "cancel_ack") && taskTerminal(t.State) {
		if err = s.resolveTaskDependenciesTx(tx, t, eventID, now); err != nil {
			return FleetTask{}, err
		}
	}
	return t, tx.Commit()
}

func taskTransition(from, to string) bool {
	switch from {
	case TaskAccepted:
		return to == TaskRefused || to == TaskCancelled
	case TaskStarting:
		return to == TaskRunning || to == TaskFailed || to == TaskCancelled || to == TaskRefused
	case TaskRunning:
		return to == TaskWaiting || to == TaskSucceeded || to == TaskFailed || to == TaskCancelled
	case TaskWaiting:
		return to == TaskRunning || to == TaskSucceeded || to == TaskFailed || to == TaskCancelled
	}
	return false
}

func (s *Store) claimTaskLeaseTx(tx *sql.Tx, t FleetTask, m TaskMutation, now time.Time) error {
	repo, n := taskLeaseKey(t)
	ts, exp := now.UTC().Format(rfc), now.Add(5*time.Minute).UTC().Format(rfc)
	// Existing rows are never stolen, even when expired. A legacy holder must
	// explicitly release before adoption; migration/drain belongs to C5.
	res, err := tx.Exec(`INSERT INTO fleet_leases (`+leaseCols+`, task_id, generation, account_owner)
  VALUES (?, ?, ?, ?, ?, '', '', ?, ?, ?, 0, 0, ?, ?, ?) ON CONFLICT(repo, issue) DO NOTHING`,
		repo, n, m.WorkerID, m.FleetID, m.EndpointID, ts, ts, exp, t.ID, t.Generation, t.Owner)
	if err != nil {
		return err
	}
	count, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return ErrTaskConflict
	}
	return nil
}

func releaseTaskLeaseTx(tx *sql.Tx, t FleetTask) error {
	repo, n := taskLeaseKey(t)
	_, err := tx.Exec(`DELETE FROM fleet_leases WHERE repo = ? AND issue = ? AND task_id = ? AND generation = ? AND worker_id = ? AND account_owner = ?`,
		repo, n, t.ID, t.Generation, t.ExecutionOwner, t.Owner)
	return err
}

func (s *Store) saveTaskTx(tx *sql.Tx, t FleetTask, now time.Time) error {
	_, err := tx.Exec(`UPDATE fleet_tasks SET state = ?, generation = ?, execution_owner = ?, execution_endpoint = ?,
  worker_id = ?, requested_agent = ?, resolved_agent = ?, actual_agent = ?, lease_ref = ?, outcome = ?, evidence = ?, observation = ?,
  attempt_id = ?, session_key = ?, parent_task = ?, parent_session = ?, parent_generation = ?, cancel_request = ?, updated_at = ? WHERE id = ? AND owner = ? AND authority_version = 1`,
		t.State, t.Generation, t.ExecutionOwner, t.ExecutionEndpoint, t.WorkerID, t.RequestedAgent, t.ResolvedAgent, t.ActualAgent,
		t.LeaseRef, t.Outcome, t.Evidence, t.Observation, t.AttemptID, t.SessionKey, t.ParentTask, t.ParentSession, t.ParentGeneration, t.CancelRequest, now.UTC().Format(rfc), t.ID, t.Owner)
	return err
}

func taskAttemptTx(tx *sql.Tx, t FleetTask, now time.Time) error {
	b, err := json.Marshal(t)
	if err != nil {
		return err
	}
	ts := now.UTC().Format(rfc)
	_, err = tx.Exec(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated, result, worker_id)
  VALUES (?, '', 'task_attempt', ?, ?, ?, 'recorded', ?, ?, ?, ?)`,
		t.AttemptID, string(b), t.Owner, t.AttemptID, ts, ts, string(b), t.ExecutionOwner)
	return err
}
func taskAttemptResultTx(tx *sql.Tx, t FleetTask, now time.Time) error {
	b, err := json.Marshal(t)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`UPDATE fleet_operations SET result = ?, updated = ?, worker_id = ? WHERE id = ? AND action = 'task_attempt'`,
		string(b), now.UTC().Format(rfc), t.ExecutionOwner, t.AttemptID)
	return err
}
