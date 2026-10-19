package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var taskLinkedTicketRE = regexp.MustCompile(`^(gh|hub):[a-z0-9][a-z0-9_.-]{0,99}/[a-z0-9][a-z0-9_.-]{0,99}#[1-9][0-9]{0,9}$`)
var taskFilingIDRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// A late ticket is an explicit, once-only attachment before execution. Neither
// the accepted request nor its replay response is rewritten. The preparation
// journal pins the filing endpoint, so another node cannot also create it.
func (s *Store) linkTaskTicketTx(tx *sql.Tx, t *FleetTask, m TaskMutation) error {
	if t.State != TaskAccepted || t.ExecutionOwner != "" || t.CancelRequest != "" || t.Repo == "" {
		return ErrTaskConflict
	}
	if m.Kind == "ticket_prepare" {
		if t.TicketRef != "" {
			return ErrTaskConflict
		}
		return nil
	}
	if !taskLinkedTicketRE.MatchString(m.TicketRef) {
		return ErrTaskInvalid
	}
	repo, n, err := taskTicket(m.TicketRef)
	if err != nil || repo != t.Repo {
		return ErrTaskFence
	}
	if t.TicketRef != "" && t.TicketRef != m.TicketRef {
		return ErrTaskConflict
	}
	var raw string
	err = tx.QueryRow(`SELECT request FROM fleet_operations WHERE actor = ? AND idem = ?`, t.Owner,
		fmt.Sprintf("task-event:%s:ticket-file:g%d", t.Ref, t.Generation)).Scan(&raw)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrTaskFence
		}
		return err
	}
	var preparation struct {
		Endpoint string
		Command  TaskMutation
	}
	if json.Unmarshal([]byte(raw), &preparation) != nil || preparation.Endpoint != m.EndpointID || preparation.Command.FilingID != m.FilingID {
		return ErrTaskFence
	}
	backend, _, _ := strings.Cut(m.TicketRef, ":")
	var owner string
	err = tx.QueryRow(`SELECT owner FROM fleet_tickets WHERE repo = ? AND num = ? AND backend = ?`, repo, n, backend).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) && backend == TicketGitHub {
		err = tx.QueryRow(`SELECT owner FROM fleet_ticket_index WHERE id = ?`, m.TicketRef).Scan(&owner)
	}
	if err == nil && owner != t.Owner {
		return ErrTaskFence
	}
	if errors.Is(err, sql.ErrNoRows) && backend == TicketHub {
		return ErrTaskInvalid
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	t.TicketRef, t.Issue = m.TicketRef, strings.TrimPrefix(m.TicketRef, backend+":")
	_, err = tx.Exec(`UPDATE fleet_tasks SET ticket_ref = ?, issue = ? WHERE id = ? AND owner = ? AND authority_version = 1`, t.TicketRef, t.Issue, t.ID, t.Owner)
	return err
}
