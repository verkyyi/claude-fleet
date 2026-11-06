package store

import (
	"encoding/json"
	"strings"
)

// A placeholder translation key is transport damage, never a task title.
func normalizeTaskTitle(t *FleetTask) {
	if t.Title == "dispatch_new_title" {
		t.Title = "新会话"
	}
	t.RequestPayload = repairTitleJSON(t.RequestPayload)
}

func repairTitleJSON(raw string) string {
	if !strings.Contains(raw, "dispatch_new_title") {
		return raw
	}
	v, ok := decodeTaskRequest(raw) // retains exact JSON numbers and unknown fields
	if !ok {
		return raw
	}
	var repair func(map[string]any)
	repair = func(value map[string]any) {
		for _, key := range []string{"title", "Title", "name"} {
			if value[key] == "dispatch_new_title" {
				value[key] = "新会话"
			}
		}
		// Only known transport slots; never a user's nested body or attachments.
		for _, key := range []string{"params", "Payload"} {
			if child, ok := value[key].(map[string]any); ok {
				repair(child)
			}
		}
	}
	repair(v)
	b, err := json.Marshal(v)
	if err != nil {
		return raw
	}
	return string(b)
}

// Exact-key repair only. User titles, bodies, task identities and execution
// history are retained. Run after both Task and ID schemas exist; idempotent.
func (s *Store) repairTaskPlaceholderTitles() error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = s.d.claimWrites(tx, "fleet_tasks"); err != nil {
		return err
	}
	rows, err := tx.Query(`SELECT id, request_payload, accepted_request FROM fleet_tasks WHERE title = ? OR request_payload LIKE '%dispatch_new_title%' OR accepted_request LIKE '%dispatch_new_title%'`, "dispatch_new_title")
	if err != nil {
		return err
	}
	type repair struct {
		id                int64
		payload, accepted string
	}
	var repairs []repair
	for rows.Next() {
		var r repair
		if err := rows.Scan(&r.id, &r.payload, &r.accepted); err != nil {
			rows.Close()
			return err
		}
		repairs = append(repairs, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, r := range repairs {
		if _, err := tx.Exec(`UPDATE fleet_tasks SET title = CASE WHEN title = 'dispatch_new_title' THEN '新会话' ELSE title END, request_payload = ?, accepted_request = ? WHERE id = ?`,
			repairTitleJSON(r.payload), repairTitleJSON(r.accepted), r.id); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`UPDATE fleet_ids SET title = ? WHERE title = ?`, "新会话", "dispatch_new_title"); err != nil {
		return err
	}
	return tx.Commit()
}
