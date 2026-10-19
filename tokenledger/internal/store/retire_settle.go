package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// What a retired endpoint left open on a repo's road to the hub
// (claude-fleet#4831). Retiring kills the token, and the token is the only
// thing that ever settled a local start: cancel / unobserved / stopped are
// each the node's own call. So a retire IS the proof that the endpoint can
// never launch or observe again, and it settles what only it could have:
//
//   - every unclosed repo_local_start journaled under it ends `retired`;
//   - every unclosed worker_start sent to one of its fleets ends `failed`
//     (claude-fleet#4864): only its node could ever answer operation_get;
//   - every legacy lease it holds goes (ReleaseLeasesOfEndpoint's rule:
//     task leases keep their fenced terminal result);
//   - one fleet_audit row says how many of each, on which repos.
//
// An endpoint that is merely offline keeps all of it: absent nodes are
// unknown, never drained. Re-running retire on an already retired endpoint
// settles what an older hub left behind and records nothing when nothing was
// left.

// RetiredSettle is what one settle closed.
type RetiredSettle struct {
	Starts int      // repo_local_start rows ended retired
	// WorkerStarts: worker_start operations on its fleets ended failed
	// (claude-fleet#4864).
	WorkerStarts int
	Repos  []string // the repos those starts were on, sorted
	Leases []Lease  // legacy leases released
}

func (r RetiredSettle) empty() bool {
	return r.Starts == 0 && r.WorkerStarts == 0 && len(r.Leases) == 0
}

func (s *Store) settleRetiredTx(tx *sql.Tx, endpointID, actor, reason string, at time.Time) (RetiredSettle, error) {
	var out RetiredSettle
	if ok, err := s.d.tableExists(tx, "fleet_operations"); err != nil {
		return out, err
	} else if ok {
		if err := s.retireStartsTx(tx, endpointID, at, &out); err != nil {
			return out, fmt.Errorf("settle its local starts: %w", err)
		}
	}
	if ok, err := s.d.tableExists(tx, "fleet_fleets"); err != nil {
		return out, err
	} else if ok {
		n, err := failRetiredWorkerStartsTx(tx, endpointID, at)
		if err != nil {
			return out, fmt.Errorf("settle its worker starts: %w", err)
		}
		out.WorkerStarts = n
	}
	if ok, err := s.d.tableExists(tx, "fleet_leases"); err != nil {
		return out, err
	} else if ok {
		leases, err := s.releaseLeasesTx(tx, endpointID)
		if err != nil {
			return out, fmt.Errorf("release its leases: %w", err)
		}
		out.Leases = leases
	}
	if out.empty() {
		return out, nil
	}
	if ok, err := s.d.tableExists(tx, "fleet_audit"); err != nil {
		return out, err
	} else if ok {
		outcome := fmt.Sprintf("SETTLED starts=%d leases=%d", out.Starts, len(out.Leases))
		if out.WorkerStarts > 0 {
			outcome += fmt.Sprintf(" worker_starts=%d", out.WorkerStarts)
		}
		if len(out.Repos) > 0 {
			outcome += " repos=" + strings.Join(out.Repos, ",")
		}
		if reason != "" {
			outcome += " reason=" + reason
		}
		if _, err := tx.Exec(`INSERT INTO fleet_audit (actor, worker_id, worker_key, action, fleet_id, outcome, operation_id, created)
			VALUES (?, '', '', 'node_retire_settle', ?, ?, '', ?)`, actor, "endpoint:"+endpointID, outcome, at.UTC().Format(rfc)); err != nil {
			return out, fmt.Errorf("audit: %w", err)
		}
	}
	return out, nil
}

// retireStartsTx ends every open start of the endpoint. Each repo's authority
// lock is taken first, in name order, so a settle and a concurrent authority
// change or start on the same repo serialize as RepoLocalStart's do.
func (s *Store) retireStartsTx(tx *sql.Tx, endpointID string, at time.Time, out *RetiredSettle) error {
	rows, err := tx.Query(`SELECT id, result FROM fleet_operations WHERE action = 'repo_local_start' AND actor = ?`, "repo-start:"+endpointID)
	if err != nil {
		return err
	}
	type open struct {
		id    string
		start RepoLocalStart
	}
	var todo []open
	for rows.Next() {
		var id, raw string
		var start RepoLocalStart
		if err = rows.Scan(&id, &raw); err != nil {
			rows.Close()
			return err
		}
		if err = json.Unmarshal([]byte(raw), &start); err != nil {
			rows.Close()
			return err
		}
		if start.EndpointID != endpointID || repoStartClosed(start.Phase) {
			continue
		}
		todo = append(todo, open{id, start})
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, o := range todo {
		if !seen[o.start.Repo] {
			seen[o.start.Repo] = true
			out.Repos = append(out.Repos, o.start.Repo)
		}
	}
	sort.Strings(out.Repos)
	for _, repo := range out.Repos {
		if err = s.lockRepoAuthority(tx, repo); err != nil {
			return err
		}
	}
	ts := at.UTC().Format(rfc)
	for _, o := range todo {
		o.start.Phase = "retired"
		b, _ := json.Marshal(o.start)
		if _, err = tx.Exec(`UPDATE fleet_operations SET result = ?, status = 'succeeded', updated = ? WHERE id = ? AND action = 'repo_local_start'`, string(b), ts, o.id); err != nil {
			return err
		}
		out.Starts++
	}
	return nil
}

// failRetiredWorkerStartsTx ends every unclosed worker_start addressed to a
// fleet whose machine answers on the retired endpoint: the node that was to
// open it can never be asked again, so it never opens. The prior status and
// result ride along in the error.
func failRetiredWorkerStartsTx(tx *sql.Tx, endpointID string, at time.Time) (int, error) {
	rows, err := tx.Query(`SELECT o.id, o.status, COALESCE(o.result, '') FROM fleet_operations o
		  JOIN fleet_fleets f ON f.fleet_id = o.fleet_id
		  JOIN fleet_machines m ON m.machine_id = f.machine_id
		 WHERE o.action = 'worker_start' AND o.status IN ('pending','accepted','running','unknown','sent')
		   AND m.endpoint_id = ?`, endpointID)
	if err != nil {
		return 0, err
	}
	type open struct{ id, status, result string }
	var todo []open
	for rows.Next() {
		var o open
		if err = rows.Scan(&o.id, &o.status, &o.result); err != nil {
			rows.Close()
			return 0, err
		}
		todo = append(todo, o)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, err
	}
	ts := at.UTC().Format(rfc)
	n := 0
	for _, o := range todo {
		var prior any
		if o.result != "" && json.Valid([]byte(o.result)) {
			prior = json.RawMessage(o.result)
		}
		b, _ := json.Marshal(map[string]any{"error": map[string]any{"code": "ENDPOINT_RETIRED",
			"message": "the fleet's endpoint was retired; this start can never open there",
			"endpoint_id": endpointID, "prior_status": o.status, "prior_result": prior}})
		res, err := tx.Exec(`UPDATE fleet_operations SET status = 'failed', result = ?, updated = ? WHERE id = ? AND status = ?`, string(b), ts, o.id, o.status)
		if err != nil {
			return n, err
		}
		if k, _ := res.RowsAffected(); k > 0 {
			n++
		}
	}
	return n, nil
}

func (s *Store) releaseLeasesTx(tx *sql.Tx, endpointID string) ([]Lease, error) {
	if err := s.d.claimWrites(tx, "fleet_leases"); err != nil {
		return nil, err
	}
	rows, err := tx.Query(`SELECT `+leaseReadCols+` FROM fleet_leases WHERE endpoint_id = ? AND task_id = 0`+s.d.forUpdate(), endpointID)
	if err != nil {
		return nil, err
	}
	var held []Lease
	for rows.Next() {
		l, err := scanLease(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		held = append(held, l)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(held) == 0 {
		return nil, nil
	}
	if _, err := tx.Exec(`DELETE FROM fleet_leases WHERE endpoint_id = ? AND task_id = 0`, endpointID); err != nil {
		return nil, err
	}
	return held, nil
}
