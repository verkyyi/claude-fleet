package store

import (
	"errors"
	"strings"
	"time"
)

var ErrCredPolicyChanged = errors.New("subscription permissions changed; review again")

func policySettings(m map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range m {
		if strings.HasPrefix(k, "fleet.cred_allow.") || k == "fleet.cred_policy.mode" {
			out[k] = v
		}
	}
	return out
}

// ActivateCredPolicy compares the reviewed policy and commits the grants, mode
// and audit in one transaction. Readers see either the old or the new policy.
func (s *Store) ActivateCredPolicy(before map[string]string, grants []string, actor string, at time.Time) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT key,value FROM fleet_settings`)
	if err != nil {
		return err
	}
	current := map[string]string{}
	for rows.Next() {
		var k, v string
		if err = rows.Scan(&k, &v); err != nil {
			rows.Close()
			return err
		}
		current[k] = v
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	a, b := policySettings(before), policySettings(current)
	if len(a) != len(b) {
		return ErrCredPolicyChanged
	}
	for k, v := range a {
		if b[k] != v {
			return ErrCredPolicyChanged
		}
	}
	for _, k := range grants {
		if _, err = tx.Exec(`INSERT INTO fleet_settings (key,value,updated) VALUES (?, ?, ?) ON CONFLICT(key) DO NOTHING`, k, `"*"`, at.UTC().Format(rfc)); err != nil {
			return err
		}
	}
	if _, err = tx.Exec(`UPDATE fleet_settings SET value = 'strict', updated = ? WHERE key = 'fleet.cred_policy.mode'`, at.UTC().Format(rfc)); err != nil {
		return err
	}
	if _, err = tx.Exec(`INSERT INTO fleet_audit (actor,action,fleet_id,outcome,operation_id,created) VALUES (?, ?, '', ?, '', ?)`, actor, "cred-policy.activate", "strict; explicit grants: "+strings.Join(grants, ","), at.UTC().Format(rfc)); err != nil {
		return err
	}
	if _, err = tx.Exec(`INSERT INTO fleet_cred_audit (at,action,detail) VALUES (?, ?, ?)`, at.UTC().Format(rfc), CredPolicy, "activate strict; retained: "+strings.Join(grants, ",")+" · by "+actor); err != nil {
		return err
	}
	return tx.Commit()
}
