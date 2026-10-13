package store

import (
	"errors"
	"fmt"
	"time"
)

// A service run's environment (claude-fleet#4005, the SPACE EPIC C3).
//
// svc_templates is what a principal registered: an agent.md by its sha256,
// immutable — a run names (template, digest) and only a registered digest is
// ever started (POST /v1/svc/templates, claude-fleet#4032). svc_run_jobs is one row
// per run attempt that got a Job: the sha256 of the Job's one-time key (the
// key itself lives only in the Job's Secret), the cluster, the model pass it
// fetched (minted once, at its first and only spec read) and when it ended —
// a key whose row has ended opens nothing.
const svcEnvSchema = `
CREATE TABLE IF NOT EXISTS svc_templates (
  principal TEXT NOT NULL,
  digest    TEXT NOT NULL,
  name      TEXT NOT NULL,
  agent_md  TEXT NOT NULL,
  created   TEXT NOT NULL,
  PRIMARY KEY (principal, digest)
);
CREATE TABLE IF NOT EXISTS svc_run_jobs (
  run_id   INTEGER NOT NULL,
  attempt  INTEGER NOT NULL,
  key_sha  TEXT NOT NULL,
  cluster  TEXT NOT NULL DEFAULT '',
  pass_id  TEXT NOT NULL DEFAULT '',
  created  TEXT NOT NULL,
  fetched  TEXT NOT NULL DEFAULT '',
  ended    TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (run_id, attempt)
);
CREATE UNIQUE INDEX IF NOT EXISTS svc_run_jobs_key ON svc_run_jobs(key_sha);`

// SvcTemplate is one registered agent.md.
type SvcTemplate struct {
	Principal, Digest, Name, AgentMD string
	Created                          time.Time
}

// SvcRunJob is one run attempt's environment.
type SvcRunJob struct {
	RunID   int64
	Attempt int
	KeySHA  string
	Cluster string
	PassID  string
	Created time.Time
	Fetched *time.Time
	Ended   *time.Time
}

func (s *Store) ensureSvcEnvs() error {
	if _, err := s.write.Exec(s.d.ddl(svcEnvSchema)); err != nil {
		return fmt.Errorf("create svc environment tables: %w", err)
	}
	return nil
}

// PutSvcTemplate registers t; a digest already registered for the principal
// stays as it was (a digest is its content).
func (s *Store) PutSvcTemplate(t SvcTemplate, now time.Time) error {
	if t.Principal == "" || t.Digest == "" || t.Name == "" || t.AgentMD == "" {
		return errors.New("a template needs a principal, a digest, a name and its agent.md")
	}
	_, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO svc_templates (principal, digest, name, agent_md, created)
		VALUES (?, ?, ?, ?, ?)`), t.Principal, t.Digest, t.Name, t.AgentMD, svcTime(now))
	return err
}

// SvcTemplateOf is principal's template of that digest; sql.ErrNoRows when it
// never registered one.
func (s *Store) SvcTemplateOf(principal, digest string) (SvcTemplate, error) {
	var t SvcTemplate
	var created string
	err := s.write.QueryRow(`SELECT principal, digest, name, agent_md, created FROM svc_templates
		WHERE principal = ? AND digest = ?`, principal, digest).Scan(&t.Principal, &t.Digest, &t.Name, &t.AgentMD, &created)
	if c := svcTimeRead(created); c != nil {
		t.Created = *c
	}
	return t, err
}

const svcRunJobCols = `run_id, attempt, key_sha, cluster, pass_id, created, fetched, ended`

func scanSvcRunJob(sc interface{ Scan(...any) error }) (SvcRunJob, error) {
	var j SvcRunJob
	var created, fetched, ended string
	if err := sc.Scan(&j.RunID, &j.Attempt, &j.KeySHA, &j.Cluster, &j.PassID, &created, &fetched, &ended); err != nil {
		return j, err
	}
	if c := svcTimeRead(created); c != nil {
		j.Created = *c
	}
	j.Fetched, j.Ended = svcTimeRead(fetched), svcTimeRead(ended)
	return j, nil
}

// AddSvcRunJob records an attempt's environment before its Job is asked for.
func (s *Store) AddSvcRunJob(j SvcRunJob, now time.Time) error {
	if j.RunID == 0 || j.Attempt < 1 || j.KeySHA == "" {
		return errors.New("a run's environment needs its run, its attempt and its key's hash")
	}
	_, err := s.write.Exec(`INSERT INTO svc_run_jobs (run_id, attempt, key_sha, cluster, created) VALUES (?, ?, ?, ?, ?)`,
		j.RunID, j.Attempt, j.KeySHA, j.Cluster, svcTime(now))
	return err
}

// SvcRunJobByKey is the environment a key opens; sql.ErrNoRows for none.
func (s *Store) SvcRunJobByKey(keySHA string) (SvcRunJob, error) {
	return scanSvcRunJob(s.write.QueryRow(`SELECT `+svcRunJobCols+` FROM svc_run_jobs WHERE key_sha = ?`, keySHA))
}

// SvcRunJobOf is run id's attempt's environment; sql.ErrNoRows for none.
func (s *Store) SvcRunJobOf(runID int64, attempt int) (SvcRunJob, error) {
	return scanSvcRunJob(s.write.QueryRow(`SELECT `+svcRunJobCols+` FROM svc_run_jobs WHERE run_id = ? AND attempt = ?`,
		runID, attempt))
}

// FetchSvcRunJob marks the attempt's one spec read and the pass it was handed;
// false when it was read already or has ended.
func (s *Store) FetchSvcRunJob(runID int64, attempt int, passID string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE svc_run_jobs SET fetched = ?, pass_id = ?
		WHERE run_id = ? AND attempt = ? AND fetched = '' AND ended = ''`, svcTime(now), passID, runID, attempt)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// EndSvcRunJob closes the attempt's environment once; false when it had ended.
func (s *Store) EndSvcRunJob(runID int64, attempt int, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE svc_run_jobs SET ended = ? WHERE run_id = ? AND attempt = ? AND ended = ''`,
		svcTime(now), runID, attempt)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// SvcTemplates is every template principal registered, newest first — the
// list carries no agent.md (AgentMD is left empty).
func (s *Store) SvcTemplates(principal string) ([]SvcTemplate, error) {
	rows, err := s.write.Query(`SELECT principal, digest, name, created FROM svc_templates
		WHERE principal = ? ORDER BY created DESC, digest`, principal)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcTemplate
	for rows.Next() {
		var t SvcTemplate
		var created string
		if err := rows.Scan(&t.Principal, &t.Digest, &t.Name, &created); err != nil {
			return nil, err
		}
		if c := svcTimeRead(created); c != nil {
			t.Created = *c
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
