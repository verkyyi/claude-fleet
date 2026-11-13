package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// A machine's identity and its desired state (claude-fleet#2214, EPIC #2329 C2).
//
// Trust is the machine's (fleet.node_trust.<machine>, claude-fleet#3300), and
// the machine an endpoint is on is the one it ENROLLED as — never the name it
// reports now, so a borrowed name inherits nothing (#2214):
//
//   - endpoints.enrolled_host (a core column, store.go): the name the endpoint
//     enrolled under — the join code's machine when the code names one;
//   - endpoints.trust / trust_source: what the join code (or an old
//     desired-state write) said. No longer read for a judgment: the hub moved
//     it onto the machine once, and a trusted code now writes the machine's
//     setting at redemption.
//
// fleet_node_desired is the hub's copy of what a managed machine should look
// like (release, component versions, accounts, spares). The node reads it and
// converges; its heartbeat says which version it reached. docs/MANAGED-NODE.md
// is the shape.
const fleetDesiredSchema = `
CREATE TABLE IF NOT EXISTS fleet_node_desired (
  endpoint_id  TEXT PRIMARY KEY,
  version      INTEGER NOT NULL DEFAULT 0,
  body         TEXT NOT NULL DEFAULT '{}',
  updated_at   TEXT NOT NULL,
  updated_by   TEXT NOT NULL DEFAULT ''
);`

// Trust sources: where an endpoint's own trust came from.
const (
	TrustSourceJoinCode = "join_code"
	TrustSourceOperator = "operator"
)

// Node roles (EPIC #2329; claude-fleet#4886). managed is a node the fleet runs
// tasks on — a login of a 托管 machine, a cluster pod; client is a person's
// terminal that only connects, looks and opens windows: it hosts no repo and
// runs no task. "" is a row written before #4886 that nobody has typed yet —
// read as before, never guessed.
const (
	NodeRoleManaged = "managed"
	NodeRoleClient  = "client"
)

// ValidNodeRole is a role an endpoint (or a join code) may hold.
func ValidNodeRole(role string) bool {
	return role == "" || role == NodeRoleManaged || role == NodeRoleClient
}

// EndpointTrust is an endpoint's trust record: EnrolledHost is its machine;
// Trust / Source what its join code said (the record, not the judgment).
type EndpointTrust struct {
	Trust        string
	Source       string
	Role         string
	EnrolledHost string
	// EnrolledUser is the OS login it enrolled as (task MPCX): written once,
	// never moved by a report. '' = it never said one.
	EnrolledUser string
}

// ErrDesiredVersion is a desired-state write that names a version other than
// the current one.
var ErrDesiredVersion = errors.New("desired state changed since it was read")

func (s *Store) ensureFleetIdentity() error {
	if _, err := s.write.Exec(s.d.ddl(fleetDesiredSchema)); err != nil {
		return fmt.Errorf("create fleet_node_desired table: %w", err)
	}
	for _, c := range []struct{ table, column string }{
		{"endpoints", "trust"}, {"endpoints", "trust_source"}, {"endpoints", "role"},
		{"fleet_join_codes", "trust"}, {"fleet_join_codes", "role"}, {"fleet_join_codes", "machine"},
	} {
		if err := s.addColumn(c.table, c.column, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	return nil
}

// CreateJoinCodeFor stores a code that also carries the trust and role the
// endpoint it enrolls will hold — the operator's word, written at minting.
// machine, when set, is the machine the code is for (a login the hub opened
// there, claude-fleet#3300): the endpoint enrolls as that machine whatever
// name it reports.
func (s *Store) CreateJoinCodeFor(codeHash, label, kind, trust, role, machine string, now time.Time, ttl time.Duration) error {
	if kind == "" {
		kind = NodeKindFixed
	}
	_, err := s.write.Exec(`INSERT INTO fleet_join_codes (code_hash, label, kind, created_at, expires_at, trust, role, machine)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, codeHash, label, kind, fmtTime(now), fmtTime(now.Add(ttl)), trust, role, machine)
	return err
}

// EndpointTrustOf is one endpoint's own trust record. Its own query, like
// EndpointKind: it gates credentials, so a caller asks for it by name.
func (s *Store) EndpointTrustOf(endpointID string) (EndpointTrust, error) {
	var t EndpointTrust
	err := s.read.QueryRow(`SELECT trust, trust_source, role, enrolled_host, enrolled_user FROM endpoints WHERE endpoint_id = ?`,
		endpointID).Scan(&t.Trust, &t.Source, &t.Role, &t.EnrolledHost, &t.EnrolledUser)
	if errors.Is(err, sql.ErrNoRows) {
		return EndpointTrust{}, ErrNoSuchEndpoint
	}
	return t, err
}

// EndpointTrusts is every live endpoint's trust record with its current
// hostname, by endpoint id — the roster's and the machine check's one read.
func (s *Store) EndpointTrusts() (map[string]EndpointTrust, map[string]string, error) {
	rows, err := s.read.Query(`SELECT endpoint_id, hostname, trust, trust_source, role, enrolled_host, enrolled_user
		FROM endpoints WHERE retired_at IS NULL`)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	out, hosts := map[string]EndpointTrust{}, map[string]string{}
	for rows.Next() {
		var id, host string
		var t EndpointTrust
		if err := rows.Scan(&id, &host, &t.Trust, &t.Source, &t.Role, &t.EnrolledHost, &t.EnrolledUser); err != nil {
			return nil, nil, err
		}
		out[id], hosts[id] = t, host
	}
	return out, hosts, rows.Err()
}

// DeviceEnrollers is who enrolled endpointID through a device's own road
// (task MPCX): a `fleet login` node pass or a `fleet node join` scan — the
// codes the hub mints tagged with the device (CreateJoinCodeForDevice, role
// client) — or tied to one later (LinkDeviceEndpoint, no role): any code row
// that names a device. byDevice is false for an endpoint enrolled any other way (an
// operator's code, a login the hub opened, `ccquota enroll`); principals are
// the devices' people, "" for a device the hub no longer knows.
func (s *Store) DeviceEnrollers(endpointID string) (principals []string, byDevice bool, err error) {
	rows, err := s.read.Query(`SELECT COALESCE(d.principal_id, '') FROM fleet_join_codes c
		LEFT JOIN fleet_devices d ON d.fingerprint = c.device_fp
		WHERE c.endpoint_id = ? AND c.device_fp <> '' AND c.used_at IS NOT NULL`, endpointID)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, false, err
		}
		byDevice = true
		principals = append(principals, p)
	}
	return principals, byDevice, rows.Err()
}

// PodEnrolled: endpointID enrolled through a code the hub minted for one
// user pod (api startClusterPod: label pod-<machine>, the machine pinned,
// managed) — the pod's own node program, whose token its person's login can
// read (task MPCX).
func (s *Store) PodEnrolled(endpointID string) (bool, error) {
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_join_codes
		WHERE endpoint_id = ? AND used_at IS NOT NULL AND role = ? AND machine <> '' AND label = 'pod-' || machine`,
		endpointID, NodeRoleManaged).Scan(&n)
	return n > 0, err
}

// MachineEnrolledByOthers: a live endpoint other than endpointID, enrolled by
// any road but a device's, enrolled as machine (first label, any case)
// — the name is a machine's, not only a device's (task MPCX). A LIKE wildcard
// in the name can only over-match, which reads as "another holds it".
func (s *Store) MachineEnrolledByOthers(endpointID, machine string) (bool, error) {
	if i := strings.IndexByte(machine, '.'); i > 0 {
		machine = machine[:i]
	}
	machine = strings.ToLower(machine)
	if machine == "" {
		return false, nil
	}
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM endpoints e
		WHERE e.retired_at IS NULL AND e.endpoint_id <> ?
		  AND (LOWER(e.enrolled_host) = ? OR LOWER(e.enrolled_host) LIKE ?)
		  AND NOT EXISTS (SELECT 1 FROM fleet_join_codes c WHERE c.endpoint_id = e.endpoint_id
		      AND c.device_fp <> '' AND c.used_at IS NOT NULL)`,
		endpointID, machine, machine+".%").Scan(&n)
	return n > 0, err
}

// MachineProgramEnrolledAs: a live endpoint other than endpointID enrolled as
// machine (first label, any case) as root by any road but a device's — that
// machine's own node program (task MPCX). A LIKE wildcard in the name can only
// over-match, which reads as "another holds it".
func (s *Store) MachineProgramEnrolledAs(endpointID, machine string) (bool, error) {
	machine = lowerFirstLabel(machine)
	if machine == "" {
		return false, nil
	}
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM endpoints e
		WHERE e.retired_at IS NULL AND e.endpoint_id <> ? AND e.enrolled_user = 'root'
		  AND (LOWER(e.enrolled_host) = ? OR LOWER(e.enrolled_host) LIKE ?)
		  AND NOT EXISTS (SELECT 1 FROM fleet_join_codes c WHERE c.endpoint_id = e.endpoint_id
		      AND c.device_fp <> '' AND c.used_at IS NOT NULL)`,
		endpointID, machine, machine+".%").Scan(&n)
	return n > 0, err
}

// LoginEnrolledOn: a live endpoint enrolled as login on machine (first label,
// any case) by any road but a device's — a login the hub or an operator
// opened there (task MPCX).
func (s *Store) LoginEnrolledOn(machine, login string) (bool, error) {
	machine = lowerFirstLabel(machine)
	if machine == "" || login == "" {
		return false, nil
	}
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM endpoints e
		WHERE e.retired_at IS NULL AND e.enrolled_user = ?
		  AND (LOWER(e.enrolled_host) = ? OR LOWER(e.enrolled_host) LIKE ?)
		  AND NOT EXISTS (SELECT 1 FROM fleet_join_codes c WHERE c.endpoint_id = e.endpoint_id
		      AND c.device_fp <> '' AND c.used_at IS NOT NULL)`,
		login, machine, machine+".%").Scan(&n)
	return n > 0, err
}

// lowerFirstLabel is a machine name's first label, lower case.
func lowerFirstLabel(machine string) string {
	if i := strings.IndexByte(machine, '.'); i > 0 {
		machine = machine[:i]
	}
	return strings.ToLower(machine)
}

// EndpointEnrollment is how an endpoint came to be, read from the join codes
// spent for it (task MPCX).
type EndpointEnrollment struct {
	// ByDevice: a code naming a device enrolled or linked it; DevicePeople
	// are those devices' people ("" for a device the hub no longer knows).
	ByDevice     bool
	DevicePeople []string
	// Pinned: a code minted for one machine enrolled it (an opened login, an
	// admin seat, a pod or a login inside one) — the machine is the code's.
	Pinned bool
	// Pod: the code the hub minted for one user pod (label pod-<machine>).
	Pod bool
	// OpenedLogin: a code minted for one login the hub opened
	// (`<machine>-<login>`, managed, pinned, no trust) — that login.
	OpenedLogin string
	// EnrolledHost is endpoints.enrolled_host ("" for an unknown endpoint).
	EnrolledHost string
}

// EnrollmentOf reads endpointID's EndpointEnrollment (two indexed reads).
func (s *Store) EnrollmentOf(endpointID string) (EndpointEnrollment, error) {
	var e EndpointEnrollment
	if err := s.read.QueryRow(`SELECT enrolled_host FROM endpoints WHERE endpoint_id = ?`, endpointID).
		Scan(&e.EnrolledHost); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return e, err
	}
	rows, err := s.read.Query(`SELECT c.device_fp, c.role, c.machine, c.label, c.trust, COALESCE(d.principal_id, '')
		FROM fleet_join_codes c LEFT JOIN fleet_devices d ON d.fingerprint = c.device_fp
		WHERE c.endpoint_id = ? AND c.used_at IS NOT NULL`, endpointID)
	if err != nil {
		return e, err
	}
	defer rows.Close()
	for rows.Next() {
		var fp, role, machine, label, trust, person string
		if err := rows.Scan(&fp, &role, &machine, &label, &trust, &person); err != nil {
			return e, err
		}
		if fp != "" {
			e.ByDevice = true
			e.DevicePeople = append(e.DevicePeople, person)
		}
		if machine != "" {
			e.Pinned = true
			if role == NodeRoleManaged && label == "pod-"+machine {
				e.Pod = true
			}
			if l, ok := openedLoginOf(label, machine, trust, role); ok {
				e.OpenedLogin = l
			}
		}
	}
	return e, rows.Err()
}

// EnrolledByAnother: a live endpoint other than endpointID enrolled as
// machine (first label, any case) — the name is that endpoint's machine
// (task MPCX). A LIKE wildcard in the name can only over-match.
func (s *Store) EnrolledByAnother(endpointID, machine string) (bool, error) {
	machine = lowerFirstLabel(machine)
	if machine == "" {
		return false, nil
	}
	var n int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM endpoints
		WHERE retired_at IS NULL AND endpoint_id <> ? AND (LOWER(enrolled_host) = ? OR LOWER(enrolled_host) LIKE ?)`,
		endpointID, machine, machine+".%").Scan(&n)
	return n > 0, err
}

// IdentityGen is bumped by every write that can change how the hub reads a
// node's identity — an enrollment, a device link, a retire, a fleet setting,
// a recorded login (task MPCX); the api's identity cache keys on it.
func (s *Store) IdentityGen() uint64 { return s.identGen.Load() }

// TouchIdentity bumps IdentityGen (a write this package does not see: a test
// editing rows directly, another replica's word).
func (s *Store) TouchIdentity() { s.identGen.Add(1) }

// deviceHeldLogins are the logins a device road's endpoint never takes as its
// enrollment from a report (task MPCX): a machine's own program enrolls as
// root, and the admin role account comes only from its machine's install.
var deviceHeldLogins = map[string]bool{"root": true, "_fleetadmin": true, "fleetadmin": true}

// deviceStampHeld: endpointID has no enrolled login yet (unstamped), and —
// when a device enrolled it or was linked to it — the login a first report
// would stamp (report, or the os_user an earlier report left) is one of
// deviceHeldLogins (hold). An unreadable answer (a ledger without the fleet
// tables) is neither.
func (s *Store) deviceStampHeld(endpointID, report string) (unstamped, hold bool) {
	var u int
	var prev string
	err := s.read.QueryRow(`SELECT CASE WHEN enrolled_user = '' THEN 1 ELSE 0 END, os_user FROM endpoints WHERE endpoint_id = ?`,
		endpointID).Scan(&u, &prev)
	if err != nil || u == 0 {
		return false, false
	}
	cand := prev
	if cand == "" {
		cand = report
	}
	if !deviceHeldLogins[cand] {
		return true, false
	}
	_, byDevice, err := s.DeviceEnrollers(endpointID)
	return true, err == nil && byDevice
}

// SetEndpointTrust writes an endpoint's own trust ("" clears it, so the
// machine-name rule decides again).
func (s *Store) SetEndpointTrust(endpointID, trust, source string) error {
	defer s.identGen.Add(1) // task MPCX: identity reads cache on it
	if trust == "" {
		source = ""
	}
	res, err := s.write.Exec(`UPDATE endpoints SET trust = ?, trust_source = ? WHERE endpoint_id = ? AND retired_at IS NULL`,
		trust, source, endpointID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrNoSuchEndpoint
	}
	return nil
}

// SetEndpointRole writes an endpoint's role — the operator's word
// (claude-fleet#4886): managed, client, or "" to clear it.
func (s *Store) SetEndpointRole(endpointID, role string) error {
	if !ValidNodeRole(role) {
		return fmt.Errorf("role: managed, client or empty, not %q", role)
	}
	res, err := s.write.Exec(`UPDATE endpoints SET role = ? WHERE endpoint_id = ? AND retired_at IS NULL`, role, endpointID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrNoSuchEndpoint
	}
	return nil
}

// NodeDesired is one machine's desired state as the hub keeps it. Body is the
// JSON object docs/MANAGED-NODE.md describes, without trust (that lives on the
// endpoint); Version bumps on every write, 0 = never written.
type NodeDesired struct {
	EndpointID string
	Version    int
	Body       string
	UpdatedAt  time.Time
	UpdatedBy  string
}

// DesiredOf is an endpoint's desired state; Version 0 and Body "{}" when the
// operator never wrote one.
func (s *Store) DesiredOf(endpointID string) (NodeDesired, error) {
	d := NodeDesired{EndpointID: endpointID, Body: "{}"}
	var at string
	err := s.read.QueryRow(`SELECT version, body, updated_at, updated_by FROM fleet_node_desired WHERE endpoint_id = ?`,
		endpointID).Scan(&d.Version, &d.Body, &at, &d.UpdatedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return d, nil
	}
	if err != nil {
		return d, err
	}
	d.UpdatedAt, _ = time.Parse(rfc, at)
	return d, nil
}

// PutDesired replaces an endpoint's desired state and returns the new
// version. ifVersion ≥ 0 is the version the writer read: anything else is
// ErrDesiredVersion and nothing is written.
func (s *Store) PutDesired(endpointID, body, by string, ifVersion int, now time.Time) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var cur int
	switch err := tx.QueryRow(`SELECT version FROM fleet_node_desired WHERE endpoint_id = ?`, endpointID).Scan(&cur); {
	case errors.Is(err, sql.ErrNoRows):
		cur = 0
	case err != nil:
		return 0, err
	}
	if ifVersion >= 0 && ifVersion != cur {
		return cur, ErrDesiredVersion
	}
	next := cur + 1
	if _, err := tx.Exec(`INSERT INTO fleet_node_desired (endpoint_id, version, body, updated_at, updated_by)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(endpoint_id) DO UPDATE SET version = excluded.version, body = excluded.body,
		  updated_at = excluded.updated_at, updated_by = excluded.updated_by`,
		endpointID, next, body, fmtTime(now), by); err != nil {
		return 0, err
	}
	return next, tx.Commit()
}
