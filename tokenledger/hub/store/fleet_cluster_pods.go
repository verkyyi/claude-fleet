package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// A cluster's pods (claude-fleet#3553, EPIC #3500 C8).
//
// In a cluster a spare is not a login opened on a shared machine but a whole
// pod — one person's, render.py --user-pod u-<nonce> — started ahead of a
// newcomer by the cluster's provisioner. The spare's principal and account
// rows are a machine spare's (spare:<cluster>:<nonce>, login fleetu<N>, state
// from the create its pod's own node ran), with the account's hostname the pod
// u-<nonce> — the pod is a machine to the hub. What a machine spare does not
// have is a place: fleet_cluster_pods remembers which cluster each pod is in
// and how far its life has got, so a claimed pod still counts against its
// cluster's cap and its destroy goes to the right provisioner. Recycling a pod
// is destroying it (Deployment · Service · PVC · join Secret) and starting a
// fresh one — never a wash in place (共同约定 5).
//
// Created with every fleet table (EnsureNodes); read only while spares are on
// and fleet.clusters names a cluster.
const fleetClusterPodsSchema = `
CREATE TABLE IF NOT EXISTS fleet_cluster_pods (
  pod          TEXT PRIMARY KEY,
  cluster      TEXT NOT NULL,
  principal_id TEXT NOT NULL DEFAULT '',
  state        TEXT NOT NULL,
  detail       TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  claimed_at   TEXT,
  destroyed_at TEXT,
  updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_cluster_pods_cluster ON fleet_cluster_pods(cluster, state);`

// Cluster pod states.
const (
	// PodProvisioning: recorded; its create ticket is (being) sent.
	PodProvisioning = "provisioning"
	// PodLive: the provisioner made it. Ready is its account's word
	// (active, credential-separated), never this row's.
	PodLive = "live"
	// PodDestroying: its destroy ticket is (being) sent.
	PodDestroying = "destroying"
	// PodGone: the provisioner deleted it. The row stays as the record.
	PodGone = "gone"
	// PodFailed: the provisioner refused or failed; detail says why.
	PodFailed = "failed"
)

// ClusterPod is one row of fleet_cluster_pods.
type ClusterPod struct {
	Pod         string     `json:"pod"`
	Cluster     string     `json:"cluster"`
	PrincipalID string     `json:"principal_id"`
	State       string     `json:"state"`
	Detail      string     `json:"detail,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	ClaimedAt   *time.Time `json:"claimed_at,omitempty"`
	DestroyedAt *time.Time `json:"destroyed_at,omitempty"`
	UpdatedAt   time.Time  `json:"updated_at"`
	// Split is the repos a person's SECOND pod takes (claude-fleet#3562),
	// comma-separated owner/name; "" for their one pod and for a spare.
	Split string `json:"split,omitempty"`
}

// Held says the pod still stands (or is on its way up).
func (p ClusterPod) Held() bool { return p.State == PodProvisioning || p.State == PodLive }

// ErrNoClusterPod is a pod name fleet_cluster_pods does not have.
var ErrNoClusterPod = errors.New("no such cluster pod")

// ClusterPodName is the pod a nonce names: render.py's u-<nonce>.
func ClusterPodName(nonce string) string { return "u-" + nonce }

func (s *Store) ensureFleetClusterPods() error {
	if _, err := s.write.Exec(s.d.ddl(fleetClusterPodsSchema)); err != nil {
		return fmt.Errorf("create fleet_cluster_pods table: %w", err)
	}
	// split (claude-fleet#3562): a person's second pod names the repos it
	// takes; "" = their one pod (or a spare).
	return s.addColumn("fleet_cluster_pods", "split", "TEXT NOT NULL DEFAULT ''")
}

const clusterPodColumns = `SELECT pod, cluster, principal_id, state, detail, created_at, claimed_at, destroyed_at, updated_at, split
	FROM fleet_cluster_pods`

func scanClusterPods(rows *sql.Rows) ([]ClusterPod, error) {
	defer rows.Close()
	var out []ClusterPod
	for rows.Next() {
		var p ClusterPod
		var created, updated string
		var claimed, destroyed sql.NullString
		if err := rows.Scan(&p.Pod, &p.Cluster, &p.PrincipalID, &p.State, &p.Detail, &created, &claimed, &destroyed, &updated, &p.Split); err != nil {
			return nil, err
		}
		p.CreatedAt, _ = time.Parse(rfc, created)
		p.UpdatedAt, _ = time.Parse(rfc, updated)
		p.ClaimedAt, p.DestroyedAt = parseTimePtr(claimed), parseTimePtr(destroyed)
		out = append(out, p)
	}
	return out, rows.Err()
}

// ClusterPods lists cluster's pods ("" = every cluster's), oldest first.
func (s *Store) ClusterPods(cluster string) ([]ClusterPod, error) {
	q, args := clusterPodColumns, []any{}
	if cluster != "" {
		q += ` WHERE cluster = ?`
		args = append(args, strings.ToLower(cluster))
	}
	rows, err := s.read.Query(q+` ORDER BY created_at, pod`, args...)
	if err != nil {
		return nil, err
	}
	return scanClusterPods(rows)
}

// ClusterPodOf reads one pod; ErrNoClusterPod when the hub never made it.
func (s *Store) ClusterPodOf(pod string) (*ClusterPod, error) {
	rows, err := s.read.Query(clusterPodColumns+` WHERE pod = ?`, strings.ToLower(pod))
	if err != nil {
		return nil, err
	}
	out, err := scanClusterPods(rows)
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, ErrNoClusterPod
	}
	return &out[0], nil
}

// SetClusterPodState moves pod to state (with detail). Gone stamps
// destroyed_at.
func (s *Store) SetClusterPodState(pod, state, detail string, at time.Time) error {
	ts := fmtTime(at)
	q := `UPDATE fleet_cluster_pods SET state = ?, detail = ?, updated_at = ?`
	args := []any{state, detail, ts}
	if state == PodGone {
		q += `, destroyed_at = ?`
		args = append(args, ts)
	}
	res, err := s.write.Exec(q+` WHERE pod = ?`, append(args, strings.ToLower(pod))...)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoClusterPod
	}
	return nil
}

// ClaimClusterPod records pod as principal's from now on.
func (s *Store) ClaimClusterPod(pod, principal string, at time.Time) error {
	ts := fmtTime(at)
	res, err := s.write.Exec(`UPDATE fleet_cluster_pods SET principal_id = ?, claimed_at = ?, updated_at = ? WHERE pod = ?`,
		principal, ts, ts, strings.ToLower(pod))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoClusterPod
	}
	return nil
}

// CreateClusterSpare records a spare pod in cluster and queues its login: a
// fresh nonce names the pod u-<nonce> and the principal
// spare:<cluster>:<nonce>, under the next free login fleetu<N>; its account
// row is pending on the pod (sent once the pod's own node is up) and its pod
// row provisioning — one transaction. The caller sends the create ticket.
func (s *Store) CreateClusterSpare(cluster string, valid func(string) bool, at time.Time) (*FleetAccount, error) {
	cluster = strings.ToLower(strings.TrimSpace(cluster))
	if cluster == "" {
		return nil, errors.New("empty cluster")
	}
	ts := fmtTime(at)
	var n int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_principals WHERE login LIKE ?`, spareLoginStem+"%").Scan(&n); err != nil {
		return nil, err
	}
	for i := 1; i <= 200; i++ {
		login := spareLoginStem + strconv.Itoa(n+i)
		if !valid(login) {
			continue
		}
		var held int
		if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_accounts WHERE login = ?`, login).Scan(&held); err != nil {
			return nil, err
		}
		if held > 0 {
			continue
		}
		nonce, err := randomLowerAlnum(10)
		if err != nil {
			return nil, err
		}
		id, pod := SparePrefix+cluster+":"+nonce, ClusterPodName(nonce)
		tx, err := s.write.Begin()
		if err != nil {
			return nil, err
		}
		_, err = tx.Exec(`INSERT INTO fleet_principals (principal_id, login, display_name, created_at)
			VALUES (?, ?, ?, ?)`, id, login, SpareFullName, ts)
		if err == nil {
			_, err = tx.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, detail, requested_at, updated_at)
				VALUES (?, ?, ?, ?, 'create', 'spare: a pod started ahead of a newcomer', ?, ?)`,
				id, pod, login, AccountPending, ts, ts)
		}
		if err == nil {
			_, err = tx.Exec(`INSERT INTO fleet_cluster_pods (pod, cluster, principal_id, state, created_at, updated_at)
				VALUES (?, ?, ?, ?, ?, ?)`, pod, cluster, id, PodProvisioning, ts, ts)
		}
		if err != nil {
			tx.Rollback()
			if isUniqueViolation(err) {
				continue
			}
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return &FleetAccount{PrincipalID: id, Hostname: pod, Login: login, State: AccountPending,
			Op: "create", RequestedAt: at.UTC(), UpdatedAt: at.UTC()}, nil
	}
	return nil, errors.New("no free spare login name")
}

// CreateClusterPodFor records a pod of p's own in cluster — the pool was
// empty — and queues p's login there under p's own name: account row pending
// on the new pod, pod row provisioning, one transaction.
func (s *Store) CreateClusterPodFor(cluster string, p *Principal, at time.Time) (*FleetAccount, error) {
	if p == nil {
		return nil, errors.New("empty cluster or principal")
	}
	return s.CreateClusterPodSplit(cluster, p, p.Login, "", at)
}

// CreateClusterPodSplit is CreateClusterPodFor under login, for the repos
// split names (claude-fleet#3562: a person's second pod — split non-empty);
// split "" is their one pod.
func (s *Store) CreateClusterPodSplit(cluster string, p *Principal, login, split string, at time.Time) (*FleetAccount, error) {
	cluster = strings.ToLower(strings.TrimSpace(cluster))
	if cluster == "" || p == nil || login == "" {
		return nil, errors.New("empty cluster, principal or login")
	}
	detail := "cluster: a pod of their own (no spare was ready)"
	if split != "" {
		detail = "cluster: their second pod, for " + split
	}
	ts := fmtTime(at)
	for i := 0; i < 5; i++ {
		nonce, err := randomLowerAlnum(10)
		if err != nil {
			return nil, err
		}
		pod := ClusterPodName(nonce)
		tx, err := s.write.Begin()
		if err != nil {
			return nil, err
		}
		_, err = tx.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, detail, requested_at, updated_at)
			VALUES (?, ?, ?, ?, 'create', ?, ?, ?)`,
			p.ID, pod, login, AccountPending, detail, ts, ts)
		if err == nil {
			_, err = tx.Exec(`INSERT INTO fleet_cluster_pods (pod, cluster, principal_id, state, created_at, claimed_at, updated_at, split)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, pod, cluster, p.ID, PodProvisioning, ts, ts, ts, split)
		}
		if err != nil {
			tx.Rollback()
			if isUniqueViolation(err) {
				continue
			}
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return &FleetAccount{PrincipalID: p.ID, Hostname: pod, Login: login, State: AccountPending,
			Op: "create", RequestedAt: at.UTC(), UpdatedAt: at.UTC()}, nil
	}
	return nil, errors.New("no free pod name")
}

// SetClusterPodSplit moves a second pod's repo list (claude-fleet#3562).
func (s *Store) SetClusterPodSplit(pod, split string, at time.Time) error {
	res, err := s.write.Exec(`UPDATE fleet_cluster_pods SET split = ?, updated_at = ? WHERE pod = ?`,
		split, fmtTime(at), strings.ToLower(pod))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoClusterPod
	}
	return nil
}

// FinishClusterPodRemoval closes the login on a destroyed pod: the account
// row (remove sent as opID) is removed, the pod row gone — one transaction.
func (s *Store) FinishClusterPodRemoval(pod, opID, detail string, at time.Time) error {
	ts := fmtTime(at)
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE fleet_accounts SET state = ?, detail = ?, updated_at = ?
		WHERE hostname = ? AND op_id = ? AND state IN (?, ?)`,
		AccountRemoved, detail, ts, strings.ToLower(pod), opID, AccountRemoving, AccountUnknown); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE fleet_cluster_pods SET state = ?, detail = ?, destroyed_at = ?, updated_at = ? WHERE pod = ?`,
		PodGone, detail, ts, ts, strings.ToLower(pod)); err != nil {
		return err
	}
	return tx.Commit()
}

// FailClusterPodAccount fails the login on pod while nothing came back for it
// (pending · creating · unknown): a spare pod that never got ready, or whose
// create ticket was refused.
func (s *Store) FailClusterPodAccount(pod, detail string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, detail = ?, updated_at = ?
		WHERE hostname = ? AND state IN (?, ?, ?)`,
		AccountFailed, detail, fmtTime(at), strings.ToLower(pod), AccountPending, AccountCreating, AccountUnknown)
	return err
}
