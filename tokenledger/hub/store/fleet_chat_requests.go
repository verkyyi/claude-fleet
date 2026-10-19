package store

// Request tombstones survive replica changes and restarts. They contain only
// admission/accounting metadata; an uncertain request is never executable a
// second time, even after its attachment and trial have ended.
func (s *Store) ensureChatRequests() error {
	_, err := s.write.Exec(s.d.ddl(`CREATE TABLE IF NOT EXISTS fleet_chat_requests (
	 id TEXT PRIMARY KEY, person TEXT NOT NULL, route TEXT NOT NULL,
	 outcome TEXT NOT NULL DEFAULT '', bytes_up INTEGER NOT NULL DEFAULT 0,
	 bytes_down INTEGER NOT NULL DEFAULT 0
	);`))
	return err
}

func (s *Store) ClaimChatRequest(id, person, route string) (bool, error) {
	r, err := s.write.Exec(`INSERT INTO fleet_chat_requests (id, person, route) VALUES (?, ?, ?) ON CONFLICT(id) DO NOTHING`, id, person, route)
	if err != nil {
		return false, err
	}
	n, err := r.RowsAffected()
	return n == 1, err
}

func (s *Store) CloseChatRequest(id, outcome string, up, down int64) error {
	_, err := s.write.Exec(`UPDATE fleet_chat_requests SET outcome = ?, bytes_up = ?, bytes_down = ? WHERE id = ?`, outcome, up, down, id)
	return err
}
