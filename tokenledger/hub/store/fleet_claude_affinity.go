package store

import (
	"fmt"
	"strings"
	"time"
)

const fleetClaudeAffinitySchema = `CREATE TABLE IF NOT EXISTS fleet_claude_affinity (
 worker_id TEXT NOT NULL,
 reference TEXT NOT NULL,
 owner TEXT NOT NULL,
 account TEXT NOT NULL,
 credential_id TEXT NOT NULL,
 account_key TEXT NOT NULL,
 ambiguous INTEGER NOT NULL DEFAULT 0,
 expires_at TEXT NOT NULL,
 PRIMARY KEY (worker_id, reference)
);`

type ClaudeAffinity struct {
	Owner, Account, CredentialID, AccountKey string
}

// RecordClaudeAffinity never reassigns a reference. A collision across account
// identities poisons it instead of letting one concurrent response win.
func (s *Store) RecordClaudeAffinity(worker string, refs []string, a ClaudeAffinity, now time.Time) error {
	refs = uniqueAffinityReferences(refs)
	if len(refs) == 0 {
		return nil
	}
	args := make([]any, 0, len(refs)*7)
	for _, ref := range refs {
		args = append(args, worker, ref, a.Owner, a.Account, a.CredentialID, a.AccountKey, now.Add(30*24*time.Hour).UTC().Format(sessRFC))
	}
	_, err := s.write.Exec(`INSERT INTO fleet_claude_affinity (worker_id,reference,owner,account,credential_id,account_key,expires_at) VALUES `+
		strings.TrimSuffix(strings.Repeat("(?,?,?,?,?,?,?),", len(refs)), ",")+` ON CONFLICT (worker_id,reference) DO UPDATE SET
 ambiguous=CASE WHEN fleet_claude_affinity.credential_id=excluded.credential_id AND fleet_claude_affinity.owner=excluded.owner AND fleet_claude_affinity.account_key=excluded.account_key
 THEN fleet_claude_affinity.ambiguous ELSE 1 END, expires_at=excluded.expires_at`, args...)
	// Keep expired identities as tombstones: deleting one would let a reused
	// provider reference become silently associated with a different account.
	return err
}

func (s *Store) ClaudeAffinityFor(worker string, refs []string, now time.Time) (ClaudeAffinity, error) {
	refs = uniqueAffinityReferences(refs)
	var result ClaudeAffinity
	if len(refs) == 0 {
		return result, fmt.Errorf("unknown_reference")
	}
	args := make([]any, 0, len(refs)+1)
	args = append(args, worker)
	for _, ref := range refs {
		args = append(args, ref)
	}
	rows, err := s.write.Query(`SELECT owner,account,credential_id,account_key,ambiguous,expires_at FROM fleet_claude_affinity WHERE worker_id=? AND reference IN (`+
		strings.TrimSuffix(strings.Repeat("?,", len(refs)), ",")+")", args...)
	if err != nil {
		return result, fmt.Errorf("reference_store_unavailable")
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var a ClaudeAffinity
		var ambiguous int
		var expiry string
		if err := rows.Scan(&a.Owner, &a.Account, &a.CredentialID, &a.AccountKey, &ambiguous, &expiry); err != nil {
			return result, fmt.Errorf("reference_store_unavailable")
		}
		until, err := time.Parse(time.RFC3339, expiry)
		if err != nil || !until.After(now) {
			return result, fmt.Errorf("expired_reference")
		}
		if ambiguous != 0 {
			return result, fmt.Errorf("ambiguous_reference")
		}
		if count > 0 && (a.Owner != result.Owner || a.CredentialID != result.CredentialID || a.AccountKey != result.AccountKey) {
			return result, fmt.Errorf("mixed_accounts")
		}
		result = a
		count++
	}
	if rows.Err() != nil || count != len(refs) {
		return result, fmt.Errorf("unknown_reference")
	}
	return result, nil
}
