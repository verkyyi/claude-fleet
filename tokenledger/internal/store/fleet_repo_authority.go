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

// Repo authority is configuration, not another task store. The existing
// settings registry holds its selection; operations journal every transition.
// Absence is legacy. Merely reading a manifest never inserts a setting.
var ErrRepoAuthority = errors.New("repo authority refuses new dispatch or unsafe cutover")

type RepoAuthority struct {
	Repo          string            `json:"repo"`
	Owner         string            `json:"owner,omitempty"`
	Mode          string            `json:"mode"` // legacy | frozen | hub
	Revision      int64             `json:"revision"`
	LegacyTickets string            `json:"legacy_tickets,omitempty"`
	FrozenAt      time.Time         `json:"frozen_at,omitempty"`
	Owners        []RepoLegacyOwner `json:"legacy_owners,omitempty"`
	Mappings      []RepoTicketMap   `json:"mappings,omitempty"`
}

type RepoLegacyOwner struct {
	WorkerID   string `json:"worker_id"`
	EndpointID string `json:"endpoint_id"`
	Stopped    string `json:"stopped_evidence,omitempty"`
}

type RepoTicketMap struct {
	From       string `json:"from"`
	To         string `json:"to"`
	SourceURL  string `json:"source_url"`
	PayloadSHA string `json:"payload_sha"`
}

type RepoAuthorityChange struct {
	Action        string            `json:"action"` // freeze | apply | rollback | stop_ack
	Revision      int64             `json:"expected_revision"`
	Key           string            `json:"idempotency_key"`
	LegacyTickets string            `json:"legacy_tickets,omitempty"`
	WorkerID      string            `json:"worker_id,omitempty"`
	Evidence      string            `json:"evidence,omitempty"`
	EndpointID    string            `json:"-"` // authenticated node, never caller JSON
	Owners        []RepoLegacyOwner `json:"-"` // current registry inventory
}

func authorityKey(repo string) string { return "task-authority:" + NormRepo(repo) }

func readRepoAuthority(q querier, repo string) (RepoAuthority, error) {
	a := RepoAuthority{Repo: NormRepo(repo), Mode: "legacy"}
	var raw string
	err := q.QueryRow(`SELECT value FROM fleet_settings WHERE key = ?`, authorityKey(repo)).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return a, nil
	}
	if err != nil {
		return a, err
	}
	if err = json.Unmarshal([]byte(raw), &a); err != nil {
		return a, err
	}
	if a.Repo != NormRepo(repo) || (a.Mode != "legacy" && a.Mode != "frozen" && a.Mode != "hub") {
		return a, ErrRepoAuthority
	}
	return a, nil
}

func (s *Store) RepoAuthority(repo string) (RepoAuthority, error) {
	return readRepoAuthority(s.read, repo)
}

// RepoTaskInventory contains identity/outcome only, never request payloads or
// transcripts. Work success and code landing remain separate manifest fields.
func (s *Store) RepoTaskInventory(repo, owner string) ([]map[string]any, error) {
	rows, err := s.read.Query(`SELECT id,authority_version,generation,execution_owner,ticket_ref,outcome,pr,evidence FROM fleet_tasks WHERE repo = ? AND owner = ? ORDER BY id`, NormRepo(repo), owner)
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
	return out, rows.Err()
}

// Serialize authority changes with acceptance, launch journals and lease claims,
// including an absent setting. No default rows are added to unrelated repos.
func (s *Store) lockRepoAuthority(tx *sql.Tx, repo string) error {
	if repo == "" {
		return nil
	}
	return s.d.lockKey(tx, "fleet_settings", authorityKey(repo))
}

func (s *Store) repoStartTx(tx *sql.Tx, repo string, accepted bool) error {
	if repo == "" {
		return nil
	}
	if err := s.lockRepoAuthority(tx, repo); err != nil {
		return err
	}
	a, err := readRepoAuthority(tx, repo)
	if err != nil {
		return err
	}
	if a.Mode == "frozen" || (a.Mode == "hub" && !accepted) {
		return ErrRepoAuthority
	}
	return nil
}

// RepoAuthorityBlockers includes EXPIRED legacy leases and terminal accepted
// tasks with retained execution leases. Neither is proof of native stop.
func repoAuthorityBlockers(q querier, repo string, rollback bool) ([]string, []RepoLegacyOwner, error) {
	blockers, owners := []string{}, []RepoLegacyOwner{}
	rows, err := q.Query(`SELECT worker_id, endpoint_id, task_id FROM fleet_leases WHERE repo = ? OR repo = ? OR task_id IN (SELECT id FROM fleet_tasks WHERE repo = ?)`, repo, "hub:"+repo, repo)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var w, ep string
		var task int64
		if err = rows.Scan(&w, &ep, &task); err != nil {
			rows.Close()
			return nil, nil, err
		}
		if task == 0 {
			owners = append(owners, RepoLegacyOwner{WorkerID: w, EndpointID: ep})
			blockers = append(blockers, "legacy lease: "+w)
		} else if rollback {
			blockers = append(blockers, "execution retained: "+TaskRef(task))
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	rows, err = q.Query(`SELECT id, request FROM fleet_operations WHERE action = 'worker_start' AND status IN ('pending','running','unknown','sent')`)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var id, raw string
		if err = rows.Scan(&id, &raw); err != nil {
			rows.Close()
			return nil, nil, err
		}
		r, _ := repoOfStart(FleetOperation{Action: "worker_start", Request: raw})
		if r == repo {
			blockers = append(blockers, "unsettled start: "+id)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, nil, err
	}
	if rollback {
		rows, err = q.Query(`SELECT id FROM fleet_tasks WHERE repo = ? AND authority_version > 0 AND outcome = ''`, repo)
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

func (s *Store) RepoAuthorityBlockers(repo string, rollback bool) ([]string, []RepoLegacyOwner, error) {
	return repoAuthorityBlockers(s.read, NormRepo(repo), rollback)
}

func rememberOwners(a *RepoAuthority, owners []RepoLegacyOwner) {
	for _, o := range owners {
		found := false
		for _, old := range a.Owners {
			if old.WorkerID == o.WorkerID && old.EndpointID == o.EndpointID {
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

func saveRepoAuthority(tx *sql.Tx, a RepoAuthority, now time.Time) error {
	b, err := json.Marshal(a)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO fleet_settings (key, value, updated) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated = excluded.updated`, authorityKey(a.Repo), string(b), now.UTC().Format(rfc))
	return err
}

func (s *Store) ChangeRepoAuthority(repo, owner string, c RepoAuthorityChange, now time.Time) (RepoAuthority, error) {
	repo = NormRepo(repo)
	if repo == "" || owner == "" || c.Key == "" {
		return RepoAuthority{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return RepoAuthority{}, err
	}
	defer tx.Rollback()
	if err = s.lockRepoAuthority(tx, repo); err != nil {
		return RepoAuthority{}, err
	}
	a, err := readRepoAuthority(tx, repo)
	if err != nil {
		return a, err
	}
	if a.Owner != "" && a.Owner != owner {
		return a, ErrTaskFence
	}
	// Exact replay precedes the revision check. Changed payload/key is refused.
	raw, _ := json.Marshal(struct {
		Change   RepoAuthorityChange
		Endpoint string
	}{c, c.EndpointID})
	actor, idem := "repo-authority:"+owner, repo+":"+c.Key
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
	blockers, owners, err := repoAuthorityBlockers(tx, repo, c.Action == "rollback")
	if err != nil {
		return a, err
	}
	switch c.Action {
	case "freeze":
		if a.Mode != "frozen" {
			if a.Revision == 0 {
				if c.LegacyTickets != "github" && c.LegacyTickets != "hub" {
					return a, ErrTaskInvalid
				}
				a.LegacyTickets = c.LegacyTickets
			}
			a.Mode = "frozen"
			a.FrozenAt = now.UTC()
		}
		rememberOwners(&a, owners)
		rememberOwners(&a, c.Owners)
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
		matched := false
		for i, o := range a.Owners {
			if o.WorkerID == c.WorkerID && o.EndpointID == c.EndpointID {
				a.Owners[i].Stopped = c.Evidence
				matched = true
			}
		}
		if !matched {
			return a, ErrTaskFence
		}
		// An authenticated native-stop receipt releases only this legacy owner.
		_, err = tx.Exec(`DELETE FROM fleet_leases WHERE (repo = ? OR repo = ?) AND worker_id = ? AND endpoint_id = ? AND task_id = 0`, repo, "hub:"+repo, c.WorkerID, c.EndpointID)
		if err != nil {
			return a, err
		}
	default:
		return a, ErrTaskInvalid
	}
	a.Owner = owner
	a.Revision++
	if err = saveRepoAuthority(tx, a, now); err != nil {
		return a, err
	}
	b, _ := json.Marshal(a)
	sum := sha256.Sum256([]byte(actor + "\x00" + idem))
	ts := now.UTC().Format(rfc)
	_, err = tx.Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,result) VALUES (?, '', 'repo_authority', ?, ?, ?, 'succeeded', ?, ?, ?)`, fmt.Sprintf("repo-authority:%x", sum[:]), string(raw), actor, idem, ts, ts, string(b))
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
func (s *Store) AdoptRepoTicket(repo, owner, source, title, body string, revision int64, now time.Time) (RepoTicketMap, error) {
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
	if err = s.lockRepoAuthority(tx, repo); err != nil {
		return RepoTicketMap{}, err
	}
	a, err := readRepoAuthority(tx, repo)
	if err != nil {
		return RepoTicketMap{}, err
	}
	if a.Owner != owner {
		return RepoTicketMap{}, ErrTaskFence
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
	blockers, _, err := repoAuthorityBlockers(tx, repo, false)
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
	if err = saveRepoAuthority(tx, a, now); err != nil {
		return RepoTicketMap{}, err
	}
	return m, tx.Commit()
}
