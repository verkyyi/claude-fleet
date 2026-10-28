package store

import "database/sql"

// Archiving is an owner's presentation preference, independent of execution,
// history availability and retention. Stable IDs survive moves and key reuse.
func (s *Store) ensureSessionArchives() error {
	_, err := s.write.Exec(s.d.ddl(`CREATE TABLE IF NOT EXISTS fleet_session_archives (
 owner TEXT NOT NULL, id TEXT NOT NULL, archived INTEGER NOT NULL, PRIMARY KEY(owner,id))`))
	return err
}

func (s *Store) SetSessionArchived(owner, id string, archived bool) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists bool
	err = tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM fleet_ids WHERE owner=? AND id=? UNION ALL SELECT 1 FROM fleet_tasks WHERE owner=? AND fid=?)`, owner, id, owner, id).Scan(&exists)
	if err != nil {
		return err
	}
	if !exists {
		return sql.ErrNoRows
	}
	value := 0
	if archived {
		value = 1
	}
	// Keep an explicit unarchive too: restored old history must not disappear
	// behind the ordinary board's age/count cap immediately after restoration.
	_, err = tx.Exec(`INSERT INTO fleet_session_archives(owner,id,archived) VALUES(?,?,?) ON CONFLICT(owner,id) DO UPDATE SET archived=excluded.archived`, owner, id, value)
	if err != nil {
		return err
	}
	return tx.Commit()
}

// SessionArchivePreferences includes explicit restores (false) as well as archives.
func (s *Store) SessionArchivePreferences(owner string) (map[string]bool, error) {
	q := `SELECT id, archived FROM fleet_session_archives`
	args := []any{}
	if owner != "" {
		q += ` WHERE owner=?`
		args = append(args, owner)
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		var archived int
		if err := rows.Scan(&id, &archived); err != nil {
			return nil, err
		}
		out[id] = archived == 1
	}
	return out, rows.Err()
}

// Manually archived/restored records remain discoverable beyond the ordinary list cap.
func (s *Store) SessionArchiveTasks(owner string) ([]FleetTask, error) {
	q := `SELECT ` + fleetTaskCols + ` FROM fleet_tasks WHERE EXISTS (SELECT 1 FROM fleet_session_archives a WHERE a.owner=fleet_tasks.owner AND a.id=fleet_tasks.fid)`
	args := []any{}
	if owner != "" {
		q += ` AND owner=?`
		args = append(args, owner)
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	return scanFleetTasks(rows)
}
