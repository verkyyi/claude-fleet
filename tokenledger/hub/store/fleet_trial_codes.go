package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// 试用二维码 (claude-fleet MRGB): an admin's channel code on the service
// account, the WeChats it reached and every scan of it (schema.sql
// fleet_trial_codes · fleet_trial_grants · fleet_trial_scans). The one rule
// the tables hold: a WeChat (who) gets one trial ever — the grants' primary
// key, so two replicas answering the same scan twice still leave one.

// A code's kinds and states.
const (
	TrialCodeLimit = "limit" // a permanent code (QR_LIMIT_STR_SCENE)
	TrialCodeTemp  = "temp"  // a temporary one, at most 30 days (QR_STR_SCENE)

	TrialCodeLive    = "live"
	TrialCodeStopped = "stopped" // an admin stopped it
	TrialCodePaused  = "paused"  // the burst alarm stopped it
)

// A grant's states.
const (
	GrantGranted = "granted"
	GrantQueued  = "queued"  // the machines were full: released in order
	GrantPending = "pending" // an approval code's request waits for an admin
)

// TrialCode is one code.
type TrialCode struct {
	ID        string    `json:"id"`
	Scene     int64     `json:"scene"`
	Channel   string    `json:"channel"`
	Terms     string    `json:"terms"`
	Cap       int       `json:"cap"`
	Until     time.Time `json:"until"`
	Approval  bool      `json:"approval"`
	Kind      string    `json:"kind"`
	State     string    `json:"state"`
	PausedWhy string    `json:"paused_why,omitempty"`
	URL       string    `json:"url"`
	Ticket    string    `json:"-"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// TrialGrant is one WeChat a code reached.
type TrialGrant struct {
	Who       string    `json:"-"`
	CodeID    string    `json:"code_id"`
	Principal string    `json:"principal"`
	OpenID    string    `json:"-"`
	State     string    `json:"state"`
	Lang      string    `json:"lang"`
	ScannedAt time.Time `json:"scanned_at"`
	GrantedAt time.Time `json:"granted_at"`
	FirstAt   time.Time `json:"first_at"`
}

// TrialScan is one scan.
type TrialScan struct {
	ID      string
	CodeID  string
	OpenID  string
	Event   string
	Outcome string
	At      time.Time
}

// ErrTrialCodeFull: the code has given every trial it may.
var ErrTrialCodeFull = errors.New("the code has given every trial it may")

const trialCodeCols = `id, scene, channel, terms, cap, until_at, approval, kind, state, paused_why,
	qr_url, ticket, created_by, created_at, updated_at`

func scanTrialCode(row interface{ Scan(...any) error }) (*TrialCode, error) {
	var c TrialCode
	var until, ca, ua int64
	var approval int
	if err := row.Scan(&c.ID, &c.Scene, &c.Channel, &c.Terms, &c.Cap, &until, &approval, &c.Kind, &c.State,
		&c.PausedWhy, &c.URL, &c.Ticket, &c.CreatedBy, &ca, &ua); err != nil {
		return nil, err
	}
	c.Until, c.CreatedAt, c.UpdatedAt = unixOrZero(until), unixOrZero(ca), unixOrZero(ua)
	c.Approval = approval == 1
	return &c, nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func unixOf(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// CreateTrialCode records c (its ID, Scene and CreatedAt set); a scene taken
// already is ErrTrialSceneTaken, for the caller to draw the next.
func (s *Store) CreateTrialCode(c TrialCode) error {
	if c.ID == "" || c.Scene <= 0 || strings.TrimSpace(c.Channel) == "" {
		return errors.New("a trial code needs an id, a scene and a channel")
	}
	if c.Kind == "" {
		c.Kind = TrialCodeLimit
	}
	if c.State == "" {
		c.State = TrialCodeLive
	}
	_, err := s.write.Exec(`INSERT INTO fleet_trial_codes (`+trialCodeCols+`)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?)`,
		c.ID, c.Scene, c.Channel, c.Terms, c.Cap, unixOf(c.Until), boolInt(c.Approval), c.Kind, c.State,
		c.URL, c.Ticket, c.CreatedBy, c.CreatedAt.Unix(), c.CreatedAt.Unix())
	if isUniqueViolation(err) {
		return ErrTrialSceneTaken
	}
	return err
}

// ErrTrialSceneTaken: another code holds the scene.
var ErrTrialSceneTaken = errors.New("the scene is taken")

// MaxTrialScene is the highest scene any code holds (0 for none).
func (s *Store) MaxTrialScene() (int64, error) {
	var n sql.NullInt64
	err := s.write.QueryRow(`SELECT MAX(scene) FROM fleet_trial_codes`).Scan(&n)
	return n.Int64, err
}

// TrialCodes is every code, newest first.
func (s *Store) TrialCodes() ([]TrialCode, error) {
	rows, err := s.write.Query(`SELECT ` + trialCodeCols + ` FROM fleet_trial_codes ORDER BY created_at DESC, id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TrialCode{}
	for rows.Next() {
		c, err := scanTrialCode(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}

// TrialCode is one code by id, nil when there is none.
func (s *Store) TrialCode(id string) (*TrialCode, error) {
	return s.trialCodeWhere(`id = ?`, id)
}

// TrialCodeByScene is the code of scene, nil when there is none.
func (s *Store) TrialCodeByScene(scene int64) (*TrialCode, error) {
	return s.trialCodeWhere(`scene = ?`, scene)
}

func (s *Store) trialCodeWhere(where string, arg any) (*TrialCode, error) {
	c, err := scanTrialCode(s.write.QueryRow(`SELECT `+trialCodeCols+` FROM fleet_trial_codes WHERE `+where, arg))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return c, err
}

// SetTrialCodeQR records the code WeChat drew for c.
func (s *Store) SetTrialCodeQR(id, url, ticket string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trial_codes SET qr_url = ?, ticket = ?, updated_at = ? WHERE id = ?`,
		url, ticket, now.Unix(), id)
	return err
}

// SetTrialCodeState moves code id to state (why: a pause's reason); false
// when it was in that state already or there is no such code.
func (s *Store) SetTrialCodeState(id, state, why string, now time.Time) (bool, error) {
	switch state {
	case TrialCodeLive, TrialCodeStopped, TrialCodePaused:
	default:
		return false, fmt.Errorf("no trial code state %q", state)
	}
	res, err := s.write.Exec(`UPDATE fleet_trial_codes SET state = ?, paused_why = ?, updated_at = ? WHERE id = ? AND state <> ?`,
		state, why, now.Unix(), id, state)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// AddTrialScan records one scan.
func (s *Store) AddTrialScan(sc TrialScan) error {
	_, err := s.write.Exec(`INSERT INTO fleet_trial_scans (id, code_id, openid, event, outcome, at) VALUES (?, ?, ?, ?, ?, ?)`,
		sc.ID, sc.CodeID, sc.OpenID, sc.Event, sc.Outcome, sc.At.Unix())
	return err
}

// TrialScansSince is how many times openid scanned code since t.
func (s *Store) TrialScansSince(codeID, openid string, since time.Time) (int, error) {
	var n int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM fleet_trial_scans WHERE code_id = ? AND openid = ? AND at >= ?`,
		codeID, openid, since.Unix()).Scan(&n)
	return n, err
}

// TrialScanCounts is code's funnel head: the WeChats that scanned it, and
// those that followed the account by scanning it.
func (s *Store) TrialScanCounts(codeID string, since time.Time) (scans, follows int, err error) {
	err = s.write.QueryRow(`SELECT COUNT(DISTINCT openid) FROM fleet_trial_scans WHERE code_id = ? AND at >= ?`,
		codeID, since.Unix()).Scan(&scans)
	if err != nil {
		return 0, 0, err
	}
	err = s.write.QueryRow(`SELECT COUNT(DISTINCT openid) FROM fleet_trial_scans WHERE code_id = ? AND event = 'subscribe' AND at >= ?`,
		codeID, since.Unix()).Scan(&follows)
	return scans, follows, err
}

const trialGrantCols = `who, code_id, principal, openid, state, lang, scanned_at, granted_at, first_at`

func scanTrialGrant(row interface{ Scan(...any) error }) (*TrialGrant, error) {
	var g TrialGrant
	var sa, ga, fa int64
	if err := row.Scan(&g.Who, &g.CodeID, &g.Principal, &g.OpenID, &g.State, &g.Lang, &sa, &ga, &fa); err != nil {
		return nil, err
	}
	g.ScannedAt, g.GrantedAt, g.FirstAt = unixOrZero(sa), unixOrZero(ga), unixOrZero(fa)
	return &g, nil
}

// TrialGrantOf is who's grant, nil when they have none.
func (s *Store) TrialGrantOf(who string) (*TrialGrant, error) {
	g, err := scanTrialGrant(s.write.QueryRow(`SELECT `+trialGrantCols+` FROM fleet_trial_grants WHERE who = ?`, who))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return g, err
}

// ClaimTrialGrant records g for its WeChat: false when that WeChat has one
// already (from any code); ErrTrialCodeFull when the code has given cap (> 0)
// already — counted in the same transaction.
func (s *Store) ClaimTrialGrant(g TrialGrant, cap int) (bool, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var had int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_trial_grants WHERE who = ?`, g.Who).Scan(&had); err != nil {
		return false, err
	}
	if had > 0 {
		return false, nil
	}
	if cap > 0 {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_trial_grants WHERE code_id = ?`, g.CodeID).Scan(&n); err != nil {
			return false, err
		}
		if n >= cap {
			return false, ErrTrialCodeFull
		}
	}
	_, err = tx.Exec(`INSERT INTO fleet_trial_grants (`+trialGrantCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)`,
		g.Who, g.CodeID, g.Principal, g.OpenID, g.State, g.Lang, g.ScannedAt.Unix(), unixOf(g.GrantedAt))
	if isUniqueViolation(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// SetTrialGrant moves who's grant to state for principal (granted: granted_at
// now). from is the state it must be in ("" = any): false when it was not.
func (s *Store) SetTrialGrant(who, from, state, principal string, now time.Time) (bool, error) {
	q := `UPDATE fleet_trial_grants SET state = ?, principal = ?, granted_at = ? WHERE who = ?`
	args := []any{state, principal, 0, who}
	if state == GrantGranted {
		args[2] = now.Unix()
	}
	if from != "" {
		q += ` AND state = ?`
		args = append(args, from)
	}
	res, err := s.write.Exec(q, args...)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// QueuedTrialGrants is every queued grant, first scanned first.
func (s *Store) QueuedTrialGrants() ([]TrialGrant, error) {
	return s.trialGrants(`state = ? ORDER BY scanned_at, who`, GrantQueued)
}

// TrialGrantsOfCode is every grant code gave, newest first.
func (s *Store) TrialGrantsOfCode(codeID string) ([]TrialGrant, error) {
	return s.trialGrants(`code_id = ? ORDER BY scanned_at DESC, who`, codeID)
}

// TrialGrantOfPrincipal is the grant that let principal in, nil for none.
func (s *Store) TrialGrantOfPrincipal(principal string) (*TrialGrant, error) {
	gs, err := s.trialGrants(`principal = ? ORDER BY scanned_at DESC LIMIT 1`, principal)
	if err != nil || len(gs) == 0 {
		return nil, err
	}
	return &gs[0], nil
}

func (s *Store) trialGrants(where string, args ...any) ([]TrialGrant, error) {
	rows, err := s.write.Query(`SELECT `+trialGrantCols+` FROM fleet_trial_grants WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TrialGrant{}
	for rows.Next() {
		g, err := scanTrialGrant(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *g)
	}
	return out, rows.Err()
}

// TrialGrantedSince is how many trials were given since t: by code ("" =
// every code).
func (s *Store) TrialGrantedSince(codeID string, since time.Time) (int, error) {
	q := `SELECT COUNT(*) FROM fleet_trial_grants WHERE state = ? AND granted_at >= ?`
	args := []any{GrantGranted, since.Unix()}
	if codeID != "" {
		q += ` AND code_id = ?`
		args = append(args, codeID)
	}
	var n int
	err := s.write.QueryRow(q, args...).Scan(&n)
	return n, err
}

// MarkTrialFirstLine records principal's first line in the chat, once: true
// when this call recorded it.
func (s *Store) MarkTrialFirstLine(principal string, now time.Time) (bool, error) {
	if principal == "" {
		return false, nil
	}
	res, err := s.write.Exec(`UPDATE fleet_trial_grants SET first_at = ? WHERE principal = ? AND state = ? AND first_at = 0`,
		now.Unix(), principal, GrantGranted)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// TrialGrantByOpenID is the grant a scan by openid made, nil for none.
func (s *Store) TrialGrantByOpenID(openid string) (*TrialGrant, error) {
	gs, err := s.trialGrants(`openid = ? ORDER BY scanned_at DESC LIMIT 1`, openid)
	if err != nil || len(gs) == 0 {
		return nil, err
	}
	return &gs[0], nil
}

// TrialScanOutcomesSince is how many WeChats a scan was answered outcome
// since t (the emergency brake's 「期间 N 人看到暂停页」, WACK C5).
func (s *Store) TrialScanOutcomesSince(outcome string, since time.Time) (int, error) {
	var n int
	err := s.read.QueryRow(`SELECT COUNT(DISTINCT openid) FROM fleet_trial_scans WHERE outcome = ? AND at >= ?`,
		outcome, since.Unix()).Scan(&n)
	return n, err
}
