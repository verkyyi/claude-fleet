package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// The notices the hub owes someone (claude-fleet#4053, EPIC #4048 C5): one
// row per notice, written where the event happens (a request submitted,
// decided) and sent by the notice desk (internal/api notify.go) — on the
// leader, retried, every step audited. Both replicas see the same rows, so a
// notice written on one is sent once.

// The kinds of notice.
const (
	NotifyKindReview = "review" // a request's result → its person
	NotifyKindNewReq = "newreq" // requests waiting → an admin
	// NotifyKindUpgrade is a trial member's 申请转正 → an admin; refs = the
	// member's principal (claude-fleet T805).
	NotifyKindUpgrade = "upgrade"
)

// The states of a notice.
const (
	NoticePending     = "pending"
	NoticeSent        = "sent"
	NoticeUndelivered = "undelivered"
)

// Notice is one row of hub_notify_outbox.
type Notice struct {
	ID       string
	Kind     string
	Owner    string // a principal, or ApplicantReachOwner(...)
	Email    string // the address the request named, if any
	Prefer   string // NotifyWeChat | NotifyEmail | NotifyPage; "" = WeChat first
	Lang     string
	Refs     []string // the requests it is about, oldest first
	State    string
	Attempts int
	DueAt    time.Time
	Channel  string // what it went by: wechat-tpl | wechat-kf | email
	FirstAt  time.Time
	Created  time.Time
	DoneAt   time.Time
}

const noticeCols = `id, kind, owner, email, prefer, lang, refs, state, attempts, due_at, channel, first_at, created_at, done_at`

func scanNotice(row interface{ Scan(...any) error }) (*Notice, error) {
	var n Notice
	var refs string
	var due, first, created, done int64
	if err := row.Scan(&n.ID, &n.Kind, &n.Owner, &n.Email, &n.Prefer, &n.Lang, &refs, &n.State, &n.Attempts,
		&due, &n.Channel, &first, &created, &done); err != nil {
		return nil, err
	}
	if refs != "" {
		n.Refs = strings.Split(refs, ",")
	}
	n.DueAt, n.FirstAt, n.Created, n.DoneAt = unixOrZero(due), unixOrZero(first), unixOrZero(created), unixOrZero(done)
	return &n, nil
}

// EnqueueNotice writes n as pending, due at n.DueAt (zero = now). n.ID must be
// set; FirstAt defaults to now.
func (s *Store) EnqueueNotice(n Notice, now time.Time) error {
	if n.ID == "" || n.Kind == "" || n.Owner == "" {
		return errors.New("a notice needs an id, a kind and an owner")
	}
	if n.DueAt.IsZero() {
		n.DueAt = now
	}
	if n.FirstAt.IsZero() {
		n.FirstAt = now
	}
	_, err := s.write.Exec(`INSERT INTO hub_notify_outbox (`+noticeCols+`)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, '', ?, ?, 0)`,
		n.ID, n.Kind, n.Owner, n.Email, n.Prefer, n.Lang, strings.Join(n.Refs, ","), NoticePending,
		n.DueAt.Unix(), n.FirstAt.Unix(), now.Unix())
	return err
}

// GatherNotice is EnqueueNotice for a notice that gathers (an admin's new
// requests): a pending one of the same owner and kind that nobody is sending
// takes n's refs instead; else n is written, due when window has passed since
// the last one of that owner and kind went out (now when none did). So the
// first request reaches the admin at once and the rest of the window's come
// as one. id is the notice the refs ended up on.
func (s *Store) GatherNotice(n Notice, window time.Duration, now time.Time) (id string, err error) {
	if n.ID == "" || n.Kind == "" || n.Owner == "" {
		return "", errors.New("a notice needs an id, a kind and an owner")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var gid, refs string
	err = tx.QueryRow(`SELECT id, refs FROM hub_notify_outbox
		WHERE owner = ? AND kind = ? AND state = ? AND lease_until < ? ORDER BY created_at LIMIT 1`,
		n.Owner, n.Kind, NoticePending, now.Unix()).Scan(&gid, &refs)
	switch {
	case err == nil:
		have := map[string]bool{}
		list := []string{}
		if refs != "" {
			list = strings.Split(refs, ",")
		}
		for _, r := range list {
			have[r] = true
		}
		for _, r := range n.Refs {
			if !have[r] {
				list = append(list, r)
			}
		}
		if _, err := tx.Exec(`UPDATE hub_notify_outbox SET refs = ? WHERE id = ?`, strings.Join(list, ","), gid); err != nil {
			return "", err
		}
		return gid, tx.Commit()
	case !errors.Is(err, sql.ErrNoRows):
		return "", err
	}
	var last int64
	if err := tx.QueryRow(`SELECT COALESCE(MAX(done_at), 0) FROM hub_notify_outbox WHERE owner = ? AND kind = ? AND state = ?`,
		n.Owner, n.Kind, NoticeSent).Scan(&last); err != nil {
		return "", err
	}
	due := now
	if last > 0 {
		if next := time.Unix(last, 0).Add(window); next.After(now) {
			due = next
		}
	}
	if n.FirstAt.IsZero() {
		n.FirstAt = now
	}
	if _, err := tx.Exec(`INSERT INTO hub_notify_outbox (`+noticeCols+`)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, '', ?, ?, 0)`,
		n.ID, n.Kind, n.Owner, n.Email, n.Prefer, n.Lang, strings.Join(n.Refs, ","), NoticePending,
		due.Unix(), n.FirstAt.Unix(), now.Unix()); err != nil {
		return "", err
	}
	return n.ID, tx.Commit()
}

// ClaimNotices takes up to limit pending notices due by now that nobody is
// sending, holding each for lease: a row one sender claimed is not handed to
// another until the lease runs out.
func (s *Store) ClaimNotices(now time.Time, lease time.Duration, limit int) ([]Notice, error) {
	rows, err := s.write.Query(`SELECT id FROM hub_notify_outbox
		WHERE state = ? AND due_at <= ? AND lease_until < ? ORDER BY due_at LIMIT ?`,
		NoticePending, now.Unix(), now.Unix(), limit)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var out []Notice
	for _, id := range ids {
		res, err := s.write.Exec(`UPDATE hub_notify_outbox SET lease_until = ?
			WHERE id = ? AND state = ? AND lease_until < ?`, now.Add(lease).Unix(), id, NoticePending, now.Unix())
		if err != nil {
			return nil, err
		}
		if k, _ := res.RowsAffected(); k == 0 {
			continue
		}
		n, err := s.Notice(id)
		if err != nil {
			return nil, err
		}
		if n != nil {
			out = append(out, *n)
		}
	}
	return out, nil
}

// Notice is one notice by id, nil when there is none.
func (s *Store) Notice(id string) (*Notice, error) {
	n, err := scanNotice(s.write.QueryRow(`SELECT `+noticeCols+` FROM hub_notify_outbox WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return n, err
}

// NoticesOf is owner's notices of kind, newest first.
func (s *Store) NoticesOf(owner, kind string) ([]Notice, error) {
	rows, err := s.write.Query(`SELECT `+noticeCols+` FROM hub_notify_outbox
		WHERE owner = ? AND kind = ? ORDER BY created_at DESC, id DESC`, owner, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Notice
	for rows.Next() {
		n, err := scanNotice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *n)
	}
	return out, rows.Err()
}

// FinishNotice ends a claimed notice: sent (by channel) or undelivered.
func (s *Store) FinishNotice(id, state, channel string, now time.Time) error {
	if state != NoticeSent && state != NoticeUndelivered {
		return errors.New("a notice ends sent or undelivered")
	}
	_, err := s.write.Exec(`UPDATE hub_notify_outbox SET state = ?, channel = ?, done_at = ?, lease_until = 0
		WHERE id = ? AND state = ?`, state, channel, now.Unix(), id, NoticePending)
	return err
}

// RetryNotice puts a claimed notice back, its attempts counted, due at due.
func (s *Store) RetryNotice(id string, attempts int, due time.Time) error {
	_, err := s.write.Exec(`UPDATE hub_notify_outbox SET attempts = ?, due_at = ?, lease_until = 0
		WHERE id = ? AND state = ?`, attempts, due.Unix(), id, NoticePending)
	return err
}

// SetLang records the language request id was asked in.
func (q RequestStore) SetLang(id, lang string) error {
	_, err := q.s.write.Exec(`UPDATE hub_access_requests SET lang = ? WHERE id = ?`, lang, id)
	return err
}

// Lang is the language request id was asked in, "" when not known.
func (q RequestStore) Lang(id string) (string, error) {
	var l string
	err := q.s.write.QueryRow(`SELECT lang FROM hub_access_requests WHERE id = ?`, id).Scan(&l)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return l, err
}
