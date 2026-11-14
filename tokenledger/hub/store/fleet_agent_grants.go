package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Connected agents (task T4DN): a person's own Claude Code, Codex, Gemini CLI
// or claude.ai reaching the hub's /mcp AS that person. One row per agent per
// purpose — a grant — whichever way it signed in: a personal key the person
// minted on the console (kind pat, its SHA-256 here), or OAuth (kind oauth, its
// access / refresh tokens in fleet_oauth_tokens, each naming this row). Revoking
// the row refuses the next call of every token it holds; the hub reads these
// rows on every call, with no cache.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetAgentGrantsSchema = `
CREATE TABLE IF NOT EXISTS fleet_agent_grants (
  id           TEXT PRIMARY KEY,
  person       TEXT NOT NULL,
  name         TEXT NOT NULL,
  client       TEXT NOT NULL DEFAULT '',
  kind         TEXT NOT NULL,
  client_id    TEXT NOT NULL DEFAULT '',
  scopes       TEXT NOT NULL DEFAULT '',
  token_hash   TEXT NOT NULL UNIQUE,
  created_at   TEXT NOT NULL,
  expires_at   TEXT NOT NULL,
  revoked_at   TEXT NOT NULL DEFAULT '',
  last_call_at TEXT NOT NULL DEFAULT '',
  calls        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS fleet_agent_grants_person ON fleet_agent_grants(person);
CREATE TABLE IF NOT EXISTS fleet_oauth_clients (
  client_id     TEXT PRIMARY KEY,
  kind          TEXT NOT NULL,
  name          TEXT NOT NULL DEFAULT '',
  redirect_uris TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS fleet_oauth_codes (
  code_hash    TEXT PRIMARY KEY,
  client_id    TEXT NOT NULL,
  person       TEXT NOT NULL,
  scopes       TEXT NOT NULL DEFAULT '',
  redirect_uri TEXT NOT NULL,
  challenge    TEXT NOT NULL,
  resource     TEXT NOT NULL DEFAULT '',
  ttl_hours    INTEGER NOT NULL DEFAULT 720,
  expires_at   TEXT NOT NULL,
  used         INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS fleet_oauth_tokens (
  token_hash TEXT PRIMARY KEY,
  grant_id   TEXT NOT NULL,
  kind       TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_oauth_tokens_grant ON fleet_oauth_tokens(grant_id);
CREATE TABLE IF NOT EXISTS fleet_oauth_failures (
  at        TEXT NOT NULL,
  person    TEXT NOT NULL DEFAULT '',
  client_id TEXT NOT NULL DEFAULT '',
  stage     TEXT NOT NULL,
  code      TEXT NOT NULL DEFAULT '',
  reason    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_oauth_failures_at ON fleet_oauth_failures(at);`

// Grant kinds.
const (
	AgentGrantPAT   = "pat"
	AgentGrantOAuth = "oauth"
)

// AgentGrant is one connected agent.
type AgentGrant struct {
	ID         string    `json:"id"`
	Person     string    `json:"person"`
	Name       string    `json:"name"`
	Client     string    `json:"client"`
	Kind       string    `json:"kind"`
	ClientID   string    `json:"client_id,omitempty"`
	Scopes     []string  `json:"scopes"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	RevokedAt  time.Time `json:"revoked_at,omitempty"`
	LastCallAt time.Time `json:"last_call_at,omitempty"`
	Calls      int64     `json:"calls"`
}

// Live reports whether the grant may still call at now.
func (g AgentGrant) Live(now time.Time) bool {
	return g.RevokedAt.IsZero() && now.Before(g.ExpiresAt)
}

// OAuthClient is a registered (DCR) or metadata-document (CIMD) client.
type OAuthClient struct {
	ClientID     string    `json:"client_id"`
	Kind         string    `json:"kind"`
	Name         string    `json:"name"`
	RedirectURIs []string  `json:"redirect_uris"`
	CreatedAt    time.Time `json:"created_at"`
}

// OAuthCode is one authorization code, stored by its hash.
type OAuthCode struct {
	ClientID    string
	Person      string
	Scopes      []string
	RedirectURI string
	Challenge   string
	Resource    string
	TTLHours    int
	ExpiresAt   time.Time
}

// ErrOAuthCodeUsed says a code was presented a second time (or never existed):
// the token endpoint answers invalid_grant either way.
var ErrOAuthCodeUsed = errors.New("authorization code unknown, expired or already used")

func (s *Store) ensureFleetAgentGrants() error {
	if _, err := s.write.Exec(s.d.ddl(fleetAgentGrantsSchema)); err != nil {
		return fmt.Errorf("create fleet_agent_grants tables: %w", err)
	}
	return nil
}

func joinScopes(v []string) string { return strings.Join(v, " ") }

func splitScopes(v string) []string {
	if strings.TrimSpace(v) == "" {
		return []string{}
	}
	return strings.Fields(v)
}

func agentTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(rfc)
}

func agentParse(v string) time.Time {
	if v == "" {
		return time.Time{}
	}
	t, _ := time.Parse(rfc, v)
	return t
}

// AddAgentGrant writes a new grant. tokenHash is the personal key's hash for a
// pat; an oauth grant has no key of its own and is written with "oauth:"+id.
func (s *Store) AddAgentGrant(g AgentGrant, tokenHash string) error {
	if tokenHash == "" {
		tokenHash = "oauth:" + g.ID
	}
	_, err := s.write.Exec(`INSERT INTO fleet_agent_grants (id, person, name, client, kind, client_id,
		scopes, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		g.ID, g.Person, g.Name, g.Client, g.Kind, g.ClientID, joinScopes(g.Scopes), tokenHash,
		agentTime(g.CreatedAt), agentTime(g.ExpiresAt))
	return err
}

const agentGrantCols = `id, person, name, client, kind, client_id, scopes, created_at, expires_at,
	revoked_at, last_call_at, calls`

func scanAgentGrant(sc interface{ Scan(...any) error }) (AgentGrant, error) {
	var g AgentGrant
	var scopes, created, expires, revoked, last string
	if err := sc.Scan(&g.ID, &g.Person, &g.Name, &g.Client, &g.Kind, &g.ClientID, &scopes,
		&created, &expires, &revoked, &last, &g.Calls); err != nil {
		return g, err
	}
	g.Scopes = splitScopes(scopes)
	g.CreatedAt, g.ExpiresAt = agentParse(created), agentParse(expires)
	g.RevokedAt, g.LastCallAt = agentParse(revoked), agentParse(last)
	return g, nil
}

// AgentGrantByTokenHash finds the pat grant a personal key belongs to.
func (s *Store) AgentGrantByTokenHash(hash string) (AgentGrant, error) {
	return scanAgentGrant(s.read.QueryRow(`SELECT `+agentGrantCols+` FROM fleet_agent_grants
		WHERE token_hash = ? AND kind = ?`, hash, AgentGrantPAT))
}

// AgentGrant reads one grant by id.
func (s *Store) AgentGrant(id string) (AgentGrant, error) {
	return scanAgentGrant(s.read.QueryRow(`SELECT `+agentGrantCols+` FROM fleet_agent_grants
		WHERE id = ?`, id))
}

// AgentGrants lists a person's grants, newest first; revoked ones only with all.
func (s *Store) AgentGrants(person string, all bool) ([]AgentGrant, error) {
	q := `SELECT ` + agentGrantCols + ` FROM fleet_agent_grants WHERE person = ?`
	if !all {
		q += ` AND revoked_at = ''`
	}
	rows, err := s.read.Query(q+` ORDER BY created_at DESC, id`, person)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AgentGrant{}
	for rows.Next() {
		g, err := scanAgentGrant(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// RevokeAgentGrant revokes a person's grant and every OAuth token it holds.
// false when no live grant of that person has that id.
func (s *Store) RevokeAgentGrant(person, id string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_agent_grants SET revoked_at = ?
		WHERE id = ? AND person = ? AND revoked_at = ''`, agentTime(now), id, person)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return false, nil
	}
	_, err = s.write.Exec(`DELETE FROM fleet_oauth_tokens WHERE grant_id = ?`, id)
	return true, err
}

// TouchAgentGrant counts one call.
func (s *Store) TouchAgentGrant(id string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_agent_grants SET calls = calls + 1, last_call_at = ?
		WHERE id = ?`, agentTime(now), id)
	return err
}

// PutOAuthClient registers (or, for a metadata-document client, refreshes) a client.
func (s *Store) PutOAuthClient(c OAuthClient) error {
	_, err := s.write.Exec(`DELETE FROM fleet_oauth_clients WHERE client_id = ?`, c.ClientID)
	if err != nil {
		return err
	}
	_, err = s.write.Exec(`INSERT INTO fleet_oauth_clients (client_id, kind, name, redirect_uris,
		created_at) VALUES (?, ?, ?, ?, ?)`, c.ClientID, c.Kind, c.Name,
		strings.Join(c.RedirectURIs, "\n"), agentTime(c.CreatedAt))
	return err
}

// ErrOAuthClientsFull: the bound on stored clients is reached and every one
// of them is in use.
var ErrOAuthClientsFull = errors.New("this hub holds as many OAuth clients as it keeps; retry later")

// PutOAuthClientBounded is PutOAuthClient within max stored clients: a new
// one past the bound first drops the oldest that no grant names and no
// unexpired code is waiting on; with none to drop it is refused
// (ErrOAuthClientsFull) and nothing is stored. A refresh of a client already
// held never counts against the bound.
func (s *Store) PutOAuthClientBounded(c OAuthClient, max int, now time.Time) error {
	var held int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_oauth_clients WHERE client_id = ?`, c.ClientID).Scan(&held); err != nil {
		return err
	}
	if held == 0 && max > 0 {
		var n int
		if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_oauth_clients`).Scan(&n); err != nil {
			return err
		}
		if over := n - max + 1; over > 0 {
			res, err := s.write.Exec(`DELETE FROM fleet_oauth_clients WHERE client_id IN (
				SELECT c.client_id FROM fleet_oauth_clients c
				WHERE NOT EXISTS (SELECT 1 FROM fleet_agent_grants g WHERE g.client_id = c.client_id)
				  AND NOT EXISTS (SELECT 1 FROM fleet_oauth_codes k WHERE k.client_id = c.client_id AND k.expires_at >= ?)
				ORDER BY c.created_at, c.client_id LIMIT ?)`, agentTime(now), over)
			if err != nil {
				return err
			}
			if gone, _ := res.RowsAffected(); gone < int64(over) {
				return ErrOAuthClientsFull
			}
		}
	}
	return s.PutOAuthClient(c)
}

// OAuthClient reads a registered client; sql.ErrNoRows when none.
func (s *Store) OAuthClient(id string) (OAuthClient, error) {
	var c OAuthClient
	var uris, created string
	err := s.read.QueryRow(`SELECT client_id, kind, name, redirect_uris, created_at
		FROM fleet_oauth_clients WHERE client_id = ?`, id).Scan(&c.ClientID, &c.Kind, &c.Name, &uris, &created)
	if err != nil {
		return c, err
	}
	if uris != "" {
		c.RedirectURIs = strings.Split(uris, "\n")
	}
	c.CreatedAt = agentParse(created)
	return c, nil
}

// PutOAuthCode stores an authorization code by its hash.
func (s *Store) PutOAuthCode(hash string, c OAuthCode) error {
	_, err := s.write.Exec(`INSERT INTO fleet_oauth_codes (code_hash, client_id, person, scopes,
		redirect_uri, challenge, resource, ttl_hours, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		hash, c.ClientID, c.Person, joinScopes(c.Scopes), c.RedirectURI, c.Challenge, c.Resource,
		c.TTLHours, agentTime(c.ExpiresAt))
	return err
}

// TakeOAuthCode spends a code: it works once, before it expires.
func (s *Store) TakeOAuthCode(hash string, now time.Time) (OAuthCode, error) {
	var c OAuthCode
	var scopes, expires string
	err := s.read.QueryRow(`SELECT client_id, person, scopes, redirect_uri, challenge, resource,
		ttl_hours, expires_at FROM fleet_oauth_codes WHERE code_hash = ? AND used = 0`, hash).Scan(
		&c.ClientID, &c.Person, &scopes, &c.RedirectURI, &c.Challenge, &c.Resource, &c.TTLHours, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrOAuthCodeUsed
	}
	if err != nil {
		return c, err
	}
	res, err := s.write.Exec(`UPDATE fleet_oauth_codes SET used = 1 WHERE code_hash = ? AND used = 0`, hash)
	if err != nil {
		return c, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return c, ErrOAuthCodeUsed
	}
	c.Scopes, c.ExpiresAt = splitScopes(scopes), agentParse(expires)
	if !now.Before(c.ExpiresAt) {
		return c, ErrOAuthCodeUsed
	}
	return c, nil
}

// PutOAuthToken stores an access or refresh token's hash for a grant.
func (s *Store) PutOAuthToken(hash, grantID, kind string, expires time.Time) error {
	_, err := s.write.Exec(`INSERT INTO fleet_oauth_tokens (token_hash, grant_id, kind, expires_at)
		VALUES (?, ?, ?, ?)`, hash, grantID, kind, agentTime(expires))
	return err
}

// OAuthToken reads a token: its grant, kind, expiry and when (if ever) a
// refresh token was spent.
func (s *Store) OAuthToken(hash string) (grantID, kind string, expires, usedAt time.Time, err error) {
	var e, u string
	err = s.read.QueryRow(`SELECT grant_id, kind, expires_at, used_at FROM fleet_oauth_tokens
		WHERE token_hash = ?`, hash).Scan(&grantID, &kind, &e, &u)
	return grantID, kind, agentParse(e), agentParse(u), err
}

// SpendOAuthRefresh marks a refresh token used; false when it already was —
// a replay, which the caller answers by revoking the whole grant.
func (s *Store) SpendOAuthRefresh(hash string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_oauth_tokens SET used_at = ?
		WHERE token_hash = ? AND kind = 'refresh' AND used_at = ''`, agentTime(now), hash)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// PruneOAuth drops expired codes and tokens.
func (s *Store) PruneOAuth(now time.Time) error {
	t := agentTime(now)
	if _, err := s.write.Exec(`DELETE FROM fleet_oauth_codes WHERE expires_at < ?`, t); err != nil {
		return err
	}
	_, err := s.write.Exec(`DELETE FROM fleet_oauth_tokens WHERE expires_at < ?`, t)
	return err
}

// OAuthFailure is one refused sign-in step (task T4DN): what the client was
// told, kept a week so its person can read why an agent would not connect.
type OAuthFailure struct {
	At       time.Time `json:"at"`
	Person   string    `json:"-"`
	ClientID string    `json:"client_id"`
	Stage    string    `json:"stage"`
	Code     string    `json:"error"`
	Reason   string    `json:"reason"`
}

// RecordOAuthFailure writes one refusal and drops those older than a week.
func (s *Store) RecordOAuthFailure(f OAuthFailure) error {
	if _, err := s.write.Exec(`INSERT INTO fleet_oauth_failures (at, person, client_id, stage, code, reason)
		VALUES (?, ?, ?, ?, ?, ?)`, agentTime(f.At), f.Person, f.ClientID, f.Stage, f.Code, f.Reason); err != nil {
		return err
	}
	_, err := s.write.Exec(`DELETE FROM fleet_oauth_failures WHERE at < ?`, agentTime(f.At.Add(-7*24*time.Hour)))
	return err
}

// OAuthFailures lists a person's refusals of the last week, newest first, at most limit.
func (s *Store) OAuthFailures(person string, limit int) ([]OAuthFailure, error) {
	rows, err := s.read.Query(`SELECT at, client_id, stage, code, reason FROM fleet_oauth_failures
		WHERE person = ? ORDER BY at DESC LIMIT `+fmt.Sprint(limit), person)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []OAuthFailure{}
	for rows.Next() {
		var f OAuthFailure
		var at string
		if err := rows.Scan(&at, &f.ClientID, &f.Stage, &f.Code, &f.Reason); err != nil {
			return nil, err
		}
		f.At = agentParse(at)
		out = append(out, f)
	}
	return out, rows.Err()
}

// PeekOAuthCode reads who a code was issued to without spending it: a refused
// token request is filed under the person who approved it.
func (s *Store) PeekOAuthCode(hash string) (person, clientID string) {
	_ = s.read.QueryRow(`SELECT person, client_id FROM fleet_oauth_codes WHERE code_hash = ?`, hash).Scan(&person, &clientID)
	return person, clientID
}
