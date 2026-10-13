package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Access requests (claude-fleet#4051, EPIC #4048 C3, 共同约定 7): a person
// the list does not name asks to be let in, from /apply. One table,
// hub_access_requests (schema.sql). A request is keyed by the way its person
// signed in — (kind, subject), never a principal: an applicant has none until
// an admin approves them (C4, the admitPerson road). The one rule the table
// itself holds: at most one pending request per (kind, subject) — a partial
// unique index, so two replicas racing a double submit still leave one
// (BREAK-IT apply-flood).

// The states of a request.
const (
	RequestPending   = "pending"
	RequestApproved  = "approved"
	RequestRejected  = "rejected"
	RequestWithdrawn = "withdrawn"
)

// The channels a result is sent through (C5's Notify reads them): WeChat to
// the person's followed openid, a mail to notify_addr, or nowhere but the
// status page.
const (
	NotifyWeChat = "wechat"
	NotifyEmail  = "email"
	NotifyPage   = "page"
)

// AccessRequest is one request.
type AccessRequest struct {
	ID            string    `json:"id"`
	Kind          string    `json:"kind"`
	Subject       string    `json:"subject"`
	Display       string    `json:"display"`
	Use           string    `json:"use"`
	Team          string    `json:"team"`
	Referrer      string    `json:"referrer"`
	NotifyChannel string    `json:"notify_channel"`
	NotifyAddr    string    `json:"notify_addr"`
	State         string    `json:"state"`
	Reason        string    `json:"reason"`
	CooldownUntil time.Time `json:"cooldown_until"`
	DecidedBy     string    `json:"decided_by"`
	CreatedAt     time.Time `json:"created_at"`
	DecidedAt     time.Time `json:"decided_at"`
	// IPHash is the submitting address, hashed: what the per-address limit
	// counts. Never the address itself.
	IPHash string `json:"-"`
}

var (
	// ErrRequestPending: the identity already has a pending request.
	ErrRequestPending = errors.New("this sign-in already has a request waiting")
	// ErrRequestNotFound: no such request for that identity.
	ErrRequestNotFound = errors.New("no such request")
	// ErrRequestNotPending: the request was decided or withdrawn already.
	ErrRequestNotPending = errors.New("the request is no longer pending")
)

// CooldownError: the identity's last request was turned down, and it may ask
// again only from Until.
type CooldownError struct{ Until time.Time }

func (e *CooldownError) Error() string {
	return "a new request is possible from " + e.Until.UTC().Format(time.RFC3339)
}

// RequestStore is the table's one door: C3's pages, C4's review, C5's
// notices all go through it.
type RequestStore struct{ s *Store }

// Requests is the access-request store.
func (s *Store) Requests() RequestStore { return RequestStore{s} }

const requestCols = `id, kind, subject, display, use_text, team, referrer, notify_channel, notify_addr,
	state, reason, cooldown_until, decided_by, created_at, decided_at, ip_hash`

func scanRequest(row interface{ Scan(...any) error }) (*AccessRequest, error) {
	var r AccessRequest
	var cu, ca, da int64
	if err := row.Scan(&r.ID, &r.Kind, &r.Subject, &r.Display, &r.Use, &r.Team, &r.Referrer,
		&r.NotifyChannel, &r.NotifyAddr, &r.State, &r.Reason, &cu, &r.DecidedBy, &ca, &da, &r.IPHash); err != nil {
		return nil, err
	}
	r.CooldownUntil, r.CreatedAt, r.DecidedAt = unixOrZero(cu), unixOrZero(ca), unixOrZero(da)
	return &r, nil
}

// Create records r as pending. It refuses a second pending request for the
// same (kind, subject) with ErrRequestPending, and a request inside the last
// refusal's cooldown with *CooldownError. r.ID and r.CreatedAt must be set.
func (q RequestStore) Create(r AccessRequest) (*AccessRequest, error) {
	if r.ID == "" || r.Kind == "" || strings.TrimSpace(r.Subject) == "" {
		return nil, errors.New("a request needs an id, a kind and a subject")
	}
	tx, err := q.s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	last, err := scanRequest(tx.QueryRow(`SELECT `+requestCols+` FROM hub_access_requests
		WHERE kind = ? AND subject = ? ORDER BY created_at DESC, id DESC LIMIT 1`, r.Kind, r.Subject))
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return nil, err
	case last.State == RequestPending:
		return nil, ErrRequestPending
	case last.State == RequestRejected && r.CreatedAt.Before(last.CooldownUntil):
		return nil, &CooldownError{Until: last.CooldownUntil}
	}
	r.State = RequestPending
	_, err = tx.Exec(`INSERT INTO hub_access_requests (`+requestCols+`)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', 0, '', ?, 0, ?)`,
		r.ID, r.Kind, r.Subject, r.Display, r.Use, r.Team, r.Referrer, r.NotifyChannel, r.NotifyAddr,
		r.State, r.CreatedAt.Unix(), r.IPHash)
	if isUniqueViolation(err) {
		return nil, ErrRequestPending
	}
	if err != nil {
		return nil, fmt.Errorf("record the request: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	r.CreatedAt = unixOrZero(r.CreatedAt.Unix())
	return &r, nil
}

// Get is one request by id, nil when there is none.
func (q RequestStore) Get(id string) (*AccessRequest, error) {
	r, err := scanRequest(q.s.write.QueryRow(`SELECT `+requestCols+` FROM hub_access_requests WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

// ByIdentity is every request (kind, subject) made, newest first.
func (q RequestStore) ByIdentity(kind, subject string) ([]AccessRequest, error) {
	return q.list(`WHERE kind = ? AND subject = ? ORDER BY created_at DESC, id DESC`, kind, subject)
}

// List is the requests in state ("" = every state), newest first, at most
// limit (≤ 0 = 500).
func (q RequestStore) List(state string, limit int) ([]AccessRequest, error) {
	if limit <= 0 {
		limit = 500
	}
	if state == "" {
		return q.list(`ORDER BY created_at DESC, id DESC LIMIT ?`, limit)
	}
	return q.list(`WHERE state = ? ORDER BY created_at DESC, id DESC LIMIT ?`, state, limit)
}

func (q RequestStore) list(where string, args ...any) ([]AccessRequest, error) {
	rows, err := q.s.write.Query(`SELECT `+requestCols+` FROM hub_access_requests `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AccessRequest{}
	for rows.Next() {
		r, err := scanRequest(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// SubmittedFrom counts the requests made from ipHash since since: the
// per-address limit, shared by every replica.
func (q RequestStore) SubmittedFrom(ipHash string, since time.Time) (int, error) {
	var n int
	err := q.s.write.QueryRow(`SELECT COUNT(*) FROM hub_access_requests WHERE ip_hash = ? AND created_at >= ?`,
		ipHash, since.Unix()).Scan(&n)
	return n, err
}

// RequestEdit is what the person may change on their pending request.
type RequestEdit struct {
	Use, Team, Referrer       string
	NotifyChannel, NotifyAddr string
}

// Edit changes the pending request id of (kind, subject). Only its own
// person, only while it waits.
func (q RequestStore) Edit(id, kind, subject string, e RequestEdit) (*AccessRequest, error) {
	res, err := q.s.write.Exec(`UPDATE hub_access_requests SET use_text = ?, team = ?, referrer = ?,
		notify_channel = ?, notify_addr = ? WHERE id = ? AND kind = ? AND subject = ? AND state = ?`,
		e.Use, e.Team, e.Referrer, e.NotifyChannel, e.NotifyAddr, id, kind, subject, RequestPending)
	if err != nil {
		return nil, err
	}
	return q.after(res, id, kind, subject)
}

// Withdraw takes back the pending request id of (kind, subject): it leaves
// the queue, and the person may ask again at once.
func (q RequestStore) Withdraw(id, kind, subject string, now time.Time) (*AccessRequest, error) {
	res, err := q.s.write.Exec(`UPDATE hub_access_requests SET state = ?, decided_at = ?, decided_by = ?
		WHERE id = ? AND kind = ? AND subject = ? AND state = ?`,
		RequestWithdrawn, now.Unix(), "self", id, kind, subject, RequestPending)
	if err != nil {
		return nil, err
	}
	return q.after(res, id, kind, subject)
}

// Decide approves or rejects the pending request id: by is the admin's
// principal; a rejection carries its reason and the time a new request is
// possible from (zero = at once).
func (q RequestStore) Decide(id, state, reason string, cooldownUntil time.Time, by string, now time.Time) (*AccessRequest, error) {
	if state != RequestApproved && state != RequestRejected {
		return nil, fmt.Errorf("a decision is %s or %s, not %q", RequestApproved, RequestRejected, state)
	}
	var cu int64
	if state == RequestRejected && !cooldownUntil.IsZero() {
		cu = cooldownUntil.Unix()
	}
	res, err := q.s.write.Exec(`UPDATE hub_access_requests SET state = ?, reason = ?, cooldown_until = ?,
		decided_by = ?, decided_at = ? WHERE id = ? AND state = ?`,
		state, reason, cu, by, now.Unix(), id, RequestPending)
	if err != nil {
		return nil, err
	}
	r, err := q.Get(id)
	if err != nil {
		return nil, err
	}
	if r == nil {
		return nil, ErrRequestNotFound
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return r, ErrRequestNotPending
	}
	return r, nil
}

// after reads id back after an update aimed at (kind, subject)'s pending
// request: ErrRequestNotFound when it is not theirs, ErrRequestNotPending
// when the update found it no longer waiting.
func (q RequestStore) after(res sql.Result, id, kind, subject string) (*AccessRequest, error) {
	r, err := q.Get(id)
	if err != nil {
		return nil, err
	}
	if r == nil || r.Kind != kind || r.Subject != subject {
		return nil, ErrRequestNotFound
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return r, ErrRequestNotPending
	}
	return r, nil
}
