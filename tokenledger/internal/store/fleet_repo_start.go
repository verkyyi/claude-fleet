package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Local starts use the existing operation journal. The reservation is made
// BEFORE tmux/native creation, never expires, and cannot be erased by an empty
// inventory. Native observation and stop are separate, endpoint-fenced writes.
type RepoLocalStart struct {
	Reservation string              `json:"reservation"`
	Repo        string              `json:"repo"`
	Owner       string              `json:"owner"`
	EndpointID  string              `json:"endpoint_id"`
	WorkerID    string              `json:"worker_id,omitempty"`
	Native      *RepoNativeIdentity `json:"native_identity,omitempty"`
	Phase       string              `json:"phase"` // reserved | starting | observed | stopped | cancelled | abandoned
}

// repoStartClosed: a start that holds nothing. abandoned = begun, but its
// supervisor saw the agent exit with no native ever observed (issue #4792).
func repoStartClosed(phase string) bool {
	return phase == "stopped" || phase == "cancelled" || phase == "abandoned"
}

func repoStartID(repo, owner, endpoint, key string) string {
	sum := sha256.Sum256([]byte(owner + "\x00" + endpoint + "\x00" + repo + "\x00" + key))
	return fmt.Sprintf("repo-start:%x", sum[:])
}

// Recovery never reserves or begins an execution. Read the original journal
// entry under the authenticated scope, including its terminal phase.
func (s *Store) ReadRepoLocalStart(repo, owner, endpoint, key string) (RepoLocalStart, error) {
	var start RepoLocalStart
	var raw string
	repo = NormRepo(repo)
	if repo == "" || owner == "" || endpoint == "" || key == "" {
		return start, ErrTaskInvalid
	}
	err := s.read.QueryRow(`SELECT result FROM fleet_operations WHERE id = ? AND action = 'repo_local_start'`, repoStartID(repo, owner, endpoint, key)).Scan(&raw)
	if err != nil {
		return start, ErrTaskFence
	}
	if err = json.Unmarshal([]byte(raw), &start); err != nil {
		return start, err
	}
	if start.Repo != repo || start.Owner != owner || start.EndpointID != endpoint || start.Reservation != key {
		return start, ErrTaskFence
	}
	if start.Phase == "starting" || start.Phase == "observed" {
		if err = recoverRepoStartFence(s.read, repoStartID(repo, owner, endpoint, key), start); err != nil {
			return start, err
		}
	}
	return start, nil
}

// Legacy reservations have no execution generation. Their creation time cannot
// order begin calls (or survive clock rollback). Recovery therefore refuses ANY
// competing history for this worker, including stopped runs. It must not invent
// a generation. Ordinary native hooks retain their existing protocol.
func recoverRepoStartFence(q querier, id string, start RepoLocalStart) error {
	rows, err := q.Query(`SELECT result FROM fleet_operations WHERE action = 'repo_local_start' AND id <> ?`, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var raw string
		var other RepoLocalStart
		if err = rows.Scan(&raw); err != nil {
			return err
		}
		if err = json.Unmarshal([]byte(raw), &other); err != nil {
			return err
		}
		if other.WorkerID != start.WorkerID || other.WorkerID == "" {
			continue
		}
		return ErrTaskFence
	}
	return rows.Err()
}

func repoLocalStarts(q querier, repo string) ([]RepoLocalStart, error) {
	rows, err := q.Query(`SELECT result FROM fleet_operations WHERE action = 'repo_local_start'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var starts []RepoLocalStart
	for rows.Next() {
		var raw string
		var start RepoLocalStart
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err = json.Unmarshal([]byte(raw), &start); err != nil {
			return nil, err
		}
		if start.Repo == repo {
			starts = append(starts, start)
		}
	}
	return starts, rows.Err()
}

// RepoStartRow is one open local start as its journal holds it, plus when it
// last moved: a node settling its own starts (issue #4832) leaves a young one
// alone, it may still be on its way to begin / observe.
type RepoStartRow struct {
	RepoLocalStart
	Updated string `json:"updated"`
}

// RepoOpenStarts lists the starts of repo that still hold something, oldest
// first — the same set repoAuthorityBlockers names as "local start retained".
// owner / endpoint "" = any. Read only: settling goes through RepoLocalStart's
// own actions (cancel · unobserved · stopped), never a write here.
func (s *Store) RepoOpenStarts(repo, owner, endpoint string) ([]RepoStartRow, error) {
	repo = NormRepo(repo)
	rows, err := s.read.Query(`SELECT result, updated FROM fleet_operations WHERE action = 'repo_local_start' ORDER BY updated, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RepoStartRow{}
	for rows.Next() {
		var raw string
		var r RepoStartRow
		if err = rows.Scan(&raw, &r.Updated); err != nil {
			return nil, err
		}
		if err = json.Unmarshal([]byte(raw), &r.RepoLocalStart); err != nil {
			return nil, err
		}
		if r.Repo != repo || repoStartClosed(r.Phase) || (owner != "" && r.Owner != owner) || (endpoint != "" && r.EndpointID != endpoint) {
			continue
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func checkRepoNativeStop(q querier, repo, endpoint string, proof *RepoNativeIdentity) error {
	starts, err := repoLocalStarts(q, repo)
	if err != nil {
		return err
	}
	matched := false
	for _, start := range starts {
		if start.WorkerID != proof.WorkerID || start.Phase == "cancelled" || start.Phase == "abandoned" {
			continue
		}
		if start.Phase == "stopped" && !sameRepoNative(start.Native, proof) {
			continue
		}
		if start.EndpointID != endpoint || !sameRepoNative(start.Native, proof) {
			return ErrTaskFence
		}
		matched = true
	}
	if !matched {
		return ErrTaskFence
	}
	return nil
}

func stopRepoNativeTx(tx *sql.Tx, repo, endpoint string, proof *RepoNativeIdentity, now time.Time) error {
	starts, err := repoLocalStarts(tx, repo)
	if err != nil {
		return err
	}
	for _, start := range starts {
		if start.EndpointID != endpoint || !sameRepoNative(start.Native, proof) {
			continue
		}
		start.Phase = "stopped"
		b, _ := json.Marshal(start)
		sum := sha256.Sum256([]byte(start.Owner + "\x00" + endpoint + "\x00" + repo + "\x00" + start.Reservation))
		if _, err = tx.Exec(`UPDATE fleet_operations SET result = ?, status = 'succeeded', updated = ? WHERE id = ? AND action = 'repo_local_start'`, string(b), now.UTC().Format(rfc), fmt.Sprintf("repo-start:%x", sum[:])); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) RepoLocalStart(repo, owner, endpoint, key, action, worker string, native *RepoNativeIdentity, now time.Time) (RepoLocalStart, error) {
	repo = NormRepo(repo)
	if repo == "" || owner == "" || endpoint == "" || key == "" {
		return RepoLocalStart{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return RepoLocalStart{}, err
	}
	defer tx.Rollback()
	if err = s.lockRepoAuthority(tx, repo); err != nil {
		return RepoLocalStart{}, err
	}
	a, err := readRepoAuthority(tx, repo)
	if err != nil {
		return RepoLocalStart{}, err
	}
	if a.Owner != "" && a.Owner != owner {
		return RepoLocalStart{}, ErrTaskFence
	}
	sum := sha256.Sum256([]byte(owner + "\x00" + endpoint + "\x00" + repo + "\x00" + key))
	id := fmt.Sprintf("repo-start:%x", sum[:])
	var raw string
	err = tx.QueryRow(`SELECT result FROM fleet_operations WHERE id = ? AND action = 'repo_local_start'`, id).Scan(&raw)
	start := RepoLocalStart{Reservation: key, Repo: repo, Owner: owner, EndpointID: endpoint, Phase: "reserved"}
	if errors.Is(err, sql.ErrNoRows) && action == "reserve" {
		if a.Mode != "legacy" {
			return start, ErrRepoAuthority
		}
		b, _ := json.Marshal(start)
		ts := now.UTC().Format(rfc)
		_, err = tx.Exec(`INSERT INTO fleet_operations(id,fleet_id,action,request,actor,idem,status,created,updated,result) VALUES (?, '', 'repo_local_start', ?, ?, ?, 'pending', ?, ?, ?)`, id, string(b), "repo-start:"+endpoint, id, ts, ts, string(b))
		if err != nil {
			return start, err
		}
		return start, tx.Commit()
	}
	if err != nil {
		return start, ErrTaskFence
	}
	if err = json.Unmarshal([]byte(raw), &start); err != nil {
		return start, err
	}
	if start.Repo != repo || start.Owner != owner || start.EndpointID != endpoint {
		return start, ErrTaskFence
	}
	switch action {
	case "reserve":
		// A replay is an identity read; it never re-arms a consumed start.
	case "begin":
		if a.Mode != "legacy" || start.Phase != "reserved" || worker == "" {
			return start, ErrRepoAuthority
		}
		start.WorkerID, start.Phase = worker, "starting"
	case "observe":
		fallthrough
	case "recover-observe":
		if !native.Valid() || native.WorkerID != start.WorkerID || (start.Phase != "starting" && start.Phase != "observed") {
			return start, ErrTaskFence
		}
		if start.Native != nil && !sameRepoNative(start.Native, native) {
			return start, ErrTaskFence
		}
		if action == "recover-observe" {
			if worker != start.WorkerID {
				return start, ErrTaskFence
			}
			if err = recoverRepoStartFence(tx, id, start); err != nil {
				return start, err
			}
			if start.Phase == "observed" {
				return start, nil // exact replay: no timestamp, event or authority write
			}
		}
		start.Native, start.Phase = native, "observed"
	case "stopped":
		if !sameRepoNative(start.Native, native) || (start.Phase != "observed" && start.Phase != "stopped") {
			return start, ErrTaskFence
		}
		start.Phase = "stopped"
	case "cancel":
		// Only a never-begun reservation may be cancelled. A competing begin
		// takes the same lock; after cancel it can never launch.
		if start.Phase != "reserved" && start.Phase != "cancelled" {
			return start, ErrTaskFence
		}
		start.Phase = "cancelled"
	case "unobserved":
		// The supervisor's agent exited and no native was ever observed — a
		// warm Codex window closed before its first turn (Codex runs SessionStart
		// only then), or a refused launch (issue #4792). Only a start with no
		// native bound may end here; a late observe is then fenced, so no
		// unregistered execution ever gets authority. Any authority mode: this
		// only closes, never launches.
		if worker == "" || worker != start.WorkerID || start.Native != nil ||
			(start.Phase != "starting" && start.Phase != "abandoned") {
			return start, ErrTaskFence
		}
		start.Phase = "abandoned"
	default:
		return start, ErrTaskInvalid
	}
	b, _ := json.Marshal(start)
	status := "running"
	if repoStartClosed(start.Phase) {
		status = "succeeded"
	}
	_, err = tx.Exec(`UPDATE fleet_operations SET result = ?, status = ?, updated = ? WHERE id = ?`, string(b), status, now.UTC().Format(rfc), id)
	if err != nil {
		return start, err
	}
	// Save a native binding even if freeze won before the hook was observed.
	// Unknown pre-existing legacy owners remain unbound and cannot be acked.
	if a.Mode == "frozen" && start.Native.Valid() {
		before, _ := json.Marshal(a.Owners)
		rememberOwners(&a, []RepoLegacyOwner{{WorkerID: start.WorkerID, EndpointID: endpoint, Native: start.Native}})
		after, _ := json.Marshal(a.Owners)
		if string(before) != string(after) {
			a.Revision++
			if err = saveRepoAuthority(tx, a, now); err != nil {
				return start, err
			}
		}
	}
	return start, tx.Commit()
}
