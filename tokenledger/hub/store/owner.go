package store

import (
	"strings"
)

// A person's own rows (claude-fleet#2514).
//
// A login NAME is not a person: `ubuntu` on one machine and `ubuntu` on
// another are two people, and cutting usage by the name alone handed each the
// other's sessions and spend. What a person owns is a (machine, login) pair —
// their fleet_accounts rows — and what a usage row carries is the endpoint
// that reported it plus the login it ran as. So a person's rows are resolved
// once, from their pairs to the (endpoint, login) pairs that report for them,
// and every query a person runs is cut by that set.

// LoginPair is one login on one machine: a fleet_accounts row's (hostname,
// login), plus the node endpoint the row was bound to when it has one (a
// 登录即认人 row, claude-fleet#2212 — the computer's own endpoint, which still
// matches when the machine's name drifts, `m.local` vs `m`).
type LoginPair struct {
	Hostname   string `json:"machine"`
	Login      string `json:"login"`
	EndpointID string `json:"-"`
}

// EndpointLogin is one login on one reporting endpoint: the unit a usage row
// and a live session are matched on.
type EndpointLogin struct {
	EndpointID string
	OSUser     string
}

// Owner is the rows one person may see. A nil *Owner is no cut; an Owner with
// no Logins sees nothing — never everything.
type Owner struct {
	Logins []EndpointLogin
}

// Owns reports whether a row reported by endpointID as osUser is the owner's.
func (o *Owner) Owns(endpointID, osUser string) bool {
	if o == nil {
		return true
	}
	for _, l := range o.Logins {
		if l.EndpointID == endpointID && l.OSUser == osUser {
			return true
		}
	}
	return false
}

// Key is a stable string for the set, for caches keyed by scope.
func (o *Owner) Key() string {
	if o == nil {
		return ""
	}
	parts := make([]string, 0, len(o.Logins)+1)
	parts = append(parts, "owner")
	for _, l := range o.Logins {
		parts = append(parts, l.EndpointID+"/"+l.OSUser)
	}
	return strings.Join(parts, "\x01")
}

// where is the predicate for the owner's rows on a table with endpoint_id and
// os_user columns ("1 = 0" for an empty set). The values are bound, never
// written into the SQL.
func (o *Owner) where() (string, []any) {
	if len(o.Logins) == 0 {
		return "1 = 0", nil
	}
	ors := make([]string, 0, len(o.Logins))
	args := make([]any, 0, 2*len(o.Logins))
	for _, l := range o.Logins {
		ors = append(ors, "(endpoint_id = ? AND os_user = ?)")
		args = append(args, l.EndpointID, l.OSUser)
	}
	return "(" + strings.Join(ors, " OR ") + ")", args
}

// OwnerOf resolves pairs to the endpoints reporting for them: every endpoint
// (or roster node) on that machine running as that login, and the endpoint a
// pair was bound to. The machine name is compared case-folded — it is the
// agent's own word.
func (s *Store) OwnerOf(pairs []LoginPair) (*Owner, error) {
	o := &Owner{Logins: []EndpointLogin{}}
	seen := map[EndpointLogin]bool{}
	add := func(q string, args ...any) error {
		rows, err := s.read.Query(q, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var l EndpointLogin
			if err := rows.Scan(&l.EndpointID, &l.OSUser); err != nil {
				return err
			}
			if !seen[l] {
				seen[l] = true
				o.Logins = append(o.Logins, l)
			}
		}
		return rows.Err()
	}
	for _, p := range pairs {
		if p.Hostname == "" || p.Login == "" {
			continue
		}
		if err := add(`SELECT endpoint_id, os_user FROM endpoints WHERE LOWER(hostname) = LOWER(?) AND os_user = ?`,
			p.Hostname, p.Login); err != nil {
			return nil, err
		}
		// The roster: a pair is only ever a fleet_accounts row, and that table
		// rides the same switch as nodes (EnsureNodes).
		if err := add(`SELECT endpoint_id, os_user FROM nodes WHERE LOWER(hostname) = LOWER(?) AND os_user = ?`,
			p.Hostname, p.Login); err != nil {
			return nil, err
		}
		if p.EndpointID != "" {
			// The bound endpoint counts as the pair's own; the login is the
			// pair's, never whatever else that endpoint reported.
			if l := (EndpointLogin{p.EndpointID, p.Login}); !seen[l] {
				seen[l] = true
				o.Logins = append(o.Logins, l)
			}
		}
	}
	return o, nil
}
