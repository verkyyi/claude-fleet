package store

import (
	"database/sql"
	"errors"
	"time"

	"github.com/verkyyi/ccquota/internal/sessions"
)

// ResolveFingerprint maps a fingerprinted account key onto a real account uuid
// when the two are provably the same subscription.
//
// A fingerprint is a guess at identity made from a schedule. A machine that is
// logged in reports its account's uuid AND, through its sessions, that same
// account's reset schedule — so the guess and the fact describe one thing.
// Nothing joined them, and the result was a phantom standing next to the real
// account: on this hub, one subscription appeared three times, twice as
// win_… and once as itself, each with its own slice of the usage.
//
// The join is the seven-day reset phase, the same value the fingerprint is
// built from: if a known account's latest reading fingerprints to this key,
// they are the same subscription.
//
// It matches against EVERY account, including other fingerprints — not only
// accounts known by uuid. A subscription that has never been seen logged in
// exists on this hub only as a fingerprint, so restricting the match to real
// uuids leaves it unable to recognise itself: the georgetown subscription here
// had no uuid, and every change to the fingerprint's own definition minted it a
// fresh identity beside the old one. A real uuid still wins when one matches,
// and otherwise the earliest-seen account does, so repeated resolution
// converges rather than ping-ponging between two equal candidates.
//
// Returns key unchanged when nothing matches — an unmatched fingerprint is a
// subscription this hub has genuinely not seen before, which is exactly the
// case fingerprinting exists for.
func (s *Store) ResolveFingerprint(key string) (string, error) {
	if !sessions.IsFingerprint(key) {
		return key, nil
	}
	rows, err := s.db.Query(`
		SELECT a.account_uuid, a.first_seen, (
		  SELECT seven_day_resets_at FROM limit_snapshots l
		   WHERE l.account_uuid = a.account_uuid AND l.seven_day_resets_at IS NOT NULL
		   ORDER BY l.observed_at DESC LIMIT 1)
		FROM accounts a`)
	if err != nil {
		return "", err
	}
	defer rows.Close()

	best, bestFirst := "", ""
	for rows.Next() {
		var uuid, first string
		var reset sql.NullString
		if err := rows.Scan(&uuid, &first, &reset); err != nil {
			return "", err
		}
		if uuid == key || !reset.Valid {
			continue
		}
		t, err := time.Parse(rfc, reset.String)
		if err != nil || sessions.FingerprintFor(&t) != key {
			continue
		}
		switch {
		case best == "":
			best, bestFirst = uuid, first
		case !sessions.IsFingerprint(uuid) && sessions.IsFingerprint(best):
			best, bestFirst = uuid, first
		case sessions.IsFingerprint(uuid) == sessions.IsFingerprint(best) && first < bestFirst:
			best, bestFirst = uuid, first
		}
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	if best != "" {
		return best, nil
	}
	return key, nil
}

// MergeAccount folds src into dst: every event, snapshot and endpoint-account
// row moves, and the src account row is deleted.
//
// For repairing a database that already accumulated phantoms. Going forward
// ResolveFingerprint stops them being created, but the split usage is already
// stored and nothing else will ever reunite it.
//
// Events are moved with INSERT OR IGNORE semantics via UPDATE OR IGNORE: the
// dedup index is (account_uuid, message_uuid), so a turn already present under
// dst would collide. Those rows are then deleted rather than left behind
// pointing at an account that no longer exists.
func (s *Store) MergeAccount(src, dst string) (moved int64, err error) {
	if src == dst || src == "" || dst == "" {
		return 0, errors.New("merge needs two different accounts")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	res, err := tx.Exec(`UPDATE OR IGNORE usage_events SET account_uuid = ? WHERE account_uuid = ?`, dst, src)
	if err != nil {
		return 0, err
	}
	moved, _ = res.RowsAffected()
	if _, err := tx.Exec(`DELETE FROM usage_events WHERE account_uuid = ?`, src); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`UPDATE limit_snapshots SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`UPDATE OR IGNORE endpoint_accounts SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM endpoint_accounts WHERE account_uuid = ?`, src); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`UPDATE endpoints SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM accounts WHERE account_uuid = ?`, src); err != nil {
		return 0, err
	}
	return moved, tx.Commit()
}

// DuplicateAccountsBySchedule groups accounts that share a seven-day reset
// phase, returning src -> dst merges. A real uuid always wins over a
// fingerprint, and between two fingerprints the older one wins, so repeated
// runs converge instead of ping-ponging.
func (s *Store) DuplicateAccountsBySchedule() (map[string]string, error) {
	type acct struct {
		uuid  string
		first string
		reset time.Time
	}
	rows, err := s.db.Query(`
		SELECT a.account_uuid, a.first_seen, (
		  SELECT seven_day_resets_at FROM limit_snapshots l
		   WHERE l.account_uuid = a.account_uuid AND l.seven_day_resets_at IS NOT NULL
		   ORDER BY l.observed_at DESC LIMIT 1)
		FROM accounts a`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	byKey := map[string][]acct{}
	for rows.Next() {
		var a acct
		var reset sql.NullString
		if err := rows.Scan(&a.uuid, &a.first, &reset); err != nil {
			return nil, err
		}
		if !reset.Valid {
			continue
		}
		t, err := time.Parse(rfc, reset.String)
		if err != nil {
			continue
		}
		a.reset = t
		k := sessions.FingerprintFor(&t)
		byKey[k] = append(byKey[k], a)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := map[string]string{}
	for _, group := range byKey {
		if len(group) < 2 {
			continue
		}
		winner := group[0]
		for _, a := range group[1:] {
			switch {
			case !sessions.IsFingerprint(a.uuid) && sessions.IsFingerprint(winner.uuid):
				winner = a // a real account always beats a fingerprint
			case sessions.IsFingerprint(a.uuid) == sessions.IsFingerprint(winner.uuid) &&
				a.first < winner.first:
				winner = a // otherwise the one seen first
			}
		}
		for _, a := range group {
			if a.uuid != winner.uuid {
				out[a.uuid] = winner.uuid
			}
		}
	}
	return out, nil
}
