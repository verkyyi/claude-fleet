package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// An invite (claude-fleet#2261, EPIC #2259 共同约定 4) lets one new person in
// without an admin at hand: an admin mints it, the newcomer's install command
// carries it, and the GitHub sign-in that presents it puts them on the list
// and opens their login. One code, one person, seven days, used once,
// revocable; optionally bound to one GitHub username. Only the code's hash is
// kept — the code itself is shown once, to the admin who made it, and never
// enters a log, an audit row or a page.
//
// The table is fleet_invites in schema.sql: invites need no fleet module.

// InviteTTL is how long an invite lives.
const InviteTTL = 7 * 24 * time.Hour

// Why an invite was refused — the reason a person reads.
const (
	InviteUnknown   = "unknown"
	InviteExpired   = "expired"
	InviteUsed      = "used"
	InviteRevoked   = "revoked"
	InviteOtherUser = "other-user"
)

// InviteError is an invite that cannot be used; Reason is one of the
// Invite* reasons above.
type InviteError struct{ Reason string }

func (e *InviteError) Error() string { return "invite " + e.Reason }

// InviteReason is err's reason when it is an InviteError, else "".
func InviteReason(err error) string {
	var ie *InviteError
	if errors.As(err, &ie) {
		return ie.Reason
	}
	return ""
}

// Invite is one invite. The code is never here: only its hash.
type Invite struct {
	ID          string    `json:"id"`
	CodeHash    string    `json:"-"`
	GitHubLogin string    `json:"github_login,omitempty"`
	CreatedBy   string    `json:"created_by,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
	UsedAt      time.Time `json:"used_at,omitempty"`
	UsedBy      string    `json:"used_by,omitempty"`
	RevokedAt   time.Time `json:"revoked_at,omitempty"`
}

// State is what the invite is at now: active, used, revoked or expired.
func (i Invite) State(now time.Time) string {
	switch {
	case !i.UsedAt.IsZero():
		return InviteUsed
	case !i.RevokedAt.IsZero():
		return InviteRevoked
	case !now.Before(i.ExpiresAt):
		return InviteExpired
	}
	return "active"
}

// CreateInvite records a new invite.
func (s *Store) CreateInvite(inv Invite) error {
	if inv.ID == "" || inv.CodeHash == "" || inv.ExpiresAt.IsZero() {
		return errors.New("invite: empty field")
	}
	_, err := s.write.Exec(`INSERT INTO fleet_invites (id, code_hash, github_login, created_by, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?)`, inv.ID, inv.CodeHash, strings.TrimSpace(inv.GitHubLogin), inv.CreatedBy,
		inv.CreatedAt.Unix(), inv.ExpiresAt.Unix())
	return err
}

const inviteCols = `id, code_hash, github_login, created_by, created_at, expires_at, used_at, used_by, revoked_at`

func scanInvite(row interface{ Scan(...any) error }) (*Invite, error) {
	var i Invite
	var c, e, u, r int64
	if err := row.Scan(&i.ID, &i.CodeHash, &i.GitHubLogin, &i.CreatedBy, &c, &e, &u, &i.UsedBy, &r); err != nil {
		return nil, err
	}
	i.CreatedAt, i.ExpiresAt = time.Unix(c, 0).UTC(), time.Unix(e, 0).UTC()
	if u > 0 {
		i.UsedAt = time.Unix(u, 0).UTC()
	}
	if r > 0 {
		i.RevokedAt = time.Unix(r, 0).UTC()
	}
	return &i, nil
}

// InviteByHash is the invite a code hashes to, in any state; nil, nil when
// there is none.
func (s *Store) InviteByHash(codeHash string) (*Invite, error) {
	i, err := scanInvite(s.read.QueryRow(`SELECT `+inviteCols+` FROM fleet_invites WHERE code_hash = ?`, codeHash))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return i, err
}

// Invites lists every invite, newest first.
func (s *Store) Invites() ([]Invite, error) {
	rows, err := s.read.Query(`SELECT ` + inviteCols + ` FROM fleet_invites ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Invite{}
	for rows.Next() {
		i, err := scanInvite(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *i)
	}
	return out, rows.Err()
}

// CheckInvite says whether the code could be used by login at now, without
// using it: the invite, or an *InviteError naming why not.
func (s *Store) CheckInvite(codeHash, login string, now time.Time) (*Invite, error) {
	i, err := s.InviteByHash(codeHash)
	if err != nil {
		return nil, err
	}
	if i == nil {
		return nil, &InviteError{InviteUnknown}
	}
	if st := i.State(now); st != "active" {
		return i, &InviteError{st}
	}
	if i.GitHubLogin != "" && !strings.EqualFold(i.GitHubLogin, strings.TrimSpace(login)) {
		return i, &InviteError{InviteOtherUser}
	}
	return i, nil
}

// UseInvite spends an invite for login (usedBy is who it let in, gh:<id>):
// once, before it expires, unrevoked, and by the username it is bound to if
// any. The spend is one conditional UPDATE, so two sign-ins racing on one
// code let exactly one person in.
func (s *Store) UseInvite(codeHash, login, usedBy string, now time.Time) (*Invite, error) {
	if _, err := s.CheckInvite(codeHash, login, now); err != nil {
		return nil, err
	}
	res, err := s.write.Exec(`UPDATE fleet_invites SET used_at = ?, used_by = ?
		WHERE code_hash = ? AND used_at = 0 AND revoked_at = 0 AND expires_at > ?
		AND (github_login = '' OR `+s.d.eqNocase("github_login")+`)`,
		now.Unix(), usedBy, codeHash, now.Unix(), strings.TrimSpace(login))
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// Lost a race since the check: read why now.
		if _, err := s.CheckInvite(codeHash, login, now); err != nil {
			return nil, err
		}
		return nil, &InviteError{InviteUsed}
	}
	return s.InviteByHash(codeHash)
}

// UnuseInvite gives an invite back when the sign-in it was spent on failed
// before the person was put on the list.
func (s *Store) UnuseInvite(codeHash string) error {
	_, err := s.write.Exec(`UPDATE fleet_invites SET used_at = 0, used_by = '' WHERE code_hash = ?`, codeHash)
	return err
}

// RevokeInvite stops an unused invite. ok=false when no such invite, or it
// was already used or revoked.
func (s *Store) RevokeInvite(id string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_invites SET revoked_at = ?
		WHERE id = ? AND used_at = 0 AND revoked_at = 0`, now.Unix(), id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// InvitedPrincipal says whether principal came in on an invite.
func (s *Store) InvitedPrincipal(principal string) (bool, error) {
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_invites WHERE used_by = ? AND used_at > 0`, principal).Scan(&n)
	return n > 0, err
}
