package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Task blockers extend the operation journal, independently of lifecycle state,
// native attention and runtime observations. No observation expires a blocker.
type TaskBlockerScope struct {
	Task       string `json:"task"`
	Owner      string `json:"owner"`
	Repo       string `json:"repo"`
	TicketRef  string `json:"ticket_ref"`
	Generation int64  `json:"generation"`
	WorkerID   string `json:"worker_id"`
}

func blockerScope(t FleetTask) TaskBlockerScope {
	return TaskBlockerScope{t.Ref, t.Owner, t.Repo, t.TicketRef, t.Generation, t.ExecutionOwner}
}

// Dependency is an explicit grant to consume this hub's committed terminal
// result for precisely this dependency attempt. URLs, issue numbers and runtime
// strings are not dependency events. Owner resolve/revoke always needs evidence.
type TaskBlockerCommand struct {
	Version    int              `json:"version"`
	Action     string           `json:"action"`
	BlockerID  string           `json:"blocker_id"`
	Repo       string           `json:"repo"`
	TicketRef  string           `json:"ticket_ref"`
	Dependency TaskBlockerScope `json:"dependency"`
	Evidence   string           `json:"evidence"`
	Reason     string           `json:"reason"`
}

type TaskBlocker struct {
	Version          int              `json:"version"`
	BlockerID        string           `json:"blocker_id"`
	Scope            TaskBlockerScope `json:"scope"`
	CreatedEndpoint  string           `json:"created_endpoint"`
	Dependency       TaskBlockerScope `json:"dependency"`
	State            string           `json:"state"` // active | resolved | revoked (not task outcomes)
	CreatedAt        time.Time        `json:"created_at"`
	ResolvedAt       *time.Time       `json:"resolved_at,omitempty"`
	RevokedAt        *time.Time       `json:"revoked_at,omitempty"`
	CreationEvidence string           `json:"creation_evidence"`
	CreationReason   string           `json:"creation_reason"`
	Evidence         string           `json:"evidence"`
	Reason           string           `json:"reason"`
	EventID          string           `json:"event_id"` // immutable journal event, not a transport ack
}

type TaskBlockerProjection struct {
	Version    int           `json:"version"`
	Generation int64         `json:"generation"`
	Items      []TaskBlocker `json:"items"`
}

type blockerReader interface {
	Query(string, ...any) (*sql.Rows, error)
}

func projectTaskBlockers(q blockerReader, t *FleetTask) error {
	if t.AuthorityVersion != TaskAuthorityVersion {
		return nil
	}
	rows, err := q.Query(`SELECT result FROM fleet_operations WHERE action = 'task_blocker' AND actor = ? AND task_ref = ? AND task_generation = ? ORDER BY id`, t.Owner, t.Ref, t.Generation)
	if err != nil {
		return err
	}
	items, err := scanTaskBlockers(rows)
	if err != nil {
		return err
	}
	t.Blockers = &TaskBlockerProjection{1, t.Generation, items}
	return nil
}

func scanTaskBlockers(rows *sql.Rows) ([]TaskBlocker, error) {
	defer rows.Close()
	items := []TaskBlocker{}
	for rows.Next() {
		var raw string
		var b TaskBlocker
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(raw), &b); err != nil {
			return nil, err
		}
		items = append(items, b)
	}
	return items, rows.Err()
}

func blockerJournalID(owner, key string) string {
	return fmt.Sprintf("task-blocker:%x", sha256.Sum256([]byte(owner+"\x00"+key)))
}
func blockerKey(scope TaskBlockerScope, id string) string {
	return fmt.Sprintf("task-blocker:%s:g%d:%s", scope.Task, scope.Generation, id)
}

var blockerToken = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$`)

func (s *Store) applyTaskBlockerTx(tx *sql.Tx, t FleetTask, endpoint, event string, c TaskBlockerCommand, now time.Time) error {
	if c.Version != 1 || !blockerToken.MatchString(c.BlockerID) || strings.TrimSpace(c.Evidence) == "" || len(c.Evidence) > 8000 || strings.TrimSpace(c.Reason) == "" || len(c.Reason) > 2000 ||
		(c.Action != "create" && c.Action != "resolve" && c.Action != "revoke") {
		return ErrTaskInvalid
	}
	if c.Repo != t.Repo || c.TicketRef != t.TicketRef || t.ExecutionOwner == "" || endpoint != t.ExecutionEndpoint {
		return ErrTaskFence
	}
	if taskTerminal(t.State) || t.CancelRequest != "" {
		return ErrTaskConflict
	}
	scope := blockerScope(t)
	key := blockerKey(scope, c.BlockerID)
	id := blockerJournalID(t.Owner, key)
	var raw string
	err := tx.QueryRow(`SELECT result FROM fleet_operations WHERE id = ? AND action = 'task_blocker'`, id).Scan(&raw)
	var b TaskBlocker
	if c.Action == "create" {
		if err == nil {
			return ErrTaskConflict
		} // only the original event may replay
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if c.Dependency.Owner != t.Owner || c.Dependency.Task == t.Ref || ParseTaskRef(c.Dependency.Task) == 0 {
			return ErrTaskFence
		}
		dep, e := s.taskInTx(tx, ParseTaskRef(c.Dependency.Task))
		if errors.Is(e, sql.ErrNoRows) {
			return ErrTaskFence
		}
		if e != nil {
			return e
		}
		if dep.AuthorityVersion != 1 || dep.ExecutionOwner == "" || blockerScope(dep) != c.Dependency {
			return ErrTaskFence
		}
		var count int
		if e = tx.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_blocker' AND actor = ? AND task_ref = ? AND task_generation = ?`, t.Owner, t.Ref, t.Generation).Scan(&count); e != nil {
			return e
		}
		if count >= 64 {
			return ErrTaskConflict
		}
		b = TaskBlocker{Version: 1, BlockerID: c.BlockerID, Scope: scope, CreatedEndpoint: endpoint, Dependency: c.Dependency,
			State: "active", CreatedAt: now.UTC(), CreationEvidence: c.Evidence, CreationReason: c.Reason, Evidence: c.Evidence, Reason: c.Reason, EventID: event}
		result, _ := json.Marshal(b)
		request, _ := json.Marshal(c)
		ts := now.UTC().Format(rfc)
		_, e = tx.Exec(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated, result, worker_id, task_ref, task_generation, dependency_task)
			VALUES (?, '', 'task_blocker', ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?)`, id, string(request), t.Owner, key, ts, ts, string(result), t.ExecutionOwner, t.Ref, t.Generation, dep.Ref)
		if e != nil {
			return e
		}
		// A dependency may have completed just before registration. Its durable
		// attempt result is already authoritative; no scan/poll or guessed event.
		if taskTerminal(dep.State) && dep.Evidence != "" {
			return s.closeDependencyBlockerTx(tx, b, dep, dep.AttemptID, now)
		}
		return nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return ErrTaskConflict
	}
	if err != nil {
		return err
	}
	if err = json.Unmarshal([]byte(raw), &b); err != nil {
		return err
	}
	if b.Scope != scope || b.Dependency != c.Dependency {
		return ErrTaskFence
	}
	if b.State != "active" {
		return ErrTaskConflict
	}
	b.State = "resolved"
	if c.Action == "revoke" {
		b.State = "revoked"
	}
	b.Evidence, b.Reason, b.EventID = c.Evidence, c.Reason, event
	return saveClosedBlockerTx(tx, b, now)
}

func saveClosedBlockerTx(tx *sql.Tx, b TaskBlocker, now time.Time) error {
	ts := now.UTC()
	if b.State == "resolved" {
		b.ResolvedAt = &ts
	} else {
		b.RevokedAt = &ts
	}
	raw, _ := json.Marshal(b)
	_, err := tx.Exec(`UPDATE fleet_operations SET status = ?, result = ?, updated = ? WHERE id = ? AND action = 'task_blocker' AND status = 'active'`, b.State, string(raw), ts.Format(rfc), blockerJournalID(b.Scope.Owner, blockerKey(b.Scope, b.BlockerID)))
	return err
}

// Called only by committed lifecycle/report writes, under the same per-account
// transaction lock as blocker writes. Cross-task row locks cannot deadlock, and
// cancellation/transfer of the waiting task is checked before each close.
func (s *Store) resolveTaskDependenciesTx(tx *sql.Tx, dep FleetTask, event string, now time.Time) error {
	if !taskTerminal(dep.State) || dep.Evidence == "" {
		return nil
	}
	rows, err := tx.Query(`SELECT result FROM fleet_operations WHERE action = 'task_blocker' AND actor = ? AND dependency_task = ? AND status = 'active' ORDER BY id`, dep.Owner, dep.Ref)
	if err != nil {
		return err
	}
	items, err := scanTaskBlockers(rows)
	if err != nil {
		return err
	}
	for _, b := range items {
		if err = s.closeDependencyBlockerTx(tx, b, dep, event, now); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) closeDependencyBlockerTx(tx *sql.Tx, b TaskBlocker, dep FleetTask, event string, now time.Time) error {
	if b.State != "active" || b.Dependency != blockerScope(dep) {
		return nil
	}
	t, err := s.taskInTx(tx, ParseTaskRef(b.Scope.Task))
	if err != nil {
		return err
	}
	if blockerScope(t) != b.Scope || t.ExecutionEndpoint != b.CreatedEndpoint || taskTerminal(t.State) || t.CancelRequest != "" {
		return nil
	}
	b.State = "revoked"
	if dep.Outcome == TaskSucceeded {
		b.State = "resolved"
	}
	b.Evidence, b.Reason = dep.Evidence, "dependency:"+dep.Outcome
	key := blockerKey(b.Scope, b.BlockerID) + ":dependency:" + event
	b.EventID = blockerJournalID(t.Owner, key)
	if err = saveClosedBlockerTx(tx, b, now); err != nil {
		return err
	}
	// Retain both the triggering journal event and the resulting blocker in an
	// immutable audit row. Duplicate source reports return before this point.
	request, _ := json.Marshal(struct {
		Source     string           `json:"source_event"`
		Dependency TaskBlockerScope `json:"dependency"`
	}{event, b.Dependency})
	stamp := now.UTC()
	if b.State == "resolved" {
		b.ResolvedAt = &stamp
	} else {
		b.RevokedAt = &stamp
	}
	result, _ := json.Marshal(b)
	_, err = tx.Exec(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated, result, worker_id, task_ref, task_generation, dependency_task)
		VALUES (?, '', 'task_blocker_event', ?, ?, ?, 'recorded', ?, ?, ?, ?, ?, ?, ?)`, b.EventID, string(request), t.Owner, key, stamp.Format(rfc), stamp.Format(rfc), string(result), dep.ExecutionOwner, t.Ref, t.Generation, dep.Ref)
	return err
}
