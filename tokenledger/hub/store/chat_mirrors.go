package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// A person's web conversation, a copy kept beside the entry (task V9DJ D): the
// last conversation the entry relayed from the person's home, sealed to that
// one principal (the caller seals — credvault SealPerson), so the page can show
// it at once and while the home is out of reach. The home stays the record: a
// read that reaches it replaces the copy. One row per principal; only the
// principal's own read opens it (ChatMirror takes the caller's principal, never
// an id); a row not refreshed for its keep is deleted, ciphertext and all. A
// principal in hub_chat_mirror_off keeps no copy (their switch); turning it off
// deletes theirs. A person talks to two assistants (task R9A2): the Claude
// conversation's row is keyed by the principal as before, the Codex one's by
// ChatMirrorKey — one copy each, the newer-wins rule per row.
var chatMirrorsSchema = []string{`
CREATE TABLE IF NOT EXISTS hub_chat_mirrors (
  principal  TEXT PRIMARY KEY,
  sealed     BLOB NOT NULL,
  expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);`, `
CREATE TABLE IF NOT EXISTS hub_chat_mirror_off (
  principal TEXT PRIMARY KEY,
  at        INTEGER NOT NULL
);`}

func (s *Store) ensureChatMirrors() error {
	for _, ddl := range chatMirrorsSchema {
		if _, err := s.write.Exec(s.d.ddl(ddl)); err != nil {
			return err
		}
	}
	return nil
}

// ChatMirrorCopy is one sealed copy and when it was taken.
type ChatMirrorCopy struct {
	Sealed    []byte
	UpdatedAt time.Time
}

// PutChatMirror keeps sealed as pid's copy until expires, replacing the last —
// unless the last was taken later than now (task Y393: two reads of one person,
// on two replicas, finish out of order; the older answer never replaces the
// newer copy). Expired copies of anyone go with it. Nothing is kept for a
// principal whose switch is off.
func (s *Store) PutChatMirror(pid string, sealed []byte, expires, now time.Time) error {
	return s.PutChatMirrorOf(pid, "", sealed, expires, now)
}

// ChatMirrorProviders are the assistants a person's conversations are kept for;
// "claude" (or "") is the principal's own row.
var ChatMirrorProviders = []string{"claude", "codex"}

// ChatMirrorKey is the row a provider's copy of pid's conversation is kept under.
func ChatMirrorKey(pid, provider string) string {
	if provider == "" || provider == "claude" {
		return pid
	}
	return pid + "#" + provider
}

// PutChatMirrorOf is PutChatMirror for one provider's conversation.
func (s *Store) PutChatMirrorOf(pid, provider string, sealed []byte, expires, now time.Time) error {
	if off, err := s.ChatMirrorOff(pid); err != nil || off {
		return err
	}
	if _, err := s.write.Exec(`DELETE FROM hub_chat_mirrors WHERE expires_at <= ?`, now.Unix()); err != nil {
		return err
	}
	_, err := s.write.Exec(`INSERT INTO hub_chat_mirrors (principal, sealed, expires_at, updated_at)
		VALUES (?, ?, ?, ?) ON CONFLICT(principal) DO UPDATE SET sealed = excluded.sealed,
		expires_at = excluded.expires_at, updated_at = excluded.updated_at
		WHERE hub_chat_mirrors.updated_at <= excluded.updated_at`,
		ChatMirrorKey(pid, provider), sealed, expires.Unix(), now.Unix())
	return err
}

// ChatMirror is pid's own copy when it has not expired at now; nil, nil for none.
func (s *Store) ChatMirror(pid string, now time.Time) (*ChatMirrorCopy, error) {
	return s.ChatMirrorOf(pid, "", now)
}

// ChatMirrorOf is ChatMirror for one provider's conversation.
func (s *Store) ChatMirrorOf(pid, provider string, now time.Time) (*ChatMirrorCopy, error) {
	var c ChatMirrorCopy
	var up int64
	err := s.write.QueryRow(`SELECT sealed, updated_at FROM hub_chat_mirrors
		WHERE principal = ? AND expires_at > ?`, ChatMirrorKey(pid, provider), now.Unix()).Scan(&c.Sealed, &up)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c.UpdatedAt = unixOrZero(up)
	return &c, nil
}

// DeleteChatMirror forgets pid's copies, every provider's.
func (s *Store) DeleteChatMirror(pid string) error {
	for _, p := range ChatMirrorProviders {
		if _, err := s.write.Exec(`DELETE FROM hub_chat_mirrors WHERE principal = ?`, ChatMirrorKey(pid, p)); err != nil {
			return err
		}
	}
	// the copies of terminal sessions' conversations read along (task YP39),
	// one row a session: <pid>#view:<worker id>
	lo := ChatMirrorKey(pid, ChatMirrorViewPrefix)
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(lo)
	_, err := s.write.Exec(`DELETE FROM hub_chat_mirrors WHERE principal LIKE ? ESCAPE '\'`, esc+"%")
	return err
}

// ChatMirrorViewPrefix is the provider a terminal session's copy is kept
// under, followed by its worker id (task YP39).
const ChatMirrorViewPrefix = "view:"

// ChatMirrorOff says whether pid turned the copy off.
func (s *Store) ChatMirrorOff(pid string) (bool, error) {
	var n int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM hub_chat_mirror_off WHERE principal = ?`, pid).Scan(&n)
	return n > 0, err
}

// SetChatMirrorOff turns pid's copy off (deleting it) or back on.
func (s *Store) SetChatMirrorOff(pid string, off bool, now time.Time) error {
	if !off {
		_, err := s.write.Exec(`DELETE FROM hub_chat_mirror_off WHERE principal = ?`, pid)
		return err
	}
	if _, err := s.write.Exec(`INSERT INTO hub_chat_mirror_off (principal, at) VALUES (?, ?)
		ON CONFLICT(principal) DO UPDATE SET at = excluded.at`, pid, now.Unix()); err != nil {
		return err
	}
	return s.DeleteChatMirror(pid)
}
