package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// A cluster's readings (claude-fleet#3734): each user pod's last reading, as
// its cluster's fleet-ops sent it — the body is the file the pod's login
// writes (control.MachineReading's JSON), kept as it came. A row per pod,
// overwritten; the hub keeps it so the replica a pod's link lands on can hand
// it over even when fleet-ops is connected to the other one. Read only for a
// link that listed control.CapClusterReading; written only from a cluster's
// ops link.
const fleetClusterReadingsSchema = `
CREATE TABLE IF NOT EXISTS fleet_cluster_readings (
  pod        TEXT PRIMARY KEY,
  cluster    TEXT NOT NULL,
  body       TEXT NOT NULL,
  ts         INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);`

func (s *Store) ensureFleetClusterReadings() error {
	if _, err := s.write.Exec(s.d.ddl(fleetClusterReadingsSchema)); err != nil {
		return fmt.Errorf("create fleet_cluster_readings table: %w", err)
	}
	return nil
}

// ClusterReading is one row of fleet_cluster_readings.
type ClusterReading struct {
	Pod, Cluster, Body string
	TS                 int64
}

// PutClusterReading keeps pod's newest reading; an older one (ts) never
// replaces a newer.
func (s *Store) PutClusterReading(r ClusterReading, at time.Time) error {
	_, err := s.write.Exec(`INSERT INTO fleet_cluster_readings (pod, cluster, body, ts, updated_at) VALUES (?, ?, ?, ?, ?)
ON CONFLICT (pod) DO UPDATE SET cluster = excluded.cluster, body = excluded.body, ts = excluded.ts, updated_at = excluded.updated_at
WHERE excluded.ts >= fleet_cluster_readings.ts`,
		strings.ToLower(r.Pod), strings.ToLower(r.Cluster), r.Body, r.TS, fmtTime(at))
	return err
}

// ClusterReadingOf is pod's last reading; nil when there is none.
func (s *Store) ClusterReadingOf(pod string) (*ClusterReading, error) {
	r := ClusterReading{}
	err := s.read.QueryRow(`SELECT pod, cluster, body, ts FROM fleet_cluster_readings WHERE pod = ?`,
		strings.ToLower(pod)).Scan(&r.Pod, &r.Cluster, &r.Body, &r.TS)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &r, nil
}
