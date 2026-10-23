package store

import (
	"database/sql"
	"errors"
	"time"
)

// Authorization and concurrency live in the shared database, never a replica's
// relay table. The latter contains only transport handles.
const fleetPreviewSchema = `
CREATE TABLE IF NOT EXISTS fleet_previews (
 id TEXT PRIMARY KEY, owner TEXT NOT NULL, endpoint TEXT NOT NULL,
 machine TEXT NOT NULL, login TEXT NOT NULL, generation TEXT NOT NULL,
 token_hash TEXT NOT NULL, task_id INTEGER NOT NULL, worker TEXT NOT NULL,
 socket TEXT NOT NULL, expires INTEGER NOT NULL, closed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS fleet_previews_owner ON fleet_previews(owner);
CREATE TABLE IF NOT EXISTS fleet_preview_enrollments (
 endpoint TEXT PRIMARY KEY, owner TEXT NOT NULL, machine TEXT NOT NULL,
 login TEXT NOT NULL, generation TEXT NOT NULL, token_hash TEXT NOT NULL, approval TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS fleet_preview_auth (
 state_hash TEXT PRIMARY KEY, preview TEXT NOT NULL, callback TEXT NOT NULL,
 expires INTEGER NOT NULL, ticket_hash TEXT NOT NULL DEFAULT '',
 owner TEXT NOT NULL DEFAULT '', sid TEXT NOT NULL DEFAULT '',
 issued INTEGER NOT NULL DEFAULT 0, session_exp INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS fleet_preview_sessions (
 hash TEXT PRIMARY KEY, preview TEXT NOT NULL, owner TEXT NOT NULL,
 sid TEXT NOT NULL, issued INTEGER NOT NULL, expires INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS fleet_preview_connections (
 id TEXT PRIMARY KEY, owner TEXT NOT NULL, preview TEXT NOT NULL, expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_preview_connections_owner ON fleet_preview_connections(owner);
`

var ErrPreview = errors.New("preview is unavailable or not yours")
var ErrPreviewLimit = errors.New("preview account limit reached")

type Preview struct {
	ID          string `json:"id"`
	Owner       string `json:"-"`
	Endpoint    string `json:"-"`
	Machine     string `json:"machine"`
	Login       string `json:"-"`
	Generation  string `json:"-"`
	TokenHash   string `json:"-"`
	TaskID      int64  `json:"-"`
	Worker      string `json:"-"`
	TaskBinding string `json:"-"`
	Socket      string `json:"socket"`
	Expires     int64  `json:"expires"`
	Closed      int    `json:"closed"`
	URL         string `json:"url,omitempty"`
	Online      bool   `json:"online"`
}

type PreviewAuthority struct{ Owner, Machine, Login, Generation, TokenHash string }

// Account-operation enrollment is the default authority. A historical node
// needs an explicit operator binding to the exact endpoint/token/account
// generation; its observed hostname or later managed role alone grants nothing.
func previewAuthority(q querier, endpoint string) (a PreviewAuthority, err error) {
	err = q.QueryRow(`SELECT a.principal_id,a.hostname,a.login,a.requested_at || ':' || a.op_id || ':' || a.updated_at,e.token_hash
 FROM endpoints e JOIN fleet_join_codes j ON j.endpoint_id=e.endpoint_id
 JOIN fleet_accounts a ON a.hostname=j.machine AND j.label=a.hostname || '-' || a.login
 WHERE e.endpoint_id=? AND e.retired_at IS NULL AND a.state='active'
 AND j.used_at IS NOT NULL AND j.role='managed' AND e.enrolled_host=j.machine
 AND j.joined_user=a.login AND e.os_user=a.login AND e.role='managed'`, endpoint).
		Scan(&a.Owner, &a.Machine, &a.Login, &a.Generation, &a.TokenHash)
	if !errors.Is(err, sql.ErrNoRows) {
		return
	}
	err = q.QueryRow(`SELECT b.owner,b.machine,b.login,b.generation || ':' || b.approval,b.token_hash
 FROM fleet_preview_enrollments b JOIN endpoints e ON e.endpoint_id=b.endpoint
 JOIN fleet_accounts a ON a.principal_id=b.owner AND a.hostname=b.machine AND a.login=b.login
 WHERE b.endpoint=? AND e.retired_at IS NULL AND e.role='managed' AND a.state='active'
 AND e.enrolled_host=b.machine AND e.os_user=b.login AND e.token_hash=b.token_hash
 AND a.requested_at || ':' || a.op_id || ':' || a.updated_at=b.generation`, endpoint).
		Scan(&a.Owner, &a.Machine, &a.Login, &a.Generation, &a.TokenHash)
	return
}
func (s *Store) PreviewAuthority(endpoint string) (PreviewAuthority, error) {
	return previewAuthority(s.write, endpoint)
}
func (s *Store) ensureFleetPreviews() error {
	_, e := s.write.Exec(s.d.ddl(fleetPreviewSchema))
	if e != nil {
		return e
	}
	return s.addColumn("fleet_previews", "task_binding", "TEXT NOT NULL DEFAULT ''")
}

const previewCols = `id,owner,endpoint,machine,login,generation,token_hash,task_id,worker,socket,expires,closed,task_binding`

func scanPreview(r interface{ Scan(...any) error }) (p Preview, e error) {
	e = r.Scan(&p.ID, &p.Owner, &p.Endpoint, &p.Machine, &p.Login, &p.Generation, &p.TokenHash, &p.TaskID, &p.Worker, &p.Socket, &p.Expires, &p.Closed, &p.TaskBinding)
	return
}
func previewValid(q querier, p Preview, now time.Time) error {
	if p.Closed != 0 || p.Expires <= now.Unix() {
		return ErrPreview
	}
	a, e := previewAuthority(q, p.Endpoint)
	if e != nil || a.Owner != p.Owner || a.Machine != p.Machine || a.Login != p.Login || a.Generation != p.Generation || a.TokenHash != p.TokenHash {
		return ErrPreview
	}
	binding, e := previewTaskBinding(q, p)
	if e != nil || (p.TaskBinding != "" && p.TaskBinding != binding) {
		return ErrPreview
	}
	return nil
}
func (s *Store) Preview(id string, now time.Time) (Preview, error) {
	p, e := scanPreview(s.write.QueryRow(`SELECT `+previewCols+` FROM fleet_previews WHERE id=?`, id))
	if e != nil {
		return p, e
	}
	return p, previewValid(s.write, p, now)
}
func (s *Store) CreatePreview(p Preview, max int, now time.Time) error {
	tx, e := s.write.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	binding, e := previewTaskBinding(tx, p)
	if e != nil || p.TaskBinding != "" && p.TaskBinding != binding {
		return ErrPreview
	}
	p.TaskBinding = binding
	if e = s.d.lockKey(tx, "fleet_previews", "preview:"+p.Owner); e != nil {
		return e
	}
	if e = previewValid(tx, p, now); e != nil {
		return e
	}
	var n int
	if e = tx.QueryRow(`SELECT COUNT(*) FROM fleet_previews WHERE owner=? AND closed=0 AND expires>?`, p.Owner, now.Unix()).Scan(&n); e != nil {
		return e
	}
	if n >= max {
		return ErrPreviewLimit
	}
	_, e = tx.Exec(`INSERT INTO fleet_previews (`+previewCols+`) VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?)`, p.ID, p.Owner, p.Endpoint, p.Machine, p.Login, p.Generation, p.TokenHash, p.TaskID, p.Worker, p.Socket, p.Expires, p.TaskBinding)
	if e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Store) ListPreviews(owner string, task int64) ([]Preview, error) {
	rows, e := s.write.Query(`SELECT `+previewCols+` FROM fleet_previews WHERE owner=? AND task_id=? AND closed=0 ORDER BY id`, owner, task)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Preview{}
	for rows.Next() {
		p, e := scanPreview(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
func (s *Store) ClosePreview(id, owner string) error {
	res, e := s.write.Exec(`UPDATE fleet_previews SET closed=1 WHERE id=? AND owner=?`, id, owner)
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrPreview
	}
	return nil
}
func (s *Store) RenewPreview(id, owner string, now time.Time, ttl time.Duration) error {
	p, e := s.Preview(id, now)
	if e != nil || p.Owner != owner {
		return ErrPreview
	}
	_, e = s.write.Exec(`UPDATE fleet_previews SET expires=? WHERE id=? AND owner=? AND closed=0 AND expires>?`, now.Add(ttl).Unix(), id, owner, now.Unix())
	return e
}

type PreviewSession struct {
	Owner, SID      string
	Issued, Expires int64
}

func (s *Store) BeginPreviewAuth(state, id, callback string, now time.Time) error {
	// Remove only expired material; session/connection reads check expiry too.
	if _, e := s.write.Exec(`DELETE FROM fleet_preview_auth WHERE expires<=?`, now.Unix()); e != nil {
		return e
	}
	_, e := s.write.Exec(`INSERT INTO fleet_preview_auth (state_hash,preview,callback,expires) VALUES (?,?,?,?)`, state, id, callback, now.Add(2*time.Minute).Unix())
	return e
}
func (s *Store) TicketPreview(state, id, callback, ticket string, a PreviewSession, now time.Time) error {
	res, e := s.write.Exec(`UPDATE fleet_preview_auth SET ticket_hash=?,owner=?,sid=?,issued=?,session_exp=? WHERE state_hash=? AND preview=? AND callback=? AND expires>? AND ticket_hash=''`, ticket, a.Owner, a.SID, a.Issued, a.Expires, state, id, callback, now.Unix())
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrPreview
	}
	return nil
}
func (s *Store) ExchangePreview(state, id, callback, ticket, session string, now time.Time) error {
	tx, e := s.write.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if e = s.d.lockKey(tx, "fleet_preview_auth", "preview-auth:"+state); e != nil {
		return e
	}
	var a PreviewSession
	if e = tx.QueryRow(`SELECT owner,sid,issued,session_exp FROM fleet_preview_auth WHERE state_hash=? AND preview=? AND callback=? AND ticket_hash=? AND ticket_hash<>'' AND expires>?`, state, id, callback, ticket, now.Unix()).Scan(&a.Owner, &a.SID, &a.Issued, &a.Expires); e != nil {
		return ErrPreview
	}
	p, e := scanPreview(tx.QueryRow(`SELECT `+previewCols+` FROM fleet_previews WHERE id=?`, id))
	if e != nil || p.Owner != a.Owner {
		return ErrPreview
	}
	if e = previewValid(tx, p, now); e != nil {
		return e
	}
	if a.Expires <= now.Unix() {
		return ErrPreview
	}
	if _, e = tx.Exec(`DELETE FROM fleet_preview_auth WHERE state_hash=?`, state); e != nil {
		return e
	}
	if _, e = tx.Exec(`INSERT INTO fleet_preview_sessions (hash,preview,owner,sid,issued,expires) VALUES (?,?,?,?,?,?)`, session, id, a.Owner, a.SID, a.Issued, a.Expires); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Store) PreviewSession(hash, id string, now time.Time) (a PreviewSession, e error) {
	e = s.write.QueryRow(`SELECT owner,sid,issued,expires FROM fleet_preview_sessions WHERE hash=? AND preview=? AND expires>?`, hash, id, now.Unix()).Scan(&a.Owner, &a.SID, &a.Issued, &a.Expires)
	return
}
func (s *Store) TakePreviewConnection(id string, p Preview, max int, now time.Time) error {
	tx, e := s.write.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if e = s.d.lockKey(tx, "fleet_preview_connections", "preview-conn:"+p.Owner); e != nil {
		return e
	}
	if e = previewValid(tx, p, now); e != nil {
		return e
	}
	if _, e = tx.Exec(`DELETE FROM fleet_preview_connections WHERE expires<=?`, now.Unix()); e != nil {
		return e
	}
	var n int
	if e = tx.QueryRow(`SELECT COUNT(*) FROM fleet_preview_connections WHERE owner=?`, p.Owner).Scan(&n); e != nil {
		return e
	}
	if n >= max {
		return ErrPreviewLimit
	}
	_, e = tx.Exec(`INSERT INTO fleet_preview_connections (id,owner,preview,expires) VALUES (?,?,?,?)`, id, p.Owner, p.ID, now.Add(10*time.Second).Unix())
	if e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Store) TouchPreviewConnection(id string, now time.Time) error {
	res, e := s.write.Exec(`UPDATE fleet_preview_connections SET expires=? WHERE id=? AND expires>?`, now.Add(10*time.Second).Unix(), id, now.Unix())
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return sql.ErrNoRows
	}
	return nil
}
func (s *Store) DropPreviewConnection(id string) {
	s.write.Exec(`DELETE FROM fleet_preview_connections WHERE id=?`, id)
}
