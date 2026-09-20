package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Retiring an endpoint, and the one case where deleting it is safe.
//
// `enroll` mints an endpoint; until this file nothing took one back, so an
// endpoint enrolled by mistake stayed on the roster forever and the only route
// left was stopping the hub and editing SQLite by hand. That is the bug: a
// product whose only way to undo a create is to stop the service will
// eventually get someone to stop the service.
//
// Two verbs, deliberately not collapsed into one:
//
//   - RETIRE keeps the row and everything pointing at it. Safe on any
//     endpoint, and the only thing offered for one that has ever reported --
//     its spend is already in the ledger, and removing it would quietly change
//     what last month cost.
//   - DELETE removes the row, and refuses unless the endpoint never reported
//     anything at all. That is the mint-then-abandon case and nothing else.
//
// Deleting a used endpoint would not even be a clean removal: nothing in the
// schema references endpoints(endpoint_id), so SQLite's foreign keys cannot
// cascade or refuse -- the row would vanish and nine tables would keep rows
// pointing at an id that no longer names anything. EndpointFootprint counts
// those rows up front instead, and DeleteEndpoint refuses on any of them.

// endpointRefTables is every table keyed by endpoint_id, and therefore
// everything DeleteEndpoint has to find empty before it will remove the row.
//
// Listed explicitly rather than discovered from the schema at runtime: a new
// table that carries an endpoint_id must be a deliberate addition here, and
// failing to add it should be caught by review, not silently make deletion
// lossy. TestEndpointRefTables_CoversSchema keeps the list honest.
var endpointRefTables = []string{
	"usage_events",
	"usage_hourly",
	"limit_snapshots",
	"endpoint_accounts",
	"account_switches",
	"quota_snapshots",
	"source_collectors",
	"source_account_switches",
	"account_usage_observations",
}

// ErrNoSuchEndpoint is returned when an endpoint id names nothing.
var ErrNoSuchEndpoint = errors.New("no such endpoint")

// Enrollment is one row of the operator's inventory: every enrollment this hub
// holds, of EVERY kind, retired or not.
//
// Deliberately not store.Endpoint. The fleet-facing list filters to
// kind = 'agent', because a repo or growth shipper is not a machine and every
// surface fed from there would report one as an agent that stopped reporting.
// `ccquota endpoint` is the opposite question -- "what tokens exist, so I can
// take one back" -- and a shipper is exactly the thing an operator most often
// needs to retire: the incident in issue #42 was a `verify-health-shipper`. A
// shipper missing from this list would be a token nobody can find the id of,
// which is the hand-edit-the-database problem all over again.
//
// It carries Kind, which store.Endpoint deliberately does not (see
// EndpointKind): that rule exists so an authorisation decision cannot be made
// from a field riding along in a widely-shared struct. This type is read by
// one command, is never handed to a gate, and an operator choosing what to
// retire has to be told what each token IS.
type Enrollment struct {
	ID         string
	Label      string
	Kind       string
	EnrolledAt time.Time
	LastSeen   *time.Time
	RetiredAt  *time.Time
}

// Retired reports whether this enrollment has been retired.
func (e Enrollment) Retired() bool { return e.RetiredAt != nil }

// ListEnrollments returns every enrollment, of every kind, newest first.
// withRetired includes the retired ones.
func (s *Store) ListEnrollments(withRetired bool) ([]Enrollment, error) {
	q := `SELECT endpoint_id, label, hostname, kind, enrolled_at, last_seen, retired_at
	      FROM endpoints`
	if !withRetired {
		q += ` WHERE retired_at IS NULL`
	}
	q += ` ORDER BY enrolled_at DESC`
	rows, err := s.read.Query(q)
	if err != nil {
		return nil, fmt.Errorf("list enrollments: %w", err)
	}
	defer rows.Close()
	var out []Enrollment
	for rows.Next() {
		var e Enrollment
		var hostname, enrolled string
		var lastSeen, retired sql.NullString
		if err := rows.Scan(&e.ID, &e.Label, &hostname, &e.Kind, &enrolled, &lastSeen, &retired); err != nil {
			return nil, fmt.Errorf("list enrollments: %w", err)
		}
		if e.Label == "" {
			e.Label = hostname
		}
		e.EnrolledAt, _ = time.Parse(rfc, enrolled)
		e.LastSeen = parseNullTime(lastSeen)
		e.RetiredAt = parseNullTime(retired)
		out = append(out, e)
	}
	return out, rows.Err()
}

// TableRows is one table's count of rows belonging to an endpoint.
type TableRows struct {
	Table string
	Rows  int64
}

// EndpointFootprint reports what an endpoint has left behind, one entry per
// table that still holds rows for it. An empty result means the endpoint never
// reported anything and can be deleted outright.
//
// Returned rather than folded into DeleteEndpoint's error so the CLI can show
// an operator exactly what retiring would preserve before they choose.
func (s *Store) EndpointFootprint(endpointID string) ([]TableRows, error) {
	var out []TableRows
	for _, tbl := range endpointRefTables {
		var n int64
		// tbl is from the package-level list above, never from input.
		err := s.read.QueryRow(
			fmt.Sprintf(`SELECT COUNT(*) FROM %s WHERE endpoint_id = ?`, tbl),
			endpointID).Scan(&n)
		if err != nil {
			return nil, fmt.Errorf("count %s for %s: %w", tbl, endpointID, err)
		}
		if n > 0 {
			out = append(out, TableRows{Table: tbl, Rows: n})
		}
	}
	return out, nil
}

// EndpointByID returns one endpoint whether or not it is retired.
//
// Unlike EndpointByTokenHash this is an operator-side lookup, not an
// authentication: `endpoint retire` and `endpoint delete` are told an id and
// must be able to say "already retired" rather than "no such endpoint".
func (s *Store) EndpointByID(endpointID string) (*Endpoint, error) {
	e, err := scanEndpoint(s.read.QueryRow(
		endpointColumns+` FROM endpoints WHERE endpoint_id = ?`, endpointID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoSuchEndpoint
	}
	if err != nil {
		return nil, fmt.Errorf("endpoint %s: %w", endpointID, err)
	}
	return e, nil
}

// RetireEndpoint marks an endpoint retired and its token dead.
//
// Reports whether anything changed, so the caller can tell "retired it" from
// "it was already retired" -- the same contract as RevokeShareLink, and for
// the same reason: an operator who runs this twice deserves to be told the
// second one was a no-op rather than shown a success it did not cause.
//
// There is no un-retire. The token hash stays on the row (it is what makes the
// revocation work), so clearing retired_at would put the retired credential
// back in service -- an undo that silently re-arms the thing the operator
// wanted gone. Re-enrolling is the supported path: a new id, a new token, and
// the retired endpoint keeps its history exactly as it stands.
func (s *Store) RetireEndpoint(endpointID string) (bool, error) {
	res, err := s.write.Exec(`UPDATE endpoints SET retired_at = ?
		WHERE endpoint_id = ? AND retired_at IS NULL`,
		fmtTime(time.Now().UTC()), endpointID)
	if err != nil {
		return false, fmt.Errorf("retire endpoint: %w", err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// InUseError says an endpoint cannot be deleted because its history is in the
// ledger, and names what would have been orphaned.
type InUseError struct {
	EndpointID string
	Footprint  []TableRows
}

func (e *InUseError) Error() string {
	parts := make([]string, 0, len(e.Footprint))
	for _, f := range e.Footprint {
		parts = append(parts, fmt.Sprintf("%s: %d", f.Table, f.Rows))
	}
	return fmt.Sprintf("endpoint %s has reported: %v", e.EndpointID, parts)
}

// DeleteEndpoint removes an endpoint that never reported anything.
//
// It refuses with an *InUseError the moment any table still holds rows for it.
// That refusal is the feature: an endpoint whose spend is in the ledger cannot
// be deleted, because deleting it would change historical totals with nothing
// left to say why. Retire that one instead -- the caller is expected to print
// exactly that.
//
// The narrow case this does serve is real: a token minted for a one-off
// experiment, or for a shipper that was replaced before it ever pushed. Such a
// row has no history to protect, and making an operator keep it forever is how
// the roster fills with things nobody can explain.
func (s *Store) DeleteEndpoint(endpointID string) error {
	if _, err := s.EndpointByID(endpointID); err != nil {
		return err
	}
	fp, err := s.EndpointFootprint(endpointID)
	if err != nil {
		return err
	}
	if len(fp) > 0 {
		return &InUseError{EndpointID: endpointID, Footprint: fp}
	}
	// last_seen is checked as well as the row counts. They should agree, but
	// they are written by different paths, and the cheaper of two disagreeing
	// answers is the one that refuses.
	var lastSeen sql.NullString
	if err := s.read.QueryRow(`SELECT last_seen FROM endpoints WHERE endpoint_id = ?`,
		endpointID).Scan(&lastSeen); err != nil {
		return fmt.Errorf("endpoint %s: %w", endpointID, err)
	}
	if lastSeen.Valid && lastSeen.String != "" {
		return &InUseError{
			EndpointID: endpointID,
			Footprint:  []TableRows{{Table: "endpoints.last_seen", Rows: 1}},
		}
	}
	if _, err := s.write.Exec(`DELETE FROM endpoints WHERE endpoint_id = ?`, endpointID); err != nil {
		return fmt.Errorf("delete endpoint: %w", err)
	}
	return nil
}
