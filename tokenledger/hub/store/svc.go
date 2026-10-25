package store

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Service principals (claude-fleet#4003, the SPACE EPIC C1):
// an identity that is not a person and not a login — SPACE's back end, which
// dispatches runs for its own users, who have no account here. A principal
// holds a fixed set of scopes and nothing else: it is never an admin, never a
// viewer, never a node, so every route outside /v1/svc/ refuses it.
//
// Its keys are bearer tokens `fcs_<prefix8>_<secret>`; only the SHA-256 of the
// whole token is stored (as api.HashToken does for ccq_), the prefix is the
// lookup key. A principal may hold two live tokens at once — the old and the
// new during a rotation — never a third. Revoking a token, or disabling its
// principal, refuses the next call: the hub reads these rows on every call,
// with no cache.
//
// Created with the fleet module (EnsureNodes) and by `ccquota svc` (EnsureSvc).
const svcSchema = `
CREATE TABLE IF NOT EXISTS svc_principals (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL UNIQUE,
  scopes  TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1,
  created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS svc_tokens (
  prefix     TEXT PRIMARY KEY,
  sha256     TEXT NOT NULL UNIQUE,
  principal  TEXT NOT NULL,
  created    TEXT NOT NULL,
  expires    TEXT NOT NULL DEFAULT '',
  revoked_at TEXT NOT NULL DEFAULT '',
  last_used  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS svc_tokens_principal ON svc_tokens(principal);`

// The scopes a service principal can hold — the whole list. A route outside
// /v1/svc/ is no scope's.
const (
	SvcRunsWrite        = "runs:write"
	SvcRunsRead         = "runs:read"
	SvcTemplatesWrite   = "templates:write"
	SvcRunsEval         = "runs:eval"
	SvcTemplatesQualify = "templates:qualify"
	// SvcPassIssue lets a long-running service hold its own standing Codex
	// pass (claude-fleet svc pass, api/svc_pass.go). Granted only by name:
	// no principal holds it without an admin listing it.
	SvcPassIssue = "pass:issue"
)

// SvcScopes is every scope, in the order they print.
var SvcScopes = []string{SvcRunsWrite, SvcRunsRead, SvcTemplatesWrite, SvcRunsEval, SvcTemplatesQualify, SvcPassIssue}

// SvcLiveTokensMax is how many unrevoked, unexpired tokens one principal may
// hold: the current one and its replacement during a rotation.
const SvcLiveTokensMax = 2

var (
	ErrSvcExists      = errors.New("a service principal by that name already exists")
	ErrNoSvcPrincipal = errors.New("no such service principal")
	ErrNoSvcToken     = errors.New("no such service token")
	ErrSvcTokenLimit  = fmt.Errorf("this principal already holds %d live tokens; revoke the old one first", SvcLiveTokensMax)
	ErrSvcScope       = errors.New("unknown scope")
)

// SvcPrincipal is one service identity. ID is `svc:<name>`.
type SvcPrincipal struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Scopes  []string  `json:"scopes"`
	Enabled bool      `json:"enabled"`
	Created time.Time `json:"created"`
}

// Has is whether p holds scope.
func (p SvcPrincipal) Has(scope string) bool {
	for _, s := range p.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}

// SvcToken is one key of a principal; the secret itself is never here.
type SvcToken struct {
	Prefix    string     `json:"prefix"`
	SHA256    string     `json:"-"`
	Principal string     `json:"principal"`
	Created   time.Time  `json:"created"`
	Expires   *time.Time `json:"expires,omitempty"`
	RevokedAt *time.Time `json:"revoked_at,omitempty"`
	LastUsed  *time.Time `json:"last_used,omitempty"`
}

// Live is whether t still opens the door at now.
func (t SvcToken) Live(now time.Time) bool {
	return t.RevokedAt == nil && (t.Expires == nil || now.Before(*t.Expires))
}

// SvcScopesParse checks and orders a scope list (comma or space separated).
func SvcScopesParse(s string) ([]string, error) {
	want := map[string]bool{}
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' }) {
		known := false
		for _, k := range SvcScopes {
			if f == k {
				known = true
			}
		}
		if !known {
			return nil, fmt.Errorf("%w %q (known: %s)", ErrSvcScope, f, strings.Join(SvcScopes, " "))
		}
		want[f] = true
	}
	var out []string
	for _, k := range SvcScopes {
		if want[k] {
			out = append(out, k)
		}
	}
	return out, nil
}

// EnsureSvc creates the principal tables and the runs' (idempotent).
func (s *Store) EnsureSvc() error {
	if _, err := s.write.Exec(s.d.ddl(svcQualificationSchema)); err != nil {
		return err
	}
	if _, err := s.write.Exec(s.d.ddl(svcSchema)); err != nil {
		return fmt.Errorf("create svc tables: %w", err)
	}
	if err := s.ensureSvcRuns(); err != nil {
		return err
	}
	return s.ensureSvcEnvs()
}

func svcTimeOpt(v string) *time.Time {
	if v == "" {
		return nil
	}
	t, err := time.Parse(rfc, v)
	if err != nil {
		return nil
	}
	return &t
}

func svcTimeStr(t *time.Time) string {
	if t == nil {
		return ""
	}
	return fmtTime(*t)
}

// CreateSvcPrincipal adds svc:<name> holding scopes, enabled.
func (s *Store) CreateSvcPrincipal(name string, scopes []string, at time.Time) (SvcPrincipal, error) {
	name = strings.TrimSpace(name)
	if name == "" || strings.ContainsAny(name, " \t:/") {
		return SvcPrincipal{}, errors.New("a service name is one word with no ':' or '/'")
	}
	if _, err := s.SvcPrincipal("svc:" + name); err == nil {
		return SvcPrincipal{}, ErrSvcExists
	}
	p := SvcPrincipal{ID: "svc:" + name, Name: name, Scopes: scopes, Enabled: true, Created: at.UTC()}
	if _, err := s.write.Exec(`INSERT INTO svc_principals (id, name, scopes, enabled, created) VALUES (?, ?, ?, 1, ?)`,
		p.ID, p.Name, strings.Join(scopes, " "), fmtTime(at)); err != nil {
		return SvcPrincipal{}, err
	}
	return p, nil
}

func scanSvcPrincipal(sc interface{ Scan(...any) error }) (SvcPrincipal, error) {
	var p SvcPrincipal
	var scopes, created string
	var enabled int
	if err := sc.Scan(&p.ID, &p.Name, &scopes, &enabled, &created); err != nil {
		return p, err
	}
	p.Scopes = strings.Fields(scopes)
	p.Enabled = enabled != 0
	if t := svcTimeOpt(created); t != nil {
		p.Created = *t
	}
	return p, nil
}

// SvcPrincipal reads one principal by id (svc:<name>) or bare name.
func (s *Store) SvcPrincipal(id string) (SvcPrincipal, error) {
	if !strings.HasPrefix(id, "svc:") {
		id = "svc:" + id
	}
	p, err := scanSvcPrincipal(s.write.QueryRow(`SELECT id, name, scopes, enabled, created FROM svc_principals WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrNoSvcPrincipal
	}
	return p, err
}

// SvcPrincipals lists every principal by name.
func (s *Store) SvcPrincipals() ([]SvcPrincipal, error) {
	rows, err := s.write.Query(`SELECT id, name, scopes, enabled, created FROM svc_principals ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcPrincipal
	for rows.Next() {
		p, err := scanSvcPrincipal(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// SetSvcPrincipalEnabled turns a principal on or off; off refuses every one
// of its tokens at the next call.
func (s *Store) SetSvcPrincipalEnabled(id string, on bool) (SvcPrincipal, error) {
	p, err := s.SvcPrincipal(id)
	if err != nil {
		return p, err
	}
	v := 0
	if on {
		v = 1
	}
	if _, err := s.write.Exec(`UPDATE svc_principals SET enabled = ? WHERE id = ?`, v, p.ID); err != nil {
		return p, err
	}
	p.Enabled = on
	return p, nil
}

func scanSvcToken(sc interface{ Scan(...any) error }) (SvcToken, error) {
	var t SvcToken
	var created, expires, revoked, used string
	if err := sc.Scan(&t.Prefix, &t.SHA256, &t.Principal, &created, &expires, &revoked, &used); err != nil {
		return t, err
	}
	if c := svcTimeOpt(created); c != nil {
		t.Created = *c
	}
	t.Expires, t.RevokedAt, t.LastUsed = svcTimeOpt(expires), svcTimeOpt(revoked), svcTimeOpt(used)
	return t, nil
}

const svcTokenCols = `prefix, sha256, principal, created, expires, revoked_at, last_used`

// AddSvcToken stores a freshly minted token's prefix and hash. Refused for a
// principal that is gone, or that already holds SvcLiveTokensMax live tokens.
func (s *Store) AddSvcToken(t SvcToken, at time.Time) error {
	p, err := s.SvcPrincipal(t.Principal)
	if err != nil {
		return err
	}
	toks, err := s.SvcTokens(p.ID)
	if err != nil {
		return err
	}
	live := 0
	for _, o := range toks {
		if o.Live(at) {
			live++
		}
	}
	if live >= SvcLiveTokensMax {
		return ErrSvcTokenLimit
	}
	_, err = s.write.Exec(`INSERT INTO svc_tokens (`+svcTokenCols+`) VALUES (?, ?, ?, ?, ?, '', '')`,
		t.Prefix, t.SHA256, p.ID, fmtTime(at), svcTimeStr(t.Expires))
	return err
}

// SvcTokens lists a principal's tokens ("" = every principal's), newest first.
func (s *Store) SvcTokens(principal string) ([]SvcToken, error) {
	q, args := `SELECT `+svcTokenCols+` FROM svc_tokens`, []any{}
	if principal != "" {
		if !strings.HasPrefix(principal, "svc:") {
			principal = "svc:" + principal
		}
		q += ` WHERE principal = ?`
		args = append(args, principal)
	}
	rows, err := s.write.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcToken
	for rows.Next() {
		t, err := scanSvcToken(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Created.After(out[j].Created) })
	return out, rows.Err()
}

// SvcTokenByPrefix reads one token by its prefix.
func (s *Store) SvcTokenByPrefix(prefix string) (SvcToken, error) {
	t, err := scanSvcToken(s.write.QueryRow(`SELECT `+svcTokenCols+` FROM svc_tokens WHERE prefix = ?`, prefix))
	if errors.Is(err, sql.ErrNoRows) {
		return t, ErrNoSvcToken
	}
	return t, err
}

// RevokeSvcToken stamps revoked_at (idempotent: the first revocation's time
// stands) and returns the row as it now is.
func (s *Store) RevokeSvcToken(prefix string, at time.Time) (SvcToken, error) {
	if _, err := s.SvcTokenByPrefix(prefix); err != nil {
		return SvcToken{}, err
	}
	if _, err := s.write.Exec(`UPDATE svc_tokens SET revoked_at = ? WHERE prefix = ? AND revoked_at = ''`,
		fmtTime(at), prefix); err != nil {
		return SvcToken{}, err
	}
	return s.SvcTokenByPrefix(prefix)
}

// TouchSvcToken records a use, at most once a minute per token so a busy
// caller costs no write per call.
func (s *Store) TouchSvcToken(prefix string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE svc_tokens SET last_used = ? WHERE prefix = ? AND (last_used = '' OR last_used < ?)`,
		fmtTime(at), prefix, fmtTime(at.Add(-time.Minute)))
	return err
}
