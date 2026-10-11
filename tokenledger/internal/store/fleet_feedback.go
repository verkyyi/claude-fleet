package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Feedback (claude-fleet#3355, EPIC #3354 C1): one line a person on a managed
// machine typed with /fleet-feedback, taken by the hub with the node's own
// token. The row is the feedback — who (principal, login, host: never shown in
// public), the context the session filled in (ctx JSON), the words, where its
// attachments sit (CCQUOTA_FLEET_FEEDBACK_DIR/F<id>/, kept seven days) — and
// everything later members write about it: the GitHub issue it became
// (gh_number, filed_at), when it was closed and what the closing said (reply),
// when that reply reached the person (replied_at). The id is the person's
// number: F<id>.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetFeedbackSchema = `
CREATE TABLE IF NOT EXISTS fleet_feedback (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  principal    TEXT NOT NULL,
  endpoint_id  TEXT NOT NULL,
  login        TEXT NOT NULL,
  host         TEXT NOT NULL,
  ctx          TEXT NOT NULL,
  text         TEXT NOT NULL,
  attach       TEXT NOT NULL,
  state        TEXT NOT NULL,
  gh_number    INTEGER NOT NULL,
  filed_at     TEXT NOT NULL,
  closed_at    TEXT NOT NULL,
  reply        TEXT NOT NULL,
  replied_at   TEXT NOT NULL,
  created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_feedback_principal ON fleet_feedback(principal, created_at);
CREATE INDEX IF NOT EXISTS fleet_feedback_created ON fleet_feedback(created_at);`

// A feedback's states. C1 writes received; filing (C2) and closing (C5) move it.
const (
	FeedbackReceived = "received"
	FeedbackFiled    = "filed"
	FeedbackClosed   = "closed"
)

// Feedback is one row of fleet_feedback.
type Feedback struct {
	ID         int64     `json:"id"`
	Principal  string    `json:"principal,omitempty"`
	EndpointID string    `json:"endpoint_id,omitempty"`
	Login      string    `json:"login,omitempty"`
	Host       string    `json:"host,omitempty"`
	Ctx        string    `json:"ctx,omitempty"`
	Text       string    `json:"text"`
	Attach     string    `json:"attach,omitempty"`
	State      string    `json:"state"`
	GHNumber   int64     `json:"gh_number,omitempty"`
	FiledAt    time.Time `json:"filed_at,omitzero"`
	ClosedAt   time.Time `json:"closed_at,omitzero"`
	Reply      string    `json:"reply,omitempty"`
	RepliedAt  time.Time `json:"replied_at,omitzero"`
	CreatedAt  time.Time `json:"created_at"`
}

// FeedbackNumber is the person-facing number of a row: F<id>.
func FeedbackNumber(id int64) string { return "F" + strconv.FormatInt(id, 10) }

// ErrFeedbackGap: the same person sent one less than the gap ago.
var ErrFeedbackGap = errors.New("feedback sent too soon after the last one")

func (s *Store) ensureFleetFeedback() error {
	if _, err := s.write.Exec(s.d.ddl(fleetFeedbackSchema)); err != nil {
		return fmt.Errorf("create fleet_feedback table: %w", err)
	}
	return nil
}

const feedbackCols = `id, principal, endpoint_id, login, host, ctx, text, attach, state, gh_number, filed_at, closed_at, reply, replied_at, created_at`

func scanFeedback(sc interface{ Scan(...any) error }) (*Feedback, error) {
	var f Feedback
	var filed, closed, replied, created string
	if err := sc.Scan(&f.ID, &f.Principal, &f.EndpointID, &f.Login, &f.Host, &f.Ctx, &f.Text, &f.Attach, &f.State,
		&f.GHNumber, &filed, &closed, &f.Reply, &replied, &created); err != nil {
		return nil, err
	}
	for _, p := range []struct {
		s string
		t *time.Time
	}{{filed, &f.FiledAt}, {closed, &f.ClosedAt}, {replied, &f.RepliedAt}, {created, &f.CreatedAt}} {
		if p.s != "" {
			*p.t, _ = time.Parse(rfc, p.s)
		}
	}
	return &f, nil
}

// InsertFeedback writes a new received row and returns its id.
func (s *Store) InsertFeedback(f Feedback) (int64, error) {
	var id int64
	err := s.write.QueryRow(`INSERT INTO fleet_feedback (principal, endpoint_id, login, host, ctx, text, attach, state,
		gh_number, filed_at, closed_at, reply, replied_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, '', '', '', '', ?) RETURNING id`,
		f.Principal, f.EndpointID, f.Login, f.Host, f.Ctx, f.Text, f.Attach, FeedbackReceived,
		f.CreatedAt.UTC().Format(rfc)).Scan(&id)
	return id, err
}

// SetFeedbackAttach records where a row's attachments were written.
func (s *Store) SetFeedbackAttach(id int64, attach string) error {
	_, err := s.write.Exec(`UPDATE fleet_feedback SET attach = ? WHERE id = ?`, attach, id)
	return err
}

// FeedbackByID is one row; nil, nil when there is none.
func (s *Store) FeedbackByID(id int64) (*Feedback, error) {
	f, err := scanFeedback(s.read.QueryRow(`SELECT `+feedbackCols+` FROM fleet_feedback WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return f, err
}

// FeedbackFor lists one person's rows, newest first.
func (s *Store) FeedbackFor(principal string, limit int) ([]Feedback, error) {
	return s.feedbackQuery(`WHERE principal = ?`, []any{principal}, limit)
}

// FeedbackList lists every row, newest first (the admin's view, C3).
func (s *Store) FeedbackList(limit int) ([]Feedback, error) {
	return s.feedbackQuery(``, nil, limit)
}

func (s *Store) feedbackQuery(where string, args []any, limit int) ([]Feedback, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.read.Query(`SELECT `+feedbackCols+` FROM fleet_feedback `+where+` ORDER BY id DESC LIMIT ?`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Feedback{}
	for rows.Next() {
		f, err := scanFeedback(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *f)
	}
	return out, rows.Err()
}

// FeedbackAttachedBefore lists the rows created before before that still
// name attachments — the seven-day sweep's work.
func (s *Store) FeedbackAttachedBefore(before time.Time) ([]Feedback, error) {
	return s.feedbackQuery(`WHERE attach <> '' AND created_at < ?`, []any{before.UTC().Format(rfc)}, 1000)
}

// TakeFeedbackGap claims key's next send at now when the last one was at
// least gap ago: one conditional UPDATE on the uses table (kind
// feedback-last, n = the last send's unix second), so two sends racing in one
// second take exactly one. ErrFeedbackGap with the seconds left otherwise.
func (s *Store) TakeFeedbackGap(key string, now time.Time, gap time.Duration) (int, error) {
	const kind, day = "feedback-last", "-"
	if _, err := s.write.Exec(`INSERT INTO fleet_debug_uses (ticket_id, kind, day, n) VALUES (?, ?, ?, 0)
		ON CONFLICT(ticket_id, kind, day) DO NOTHING`, key, kind, day); err != nil {
		return 0, err
	}
	at, edge := now.Unix(), now.Add(-gap).Unix()
	res, err := s.write.Exec(`UPDATE fleet_debug_uses SET n = ? WHERE ticket_id = ? AND kind = ? AND day = ? AND n <= ?`,
		at, key, kind, day, edge)
	if err != nil {
		return 0, err
	}
	if k, _ := res.RowsAffected(); k == 1 {
		return 0, nil
	}
	var last int64
	if err := s.read.QueryRow(`SELECT n FROM fleet_debug_uses WHERE ticket_id = ? AND kind = ? AND day = ?`, key, kind, day).Scan(&last); err != nil {
		return 0, err
	}
	left := int(last - edge)
	if left < 1 {
		left = 1
	}
	return left, ErrFeedbackGap
}
