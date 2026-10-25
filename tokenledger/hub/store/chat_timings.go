package store

import (
	"fmt"
	"time"
)

// A new web session's wait (task PNWW): the console's 新会话 page keeps one
// clock per start — the press to the first words of the reply on screen — and
// the stages inside it (open answered, the session's page shown). Like the
// trial's timings these keep when and how long, never who: the home's machine,
// the agent and the page's time zone (how a mainland start is told apart) are
// the only labels.
const chatTimingsSchema = `
CREATE TABLE IF NOT EXISTS fleet_chat_timings (
  at       INTEGER NOT NULL,
  ms       INTEGER NOT NULL,
  open_ms  INTEGER NOT NULL DEFAULT 0,
  shown_ms INTEGER NOT NULL DEFAULT 0,
  agent    TEXT NOT NULL DEFAULT '',
  machine  TEXT NOT NULL DEFAULT '',
  tz       TEXT NOT NULL DEFAULT ''
);`

// ChatTiming is one new web session's clock.
type ChatTiming struct {
	At      time.Time
	MS      int64
	OpenMS  int64
	ShownMS int64
	Agent   string
	Machine string
	TZ      string
}

func (s *Store) ensureChatTimings() error {
	if _, err := s.write.Exec(s.d.ddl(chatTimingsSchema)); err != nil {
		return fmt.Errorf("create chat timings table: %w", err)
	}
	return nil
}

// RecordChatTiming keeps one clock.
func (s *Store) RecordChatTiming(t ChatTiming) error {
	_, err := s.write.Exec(`INSERT INTO fleet_chat_timings (at, ms, open_ms, shown_ms, agent, machine, tz) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		t.At.Unix(), t.MS, t.OpenMS, t.ShownMS, t.Agent, t.Machine, t.TZ)
	return err
}

// ChatTimings are the clocks kept at or after since, oldest first.
func (s *Store) ChatTimings(since time.Time) ([]ChatTiming, error) {
	rows, err := s.write.Query(`SELECT at, ms, open_ms, shown_ms, agent, machine, tz FROM fleet_chat_timings WHERE at >= ? ORDER BY at`, since.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ChatTiming
	for rows.Next() {
		var t ChatTiming
		var at int64
		if err := rows.Scan(&at, &t.MS, &t.OpenMS, &t.ShownMS, &t.Agent, &t.Machine, &t.TZ); err != nil {
			return nil, err
		}
		t.At = time.Unix(at, 0)
		out = append(out, t)
	}
	return out, rows.Err()
}
