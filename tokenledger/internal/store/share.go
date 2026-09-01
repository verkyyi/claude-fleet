package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/base32"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ShareLink is a revocable credential for the redacted public view.
type ShareLink struct {
	ID         string     `json:"id"`
	Label      string     `json:"label"`
	ShowCosts  bool       `json:"show_costs"`
	CreatedAt  time.Time  `json:"created_at"`
	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
	Uses       int64      `json:"uses"`
}

// Active reports whether the link would be accepted right now.
func (l ShareLink) Active(now time.Time) bool {
	if l.RevokedAt != nil {
		return false
	}
	if l.ExpiresAt != nil && now.After(*l.ExpiresAt) {
		return false
	}
	return true
}

// Status is a word for the operator, so `share --list` reads as a decision
// rather than three nullable timestamps.
func (l ShareLink) Status(now time.Time) string {
	switch {
	case l.RevokedAt != nil:
		return "revoked"
	case l.ExpiresAt != nil && now.After(*l.ExpiresAt):
		return "expired"
	case l.Uses == 0:
		return "unused"
	default:
		return "active"
	}
}

// newShareID returns a short, printable, unambiguous id. Base32 without padding
// avoids the characters people misread aloud when revoking one over a call.
func newShareID() (string, error) {
	b := make([]byte, 5)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b)), nil
}

// CreateShareLink stores a new link and returns it. tokenHash is the caller's;
// the plaintext token never reaches this package.
func (s *Store) CreateShareLink(label, tokenHash string, showCosts bool, expiresAt *time.Time) (*ShareLink, error) {
	id, err := newShareID()
	if err != nil {
		return nil, fmt.Errorf("generate share id: %w", err)
	}
	now := time.Now().UTC()
	costs := 0
	if showCosts {
		costs = 1
	}
	if _, err := s.db.Exec(`
		INSERT INTO share_links (id, token_hash, label, show_costs, created_at, expires_at)
		VALUES (?,?,?,?,?,?)`,
		id, tokenHash, label, costs, fmtTime(now), fmtTimePtr(expiresAt)); err != nil {
		return nil, fmt.Errorf("create share link: %w", err)
	}
	return &ShareLink{ID: id, Label: label, ShowCosts: showCosts, CreatedAt: now, ExpiresAt: expiresAt}, nil
}

// ShareLinkByToken looks a link up by token hash and records the use.
//
// Returns nil (no error) when there is no such link, or when it is revoked or
// expired — the caller cannot then distinguish "wrong token" from "revoked
// token", which is the point: an ex-recipient probing the link learns nothing.
func (s *Store) ShareLinkByToken(tokenHash string) (*ShareLink, error) {
	l, err := s.scanShare(s.db.QueryRow(`
		SELECT id, label, show_costs, created_at, expires_at, revoked_at, last_used_at, uses
		FROM share_links WHERE token_hash = ?`, tokenHash))
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, err
	}
	if !l.Active(time.Now().UTC()) {
		return nil, nil
	}
	// Best effort: a failure to record the use must not deny access.
	_, _ = s.db.Exec(`UPDATE share_links SET uses = uses + 1, last_used_at = ? WHERE id = ?`,
		fmtTime(time.Now().UTC()), l.ID)
	return l, nil
}

// RevokeShareLink marks a link dead. Revoking an already-revoked or unknown id
// reports whether anything changed, so the CLI can say so plainly.
func (s *Store) RevokeShareLink(id string) (bool, error) {
	res, err := s.db.Exec(`UPDATE share_links SET revoked_at = ?
		WHERE id = ? AND revoked_at IS NULL`, fmtTime(time.Now().UTC()), id)
	if err != nil {
		return false, fmt.Errorf("revoke share link: %w", err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ListShareLinks returns every link, newest first, including dead ones — an
// operator auditing what was ever handed out needs the revoked ones too.
func (s *Store) ListShareLinks() ([]ShareLink, error) {
	rows, err := s.db.Query(`
		SELECT id, label, show_costs, created_at, expires_at, revoked_at, last_used_at, uses
		FROM share_links ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("list share links: %w", err)
	}
	defer rows.Close()
	var out []ShareLink
	for rows.Next() {
		l, err := s.scanShare(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *l)
	}
	return out, rows.Err()
}

func (s *Store) scanShare(row rowScanner) (*ShareLink, error) {
	var l ShareLink
	var costs int
	var created string
	var expires, revoked, used sql.NullString
	if err := row.Scan(&l.ID, &l.Label, &costs, &created, &expires, &revoked, &used, &l.Uses); err != nil {
		return nil, err
	}
	l.ShowCosts = costs == 1
	l.CreatedAt, _ = time.Parse(rfc, created)
	l.ExpiresAt = parseNullTime(expires)
	l.RevokedAt = parseNullTime(revoked)
	l.LastUsedAt = parseNullTime(used)
	return &l, nil
}
