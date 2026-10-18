package store

import (
	"strings"
	"time"
)

// A login's check before it is handed out (claude-fleet#4673, EPIC #4667 C6).
//
// The node runs bin/fleet-login-ready.sh ONCE at the end of a create or a wash
// the hub asked for — a session credential from the machine's proxy, the
// login's home up, a first reply — and answers the time each step passed. The
// row is keyed by the op that ran it: a washed spare keeps its reset's op_id
// (RecycleAccount), so the check belongs to the account row whose op_id it is.
// A spare is handed out only while its op's check passed all three
// (spareCheckedSQL).

// AccountCheck is one op's check.
type AccountCheck struct {
	OpID         string     `json:"-"`
	Op           string     `json:"op,omitempty"` // create | reset: which run checked it
	CredOK       *time.Time `json:"cred_ok,omitempty"`
	HomeOK       *time.Time `json:"home_ok,omitempty"`
	FirstReplyOK *time.Time `json:"first_reply_ok,omitempty"`
	// Why is the step that did not pass and why ("reply: claude -p exited
	// 1: …"), or why there was no check at all (an older node).
	Why       string    `json:"why,omitempty"`
	CheckedAt time.Time `json:"checked_at"`
}

// Passed says all three steps passed.
func (c AccountCheck) Passed() bool { return c.Why == "" && c.Steps() == 3 }

// Steps is how many of the three passed.
func (c AccountCheck) Steps() int {
	n := 0
	for _, t := range []*time.Time{c.CredOK, c.HomeOK, c.FirstReplyOK} {
		if t != nil {
			n++
		}
	}
	return n
}

// spareCheckedSQL is a claim's " AND <account row> passed its check": col is
// the account row's op_id column.
func spareCheckedSQL(col string) string {
	return ` AND EXISTS (SELECT 1 FROM fleet_account_checks c WHERE c.op_id = ` + col +
		` AND c.cred_ok <> '' AND c.home_ok <> '' AND c.first_reply_ok <> '' AND c.why = '')`
}

func checkTime(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.UTC().Format(rfc)
}

func readCheckTime(v string) *time.Time {
	if v == "" {
		return nil
	}
	t, err := time.Parse(rfc, v)
	if err != nil {
		return nil
	}
	return &t
}

// RecordAccountCheck keeps c for its op (a second answer replaces the first)
// and drops the checks of ops no account row names any more.
func (s *Store) RecordAccountCheck(c AccountCheck) error {
	if strings.TrimSpace(c.OpID) == "" {
		return nil
	}
	if _, err := s.write.Exec(`INSERT INTO fleet_account_checks (op_id, op, cred_ok, home_ok, first_reply_ok, why, checked_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(op_id) DO UPDATE SET op = excluded.op, cred_ok = excluded.cred_ok, home_ok = excluded.home_ok,
		  first_reply_ok = excluded.first_reply_ok, why = excluded.why, checked_at = excluded.checked_at`,
		c.OpID, c.Op, checkTime(c.CredOK), checkTime(c.HomeOK), checkTime(c.FirstReplyOK), c.Why,
		c.CheckedAt.UTC().Format(rfc)); err != nil {
		return err
	}
	_, err := s.write.Exec(`DELETE FROM fleet_account_checks WHERE op_id NOT IN (SELECT op_id FROM fleet_accounts)`)
	return err
}

// AccountChecks is every op's check, by op_id.
func (s *Store) AccountChecks() (map[string]AccountCheck, error) {
	rows, err := s.read.Query(`SELECT op_id, op, cred_ok, home_ok, first_reply_ok, why, checked_at FROM fleet_account_checks`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]AccountCheck{}
	for rows.Next() {
		var c AccountCheck
		var cred, home, reply, at string
		if err := rows.Scan(&c.OpID, &c.Op, &cred, &home, &reply, &c.Why, &at); err != nil {
			return nil, err
		}
		c.CredOK, c.HomeOK, c.FirstReplyOK = readCheckTime(cred), readCheckTime(home), readCheckTime(reply)
		c.CheckedAt, _ = time.Parse(rfc, at)
		out[c.OpID] = c
	}
	return out, rows.Err()
}
