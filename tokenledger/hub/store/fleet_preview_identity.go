package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// BindPreviewEnrollment is only called by the existing admin accounts route.
// It grants no OS permission, rotates no token, and does not rewrite join-code
// history. An ordinary node cannot approve its own observed identity.
func (s *Store) BindPreviewEnrollment(owner, machine, login, endpoint, actor string, bind bool, now time.Time) error {
	if owner == "" || machine == "" || login == "" || endpoint == "" || actor == "" {
		return fmt.Errorf("preview enrollment needs principal_id, hostname, login and endpoint_id")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	action := "preview_unbind"
	if bind {
		var generation, hash string
		err = tx.QueryRow(`SELECT a.requested_at || ':' || a.op_id || ':' || a.updated_at,e.token_hash
 FROM fleet_accounts a JOIN endpoints e ON e.endpoint_id=?
 WHERE a.principal_id=? AND a.hostname=? AND a.login=? AND a.state='active'
 AND e.retired_at IS NULL AND e.role='managed' AND e.enrolled_host=a.hostname AND e.os_user=a.login`,
			endpoint, owner, machine, login).Scan(&generation, &hash)
		if err != nil {
			return fmt.Errorf("preview enrollment needs a matching active account and live managed endpoint")
		}
		approval, e := newFleetID()
		if e != nil {
			return e
		}
		if _, err = tx.Exec(`DELETE FROM fleet_preview_enrollments WHERE endpoint=?`, endpoint); err != nil {
			return err
		}
		_, err = tx.Exec(`INSERT INTO fleet_preview_enrollments (endpoint,owner,machine,login,generation,token_hash,approval)
 VALUES (?,?,?,?,?,?,?)`, endpoint, owner, machine, login, generation, hash, approval)
		action = "preview_bind"
	} else {
		_, err = tx.Exec(`DELETE FROM fleet_preview_enrollments WHERE endpoint=? AND owner=? AND machine=? AND login=?`, endpoint, owner, machine, login)
	}
	if err != nil {
		return err
	}
	// Re-approving the same endpoint must never resurrect URLs revoked by an
	// earlier unbind. Bind/unbind explicitly closes this account's old leases.
	if _, err = tx.Exec(`UPDATE fleet_previews SET closed=1 WHERE endpoint=? AND owner=? AND machine=? AND login=?`, endpoint, owner, machine, login); err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO fleet_audit (actor,action,fleet_id,outcome,operation_id,created) VALUES (?,?,?,?,?,?)`,
		actor, action, "endpoint:"+endpoint, owner+" "+login+"@"+machine, "", now.UTC().Format(rfc))
	if err != nil {
		return err
	}
	return tx.Commit()
}

// PreviewTaskBinding checks the durable Task association. Callers supply only
// the authenticated endpoint and verified worker identity. Creation rechecks
// inside its transaction, and every request/watchdog reads the same database.
func (s *Store) PreviewTaskBinding(p Preview) (string, error) {
	return previewTaskBinding(s.write, p)
}

func previewTaskBinding(q querier, p Preview) (string, error) {
	rows, err := q.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE id=?`, p.TaskID)
	if err != nil {
		return "", err
	}
	ts, err := scanFleetTasks(rows)
	if err != nil || len(ts) != 1 {
		return "", ErrPreview
	}
	t := ts[0]
	if t.Owner != p.Owner || p.Worker == "" || t.CancelRequest != "" {
		return "", ErrPreview
	}
	mode := "legacy"
	if t.ExecutionEndpoint != "" || t.ExecutionOwner != "" || t.OperationID != "" && taskExecutionVersionOf(q, t.OperationID) {
		mode = "execution"
		o, generation, err := taskExecutionBindingTx(q, t)
		fleet, _, parseErr := fleetid.ParseWorkerID(p.Worker)
		if err != nil || parseErr != nil || generation != t.Generation || t.ExecutionOwner != p.Worker || t.ExecutionEndpoint != p.Endpoint || o.FleetID != fleet {
			return "", ErrPreview
		}
	} else if t.WorkerID != "" || t.Machine != "" || t.Login != "" {
		if t.WorkerID != p.Worker || t.Machine != p.Machine || t.Login != p.Login {
			return "", ErrPreview
		}
	} else {
		mode = "session"
		fleet, fid, err := fleetid.ParseWorkerID(p.Worker)
		if err != nil || !fleetid.IsUUID(fid) || fid != t.FID {
			return "", ErrPreview
		}
		var n int
		err = q.QueryRow(`SELECT COUNT(*) FROM fleet_ids i JOIN fleet_fleets f ON f.fleet_id=?
 JOIN fleet_machines m ON m.machine_id=f.machine_id
 WHERE i.id=? AND i.owner=? AND i.endpoint_id=? AND i.machine=? AND i.login=?
 AND i.closed_at=0 AND i.seq>0 AND m.endpoint_id=i.endpoint_id AND i.task_id=?`,
			fleet, fid, p.Owner, p.Endpoint, p.Machine, p.Login, t.FID).Scan(&n)
		if err != nil || n != 1 {
			return "", ErrPreview
		}
	}
	// Persist the generation as well as the worker: stop/resume or a new attempt
	// cannot silently inherit an old preview, even when the Session FID survives.
	b, _ := json.Marshal([]any{mode, t.FID, t.Generation, t.AttemptID, t.OperationID, p.Worker, p.Endpoint})
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:]), nil
}

func taskExecutionVersionOf(q querier, operation string) bool {
	var request string
	// A broken operation must not fall back to a weaker legacy association.
	if err := q.QueryRow(`SELECT request FROM fleet_operations WHERE id=?`, operation).Scan(&request); err != nil {
		return true
	}
	return taskExecutionVersion(request)
}
