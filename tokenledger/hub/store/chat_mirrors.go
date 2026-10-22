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
	ExpiresAt time.Time
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
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Serialize view-cache arrivals with history hide's snapshot and apply.
	if err := s.d.lockKey(tx, "hub_chat_mirrors", "fleet_ids:"+pid); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM hub_chat_mirrors WHERE expires_at <= ?`, now.Unix()); err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO hub_chat_mirrors (principal, sealed, expires_at, updated_at)
		VALUES (?, ?, ?, ?) ON CONFLICT(principal) DO UPDATE SET sealed = excluded.sealed,
		expires_at = excluded.expires_at, updated_at = excluded.updated_at
		WHERE hub_chat_mirrors.updated_at <= excluded.updated_at`,
		ChatMirrorKey(pid, provider), sealed, expires.Unix(), now.Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
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

// ChatMirrorSession opens a sealed view copy as its owner. The API owns the
// vault; the store owns the identity join and transaction snapshot.
type ChatMirrorSession func(owner string, sealed []byte) (string, error)

// historyViewCopies attributes legacy and FID keys alike through the native SID
// inside the sealed document. Keys, cwd, title and recency are never identity.
// Include expired-but-still-stored copies for cleanup: expiry is not absence.
// Unknown or ambiguous attribution is conservative evidence against hiding.
func historyViewCopies(q querier, owner string, decode ChatMirrorSession) (map[string][]ChatMirrorCopy, bool, error) {
	rows, err := q.Query(`SELECT n.native, n.id FROM fleet_id_natives n JOIN fleet_ids i ON i.id=n.id WHERE i.owner=?`, owner)
	if err != nil {
		return nil, false, err
	}
	ids := map[string]string{}
	for rows.Next() {
		var sid, fid string
		if err := rows.Scan(&sid, &fid); err != nil {
			rows.Close()
			return nil, false, err
		}
		if old, ok := ids[sid]; ok && old != fid {
			ids[sid] = ""
		} else if !ok {
			ids[sid] = fid
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	prefix := owner + "#view:"
	rows, err = q.Query(`SELECT sealed,updated_at,expires_at FROM hub_chat_mirrors WHERE substr(principal,1,?)=?`, len(prefix), prefix)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	copies := map[string][]ChatMirrorCopy{}
	unknown := false
	for rows.Next() {
		var c ChatMirrorCopy
		var at, expires int64
		if err := rows.Scan(&c.Sealed, &at, &expires); err != nil {
			return nil, false, err
		}
		c.UpdatedAt, c.ExpiresAt = time.Unix(at, 0), time.Unix(expires, 0)
		if decode == nil {
			unknown = true
			continue
		}
		sid, err := decode(owner, c.Sealed)
		fid := ids[sid]
		if err != nil || sid == "" || fid == "" {
			unknown = true
			continue
		}
		copies[fid] = append(copies[fid], c)
	}
	return copies, unknown, rows.Err()
}

// ChatHistoryMirrorOf also reads legacy key caches, but only when their sealed
// native SID has one verified FID belonging to this owner. A malformed unrelated
// copy cannot supply content; an ambiguous SID cannot supply any FID's content.
func (s *Store) ChatHistoryMirrorOf(pid, fid string, now time.Time, decode ChatMirrorSession) (*ChatMirrorCopy, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := s.d.lockKey(tx, "fleet_ids", "fleet_ids:"+pid); err != nil {
		return nil, err
	}
	copies, _, err := historyViewCopies(tx, pid, decode)
	if err != nil {
		return nil, err
	}
	var newest *ChatMirrorCopy
	for _, c := range copies[fid] {
		if c.ExpiresAt.After(now) && (newest == nil || c.UpdatedAt.After(newest.UpdatedAt)) {
			copy := c
			newest = &copy
		}
	}
	return newest, nil
}
