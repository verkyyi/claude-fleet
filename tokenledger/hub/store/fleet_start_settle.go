package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// Settling a worker_start whose worker never appeared (claude-fleet#4932).
// An online node that answers operation_get with UNKNOWN_OUTCOME ("Spawn
// returned but no matching worker is visible …") keeps the start `unknown`
// forever: the node cannot tell, and every unknown start is an "unsettled
// start" blocker on its owner's authority switch. The hub does not take the
// node's word for it. It ends the start `failed` only on its own books, all
// re-read in the transaction that writes:
//
//   - the operation is still that unknown worker_start, older than the grace;
//   - its fleet is present with a known inventory observed past the grace —
//     a reading taken after the spawn could have shown the worker;
//   - nothing there is the start's worker: no inventory row, no lease, no
//     unclosed local start that could be it.
//
// "The start's worker" is what the hub can name: an issue start's issue (in
// its repo), or the window identity the node named (`fid:<uuid>`). A scratch
// or new-issue start that names neither cannot be checked and stays unknown.

// StartWorker names the worker one worker_start would have opened.
type StartWorker struct {
	Issue    int    // an issue start's issue; 0 for none
	Repo     string // the issue's repo; "" = any repo
	Identity string // the window's @fleet_id the node named; "" for none
}

func (w StartWorker) named() bool { return w.Issue > 0 || w.Identity != "" }

// SettleNeverAppearedStart ends op failed when nothing on the hub's books is
// its worker (see above); settled false with why when it keeps it.
func (s *Store) SettleNeverAppearedStart(opID string, w StartWorker, grace time.Duration, evidence func(why string) string, now time.Time) (bool, string, error) {
	if !w.named() {
		return false, "the start names no worker the hub can check", nil
	}
	tx, err := s.write.Begin()
	if err != nil {
		return false, "", err
	}
	defer tx.Rollback()
	var fleetID, action, status, created string
	if err = tx.QueryRow(`SELECT fleet_id, action, status, created FROM fleet_operations WHERE id = ?`, opID).Scan(&fleetID, &action, &status, &created); err != nil {
		return false, "", err
	}
	at, _ := time.Parse(rfc, created)
	if action != "worker_start" || status != "unknown" {
		return false, "no longer an unknown worker_start", nil
	}
	if at.IsZero() || now.Sub(at) < grace {
		return false, "inside the grace", nil
	}
	var state, observed, workers string
	var present int
	err = tx.QueryRow(`SELECT state, present, observed_at, workers_json FROM fleet_fleets WHERE fleet_id = ?`, fleetID).Scan(&state, &present, &observed, &workers)
	if errors.Is(err, sql.ErrNoRows) {
		return false, "the fleet is not registered", nil
	}
	if err != nil {
		return false, "", err
	}
	obs, _ := time.Parse(rfc, observed)
	if present == 0 || state == fleetStateUnknown || obs.Before(at.Add(grace)) {
		return false, "no inventory read since the start could have shown it", nil
	}
	why, err := startWorkerHeld(tx, fleetID, workers, w)
	if err != nil || why != "" {
		return false, why, err
	}
	res, err := tx.Exec(`UPDATE fleet_operations SET status = 'failed', result = ?, updated = ? WHERE id = ? AND status = 'unknown'`,
		evidence("inventory observed "+obs.UTC().Format(rfc)), now.UTC().Format(rfc), opID)
	if err != nil {
		return false, "", err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, "changed while settling", nil
	}
	return true, "", tx.Commit()
}

// startWorkerHeld says what in fleetID could be w's worker; "" for nothing.
func startWorkerHeld(q querier, fleetID, workersJSON string, w StartWorker) (string, error) {
	var ws []map[string]any
	if json.Unmarshal([]byte(workersJSON), &ws) != nil {
		return "inventory unreadable", nil
	}
	for _, row := range ws {
		id, _ := row["worker_id"].(string)
		ident, _ := row["identity"].(string)
		repo, _ := row["repo"].(string)
		if w.Identity != "" && (ident == w.Identity || id == fleetID+"/"+w.Identity) {
			return "in inventory: " + id, nil
		}
		if n, ok := row["issue"].(float64); ok && w.Issue > 0 && int(n) == w.Issue && sameRepo(repo, w.Repo) {
			return "in inventory: " + id, nil
		}
	}
	rows, err := q.Query(`SELECT repo, issue, worker_id FROM fleet_leases WHERE fleet_id = ?`, fleetID)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var repo, worker string
		var issue int
		if err = rows.Scan(&repo, &issue, &worker); err != nil {
			rows.Close()
			return "", err
		}
		if (w.Issue > 0 && issue == w.Issue && sameRepo(repo, w.Repo)) || startWorkerID(fleetID, worker, w) {
			rows.Close()
			return "lease held: " + worker, nil
		}
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return "", err
	}
	starts, err := localStarts(q, func(st RepoLocalStart) bool {
		return !repoStartClosed(st.Phase) && startWorkerID(fleetID, st.WorkerID, w) && sameRepo(st.Repo, w.Repo)
	})
	if err != nil {
		return "", err
	}
	if len(starts) > 0 {
		return "local start retained: " + starts[0].WorkerID, nil
	}
	return "", nil
}

// startWorkerID: worker (a worker_id) could be w's — the identity it named, an
// issue key `issue-N` / `<slug>:issue-N`, or (for an issue start) any identity
// form of the fleet, which the hub cannot map to an issue.
func startWorkerID(fleetID, worker string, w StartWorker) bool {
	half, ok := strings.CutPrefix(worker, fleetID+"/")
	if !ok {
		return false
	}
	if w.Identity != "" && half == w.Identity {
		return true
	}
	if w.Issue <= 0 {
		return false
	}
	key := "issue-" + strconv.Itoa(w.Issue)
	return half == key || strings.HasSuffix(half, ":"+key) || fleetid.IsUUID(half)
}

// sameRepo: a and b may be the same repo — either unknown, equal, or the same
// name once the owner is dropped (an inventory may carry a slug).
func sameRepo(a, b string) bool {
	a, b = NormRepo(a), NormRepo(b)
	if a == "" || b == "" || a == "?" || b == "?" || a == b {
		return true
	}
	tail := func(r string) string { return r[strings.LastIndex(r, "/")+1:] }
	return tail(a) == tail(b)
}
