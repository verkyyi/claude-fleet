package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Registered devices (claude-fleet#1470).
//
// A device is a computer that scanned once: the public half of its
// ~/.ssh/fleet-cert key, bound to the person who confirmed the scan. From then
// on the device renews its 12-hour certificate by signing with that key —
// no scan — until it has gone unused for the idle window (seven days) or the
// operator revokes it. Every registration, renewal, refusal, revocation and
// machine pick is one row of fleet_device_audit.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetDevicesSchema = `
CREATE TABLE IF NOT EXISTS fleet_devices (
  fingerprint   TEXT PRIMARY KEY,
  principal_id  TEXT NOT NULL,
  public_key    TEXT NOT NULL,
  name          TEXT NOT NULL DEFAULT '',
  registered_at TEXT NOT NULL,
  last_used_at  TEXT NOT NULL,
  last_machine  TEXT NOT NULL DEFAULT '',
  renewals      INTEGER NOT NULL DEFAULT 0,
  revoked_at    TEXT NOT NULL DEFAULT '',
  revoked_by    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_devices_principal ON fleet_devices(principal_id, last_used_at);
CREATE TABLE IF NOT EXISTS fleet_device_audit (
  id           INTEGER PRIMARY KEY,
  at           TEXT NOT NULL,
  action       TEXT NOT NULL,
  fingerprint  TEXT NOT NULL,
  principal_id TEXT NOT NULL DEFAULT '',
  actor        TEXT NOT NULL DEFAULT '',
  detail       TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_device_audit_at ON fleet_device_audit(at);`

// Device audit actions.
const (
	DeviceRegister     = "register"      // a scan bound this key to a person (or re-bound / re-enabled it)
	DeviceRenew        = "renew"         // a certificate renewed by the device key
	DeviceRenewRefused = "renew_refused" // the detail says why
	DeviceRevoke       = "revoke"
	DeviceHome         = "home" // the hub picked a machine for this device
	// A login-registered node pass (claude-fleet#2212): issued (detail says
	// enrolled or reissued), or refused (detail says why).
	DeviceNodePass        = "node_pass"
	DeviceNodePassRefused = "node_pass_refused"
)

// ErrNoDevice: no device with that fingerprint.
var ErrNoDevice = errors.New("no such device")

// FleetDevice is one registered device.
type FleetDevice struct {
	Fingerprint  string     `json:"fingerprint"` // SHA256:… of the public key
	PrincipalID  string     `json:"principal_id"`
	PublicKey    string     `json:"public_key"`
	Name         string     `json:"name"` // the client's own hostname — its word, display only
	RegisteredAt time.Time  `json:"registered_at"`
	LastUsedAt   time.Time  `json:"last_used_at"`
	LastMachine  string     `json:"last_machine,omitempty"`
	Renewals     int        `json:"renewals"`
	RevokedAt    *time.Time `json:"revoked_at,omitempty"`
	RevokedBy    string     `json:"revoked_by,omitempty"`
	// Host is not stored: the hub sets it on GET /v1/fleet/devices when the
	// device's name is one of the fleet's hosting machines (claude-fleet#2680)
	// — a `fleet login` run ON a machine that runs sessions, not a client.
	Host         bool       `json:"host,omitempty"`
}

// Revoked reports whether the device may no longer renew.
func (d FleetDevice) Revoked() bool { return d.RevokedAt != nil }

// DeviceAudit is one row of the device audit.
type DeviceAudit struct {
	ID          int64     `json:"id"`
	At          time.Time `json:"at"`
	Action      string    `json:"action"`
	Fingerprint string    `json:"fingerprint"`
	PrincipalID string    `json:"principal_id,omitempty"`
	Actor       string    `json:"actor,omitempty"`
	Detail      string    `json:"detail,omitempty"`
}

func (s *Store) ensureFleetDevices() error {
	if _, err := s.write.Exec(s.d.ddl(fleetDevicesSchema)); err != nil {
		return fmt.Errorf("create fleet_devices tables: %w", err)
	}
	return nil
}

// RegisterDevice binds a key to a person: a new row, or — for a key already
// known — the person, name and last-used time are set again and any
// revocation is cleared, because a fresh scan IS the strong proof. Returns
// whether the device was new.
func (s *Store) RegisterDevice(d FleetDevice, now time.Time) (bool, error) {
	ts := now.UTC().Format(rfc)
	if _, err := s.write.Exec(`INSERT INTO fleet_devices (fingerprint, principal_id, public_key, name, registered_at, last_used_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(fingerprint) DO UPDATE SET principal_id = excluded.principal_id, public_key = excluded.public_key,
		  name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE fleet_devices.name END,
		  last_used_at = excluded.last_used_at, revoked_at = '', revoked_by = ''`,
		d.Fingerprint, d.PrincipalID, d.PublicKey, d.Name, ts, ts); err != nil {
		return false, err
	}
	// SQLite's upsert reports one changed row either way; tell new from
	// re-registered by the registered_at it kept.
	var reg string
	if err := s.read.QueryRow(`SELECT registered_at FROM fleet_devices WHERE fingerprint = ?`, d.Fingerprint).Scan(&reg); err != nil {
		return false, err
	}
	return reg == ts, nil
}

// Device reads one device; ErrNoDevice when unknown.
func (s *Store) Device(fingerprint string) (*FleetDevice, error) {
	rows, err := s.queryDevices(`WHERE fingerprint = ?`, 1, fingerprint)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, ErrNoDevice
	}
	return &rows[0], nil
}

// Devices lists devices, most recently used first; principalID "" is everyone's.
func (s *Store) Devices(principalID string, limit int) ([]FleetDevice, error) {
	if principalID == "" {
		return s.queryDevices("", limit)
	}
	return s.queryDevices(`WHERE principal_id = ?`, limit, principalID)
}

func (s *Store) queryDevices(where string, limit int, args ...any) ([]FleetDevice, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.read.Query(`SELECT fingerprint, principal_id, public_key, name, registered_at, last_used_at,
		last_machine, renewals, revoked_at, revoked_by FROM fleet_devices `+where+
		` ORDER BY last_used_at DESC, fingerprint LIMIT `+strconv.Itoa(limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetDevice{}
	for rows.Next() {
		var d FleetDevice
		var reg, used, rev string
		if err := rows.Scan(&d.Fingerprint, &d.PrincipalID, &d.PublicKey, &d.Name, &reg, &used,
			&d.LastMachine, &d.Renewals, &rev, &d.RevokedBy); err != nil {
			return nil, err
		}
		d.RegisteredAt, _ = time.Parse(rfc, reg)
		d.LastUsedAt, _ = time.Parse(rfc, used)
		if rev != "" {
			if t, err := time.Parse(rfc, rev); err == nil {
				d.RevokedAt = &t
			}
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// TouchDevice marks a use: last_used_at = at; machine, when given, becomes
// last_machine; renewed counts one more renewal.
func (s *Store) TouchDevice(fingerprint string, at time.Time, machine string, renewed bool) error {
	inc := 0
	if renewed {
		inc = 1
	}
	_, err := s.write.Exec(`UPDATE fleet_devices SET last_used_at = ?, renewals = renewals + ?,
		last_machine = CASE WHEN ? <> '' THEN ? ELSE last_machine END WHERE fingerprint = ?`,
		at.UTC().Format(rfc), inc, machine, machine, fingerprint)
	return err
}

// SetDeviceName keeps the device's newest self-reported name.
func (s *Store) SetDeviceName(fingerprint, name string) error {
	_, err := s.write.Exec(`UPDATE fleet_devices SET name = ? WHERE fingerprint = ?`, name, fingerprint)
	return err
}

// RevokeDevice stops a device renewing. False when it is unknown or already
// revoked — nothing changed.
func (s *Store) RevokeDevice(fingerprint, by string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_devices SET revoked_at = ?, revoked_by = ?
		WHERE fingerprint = ? AND revoked_at = ''`, at.UTC().Format(rfc), by, fingerprint)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// DeviceRevoked reports whether a key's device has been revoked. An unknown
// key is not revoked: a certificate from before devices existed still works
// until it runs out.
func (s *Store) DeviceRevoked(fingerprint string) (bool, error) {
	var rev string
	err := s.read.QueryRow(`SELECT revoked_at FROM fleet_devices WHERE fingerprint = ?`, fingerprint).Scan(&rev)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return rev != "", nil
}

// AddDeviceAudit writes one audit row.
func (s *Store) AddDeviceAudit(a DeviceAudit) error {
	if a.At.IsZero() {
		a.At = time.Now()
	}
	_, err := s.write.Exec(`INSERT INTO fleet_device_audit (at, action, fingerprint, principal_id, actor, detail)
		VALUES (?, ?, ?, ?, ?, ?)`, a.At.UTC().Format(rfc), a.Action, a.Fingerprint, a.PrincipalID, a.Actor, a.Detail)
	return err
}

// DeviceAuditLog lists audit rows, newest first; principalID "" is everyone's.
func (s *Store) DeviceAuditLog(principalID string, limit int) ([]DeviceAudit, error) {
	if limit <= 0 {
		limit = 100
	}
	q := `SELECT id, at, action, fingerprint, principal_id, actor, detail FROM fleet_device_audit`
	args := []any{}
	if principalID != "" {
		q += ` WHERE principal_id = ?`
		args = append(args, principalID)
	}
	q += ` ORDER BY id DESC LIMIT ` + strconv.Itoa(limit)
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DeviceAudit{}
	for rows.Next() {
		var a DeviceAudit
		var at string
		if err := rows.Scan(&a.ID, &at, &a.Action, &a.Fingerprint, &a.PrincipalID, &a.Actor, &a.Detail); err != nil {
			return nil, err
		}
		a.At, _ = time.Parse(rfc, at)
		out = append(out, a)
	}
	return out, rows.Err()
}
