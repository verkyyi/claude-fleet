package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Task authority is configuration, not another task store, and it is a
// PERSON's (claude-fleet#4896): tasks belong to their owner, a repo is only a
// field on one. fleet_settings["task-authority:owner:<owner>"] holds that
// person's selection; operations journal every transition. Absence is legacy.
// Merely reading a manifest never inserts a setting. One person's selection
// never admits, refuses or blocks another person's start, whatever repo the
// two share. The old per-repo rows (task-authority:<repo>) are read as absent.
var ErrRepoAuthority = errors.New("task authority refuses new dispatch or unsafe cutover")

type OwnerAuthority struct {
	Owner    string            `json:"owner"`
	Mode     string            `json:"mode"` // legacy | frozen | hub
	Revision int64             `json:"revision"`
	FrozenAt time.Time         `json:"frozen_at,omitempty"`
	Owners   []RepoLegacyOwner `json:"legacy_owners,omitempty"` // the executions to drain
	Mappings []RepoTicketMap   `json:"mappings,omitempty"`
}

type RepoLegacyOwner struct {
	WorkerID   string              `json:"worker_id"`
	EndpointID string              `json:"endpoint_id"`
	Stopped    string              `json:"stopped_evidence,omitempty"`
	Native     *RepoNativeIdentity `json:"native_identity,omitempty"`
}

// A saved observation, never a PID selected by the stop requester. Each local
// launch reservation may bind this identity only once, from the native hook.
type RepoNativeIdentity struct {
	WorkerID      string `json:"worker_id"`
	NativeSession string `json:"native_session"`
	PID           int    `json:"pid"`
	Birth         string `json:"birth"`
	Executable    string `json:"executable"`
}

func (n *RepoNativeIdentity) Valid() bool {
	return n != nil && n.WorkerID != "" && n.NativeSession != "" && n.PID > 0 && n.Birth != "" && strings.HasPrefix(n.Executable, "/")
}

func sameRepoNative(a, b *RepoNativeIdentity) bool { return a.Valid() && b.Valid() && *a == *b }

type RepoTicketMap struct {
	From       string `json:"from"`
	To         string `json:"to"`
	SourceURL  string `json:"source_url"`
	PayloadSHA string `json:"payload_sha"`
}

type OwnerAuthorityChange struct {
	Action     string            `json:"action"` // freeze | apply | rollback | stop_ack
	Revision   int64             `json:"expected_revision"`
	Key        string            `json:"idempotency_key"`
	WorkerID   string            `json:"worker_id,omitempty"`
	Evidence   string            `json:"evidence,omitempty"`
	EndpointID string            `json:"-"` // authenticated node, never caller JSON
	Owners     []RepoLegacyOwner `json:"-"` // current registry inventory
	Endpoints  []string          `json:"-"` // the owner's endpoints, from the registry
}

func ownerAuthorityKey(owner string) string { return "task-authority:owner:" + owner }

func readOwnerAuthority(q querier, owner string) (OwnerAuthority, error) {
	a := OwnerAuthority{Owner: owner, Mode: "legacy"}
	var raw string
	err := q.QueryRow(`SELECT value FROM fleet_settings WHERE key = ?`, ownerAuthorityKey(owner)).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return a, nil
	}
	if err != nil {
		return a, err
	}
	if err = json.Unmarshal([]byte(raw), &a); err != nil {
		return a, err
	}
	if a.Owner != owner || (a.Mode != "legacy" && a.Mode != "frozen" && a.Mode != "hub") {
		return a, ErrRepoAuthority
	}
	return a, nil
}

// seedNewOwnerAuthority puts a NEW person on the hub (claude-fleet T490):
// hub-coordinated tasks are every account's default, so the row the list's
// first write for them adds says mode=hub at revision 1, journalled as a
// repo_authority operation like any transition, and their hosts are told on
// their first beat. Absence still reads legacy (readOwnerAuthority): an
// account that was on the list before has no setting and keeps it — it is
// cut over (freeze · drain · apply) by its own migration, never here. A person
// who already has a selection, any task record, or anything that would hold a
// cutover is left alone too. Reports whether it wrote.
func (s *Store) seedNewOwnerAuthority(tx *sql.Tx, owner string, now time.Time) (bool, error) {
	if owner == "" {
		return false, nil
	}
	if err := s.lockOwnerAuthority(tx, owner); err != nil {
		return false, err
	}
	var one int
	err := tx.QueryRow(`SELECT 1 FROM fleet_settings WHERE key = ?`, ownerAuthorityKey(owner)).Scan(&one)
	if err == nil {
		return false, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	err = tx.QueryRow(`SELECT 1 FROM fleet_tasks WHERE owner = ? LIMIT 1`, owner).Scan(&one)
	if err == nil {
		return false, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	blockers, _, err := ownerAuthorityBlockers(tx, owner, nil, false)
	if err != nil || len(blockers) > 0 {
		return false, err
	}
	a := OwnerAuthority{Owner: owner, Mode: "hub", Revision: 1}
	if err = saveOwnerAuthority(tx, a, now); err != nil {
		return false, err
	}
	b, _ := json.Marshal(a)
	actor, idem := "task-authority:"+owner, "owner:account-created"
	sum := sha256.Sum256([]byte(actor + "\x00" + idem))
	ts := now.UTC().Format(rfc)
	_, err = tx.Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,result) VALUES (?, '', 'repo_authority', ?, ?, ?, 'succeeded', ?, ?, ?)`,
		fmt.Sprintf("task-authority:%x", sum[:]), `{"Change":{"action":"account_created"}}`, actor, idem, ts, ts, string(b))
	return err == nil, err
}

// OwnerAuthority is owner's selection; legacy at revision 0 when none.
func (s *Store) OwnerAuthority(owner string) (OwnerAuthority, error) {
	return readOwnerAuthority(s.read, owner)
}

// RepoTaskInventory contains identity/outcome only, never request payloads or
// transcripts. Work success and code landing remain separate manifest fields.
// repo "" lists every task of owner's (the per-person manifest).
func (s *Store) RepoTaskInventory(repo, owner string) ([]map[string]any, error) {
	rows, err := s.read.Query(`SELECT id,authority_version,generation,execution_owner,ticket_ref,outcome,pr,evidence FROM fleet_tasks WHERE (repo = ? OR ? = '') AND owner = ? ORDER BY id`, NormRepo(repo), NormRepo(repo), owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, generation int64
		var version int
		var worker, ref, outcome, pr, evidence string
		if err = rows.Scan(&id, &version, &generation, &worker, &ref, &outcome, &pr, &evidence); err != nil {
			return nil, err
		}
		var proof map[string]any
		_ = json.Unmarshal([]byte(evidence), &proof)
		landing := "unverified"
		if state, ok := proof["pr_state"].(string); ok && (state == "waiting" || state == "merged" || state == "none") {
			landing = state
		}
		if p, ok := proof["pr"].(string); ok && p != "" {
			pr = p
		}
		out = append(out, map[string]any{"task": TaskRef(id), "authority_version": version, "generation": generation, "worker_id": worker, "ticket_ref": ref, "work_outcome": outcome, "pr": pr, "pr_state": landing})
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	// A later confirmed code landing is already recorded as an owner-fenced
	// task_report. Project it independently of the immutable terminal outcome;
	// neither a waiting report nor an earlier generation can overwrite it.
	byRef := map[string]map[string]any{}
	for _, item := range out {
		byRef[item["task"].(string)] = item
	}
	reports, err := s.read.Query(`SELECT result FROM fleet_operations WHERE action = 'task_report' AND actor = ? ORDER BY created`, owner)
	if err != nil {
		return nil, err
	}
	defer reports.Close()
	for reports.Next() {
		var raw string
		var receipt TaskReportReceipt
		if err = reports.Scan(&raw); err != nil {
			return nil, err
		}
		if json.Unmarshal([]byte(raw), &receipt) != nil {
			return nil, ErrTaskInvalid
		}
		r := receipt.Report
		item := byRef[r.Task]
		if item == nil || r.Generation != item["generation"] || r.WorkerID != item["worker_id"] || r.TicketRef != item["ticket_ref"] || r.Status != "merged" {
			continue
		}
		var proof map[string]any
		if json.Unmarshal([]byte(r.Evidence), &proof) != nil || proof["pr_state"] != "merged" {
			continue
		}
		pr, ok := proof["pr"].(string)
		if !ok || pr == "" || (item["pr"] != "" && item["pr"] != pr) {
			continue
		}
		item["pr"], item["pr_state"] = pr, "merged"
	}
	return out, reports.Err()
}

// Serialize authority changes with acceptance, launch journals and lease claims
// of the SAME person, including an absent setting. Two people never wait on
// each other's key. No default rows are added for anyone.
func (s *Store) lockOwnerAuthority(tx *sql.Tx, owner string) error {
	if owner == "" {
		return nil
	}
	return s.d.lockKey(tx, "fleet_settings", ownerAuthorityKey(owner))
}

// ownerStartTx admits one start of owner's: frozen refuses every start, hub
// only an accepted one. owner "" (an internal caller with no person) consults
// no authority.
func (s *Store) ownerStartTx(tx *sql.Tx, owner string, accepted bool) error {
	if owner == "" {
		return nil
	}
	if err := s.lockOwnerAuthority(tx, owner); err != nil {
		return err
	}
	a, err := readOwnerAuthority(tx, owner)
	if err != nil {
		return err
	}
	if a.Mode == "frozen" || (a.Mode == "hub" && !accepted) {
		return ErrRepoAuthority
	}
	return nil
}

func inSet(set []string, v string) bool {
	for _, x := range set {
		if x != "" && x == v {
			return true
		}
	}
	return false
}

// ownerAuthorityBlockers is what still holds owner's cutover, and ONLY owner's:
// their local starts, their legacy leases (account_owner, else one held on one
// of their endpoints), their unfinished v0 T, their unsettled worker_starts
// (task_owner, else the actor or the fleet's endpoint) and, for a rollback,
// their accepted work. It includes EXPIRED legacy leases and terminal accepted
// tasks with retained execution leases: neither is proof of native stop.
func ownerAuthorityBlockers(q querier, owner string, endpoints []string, rollback bool) ([]string, []RepoLegacyOwner, error) {
	blockers, owners := []string{}, []RepoLegacyOwner{}
	starts, err := localStarts(q, func(st RepoLocalStart) bool { return st.Owner == owner })
	if err != nil {
		return nil, nil, err
	}
	for _, start := range starts {
		if repoStartClosed(start.Phase) {
			continue
		}
		blockers = append(blockers, "local start retained: "+start.Reservation)
		if start.WorkerID != "" {
			owners = append(owners, RepoLegacyOwner{WorkerID: start.WorkerID, EndpointID: start.EndpointID, Native: start.Native})
		}
	}
	rows, err := q.Query(`SELECT l.worker_id, l.endpoint_id, l.task_id, l.account_owner, COALESCE(t.owner, '') FROM fleet_leases l LEFT JOIN fleet_tasks t ON t.id = l.task_id AND l.task_id <> 0`)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var w, ep, account, taskOwner string
		var task int64
		if err = rows.Scan(&w, &ep, &task, &account, &taskOwner); err != nil {
			rows.Close()
			return nil, nil, err
		}
		if task == 0 {
			if account == owner || (account == "" && inSet(endpoints, ep)) {
				owners = append(owners, RepoLegacyOwner{WorkerID: w, EndpointID: ep})
				blockers = append(blockers, "legacy lease: "+w)
			}
		} else if rollback && taskOwner == owner {
			blockers = append(blockers, "execution retained: "+TaskRef(task))
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	// Legacy placement records can retain an owner even after both its lease
	// and snapshot disappear. An unfinished T is not an empty-inventory proof;
	// one settled on evidence (TaskClosed, claude-fleet#4867) is ended.
	rows, err = q.Query(`SELECT worker_id FROM fleet_tasks WHERE owner = ? AND authority_version = 0 AND worker_id <> '' AND state NOT IN (?, ?)`, owner, TaskClosed, TaskRefused)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var worker string
		if err = rows.Scan(&worker); err != nil {
			rows.Close()
			return nil, nil, err
		}
		blockers = append(blockers, "legacy task owner is unverified: "+worker)
		owners = append(owners, RepoLegacyOwner{WorkerID: worker})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	rows, err = q.Query(`SELECT o.id, o.actor, o.task_owner, COALESCE(m.endpoint_id, '') FROM fleet_operations o
		  LEFT JOIN fleet_fleets f ON f.fleet_id = o.fleet_id
		  LEFT JOIN fleet_machines m ON m.machine_id = f.machine_id
		 WHERE o.action = 'worker_start' AND o.status IN ('pending','running','unknown','sent')`)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id, actor, taskOwner, ep string
		if err = rows.Scan(&id, &actor, &taskOwner, &ep); err != nil {
			rows.Close()
			return nil, nil, err
		}
		// A start journalled before task_owner existed is its actor's, else
		// the person's whose endpoint it was sent to.
		if taskOwner == owner || (taskOwner == "" && (actor == owner || inSet(endpoints, ep))) {
			blockers = append(blockers, "unsettled start: "+id)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	if rollback {
		rows, err = q.Query(`SELECT id FROM fleet_tasks WHERE owner = ? AND authority_version > 0 AND outcome = ''`, owner)
		if err != nil {
			return nil, nil, err
		}
		for rows.Next() {
			var id int64
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return nil, nil, err
			}
			blockers = append(blockers, "accepted work: "+TaskRef(id))
		}
		err = rows.Err()
		rows.Close()
	}
	return blockers, owners, err
}

// OwnerAuthorityBlockers is ownerAuthorityBlockers on the read pool. endpoints
// are the owner's own endpoints, read from the registry by the caller.
func (s *Store) OwnerAuthorityBlockers(owner string, endpoints []string, rollback bool) ([]string, []RepoLegacyOwner, error) {
	return ownerAuthorityBlockers(s.read, owner, endpoints, rollback)
}

func rememberOwners(a *OwnerAuthority, owners []RepoLegacyOwner) {
	for _, o := range owners {
		found := false
		for i, old := range a.Owners {
			if old.WorkerID == o.WorkerID && old.EndpointID == o.EndpointID {
				if o.Native.Valid() && !sameRepoNative(old.Native, o.Native) {
					a.Owners[i].Native = o.Native
					a.Owners[i].Stopped = ""
				}
				found = true
				break
			}
		}
		if !found {
			o.Stopped = ""
			a.Owners = append(a.Owners, o)
		}
	}
}

func saveOwnerAuthority(tx *sql.Tx, a OwnerAuthority, now time.Time) error {
	b, err := json.Marshal(a)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO fleet_settings (key, value, updated) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated = excluded.updated`, ownerAuthorityKey(a.Owner), string(b), now.UTC().Format(rfc))
	return err
}

// ChangeOwnerAuthority moves owner's own selection: freeze → (stop_ack each
// drained execution) → apply, or freeze → rollback. CAS on the revision, an
// idempotency key per owner (an exact replay returns the first answer, a
// changed one conflicts), journalled as a repo_authority operation.
func (s *Store) ChangeOwnerAuthority(owner string, c OwnerAuthorityChange, now time.Time) (OwnerAuthority, error) {
	if owner == "" || c.Key == "" {
		return OwnerAuthority{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return OwnerAuthority{}, err
	}
	defer tx.Rollback()
	if err = s.lockOwnerAuthority(tx, owner); err != nil {
		return OwnerAuthority{}, err
	}
	a, err := readOwnerAuthority(tx, owner)
	if err != nil {
		return a, err
	}
	// Exact replay precedes the revision check. Changed payload/key is refused.
	raw, _ := json.Marshal(struct {
		Change   OwnerAuthorityChange
		Endpoint string
	}{c, c.EndpointID})
	actor, idem := "task-authority:"+owner, "owner:"+c.Key
	var request, result string
	err = tx.QueryRow(`SELECT request, result FROM fleet_operations WHERE actor = ? AND idem = ?`, actor, idem).Scan(&request, &result)
	if err == nil {
		if request != string(raw) {
			return a, ErrTaskConflict
		}
		if err = json.Unmarshal([]byte(result), &a); err != nil {
			return a, err
		}
		return a, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return a, err
	}
	if a.Revision != c.Revision {
		return a, ErrTaskConflict
	}
	blockers, owners, err := ownerAuthorityBlockers(tx, owner, c.Endpoints, c.Action == "rollback")
	if err != nil {
		return a, err
	}
	switch c.Action {
	case "freeze":
		// An old native without a saved binding has no safe stop_ack road.
		// Refuse BEFORE changing authority, so its existing owner can drain on
		// the legacy road and retry preflight. Never create a permanent freeze.
		next := a
		next.Owners = append([]RepoLegacyOwner(nil), a.Owners...)
		rememberOwners(&next, owners)
		rememberOwners(&next, c.Owners)
		for _, o := range next.Owners {
			if o.Stopped == "" && !o.Native.Valid() {
				return a, fmt.Errorf("%w: drain/reconcile unbound legacy execution %s before freeze", ErrRepoAuthority, o.WorkerID)
			}
		}
		a = next
		if a.Mode != "frozen" {
			a.Mode = "frozen"
			a.FrozenAt = now.UTC()
		}
	case "apply", "rollback":
		want := "hub"
		if c.Action == "rollback" {
			want = "legacy"
		}
		if a.Mode != want {
			if a.Mode != "frozen" || len(blockers) > 0 {
				return a, ErrRepoAuthority
			}
			for _, o := range a.Owners {
				if o.Stopped == "" {
					return a, ErrRepoAuthority
				}
			}
			if len(c.Owners) > 0 {
				return a, ErrRepoAuthority
			}
			a.Mode = want
		}
	case "stop_ack":
		if a.Mode != "frozen" || c.EndpointID == "" || c.WorkerID == "" || c.Evidence == "" {
			return a, ErrTaskInvalid
		}
		var proof struct {
			RepoNativeIdentity
			Stopped bool `json:"execution_stopped"`
		}
		if json.Unmarshal([]byte(c.Evidence), &proof) != nil || !proof.Stopped || !proof.RepoNativeIdentity.Valid() || proof.WorkerID != c.WorkerID {
			return a, ErrTaskFence
		}
		// The operation journal is the saved native observation. A missing,
		// unbound or replacement execution cannot be released by an old receipt.
		if err = checkRepoNativeStop(tx, owner, c.EndpointID, &proof.RepoNativeIdentity); err != nil {
			return a, err
		}
		matched := false
		for i, o := range a.Owners {
			if o.WorkerID == c.WorkerID && o.EndpointID == c.EndpointID {
				if !sameRepoNative(o.Native, &proof.RepoNativeIdentity) {
					return a, ErrTaskFence
				}
				a.Owners[i].Stopped = c.Evidence
				matched = true
			}
		}
		if !matched {
			return a, ErrTaskFence
		}
		if err = stopRepoNativeTx(tx, owner, c.EndpointID, &proof.RepoNativeIdentity, now); err != nil {
			return a, err
		}
		// An authenticated native-stop receipt releases only this legacy owner.
		_, err = tx.Exec(`DELETE FROM fleet_leases WHERE worker_id = ? AND endpoint_id = ? AND task_id = 0`, c.WorkerID, c.EndpointID)
		if err != nil {
			return a, err
		}
	default:
		return a, ErrTaskInvalid
	}
	a.Revision++
	if err = saveOwnerAuthority(tx, a, now); err != nil {
		return a, err
	}
	b, _ := json.Marshal(a)
	sum := sha256.Sum256([]byte(actor + "\x00" + idem))
	ts := now.UTC().Format(rfc)
	_, err = tx.Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,result) VALUES (?, '', 'repo_authority', ?, ?, ?, 'succeeded', ?, ?, ?)`, fmt.Sprintf("task-authority:%x", sum[:]), string(raw), actor, idem, ts, ts, string(b))
	if err != nil {
		return a, err
	}
	return a, tx.Commit()
}

// Gate journals too: a legacy scratch has no issue lease. The operation and
// authority change must not pass each other between the API check and send.
func repoOfStart(o FleetOperation) (string, bool) {
	if o.Action != "worker_start" {
		return "", false
	}
	var r struct {
		Params struct {
			Repo     string `json:"repo"`
			Dispatch *struct {
				Task string `json:"task"`
			} `json:"dispatch"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(o.Request), &r) != nil {
		return "", false
	}
	return NormRepo(r.Params.Repo), r.Params.Dispatch != nil && strings.HasPrefix(r.Params.Dispatch.Task, "T")
}

// AdoptRepoTicket copies only an explicitly selected backlog item. It never
// takes over a running executor, imports its number, or writes to GitHub.
// The mapping and independently allocated hub ticket commit together.
// The mapping is kept on owner's authority, and owner's cutover must be
// drained (endpoints: the owner's own, as for OwnerAuthorityBlockers).
func (s *Store) AdoptRepoTicket(repo, owner string, endpoints []string, source, title, body string, revision int64, now time.Time) (RepoTicketMap, error) {
	repo = NormRepo(repo)
	r, n, ok := splitGHID(source)
	if !ok || r != repo || title == "" {
		return RepoTicketMap{}, ErrTaskInvalid
	}
	source = TicketRef(TicketGitHub, repo, n)
	payload, _ := json.Marshal([]string{source, title, body})
	sum := sha256.Sum256(payload)
	digest := fmt.Sprintf("%x", sum[:])
	tx, err := s.write.Begin()
	if err != nil {
		return RepoTicketMap{}, err
	}
	defer tx.Rollback()
	if err = s.lockOwnerAuthority(tx, owner); err != nil {
		return RepoTicketMap{}, err
	}
	a, err := readOwnerAuthority(tx, owner)
	if err != nil {
		return RepoTicketMap{}, err
	}
	for _, m := range a.Mappings {
		if m.From == source {
			if m.PayloadSHA != digest {
				return RepoTicketMap{}, ErrTaskConflict
			}
			return m, tx.Commit()
		}
	}
	if a.Revision != revision || (a.Mode != "hub" && a.Mode != "frozen") {
		return RepoTicketMap{}, ErrRepoAuthority
	}
	blockers, _, err := ownerAuthorityBlockers(tx, owner, endpoints, false)
	if err != nil {
		return RepoTicketMap{}, err
	}
	if len(blockers) > 0 {
		return RepoTicketMap{}, ErrRepoAuthority
	}
	for _, o := range a.Owners {
		if o.Stopped == "" {
			return RepoTicketMap{}, ErrRepoAuthority
		}
	}
	if len(a.Mappings) >= 1000 {
		return RepoTicketMap{}, errors.New("selective adoption limit reached")
	}
	var previousOwner string
	err = tx.QueryRow(`SELECT owner FROM fleet_tickets WHERE repo = ? AND num = ? AND backend = 'gh'`, repo, n).Scan(&previousOwner)
	if err == nil && previousOwner != owner {
		return RepoTicketMap{}, ErrTaskFence
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return RepoTicketMap{}, err
	}
	// The original reference registry is keyed by full ID, so gh:r#7 and
	// hub:r#7 retain independent identities even if the local row is occupied.
	err = tx.QueryRow(`SELECT owner FROM fleet_ticket_index WHERE id = ?`, source).Scan(&previousOwner)
	if err == nil && previousOwner != owner {
		return RepoTicketMap{}, ErrTaskFence
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return RepoTicketMap{}, err
	}
	url := "https://github.com/" + repo + "/issues/" + fmt.Sprint(n)
	ts := now.UTC().Format(rfc)
	_, err = tx.Exec(`INSERT INTO fleet_ticket_index (id,owner,title,state,backend,url,origin,endpoint_id,created_at,updated_at) VALUES (?, ?, ?, 'open', 'gh', ?, '', '', ?, ?) ON CONFLICT(id) DO NOTHING`, source, owner, title, url, ts, ts)
	if err != nil {
		return RepoTicketMap{}, err
	}
	allocated, err := s.createFleetTicketTx(tx, FleetTicket{Repo: repo, Owner: owner, Title: title, Body: body}, 0, now)
	if err != nil {
		return RepoTicketMap{}, err
	}
	m := RepoTicketMap{From: source, To: TicketRef(TicketHub, repo, allocated), SourceURL: url, PayloadSHA: digest}
	a.Mappings = append(a.Mappings, m)
	a.Revision++
	if err = saveOwnerAuthority(tx, a, now); err != nil {
		return RepoTicketMap{}, err
	}
	return m, tx.Commit()
}
