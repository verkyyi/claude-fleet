package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// An admin's service notices to members (claude-fleet#4063, EPIC #4048 R1):
// the words an admin wrote once, and who they went to. Each recipient's copy
// is a notice desk row (hub_notify_outbox, kind NotifyKindNotice, refs = the
// notice's id), so the desk's roads, retries and audit are the same as for a
// request's result.

// NotifyKindNotice is an admin's service notice → a member.
const NotifyKindNotice = "notice"

// NoticeAll is the audience "every member".
const NoticeAll = "all"

// ErrNoticeLimit: the day's notices are spent.
var ErrNoticeLimit = errors.New("the day's notices are spent")

// ServiceNotice is one row of hub_notices.
type ServiceNotice struct {
	ID         string    `json:"id"`
	Body       string    `json:"body"`
	Link       string    `json:"link,omitempty"`
	Audience   string    `json:"audience"` // NoticeAll | "some"
	Recipients []string  `json:"recipients"`
	CreatedBy  string    `json:"created_by"`
	CreatedAt  time.Time `json:"created_at"`
}

const serviceNoticeCols = `id, body, link, audience, recipients, created_by, created_at`

func scanServiceNotice(row interface{ Scan(...any) error }) (*ServiceNotice, error) {
	var n ServiceNotice
	var to string
	var at int64
	if err := row.Scan(&n.ID, &n.Body, &n.Link, &n.Audience, &to, &n.CreatedBy, &at); err != nil {
		return nil, err
	}
	n.Recipients = []string{}
	if to != "" {
		n.Recipients = strings.Split(to, ",")
	}
	n.CreatedAt = unixOrZero(at)
	return &n, nil
}

// CreateServiceNotice writes n and one pending desk row per recipient (each
// of lang langOf(principal)), in one transaction — unless limit notices were
// already written since since (ErrNoticeLimit, nothing written).
func (s *Store) CreateServiceNotice(n ServiceNotice, langOf func(string) string, limit int, since, now time.Time) error {
	if n.ID == "" || n.Body == "" || len(n.Recipients) == 0 {
		return errors.New("a notice needs an id, words and someone to tell")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var k int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM hub_notices WHERE created_at >= ?`, since.Unix()).Scan(&k); err != nil {
		return err
	}
	if k >= limit {
		return ErrNoticeLimit
	}
	if _, err := tx.Exec(`INSERT INTO hub_notices (`+serviceNoticeCols+`) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		n.ID, n.Body, n.Link, n.Audience, strings.Join(n.Recipients, ","), n.CreatedBy, now.Unix()); err != nil {
		return err
	}
	for _, p := range n.Recipients {
		lang := ""
		if langOf != nil {
			lang = langOf(p)
		}
		if _, err := tx.Exec(`INSERT INTO hub_notify_outbox (`+noticeCols+`)
			VALUES (?, ?, ?, '', '', ?, ?, ?, 0, ?, '', ?, ?, 0)`,
			n.ID+"-"+p, NotifyKindNotice, p, lang, n.ID, NoticePending, now.Unix(), now.Unix(), now.Unix()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ServiceNotice is one notice by id, nil when there is none.
func (s *Store) ServiceNotice(id string) (*ServiceNotice, error) {
	n, err := scanServiceNotice(s.write.QueryRow(`SELECT `+serviceNoticeCols+` FROM hub_notices WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return n, err
}

// ServiceNotices is every notice, newest first, at most limit (0 = all).
func (s *Store) ServiceNotices(limit int) ([]ServiceNotice, error) {
	q := `SELECT ` + serviceNoticeCols + ` FROM hub_notices ORDER BY created_at DESC, id DESC`
	var args []any
	if limit > 0 {
		q += ` LIMIT ?`
		args = append(args, limit)
	}
	rows, err := s.write.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ServiceNotice{}
	for rows.Next() {
		n, err := scanServiceNotice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *n)
	}
	return out, rows.Err()
}

// ServiceNoticesSince counts the notices written since since.
func (s *Store) ServiceNoticesSince(since time.Time) (int, error) {
	var k int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM hub_notices WHERE created_at >= ?`, since.Unix()).Scan(&k)
	return k, err
}

// NoticeDelivery is how one notice's copies went: by state, and the sent
// ones by road.
type NoticeDelivery struct {
	Pending     int            `json:"pending"`
	Sent        int            `json:"sent"`
	Undelivered int            `json:"undelivered"`
	Via         map[string]int `json:"via"`
}

// ServiceNoticeDelivery reads how notice id's copies went.
func (s *Store) ServiceNoticeDelivery(id string) (NoticeDelivery, error) {
	d := NoticeDelivery{Via: map[string]int{}}
	rows, err := s.write.Query(`SELECT state, channel, COUNT(*) FROM hub_notify_outbox
		WHERE kind = ? AND refs = ? GROUP BY state, channel`, NotifyKindNotice, id)
	if err != nil {
		return d, err
	}
	defer rows.Close()
	for rows.Next() {
		var state, ch string
		var k int
		if err := rows.Scan(&state, &ch, &k); err != nil {
			return d, err
		}
		switch state {
		case NoticeSent:
			d.Sent += k
			d.Via[ch] += k
		case NoticeUndelivered:
			d.Undelivered += k
		default:
			d.Pending += k
		}
	}
	return d, rows.Err()
}
