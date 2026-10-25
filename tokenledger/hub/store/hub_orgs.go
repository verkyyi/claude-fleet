package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Organizations and subscription pools (task PNWW).
//
// An organization sits above persons: every person belongs to exactly ONE
// (hub_users.org_id), with a role in it (hub_users.org_role: admin | member).
// There is one level only — no team inside an organization.
//
// A pool is a set of subscriptions (fleet_credentials.pool_id) owned by the
// platform, by one organization, or by one person. A person may use, in this
// order: the pools they own (their own subscriptions sit in their personal
// pool) → their organization's → the platform's (unless the organization
// turned allow_platform_pool off); inside a level, smaller priority first.
//
// Bootstrap is additive and idempotent (ensureFleetOrgs): the organizations
// platform and trial and the pool platform-default exist; every shared row
// (PoolPrincipal) without a pool sits in platform-default, every person's own
// row in that person's personal pool. Defaults are read, not only written: a
// row with pool_id ” is in its default pool and a person with org_id ” in
// their default organization (DefaultOrgFor), so a row or a person added
// after the bootstrap reads exactly as one the bootstrap stamped. So after it
// every person may use exactly what they could before: their own plus the
// shared pool (api: TestOrgBootstrapKeepsEveryonesAccounts).
const hubOrgsSchema = `
CREATE TABLE IF NOT EXISTS hub_orgs (
  org_id     TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  kind       TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'active',
  allow_platform_pool INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS hub_pools (
  pool_id    TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  owner_kind TEXT NOT NULL,
  owner_id   TEXT NOT NULL DEFAULT '',
  priority   INTEGER NOT NULL DEFAULT 0,
  enabled    INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS hub_pools_owner ON hub_pools(owner_kind, owner_id);`

// The bootstrap's organizations and pool.
const (
	OrgPlatform         = "platform"
	OrgTrial            = "trial"
	PoolPlatformDefault = "platform-default"
	// personalPoolPrefix + principal is a person's personal pool.
	personalPoolPrefix = "personal:"
)

// Organization kinds and statuses, pool owner kinds, org roles.
const (
	OrgKindPlatform = "platform"
	OrgKindTrial    = "trial"
	OrgKindCustomer = "customer"

	OrgActive   = "active"
	OrgDisabled = "disabled"

	PoolOwnerPlatform = "platform"
	PoolOwnerOrg      = "org"
	PoolOwnerPerson   = "person"

	OrgRoleAdmin  = "admin"
	OrgRoleMember = "member"
)

// Org is one organization.
type Org struct {
	ID                string    `json:"org_id"`
	Name              string    `json:"name"`
	Kind              string    `json:"kind"`
	Status            string    `json:"status"`
	AllowPlatformPool bool      `json:"allow_platform_pool"`
	CreatedAt         time.Time `json:"created_at"`
}

// Pool is one subscription pool.
type Pool struct {
	ID        string    `json:"pool_id"`
	Name      string    `json:"name"`
	OwnerKind string    `json:"owner_kind"`
	OwnerID   string    `json:"owner_id"`
	Priority  int       `json:"priority"`
	Enabled   bool      `json:"enabled"`
	CreatedAt time.Time `json:"created_at"`
	// Implicit: not a row — a default pool read as there (platform-default
	// before the bootstrap wrote it, a person's personal pool).
	Implicit bool `json:"implicit,omitempty"`
}

// ErrNoOrg / ErrNoPool / ErrNoMember are the unknowns.
var (
	ErrNoOrg    = errors.New("no such organization")
	ErrNoPool   = errors.New("no such pool")
	ErrNoMember = errors.New("not a person on the list (hub_users): add them first")
)

// ValidOrgKind, ValidPoolOwner and ValidOrgRole check a value.
func ValidOrgKind(k string) bool {
	return k == OrgKindPlatform || k == OrgKindTrial || k == OrgKindCustomer
}
func ValidPoolOwner(k string) bool {
	return k == PoolOwnerPlatform || k == PoolOwnerOrg || k == PoolOwnerPerson
}
func ValidOrgRole(r string) bool { return r == OrgRoleAdmin || r == OrgRoleMember }

// PersonalPoolID is principal's personal pool.
func PersonalPoolID(principal string) string { return personalPoolPrefix + principal }

// IsPersonalPool says whether id is some person's personal pool, and whose.
func IsPersonalPool(id string) (string, bool) {
	return strings.CutPrefix(id, personalPoolPrefix)
}

// EffectivePoolID is the pool c sits in: its pool_id, else its default.
func EffectivePoolID(c Credential) string {
	if c.PoolID != "" {
		return c.PoolID
	}
	if c.PrincipalID == PoolPrincipal {
		return PoolPlatformDefault
	}
	return PersonalPoolID(c.PrincipalID)
}

func (s *Store) ensureFleetOrgs() error {
	if _, err := s.write.Exec(s.d.ddl(hubOrgsSchema)); err != nil {
		return fmt.Errorf("create org tables: %w", err)
	}
	for _, c := range []string{"org_id", "org_role"} {
		if err := s.addColumn("hub_users", c, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	return s.bootstrapOrgs(time.Now())
}

// BootstrapOrgs runs the bootstrap again (Open already did): idempotent,
// it only fills what is missing.
func (s *Store) BootstrapOrgs(now time.Time) error { return s.bootstrapOrgs(now) }

// bootstrapOrgs is idempotent: it only fills what is missing.
func (s *Store) bootstrapOrgs(now time.Time) error {
	at := fmtTime(now)
	for _, o := range []Org{{ID: OrgPlatform, Name: "Platform", Kind: OrgKindPlatform},
		{ID: OrgTrial, Name: "Trial", Kind: OrgKindTrial}} {
		if _, err := s.write.Exec(`INSERT INTO hub_orgs (org_id, name, kind, status, allow_platform_pool, created_at)
			VALUES (?, ?, ?, 'active', 1, ?) ON CONFLICT(org_id) DO NOTHING`, o.ID, o.Name, o.Kind, at); err != nil {
			return fmt.Errorf("bootstrap org %s: %w", o.ID, err)
		}
	}
	if _, err := s.write.Exec(`INSERT INTO hub_pools (pool_id, name, owner_kind, owner_id, priority, enabled, created_at)
		VALUES (?, 'Platform default', 'platform', '', 0, 1, ?) ON CONFLICT(pool_id) DO NOTHING`, PoolPlatformDefault, at); err != nil {
		return fmt.Errorf("bootstrap pool: %w", err)
	}
	// A person's own rows: a personal pool each, the rows put in it.
	rows, err := s.write.Query(`SELECT DISTINCT principal_id FROM fleet_credentials WHERE principal_id != ?`, PoolPrincipal)
	if err != nil {
		return err
	}
	var owners []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			rows.Close()
			return err
		}
		owners = append(owners, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, p := range owners {
		if _, err := s.write.Exec(`INSERT INTO hub_pools (pool_id, name, owner_kind, owner_id, priority, enabled, created_at)
			VALUES (?, 'Personal', 'person', ?, 0, 1, ?) ON CONFLICT(pool_id) DO NOTHING`, PersonalPoolID(p), p, at); err != nil {
			return fmt.Errorf("bootstrap personal pool of %s: %w", p, err)
		}
	}
	if _, err := s.write.Exec(`UPDATE fleet_credentials SET pool_id = ? WHERE pool_id = '' AND principal_id = ?`,
		PoolPlatformDefault, PoolPrincipal); err != nil {
		return err
	}
	if _, err := s.write.Exec(`UPDATE fleet_credentials SET pool_id = '`+personalPoolPrefix+`' || principal_id WHERE pool_id = '' AND principal_id != ?`,
		PoolPrincipal); err != nil {
		return err
	}
	// Everyone on the list: the platform (a trial person has no list row;
	// DefaultOrgFor reads them as trial).
	_, err = s.write.Exec(`UPDATE hub_users SET org_id = ? WHERE org_id = ''`, OrgPlatform)
	return err
}

func scanOrg(sc interface{ Scan(...any) error }) (Org, error) {
	var o Org
	var allow int
	var created string
	if err := sc.Scan(&o.ID, &o.Name, &o.Kind, &o.Status, &allow, &created); err != nil {
		return o, err
	}
	o.AllowPlatformPool = allow != 0
	o.CreatedAt, _ = time.Parse(rfc, created)
	return o, nil
}

const orgCols = `SELECT org_id, name, kind, status, allow_platform_pool, created_at FROM hub_orgs`

// Orgs lists every organization by id.
func (s *Store) Orgs() ([]Org, error) {
	rows, err := s.write.Query(orgCols + ` ORDER BY org_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Org{}
	for rows.Next() {
		o, err := scanOrg(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// Org reads one; ErrNoOrg when unknown.
func (s *Store) Org(id string) (*Org, error) {
	o, err := scanOrg(s.write.QueryRow(orgCols+` WHERE org_id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoOrg
	}
	if err != nil {
		return nil, err
	}
	return &o, nil
}

// PutOrg creates or updates one (created_at kept).
func (s *Store) PutOrg(o Org, at time.Time) error {
	if o.Status == "" {
		o.Status = OrgActive
	}
	allow := 0
	if o.AllowPlatformPool {
		allow = 1
	}
	_, err := s.write.Exec(`INSERT INTO hub_orgs (org_id, name, kind, status, allow_platform_pool, created_at)
		VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(org_id) DO UPDATE SET name = excluded.name, kind = excluded.kind,
		status = excluded.status, allow_platform_pool = excluded.allow_platform_pool`,
		o.ID, o.Name, o.Kind, o.Status, allow, fmtTime(at))
	return err
}

// DeleteOrg removes an organization with no member and no pool; the
// bootstrap's two are never removed.
func (s *Store) DeleteOrg(id string) error {
	if id == OrgPlatform || id == OrgTrial {
		return fmt.Errorf("organization %s is the hub's own and stays (disable it instead)", id)
	}
	var n int
	if err := s.write.QueryRow(`SELECT COUNT(*) FROM hub_users WHERE org_id = ?`, id).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("organization %s still has %d member(s): move them first", id, n)
	}
	if err := s.write.QueryRow(`SELECT COUNT(*) FROM hub_pools WHERE owner_kind = 'org' AND owner_id = ?`, id).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("organization %s still owns %d pool(s): remove them first", id, n)
	}
	res, err := s.write.Exec(`DELETE FROM hub_orgs WHERE org_id = ?`, id)
	if err != nil {
		return err
	}
	if k, _ := res.RowsAffected(); k == 0 {
		return ErrNoOrg
	}
	return nil
}

// PersonOrg is principal's organization and role there: hub_users when it
// says, else DefaultOrgFor. A service principal (svc:) is in none ("").
func (s *Store) PersonOrg(principal string) (orgID, role string, err error) {
	if principal == "" || principal == PoolPrincipal || strings.HasPrefix(principal, "svc:") {
		return "", "", nil
	}
	var org, r string
	err = s.write.QueryRow(`SELECT org_id, org_role FROM hub_users WHERE principal_id = ?`, principal).Scan(&org, &r)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		org, r = "", ""
	case err != nil:
		return "", "", err
	}
	if r == "" {
		r = OrgRoleMember
	}
	if org != "" {
		return org, r, nil
	}
	org, err = s.DefaultOrgFor(principal)
	return org, r, err
}

// DefaultOrgFor is the organization a person reads as when nothing records
// one: trial for a person who came in through the trial and is not on the
// list (the same rule as the trial role), else platform.
func (s *Store) DefaultOrgFor(principal string) (string, error) {
	var onList int
	if err := s.write.QueryRow(`SELECT COUNT(*) FROM hub_users WHERE principal_id = ?`, principal).Scan(&onList); err != nil {
		return "", err
	}
	if onList > 0 {
		return OrgPlatform, nil
	}
	var state string
	err := s.write.QueryRow(`SELECT state FROM fleet_trials WHERE principal = ?`, principal).Scan(&state)
	if errors.Is(err, sql.ErrNoRows) {
		return OrgPlatform, nil
	}
	if err != nil {
		if strings.Contains(err.Error(), "no such table") || strings.Contains(err.Error(), "does not exist") {
			return OrgPlatform, nil
		}
		return "", err
	}
	if state == TrialConverted {
		return OrgPlatform, nil
	}
	return OrgTrial, nil
}

// SetPersonOrg puts principal in org with role. Only a person on the list
// (hub_users) has a row to hold it: ErrNoMember otherwise.
func (s *Store) SetPersonOrg(principal, org, role string) error {
	if _, err := s.Org(org); err != nil {
		return err
	}
	if role == "" {
		role = OrgRoleMember
	}
	res, err := s.write.Exec(`UPDATE hub_users SET org_id = ?, org_role = ? WHERE principal_id = ?`, org, role, principal)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoMember
	}
	return nil
}

// OrgMember is one person in an organization.
type OrgMember struct {
	Principal string `json:"principal"`
	Login     string `json:"login"`
	OrgID     string `json:"org_id"`
	Role      string `json:"org_role"`
	OnList    bool   `json:"on_list"`
}

// OrgMembers lists every person and their organization (org "" = all): the
// list, and the trial people the list does not hold.
func (s *Store) OrgMembers(org string) ([]OrgMember, error) {
	rows, err := s.write.Query(`SELECT principal_id, login, org_id, org_role FROM hub_users ORDER BY login, principal_id`)
	if err != nil {
		return nil, err
	}
	out := []OrgMember{}
	seen := map[string]bool{}
	for rows.Next() {
		var m OrgMember
		if err := rows.Scan(&m.Principal, &m.Login, &m.OrgID, &m.Role); err != nil {
			rows.Close()
			return nil, err
		}
		m.OnList, seen[m.Principal] = true, true
		if m.OrgID == "" {
			m.OrgID = OrgPlatform
		}
		if m.Role == "" {
			m.Role = OrgRoleMember
		}
		if org == "" || m.OrgID == org {
			out = append(out, m)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if org != "" && org != OrgTrial {
		return out, nil
	}
	trows, err := s.write.Query(`SELECT principal, subject FROM fleet_trials WHERE state != ? ORDER BY principal`, TrialConverted)
	if err != nil {
		return out, nil // a hub without the trial: nobody more
	}
	defer trows.Close()
	for trows.Next() {
		var m OrgMember
		if err := trows.Scan(&m.Principal, &m.Login); err != nil {
			return nil, err
		}
		if seen[m.Principal] {
			continue
		}
		m.OrgID, m.Role = OrgTrial, OrgRoleMember
		out = append(out, m)
	}
	return out, trows.Err()
}

func scanPool(sc interface{ Scan(...any) error }) (Pool, error) {
	var p Pool
	var en int
	var created string
	if err := sc.Scan(&p.ID, &p.Name, &p.OwnerKind, &p.OwnerID, &p.Priority, &en, &created); err != nil {
		return p, err
	}
	p.Enabled = en != 0
	p.CreatedAt, _ = time.Parse(rfc, created)
	return p, nil
}

const poolCols = `SELECT pool_id, name, owner_kind, owner_id, priority, enabled, created_at FROM hub_pools`

// Pools lists every pool row by id.
func (s *Store) Pools() ([]Pool, error) {
	rows, err := s.write.Query(poolCols + ` ORDER BY pool_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Pool{}
	for rows.Next() {
		p, err := scanPool(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// PoolByID reads one: a row, else a default pool read as there (Implicit),
// else ErrNoPool.
func (s *Store) PoolByID(id string) (*Pool, error) {
	p, err := scanPool(s.write.QueryRow(poolCols+` WHERE pool_id = ?`, id))
	if err == nil {
		return &p, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if id == PoolPlatformDefault {
		return &Pool{ID: id, Name: "Platform default", OwnerKind: PoolOwnerPlatform, Enabled: true, Implicit: true}, nil
	}
	if who, ok := IsPersonalPool(id); ok && who != "" {
		return &Pool{ID: id, Name: "Personal", OwnerKind: PoolOwnerPerson, OwnerID: who, Enabled: true, Implicit: true}, nil
	}
	return nil, ErrNoPool
}

// PutPool creates or updates one (created_at kept).
func (s *Store) PutPool(p Pool, at time.Time) error {
	en := 0
	if p.Enabled {
		en = 1
	}
	_, err := s.write.Exec(`INSERT INTO hub_pools (pool_id, name, owner_kind, owner_id, priority, enabled, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(pool_id) DO UPDATE SET name = excluded.name, owner_kind = excluded.owner_kind,
		owner_id = excluded.owner_id, priority = excluded.priority, enabled = excluded.enabled`,
		p.ID, p.Name, p.OwnerKind, p.OwnerID, p.Priority, en, fmtTime(at))
	return err
}

// PoolCredentials counts the rows sitting in pool id (defaults included).
func (s *Store) PoolCredentials(id string) (int, error) {
	q, args := `SELECT COUNT(*) FROM fleet_credentials WHERE pool_id = ?`, []any{id}
	if id == PoolPlatformDefault {
		q, args = `SELECT COUNT(*) FROM fleet_credentials WHERE pool_id = ? OR (pool_id = '' AND principal_id = ?)`, []any{id, PoolPrincipal}
	} else if who, ok := IsPersonalPool(id); ok {
		q, args = `SELECT COUNT(*) FROM fleet_credentials WHERE pool_id = ? OR (pool_id = '' AND principal_id = ?)`, []any{id, who}
	}
	var n int
	err := s.write.QueryRow(q, args...).Scan(&n)
	return n, err
}

// DeletePool removes an empty pool; platform-default and personal pools stay.
func (s *Store) DeletePool(id string) error {
	if _, personal := IsPersonalPool(id); id == PoolPlatformDefault || personal {
		return fmt.Errorf("pool %s is a default pool and stays (disable it instead)", id)
	}
	n, err := s.PoolCredentials(id)
	if err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("pool %s still holds %d subscription(s): move them first", id, n)
	}
	res, err := s.write.Exec(`DELETE FROM hub_pools WHERE pool_id = ?`, id)
	if err != nil {
		return err
	}
	if k, _ := res.RowsAffected(); k == 0 {
		return ErrNoPool
	}
	return nil
}

// SetCredentialPool moves one row into pool id (no secret is touched).
func (s *Store) SetCredentialPool(principalID, provider, account, id string) error {
	res, err := s.write.Exec(`UPDATE fleet_credentials SET pool_id = ? WHERE principal_id = ? AND provider = ? AND account = ?`,
		id, principalID, provider, account)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoCredential
	}
	return nil
}

// stampPoolUsage fills a usage row's organization and pool (task PNWW): the
// person's organization now, and the pool of the subscription it rode — the
// person's own row of that name first, else the shared one.
func (s *Store) stampPoolUsage(u *PoolUsage) error {
	if u.OrgID == "" {
		org, _, err := s.PersonOrg(u.Principal)
		if err != nil && !isMissingSchema(err) {
			return err
		}
		u.OrgID = org
	}
	if u.PoolID == "" && u.Account != "" {
		var pid, owner string
		err := s.write.QueryRow(`SELECT pool_id, principal_id FROM fleet_credentials
			WHERE provider = ? AND account = ? AND principal_id IN (?, ?)
			ORDER BY CASE WHEN principal_id = ? THEN 0 ELSE 1 END LIMIT 1`,
			u.Provider, u.Account, u.Principal, PoolPrincipal, u.Principal).Scan(&pid, &owner)
		switch {
		case err == nil:
			u.PoolID = EffectivePoolID(Credential{PrincipalID: owner, PoolID: pid})
		case errors.Is(err, sql.ErrNoRows), isMissingSchema(err):
		default:
			return err
		}
	}
	return nil
}

func isMissingSchema(err error) bool {
	if err == nil {
		return false
	}
	m := err.Error()
	return strings.Contains(m, "no such table") || strings.Contains(m, "no such column") ||
		strings.Contains(m, "does not exist")
}

// OrgUsageRow is one counted row of an organization's pool usage.
type OrgUsageRow struct {
	At     time.Time
	Tokens int64
}

// OrgUsageSince lists org's rows (input + cache writes + output) at or after
// since, oldest first — what an organization's budget sums.
func (s *Store) OrgUsageSince(org string, since time.Time) ([]OrgUsageRow, error) {
	rows, err := s.write.Query(`SELECT at_unix, tokens_in + cache_write + tokens_out FROM pool_usage
		WHERE org_id = ? AND at_unix >= ? ORDER BY at_unix, id`, org, since.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OrgUsageRow
	for rows.Next() {
		var at, n int64
		if err := rows.Scan(&at, &n); err != nil {
			return nil, err
		}
		out = append(out, OrgUsageRow{At: time.Unix(at, 0).UTC(), Tokens: n})
	}
	return out, rows.Err()
}
