package store

import (
	"database/sql"
	"regexp"
	"strings"
	"time"
)

// The standing reconcile of the ID mirror (task BCYB). A window that goes away
// without its ledger saying `closed` — a reaper that only marked it retired, a
// test tmux server that lazily opened an ID on the real ledger, a task's
// reserved ID no window ever took — stayed open on the hub for good, and every
// panel that reads the hub counted it. So each node says, on its cleanup tick,
// which IDs its windows carry now (POST /v1/node/ids/live, bin/fleet_id.py
// live); the hub closes every open ID of THAT endpoint the list leaves out —
// once it has been quiet for the grace (a window just spawned may not be in the
// inventory yet) — and the reserved ID of a task that has ended.
//
// A close the hub makes says so: close_reason `hub:gone` · `hub:probe` (a
// probe / 可关 / 空会话 session) · `hub:task-over`. It is never final: an ID a
// later list names again is reopened (a window the node could not see for a
// tick, a move), and a reserved ID a machine takes after all drops its close.
// A node's own close (reaped, exited, stopped …) is never touched.

// IDLiveGrace is how long an absent open ID is left alone before the hub closes it.
const IDLiveGrace = 10 * time.Minute

// IDLiveMax bounds the IDs one live list may name.
const IDLiveMax = 2000

// IDHubClose prefixes every close_reason the hub writes itself.
const IDHubClose = "hub:"

// idProbeRE is a session a person opened to measure or try something — never
// work to keep: a probe, a placement demo, one its title says may be closed.
var idProbeRE = regexp.MustCompile(`(?i)(可关|探针|空会话|放置演示|放置计时|\bprobe\b)`)

// IsProbeTitle reports whether a session's title marks it a probe / drill.
func IsProbeTitle(title string) bool { return idProbeRE.MatchString(title) }

// IDReconciled is one ID a reconcile closed (or would close) or reopened.
type IDReconciled struct {
	ID       string `json:"id"`
	Short    string `json:"short"`
	Machine  string `json:"machine,omitempty"`
	Title    string `json:"title,omitempty"`
	Reason   string `json:"reason"`
	OpenedAt int64  `json:"opened_at,omitempty"`
}

// IDReconcile is a reconcile's answer: what it closed, what it reopened, and
// the endpoint's open IDs it kept (named live or still within the grace).
type IDReconcile struct {
	Closed   []IDReconciled `json:"closed"`
	Reopened []IDReconciled `json:"reopened"`
	Kept     int            `json:"kept"`
	Live     int            `json:"live"`
}

// ReconcileFleetIDs closes the open IDs of one endpoint its live list leaves
// out, the reserved IDs of the owner's ended tasks, and reopens a hub-closed ID
// the list names again. apply false answers the same without writing.
func (s *Store) ReconcileFleetIDs(owner, endpointID string, live []string, now time.Time, grace time.Duration, apply bool) (IDReconcile, error) {
	out := IDReconcile{Closed: []IDReconciled{}, Reopened: []IDReconciled{}}
	in := map[string]bool{}
	for _, id := range live {
		if IsFleetID(id) {
			in[id] = true
		}
	}
	out.Live = len(in)
	tx, err := s.write.Begin()
	if err != nil {
		return out, err
	}
	defer tx.Rollback()
	if apply {
		if err := s.d.lockKey(tx, "fleet_ids", "fleet_ids:"+owner); err != nil {
			return out, err
		}
	}
	type row struct {
		id, short, machine, title, reason, updated string
		opened, closed                             int64
		reserved, ended                            bool
	}
	read := func(q string, args ...any) ([]row, error) {
		rs, err := tx.Query(q, args...)
		if err != nil {
			return nil, err
		}
		defer rs.Close()
		var got []row
		for rs.Next() {
			var r row
			var state sql.NullString
			if err := rs.Scan(&r.id, &r.short, &r.machine, &r.title, &r.reason, &r.updated, &r.opened, &r.closed, &state); err != nil {
				return nil, err
			}
			r.ended = state.Valid && taskFinished(state.String)
			got = append(got, r)
		}
		return got, rs.Err()
	}
	cols := `i.id, i.short, i.machine, i.title, i.close_reason, i.updated_at, i.opened_at, i.closed_at, t.state`
	join := ` FROM fleet_ids i LEFT JOIN fleet_tasks t ON t.fid = i.id AND t.owner = i.owner`
	mine, err := read(`SELECT `+cols+join+` WHERE i.owner = ? AND i.endpoint_id = ? AND i.closed_at = 0`, owner, endpointID)
	if err != nil {
		return out, err
	}
	reserved, err := read(`SELECT `+cols+join+` WHERE i.owner = ? AND i.endpoint_id = '' AND i.seq = 0 AND i.closed_at = 0`, owner)
	if err != nil {
		return out, err
	}
	for i := range reserved {
		reserved[i].reserved = true
	}
	back, err := read(`SELECT `+cols+join+` WHERE i.owner = ? AND i.closed_at > 0 AND i.close_reason LIKE ?`, owner, IDHubClose+"%")
	if err != nil {
		return out, err
	}
	quiet := func(r row) bool {
		if r.opened > now.Add(-grace).Unix() {
			return false
		}
		if u, err := time.Parse(rfc, r.updated); err == nil && u.After(now.Add(-grace)) {
			return false
		}
		return true
	}
	stamp := now.UTC().Format(rfc)
	close := func(r row, why string) error {
		out.Closed = append(out.Closed, IDReconciled{ID: r.id, Short: r.short, Machine: r.machine, Title: r.title, Reason: why, OpenedAt: r.opened})
		if !apply {
			return nil
		}
		_, err := tx.Exec(`UPDATE fleet_ids SET closed_at = ?, close_reason = ?, updated_at = ? WHERE id = ? AND closed_at = 0`,
			now.Unix(), why, stamp, r.id)
		return err
	}
	for _, r := range mine {
		if in[r.id] {
			out.Kept++
			continue
		}
		if !quiet(r) {
			out.Kept++
			continue
		}
		why := IDHubClose + "gone"
		if IsProbeTitle(r.title) {
			why = IDHubClose + "probe"
		}
		if err := close(r, why); err != nil {
			return out, err
		}
	}
	for _, r := range reserved {
		if in[r.id] || !r.ended || !quiet(r) {
			continue
		}
		if err := close(r, IDHubClose+"task-over"); err != nil {
			return out, err
		}
	}
	for _, r := range back {
		if !in[r.id] || !strings.HasPrefix(r.reason, IDHubClose) {
			continue
		}
		out.Reopened = append(out.Reopened, IDReconciled{ID: r.id, Short: r.short, Machine: r.machine, Title: r.title, Reason: r.reason, OpenedAt: r.opened})
		if apply {
			if _, err := tx.Exec(`UPDATE fleet_ids SET closed_at = 0, close_reason = '', updated_at = ? WHERE id = ? AND close_reason = ?`,
				stamp, r.id, r.reason); err != nil {
				return out, err
			}
		}
	}
	if !apply {
		return out, nil
	}
	return out, tx.Commit()
}

// FleetIDOpenCount is how many IDs of an owner are open, per machine ("" =
// reserved, no machine yet) — the doctor's «hub open IDs» beside the windows.
func (s *Store) FleetIDOpenCount(owner string) (map[string]int, error) {
	rs, err := s.read.Query(`SELECT machine, COUNT(*) FROM fleet_ids WHERE owner = ? AND closed_at = 0 GROUP BY machine`, owner)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	got := map[string]int{}
	for rs.Next() {
		var m string
		var n int
		if err := rs.Scan(&m, &n); err != nil {
			return nil, err
		}
		got[m] = n
	}
	return got, rs.Err()
}
