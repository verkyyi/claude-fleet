package store

import (
	"database/sql"
	"errors"
	"fmt"
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
	rows, err := s.read.Query(`
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

// MergeAccount folds src into dst: every event, hour-row, snapshot and
// endpoint-account row moves, and the src account row is deleted.
//
// For repairing a database that already accumulated phantoms, and for adopting
// a pool of unassigned usage into the subscription it actually belongs to.
// Going forward ResolveFingerprint stops phantoms being created, but the split
// usage is already stored and nothing else will ever reunite it.
//
// Returns raw turns moved AND rollup turns folded, because the two routinely
// disagree: retention pruning deletes usage_events and never usage_hourly, so
// an account whose history is older than the window moves entirely as
// hour-rows and reports zero turns moved. Reporting only the raw count would
// make the merge that matters most look like it did nothing — the codex pool
// on this hub was 14,764 rollup turns against 1,730 surviving raw ones.
//
// Events are moved with INSERT OR IGNORE semantics via UPDATE OR IGNORE: the
// dedup index is (account_uuid, message_uuid), so a turn already present under
// dst would collide. Those rows are then deleted rather than left behind
// pointing at an account that no longer exists.
func (s *Store) MergeAccount(src, dst string) (moved, folded int64, err error) {
	if src == dst || src == "" || dst == "" {
		return 0, 0, errors.New("merge needs two different accounts")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()

	// A destination that does not exist is a typo, and merging into it would
	// move the usage somewhere nothing can ever show it again — this deletes
	// the source account row, so there would be no way back to the name.
	var known int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM accounts WHERE account_uuid = ?`, dst).Scan(&known); err != nil {
		return 0, 0, err
	}
	if known == 0 {
		return 0, 0, fmt.Errorf("no account %q on this hub to merge into", dst)
	}

	if err := tx.QueryRow(`SELECT COALESCE(SUM(events),0) FROM usage_hourly WHERE account_uuid = ?`, src).
		Scan(&folded); err != nil {
		return 0, 0, err
	}

	res, err := tx.Exec(`UPDATE OR IGNORE usage_events SET account_uuid = ? WHERE account_uuid = ?`, dst, src)
	if err != nil {
		return 0, 0, err
	}
	moved, _ = res.RowsAffected()
	if _, err := tx.Exec(`DELETE FROM usage_events WHERE account_uuid = ?`, src); err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(hourlyFoldSQL, dst, src); err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(`DELETE FROM usage_hourly WHERE account_uuid = ?`, src); err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(`UPDATE limit_snapshots SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
		return 0, 0, err
	}
	// Keyed by account, so the destination may already hold the same reading;
	// keep one and drop the duplicate rather than orphan it.
	for _, t := range []string{"quota_snapshots", "account_usage_observations", "endpoint_accounts"} {
		if _, err := tx.Exec(`UPDATE OR IGNORE `+t+` SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
			return 0, 0, err
		}
		if _, err := tx.Exec(`DELETE FROM `+t+` WHERE account_uuid = ?`, src); err != nil {
			return 0, 0, err
		}
	}
	// account_uuid is a plain column here, not part of the key.
	if _, err := tx.Exec(`UPDATE source_collectors SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
		return 0, 0, err
	}
	// A recorded switch BETWEEN the two accounts stops being a switch the
	// moment they are one account; rewriting it would leave a row claiming the
	// endpoint moved from an account to itself.
	for _, t := range []string{"account_switches", "source_account_switches"} {
		if _, err := tx.Exec(`UPDATE `+t+` SET from_account = ? WHERE from_account = ?`, dst, src); err != nil {
			return 0, 0, err
		}
		if _, err := tx.Exec(`UPDATE `+t+` SET to_account = ? WHERE to_account = ?`, dst, src); err != nil {
			return 0, 0, err
		}
		if _, err := tx.Exec(`DELETE FROM ` + t + ` WHERE from_account = to_account`); err != nil {
			return 0, 0, err
		}
	}
	if _, err := tx.Exec(`UPDATE endpoints SET account_uuid = ? WHERE account_uuid = ?`, dst, src); err != nil {
		return 0, 0, err
	}
	if _, err := tx.Exec(`DELETE FROM accounts WHERE account_uuid = ?`, src); err != nil {
		return 0, 0, err
	}
	return moved, folded, tx.Commit()
}

// hourlyFoldSQL moves one account's hour-rows onto another account, ADDING to
// any row the destination already has for the same hour and shape.
//
// The rollup's key contains the account, so the same hour under two accounts
// is two rows that become one. UPDATE OR IGNORE (what usage_events uses) would
// keep the destination's row and silently discard the source's tokens; the
// rollup is a sum, not a set of distinct turns, so the fold has to be additive
// in exactly the way ingest is (rollupInsertSQL, same ON CONFLICT list).
const hourlyFoldSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider, git_branch,
  effort, entrypoint, is_sidechain, source,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts,
  cache_write_tokens, cache_write_known_events)
SELECT hour, ?, endpoint_id, session_id, os_user, cwd, model, provider, git_branch,
       effort, entrypoint, is_sidechain, source,
       events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
       cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts,
       cache_write_tokens, cache_write_known_events
  FROM usage_hourly WHERE account_uuid = ?
ON CONFLICT(hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider,
            git_branch, effort, entrypoint, is_sidechain, source) DO UPDATE SET
  events                   = events + excluded.events,
  input_tokens             = input_tokens + excluded.input_tokens,
  output_tokens            = output_tokens + excluded.output_tokens,
  cache_create_5m_tokens   = cache_create_5m_tokens + excluded.cache_create_5m_tokens,
  cache_create_1h_tokens   = cache_create_1h_tokens + excluded.cache_create_1h_tokens,
  cache_read_tokens        = cache_read_tokens + excluded.cache_read_tokens,
  thinking_tokens          = thinking_tokens + excluded.thinking_tokens,
  cost_usd                 = cost_usd + excluded.cost_usd,
  unpriced_events          = unpriced_events + excluded.unpriced_events,
  cache_write_tokens       = cache_write_tokens + excluded.cache_write_tokens,
  cache_write_known_events = cache_write_known_events + excluded.cache_write_known_events,
  min_ts                   = min(min_ts, excluded.min_ts),
  max_ts                   = max(max_ts, excluded.max_ts)`

// DuplicateAccountsBySchedule groups accounts that share a seven-day reset
// phase, returning src -> dst merges. A real uuid always wins over a
// fingerprint, and between two fingerprints the older one wins, so repeated
// runs converge instead of ping-ponging.
//
// skipped counts accounts with no limits snapshot to compare. They are NOT
// evidence of distinctness — nothing was checked about them — and the caller
// must say so. Reporting "every account has a distinct schedule" while silently
// ignoring one is how a duplicate hides: it happened here the moment a freshly
// logged-in account was queried before its first limits poll landed.
func (s *Store) DuplicateAccountsBySchedule() (dupes map[string]string, skipped []string, err error) {
	type acct struct {
		uuid  string
		first string
		reset time.Time
	}
	rows, err := s.read.Query(`
		SELECT a.account_uuid, a.first_seen, (
		  SELECT seven_day_resets_at FROM limit_snapshots l
		   WHERE l.account_uuid = a.account_uuid AND l.seven_day_resets_at IS NOT NULL
		   ORDER BY l.observed_at DESC LIMIT 1)
		FROM accounts a`)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	byKey := map[string][]acct{}
	for rows.Next() {
		var a acct
		var reset sql.NullString
		if err := rows.Scan(&a.uuid, &a.first, &reset); err != nil {
			return nil, nil, err
		}
		if !reset.Valid {
			skipped = append(skipped, a.uuid)
			continue
		}
		t, err := time.Parse(rfc, reset.String)
		if err != nil {
			skipped = append(skipped, a.uuid)
			continue
		}
		a.reset = t
		k := sessions.FingerprintFor(&t)
		byKey[k] = append(byKey[k], a)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	dupes = map[string]string{}
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
				dupes[a.uuid] = winner.uuid
			}
		}
	}
	return dupes, skipped, nil
}

// AccountFootprint is what a merge would move: raw turns still in
// usage_events, turns in the rollup, and the rollup's tokens.
//
// Raw and rollup turns are reported separately rather than reconciled: past
// the retention window only the rollup survives, and an operator about to
// delete an account row needs to see that the two numbers differ.
func (s *Store) AccountFootprint(account string) (rawTurns, rollupTurns, tokens int64, err error) {
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_uuid = ?`, account).
		Scan(&rawTurns); err != nil {
		return 0, 0, 0, err
	}
	err = s.read.QueryRow(fmt.Sprintf(`
		SELECT COALESCE(SUM(events),0), COALESCE(%s,0) FROM usage_hourly WHERE account_uuid = ?`,
		tokenSumExpr), account).Scan(&rollupTurns, &tokens)
	if err != nil {
		return 0, 0, 0, err
	}
	return rawTurns, rollupTurns, tokens, nil
}

// PoolAccount is the key a source parks usage under when the transcript cannot
// name the account that paid for it — "codex:local" for Codex. It is a real
// row in accounts, not a sentinel, so that the usage is visible rather than
// silently attributed to whoever happens to be logged in.
func PoolAccount(source string) string { return source + ":local" }

// BindSourcePool records that a source's unassigned pool is really one
// account on this hub, so ingest stops creating the pool again.
//
// Separate from MergeAccount because they answer different questions: the
// merge repairs the history already stored, the binding decides where the
// NEXT unattributable turn goes. Doing only the merge means the pool is back
// the first time a Codex session runs that no profile can claim — which is
// every session recorded before that profile was logged in.
func (s *Store) BindSourcePool(source, account string) error {
	if source == "" || account == "" {
		return errors.New("binding needs a source and an account")
	}
	var known int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM accounts WHERE account_uuid = ?`, account).Scan(&known); err != nil {
		return err
	}
	if known == 0 {
		return fmt.Errorf("no account %q on this hub to bind %s usage to", account, source)
	}
	_, err := s.write.Exec(`
		INSERT INTO source_pool_bindings(source, account_uuid, bound_at) VALUES(?,?,?)
		ON CONFLICT(source) DO UPDATE SET account_uuid = excluded.account_uuid, bound_at = excluded.bound_at`,
		source, account, fmtTime(time.Now().UTC()))
	return err
}

// ResolvePool maps a source's unassigned pool onto the account the operator
// bound it to. Anything else — a real uuid, an unbound pool — is returned
// unchanged, so an unbound hub keeps the pool exactly as before.
func (s *Store) ResolvePool(source, account string) (string, error) {
	if source == "" || account != PoolAccount(source) {
		return account, nil
	}
	var bound string
	err := s.read.QueryRow(`SELECT account_uuid FROM source_pool_bindings WHERE source = ?`, source).Scan(&bound)
	if errors.Is(err, sql.ErrNoRows) {
		return account, nil
	}
	if err != nil {
		return "", err
	}
	return bound, nil
}

// SourcePoolBinding reports the account a source's pool is bound to, or "".
func (s *Store) SourcePoolBinding(source string) (string, error) {
	var bound string
	err := s.read.QueryRow(`SELECT account_uuid FROM source_pool_bindings WHERE source = ?`, source).Scan(&bound)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return bound, err
}
