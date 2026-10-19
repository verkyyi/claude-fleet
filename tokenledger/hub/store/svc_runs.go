package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Service runs (claude-fleet#4004, the SPACE EPIC C2): ONE row per run a
// service principal dispatched — R<id> — from the POST that asked for it to the
// callback that told it how it ended. It is not a fleet_tasks record: that one
// is a person's session; a run is a back end's one-shot job for one of ITS
// users (tenant, subject), who has no account here.
//
// deadline_at is fixed at the FIRST start (started_at + deadline_s) and kept
// when an infra_error puts the run back in the queue for its one retry
// (claude-fleet#4007, RequeueSvcRun) — the retry lives inside what is left.
//
// States: queued → running → succeeded | failed | cancelled | expired. A
// terminal state is written once (every finish is guarded on a live state), so
// a runner's late word after a cancel or a timeout changes nothing.
//
// Times are fixed-width UTC text (svcTS) so a string comparison is a time
// comparison on both dialects.
//
// svc_callbacks is a principal's callback registration: the URL prefix every
// run's callback_url must sit under, and the HMAC secret its callbacks are
// signed with (the hub must hold that one in the clear to sign).
const svcRunsSchema = `
CREATE TABLE IF NOT EXISTS svc_runs (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  principal         TEXT NOT NULL,
  tenant            TEXT NOT NULL,
  subject           TEXT NOT NULL DEFAULT '',
  template          TEXT NOT NULL,
  digest            TEXT NOT NULL,
  inputs_json       TEXT NOT NULL DEFAULT '{}',
  idempotency_key   TEXT NOT NULL,
  request_sha       TEXT NOT NULL DEFAULT '',
  state             TEXT NOT NULL DEFAULT 'queued',
  error_code        TEXT NOT NULL DEFAULT '',
  attempt           INTEGER NOT NULL DEFAULT 0,
  deadline_s        INTEGER NOT NULL DEFAULT 900,
  queued_at         TEXT NOT NULL,
  started_at        TEXT NOT NULL DEFAULT '',
  finished_at       TEXT NOT NULL DEFAULT '',
  usage_json        TEXT NOT NULL DEFAULT '',
  result_json       TEXT NOT NULL DEFAULT '',
  callback_url      TEXT NOT NULL DEFAULT '',
  callback_state    TEXT NOT NULL DEFAULT '',
  callback_attempts INTEGER NOT NULL DEFAULT 0,
  callback_next     TEXT NOT NULL DEFAULT '',
  callback_last     TEXT NOT NULL DEFAULT '',
  deadline_at       TEXT NOT NULL DEFAULT '',
  UNIQUE (principal, idempotency_key)
);
CREATE INDEX IF NOT EXISTS svc_runs_state ON svc_runs(state, queued_at);
CREATE INDEX IF NOT EXISTS svc_runs_tenant ON svc_runs(principal, tenant, id);
CREATE INDEX IF NOT EXISTS svc_runs_callback ON svc_runs(callback_state, callback_next);
CREATE TABLE IF NOT EXISTS svc_callbacks (
  principal  TEXT PRIMARY KEY,
  url_prefix TEXT NOT NULL,
  secret     TEXT NOT NULL,
  updated    TEXT NOT NULL
);`

// Run states.
const (
	SvcRunQueued    = "queued"
	SvcRunRunning   = "running"
	SvcRunSucceeded = "succeeded"
	SvcRunFailed    = "failed"
	SvcRunCancelled = "cancelled"
	SvcRunExpired   = "expired"
)

// SvcRunTerminal is whether state is one a run ends in.
func SvcRunTerminal(state string) bool {
	switch state {
	case SvcRunSucceeded, SvcRunFailed, SvcRunCancelled, SvcRunExpired:
		return true
	}
	return false
}

// Callback states: "" = no callback_url, nothing to send.
const (
	SvcCallbackPending   = "pending"
	SvcCallbackDelivered = "delivered"
	SvcCallbackFailed    = "failed"
)

// svcTS is the fixed-width time every svc_runs column is written in.
const svcTS = "2006-01-02T15:04:05.000Z"

func svcTime(t time.Time) string { return t.UTC().Format(svcTS) }

func svcTimeRead(v string) *time.Time {
	if v == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, v)
	if err != nil {
		return nil
	}
	return &t
}

// SvcRun is one run.
type SvcRun struct {
	ID               int64      `json:"-"`
	Principal        string     `json:"principal"`
	Tenant           string     `json:"tenant"`
	Subject          string     `json:"subject"`
	Template         string     `json:"template"`
	Digest           string     `json:"template_digest"`
	InputsJSON       string     `json:"-"`
	IdempotencyKey   string     `json:"idempotency_key"`
	RequestSHA       string     `json:"-"`
	State            string     `json:"state"`
	ErrorCode        string     `json:"error_code,omitempty"`
	Attempt          int        `json:"attempt"`
	DeadlineS        int        `json:"deadline_s"`
	QueuedAt         time.Time  `json:"queued_at"`
	StartedAt        *time.Time `json:"started_at,omitempty"`
	FinishedAt       *time.Time `json:"finished_at,omitempty"`
	UsageJSON        string     `json:"-"`
	ResultJSON       string     `json:"-"`
	CallbackURL      string     `json:"callback_url,omitempty"`
	CallbackState    string     `json:"callback_state,omitempty"`
	CallbackAttempts int        `json:"callback_attempts"`
	CallbackNext     *time.Time `json:"-"`
	CallbackLast     string     `json:"-"`
	DeadlineAt       *time.Time `json:"deadline_at,omitempty"`
}

// SvcRunRef is a run's number as SPACE writes it: R42.
func SvcRunRef(id int64) string { return "R" + strconv.FormatInt(id, 10) }

// ParseSvcRunRef reads R42 back; 0 when it is not one.
func ParseSvcRunRef(ref string) int64 {
	if !strings.HasPrefix(ref, "R") {
		return 0
	}
	n, err := strconv.ParseInt(ref[1:], 10, 64)
	if err != nil || n <= 0 || strconv.FormatInt(n, 10) != ref[1:] {
		return 0
	}
	return n
}

// Ref is the run's R<id>.
func (r SvcRun) Ref() string { return SvcRunRef(r.ID) }

const svcRunCols = `id, principal, tenant, subject, template, digest, inputs_json, idempotency_key, request_sha,
	state, error_code, attempt, deadline_s, queued_at, started_at, finished_at, usage_json, result_json,
	callback_url, callback_state, callback_attempts, callback_next, callback_last, deadline_at`

func scanSvcRun(sc interface{ Scan(...any) error }) (SvcRun, error) {
	var r SvcRun
	var queued, started, finished, next, deadline string
	if err := sc.Scan(&r.ID, &r.Principal, &r.Tenant, &r.Subject, &r.Template, &r.Digest, &r.InputsJSON,
		&r.IdempotencyKey, &r.RequestSHA, &r.State, &r.ErrorCode, &r.Attempt, &r.DeadlineS, &queued, &started,
		&finished, &r.UsageJSON, &r.ResultJSON, &r.CallbackURL, &r.CallbackState, &r.CallbackAttempts, &next,
		&r.CallbackLast, &deadline); err != nil {
		return r, err
	}
	if t := svcTimeRead(queued); t != nil {
		r.QueuedAt = *t
	}
	r.StartedAt, r.FinishedAt, r.CallbackNext = svcTimeRead(started), svcTimeRead(finished), svcTimeRead(next)
	r.DeadlineAt = svcTimeRead(deadline)
	return r, nil
}

func (s *Store) ensureSvcRuns() error {
	if _, err := s.write.Exec(s.d.ddl(svcRunsSchema)); err != nil {
		return fmt.Errorf("create svc_runs tables: %w", err)
	}
	// claude-fleet#4007: a database made by #4004's first version.
	return s.addColumn("svc_runs", "deadline_at", "TEXT NOT NULL DEFAULT ''")
}

// CreateSvcRun queues r unless its principal already used its idempotency
// key: then the first run comes back and created is false — never a second.
func (s *Store) CreateSvcRun(r SvcRun, now time.Time) (run SvcRun, created bool, err error) {
	if r.Principal == "" || r.IdempotencyKey == "" || r.Tenant == "" || r.Template == "" {
		return SvcRun{}, false, errors.New("a run needs a principal, an idempotency key, a tenant and a template")
	}
	if r.DeadlineS <= 0 {
		r.DeadlineS = 900
	}
	res, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO svc_runs (principal, tenant, subject, template, digest,
		inputs_json, idempotency_key, request_sha, state, deadline_s, queued_at, callback_url)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?)`),
		r.Principal, r.Tenant, r.Subject, r.Template, r.Digest, r.InputsJSON, r.IdempotencyKey, r.RequestSHA,
		r.DeadlineS, svcTime(now), r.CallbackURL)
	if err != nil {
		return SvcRun{}, false, err
	}
	n, _ := res.RowsAffected()
	run, err = s.svcRunBy(`principal = ? AND idempotency_key = ?`, r.Principal, r.IdempotencyKey)
	return run, n == 1, err
}

func (s *Store) svcRunBy(where string, args ...any) (SvcRun, error) {
	return scanSvcRun(s.write.QueryRow(`SELECT `+svcRunCols+` FROM svc_runs WHERE `+where, args...))
}

// SvcRun reads one run; sql.ErrNoRows when there is none.
func (s *Store) SvcRun(id int64) (SvcRun, error) { return s.svcRunBy(`id = ?`, id) }

// SvcRunFilter narrows SvcRuns; an empty field does not.
type SvcRunFilter struct {
	Principal, Tenant, State string
	Since                    time.Time
	Limit                    int
}

// SvcRuns lists runs newest first.
func (s *Store) SvcRuns(f SvcRunFilter) ([]SvcRun, error) {
	where, args := []string{"1 = 1"}, []any{}
	if f.Principal != "" {
		where, args = append(where, "principal = ?"), append(args, f.Principal)
	}
	if f.Tenant != "" {
		where, args = append(where, "tenant = ?"), append(args, f.Tenant)
	}
	if f.State != "" {
		where, args = append(where, "state = ?"), append(args, f.State)
	}
	if !f.Since.IsZero() {
		where, args = append(where, "queued_at >= ?"), append(args, svcTime(f.Since))
	}
	if f.Limit <= 0 || f.Limit > 500 {
		f.Limit = 100
	}
	rows, err := s.write.Query(`SELECT `+svcRunCols+` FROM svc_runs WHERE `+strings.Join(where, " AND ")+
		` ORDER BY id DESC LIMIT `+strconv.Itoa(f.Limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcRun
	for rows.Next() {
		r, err := scanSvcRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ClaimSvcRuns moves queued runs to running, oldest first, while fewer than
// maxRunning of principal's runs run and none of the same tenant does — one
// writer at a time, so two dispatchers never pass either limit. It returns the
// runs it moved (attempt counted, started_at stamped, deadline_at fixed at the
// first start and kept on a retry).
func (s *Store) ClaimSvcRuns(principal string, maxRunning int, now time.Time) ([]SvcRun, error) {
	return s.ClaimSvcRunsUpTo(principal, maxRunning, -1, now)
}

// ClaimSvcRunsUpTo is ClaimSvcRuns moving at most maxNew runs (-1: no bound) —
// a runner with a fixed number of free slots (claude-fleet#4086) claims no
// more than it can start; the rest stay queued, oldest first.
func (s *Store) ClaimSvcRunsUpTo(principal string, maxRunning, maxNew int, now time.Time) ([]SvcRun, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "svc_runs"); err != nil {
		return nil, err
	}
	rows, err := tx.Query(`SELECT `+svcRunCols+` FROM svc_runs WHERE principal = ? AND state IN ('queued', 'running')
		ORDER BY queued_at, id`+s.d.forUpdate(), principal)
	if err != nil {
		return nil, err
	}
	var live []SvcRun
	for rows.Next() {
		r, err := scanSvcRun(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		live = append(live, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	running, busy := 0, map[string]bool{}
	for _, r := range live {
		if r.State == SvcRunRunning {
			running++
			busy[r.Tenant] = true
		}
	}
	var out []SvcRun
	for _, r := range live {
		if running >= maxRunning || (maxNew >= 0 && len(out) >= maxNew) {
			break
		}
		if r.State != SvcRunQueued || busy[r.Tenant] {
			continue
		}
		if r.DeadlineAt == nil {
			d := now.UTC().Add(time.Duration(r.DeadlineS) * time.Second)
			r.DeadlineAt = &d
		}
		if _, err := tx.Exec(`UPDATE svc_runs SET state = 'running', started_at = ?, attempt = attempt + 1,
			deadline_at = ? WHERE id = ? AND state = 'queued'`, svcTime(now), svcTime(*r.DeadlineAt), r.ID); err != nil {
			return nil, err
		}
		r.State, r.Attempt = SvcRunRunning, r.Attempt+1
		t := now.UTC()
		r.StartedAt = &t
		busy[r.Tenant] = true
		running++
		out = append(out, r)
	}
	return out, tx.Commit()
}

// SvcRunsIn lists every run in state (queued / running: the sweep's input).
func (s *Store) SvcRunsIn(state string) ([]SvcRun, error) {
	rows, err := s.write.Query(`SELECT `+svcRunCols+` FROM svc_runs WHERE state = ? ORDER BY id`, state)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcRun
	for rows.Next() {
		r, err := scanSvcRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// RequeueSvcRun puts a running run that failed for a back-end reason back in
// the queue for its ONE retry (claude-fleet#4007): only from its first attempt,
// only while at least minLeft of its deadline remains. requeued is false when
// any of that does not hold — then the caller ends it as it would have.
// queued_at is kept, so the retry is first in its principal's line.
func (s *Store) RequeueSvcRun(id int64, now time.Time, minLeft time.Duration) (run SvcRun, requeued bool, err error) {
	res, err := s.write.Exec(`UPDATE svc_runs SET state = 'queued', started_at = '', error_code = ''
		WHERE id = ? AND state = 'running' AND attempt = 1 AND deadline_at > ?`, id, svcTime(now.Add(minLeft)))
	if err != nil {
		return SvcRun{}, false, err
	}
	n, _ := res.RowsAffected()
	run, err = s.SvcRun(id)
	return run, n == 1, err
}

// SvcRunsSince is every run that touched the window from since: still queued,
// started at or after it, or ended at or after it — the alert sweep's input.
func (s *Store) SvcRunsSince(since time.Time) ([]SvcRun, error) {
	t := svcTime(since)
	rows, err := s.write.Query(`SELECT `+svcRunCols+` FROM svc_runs WHERE state = 'queued' OR started_at >= ?
		OR finished_at >= ? ORDER BY id`, t, t)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcRun
	for rows.Next() {
		r, err := scanSvcRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// SvcRunsPrincipals is every principal with a queued run (whom to dispatch for).
func (s *Store) SvcRunsPrincipals() ([]string, error) {
	rows, err := s.write.Query(`SELECT DISTINCT principal FROM svc_runs WHERE state = 'queued' ORDER BY principal`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// SvcRunEnd is how a run ended.
type SvcRunEnd struct {
	State, ErrorCode, UsageJSON, ResultJSON string
}

// FinishSvcRun writes a terminal state once: changed is false when the run had
// already ended (a cancel beat the runner's word, a timeout beat a late
// result). A run with a callback_url gets its callback queued for now.
func (s *Store) FinishSvcRun(id int64, end SvcRunEnd, now time.Time) (run SvcRun, changed bool, err error) {
	if !SvcRunTerminal(end.State) {
		return SvcRun{}, false, fmt.Errorf("%q is not a state a run ends in", end.State)
	}
	ts := svcTime(now)
	res, err := s.write.Exec(`UPDATE svc_runs SET state = ?, error_code = ?, usage_json = ?, result_json = ?,
		finished_at = ?,
		callback_state = CASE WHEN callback_url = '' THEN '' ELSE 'pending' END,
		callback_next = CASE WHEN callback_url = '' THEN '' ELSE ? END
		WHERE id = ? AND state IN ('queued', 'running')`,
		end.State, end.ErrorCode, end.UsageJSON, end.ResultJSON, ts, ts, id)
	if err != nil {
		return SvcRun{}, false, err
	}
	n, _ := res.RowsAffected()
	run, err = s.SvcRun(id)
	return run, n == 1, err
}

// SvcCallbacksDue lists runs whose callback is pending and due at now.
func (s *Store) SvcCallbacksDue(now time.Time, limit int) ([]SvcRun, error) {
	rows, err := s.write.Query(`SELECT `+svcRunCols+` FROM svc_runs WHERE callback_state = 'pending'
		AND callback_next <= ? ORDER BY callback_next LIMIT `+strconv.Itoa(limit), svcTime(now))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcRun
	for rows.Next() {
		r, err := scanSvcRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// LeaseSvcCallback pushes a due callback's next try to until, but only if it
// is still the one r read — so of two senders exactly one sends it, and a
// sender that dies leaves it to be tried again at until.
func (s *Store) LeaseSvcCallback(r SvcRun, until time.Time) (bool, error) {
	if r.CallbackNext == nil {
		return false, nil
	}
	res, err := s.write.Exec(`UPDATE svc_runs SET callback_next = ? WHERE id = ? AND callback_state = 'pending'
		AND callback_next = ?`, svcTime(until), r.ID, svcTime(*r.CallbackNext))
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// RecordSvcCallback writes one attempt's outcome: state delivered / pending
// (next = when to try again) / failed, attempts so far, the last error.
func (s *Store) RecordSvcCallback(id int64, state string, attempts int, next *time.Time, last string) error {
	n := ""
	if next != nil {
		n = svcTime(*next)
	}
	if len(last) > 300 {
		last = last[:300]
	}
	_, err := s.write.Exec(`UPDATE svc_runs SET callback_state = ?, callback_attempts = ?, callback_next = ?,
		callback_last = ? WHERE id = ?`, state, attempts, n, last, id)
	return err
}

// SvcCallback is a principal's callback registration.
type SvcCallback struct {
	Principal string    `json:"principal"`
	URLPrefix string    `json:"url_prefix"`
	Secret    string    `json:"-"`
	Updated   time.Time `json:"updated"`
}

// ErrNoSvcCallback: the principal registered no callback prefix.
var ErrNoSvcCallback = errors.New("no callback registered for this principal")

// SvcCallbackOf reads principal's registration.
func (s *Store) SvcCallbackOf(principal string) (SvcCallback, error) {
	var c SvcCallback
	var updated string
	err := s.write.QueryRow(`SELECT principal, url_prefix, secret, updated FROM svc_callbacks WHERE principal = ?`,
		principal).Scan(&c.Principal, &c.URLPrefix, &c.Secret, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNoSvcCallback
	}
	if t := svcTimeRead(updated); t != nil {
		c.Updated = *t
	}
	return c, err
}

// SetSvcCallback stores principal's prefix and secret (replacing both).
func (s *Store) SetSvcCallback(c SvcCallback, now time.Time) error {
	_, err := s.write.Exec(s.d.insertReplace(`INSERT OR REPLACE INTO svc_callbacks (principal, url_prefix, secret, updated)
		VALUES (?, ?, ?, ?)`, "principal"), c.Principal, c.URLPrefix, c.Secret, svcTime(now))
	return err
}
