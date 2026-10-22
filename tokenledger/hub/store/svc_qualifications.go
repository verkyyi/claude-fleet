package store

// Only the authenticated admin API writes policies. Evidence is keyed by the
// policy hash so changing the evaluator, grader or cases revokes old approvals.
const svcQualificationSchema = `
CREATE TABLE IF NOT EXISTS svc_eval_policies (
 principal TEXT PRIMARY KEY,
 policy_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS svc_template_qualifications (
 principal TEXT NOT NULL,
 engine TEXT NOT NULL,
 digest TEXT NOT NULL,
 policy_hash TEXT NOT NULL,
 evidence_json TEXT NOT NULL,
 PRIMARY KEY (principal, engine, digest, policy_hash)
);`

func (s *Store) PutSvcEvalPolicy(principal, policy string) error {
	_, err := s.write.Exec(`INSERT INTO svc_eval_policies (principal, policy_json) VALUES (?, ?)
 ON CONFLICT(principal) DO UPDATE SET policy_json = excluded.policy_json`, principal, policy)
	return err
}

func (s *Store) SvcEvalPolicy(principal string) (string, error) {
	var v string
	err := s.write.QueryRow(`SELECT policy_json FROM svc_eval_policies WHERE principal = ?`, principal).Scan(&v)
	return v, err
}

func (s *Store) PutSvcQualification(principal, engine, digest, policyHash, evidence string) error {
	_, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO svc_template_qualifications
 (principal, engine, digest, policy_hash, evidence_json) VALUES (?, ?, ?, ?, ?)`), principal, engine, digest, policyHash, evidence)
	return err
}

func (s *Store) SvcQualification(principal, engine, digest, policyHash string) (string, error) {
	var v string
	err := s.write.QueryRow(`SELECT evidence_json FROM svc_template_qualifications
 WHERE principal = ? AND engine = ? AND digest = ? AND policy_hash = ?`, principal, engine, digest, policyHash).Scan(&v)
	return v, err
}
