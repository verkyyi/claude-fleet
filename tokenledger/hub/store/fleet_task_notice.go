package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// The completion notice (task T9AQ): a task someone dispatched from a session
// (`task` tool — the record's request_payload names that session's ID as
// from_fid) tells that session when it ends or waits on a person, as ONE
// ordinary cross-machine message — a fleet_relays row, the same road a `send`
// takes. No parent tree, no await, no adoption: the dispatcher gets a line in
// its inbox (or, with no live window, in its login's 「✦ 消息」 —
// fleet-hub-node.sh deliver), and nothing waits on it.
//
// What raises one — every input is an event of the task's own ID ledger, so a
// resend after an outage is a no-op (ApplyFleetIDEvents skips what it has):
//
//	turn    the worker's turn ended (`done`) or a dialog / question holds it
//	        (`waiting`) — bin/fleet_task_notify.py off set-claude-state.sh,
//	        with the reply's first words, PR and artifacts; `mark` names the
//	        reply, so the Stop hook and the agent's own OSC 7501 saying the same
//	        turn is one notice
//	result  an explicit result (succeeded → done, failed → failed)
//	closed  the session closed with no notice sent before it (→ ended)
//
// Exactly-once per state: the relay id is `<from>#tn-<state>-<mark>`, the
// table's primary key; a result / close whose state equals the newest notice's
// is dropped (同一状态去重). A record dispatched with notify=off, one with no
// from_fid (a person's own ⌘P task) or one whose dispatcher's ID belongs to
// another owner raises nothing.
//
// `turn` also writes the record: note = the reply's first words, pr = the PR —
// what `task get` / the lists show after the worker parks.

// Notice states.
const (
	TaskNoticeDone    = "done"
	TaskNoticeWaiting = "waiting"
	TaskNoticeFailed  = "failed"
	// ended: the session closed before any notice — it handed back no result
	TaskNoticeEnded = "ended"
)

// TaskNoticeEndpoint is the from_endpoint of a hub-made notice: no node sends
// it, so no node is owed its receipt.
const TaskNoticeEndpoint = "hub:task-notice"

// TaskNoticeSummaryMax caps the conclusion carried in a notice (runes).
const TaskNoticeSummaryMax = 300

var noticeMarkRE = regexp.MustCompile(`[^A-Za-z0-9]`)

// taskNotice is one notice to raise, folded from an ID event.
type taskNotice struct {
	State     string
	Mark      string
	Summary   string
	PR        string
	Artifacts []string
	// OnlyFirst: raise it only when no notice was sent for the task before
	// (a close after a done says nothing new).
	OnlyFirst bool
	// NewState: raise it only when the newest notice says another state (a
	// result after its turn's done says nothing new). A turn's notice is new
	// per reply (its mark) instead.
	NewState bool
}

func noticeWord(state string) string {
	switch state {
	case TaskNoticeDone:
		return "完成"
	case TaskNoticeWaiting:
		return "等人"
	case TaskNoticeEnded:
		return "结束·没交回结果"
	}
	return "失败"
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	r := []rune(s)
	return string(r[:max]) + "…"
}

// TaskNoticeText is the message a dispatcher reads.
func TaskNoticeText(short, title, state, summary, pr string, artifacts []string, machine string) string {
	var b strings.Builder
	b.WriteString("[任务通知] " + short + " " + noticeWord(state) + " · " + oneLine(title, 80))
	if s := oneLine(summary, TaskNoticeSummaryMax); s != "" {
		label := "结论："
		if state == TaskNoticeWaiting {
			label = "在等："
		}
		b.WriteString("\n" + label + s)
	}
	var arts []string
	if pr != "" {
		arts = append(arts, "PR "+pr)
	}
	for _, a := range artifacts {
		if a = oneLine(a, 200); a != "" && len(arts) < 6 {
			arts = append(arts, a)
		}
	}
	if len(arts) > 0 {
		b.WriteString("\n产物：" + strings.Join(arts, " · "))
	}
	where := ""
	if machine != "" {
		where = "在 " + machine + " · "
	}
	b.WriteString("\n" + where + "全文：fleet-task-record.sh get " + short)
	return b.String()
}

// raiseTaskNotice writes n's relay for the task the ID r carries, inside the
// ID push's transaction. It returns the endpoint to push it down ("" = none).
func raiseTaskNotice(tx *sql.Tx, r *idRow, n taskNotice, now time.Time) (string, error) {
	if n.State != TaskNoticeDone && n.State != TaskNoticeWaiting && n.State != TaskNoticeFailed && n.State != TaskNoticeEnded {
		return "", nil
	}
	var title, payload, pr string
	err := tx.QueryRow(`SELECT title, request_payload, pr FROM fleet_tasks WHERE owner = ? AND fid = ? ORDER BY id DESC LIMIT 1`,
		r.Owner, firstNonEmpty(r.taskID, r.ID)).Scan(&title, &payload, &pr)
	if errors.Is(err, sql.ErrNoRows) && r.taskID != "" {
		err = tx.QueryRow(`SELECT title, request_payload, pr FROM fleet_tasks WHERE owner = ? AND fid = ? ORDER BY id DESC LIMIT 1`,
			r.Owner, r.ID).Scan(&title, &payload, &pr)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil // not a task's session
	}
	if err != nil {
		return "", err
	}
	var p struct {
		FromFID string `json:"from_fid"`
		Notify  string `json:"notify"`
	}
	if json.Unmarshal([]byte(payload), &p) != nil || !IsFleetID(p.FromFID) || p.FromFID == r.ID || p.Notify == "off" {
		return "", nil
	}
	// The dispatcher's ID: the owner's own, and where it lives now.
	var dOwner, dEP string
	err = tx.QueryRow(`SELECT owner, endpoint_id FROM fleet_ids WHERE id = ?`, p.FromFID).Scan(&dOwner, &dEP)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if dOwner != r.Owner || dEP == "" {
		return "", nil
	}
	fleet, err := dispatcherFleet(tx, dEP, p.FromFID)
	if err != nil || fleet == "" {
		return "", err
	}
	from := fleet + "/" + r.ID
	prev := ""
	// the newest notice for this task: a primary-key range, `<from>#tn-…`
	if err := tx.QueryRow(`SELECT id FROM fleet_relays WHERE id >= ? AND id < ? AND from_endpoint = ? ORDER BY created DESC, id DESC LIMIT 1`,
		from+"#tn-", from+"#tn.", TaskNoticeEndpoint).Scan(&prev); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if n.OnlyFirst && prev != "" {
		return "", nil
	}
	prevState := ""
	if _, suf, ok := strings.Cut(prev, "#tn-"); ok {
		prevState, _, _ = strings.Cut(suf, "-")
	}
	mark := noticeMarkRE.ReplaceAllString(n.Mark, "")
	if len(mark) > 40 {
		mark = mark[:40]
	}
	if mark == "" {
		mark = "x"
	}
	id := from + "#tn-" + n.State + "-" + mark
	if n.NewState && prevState == n.State {
		return "", nil // the newest notice already says this state
	}
	if n.PR == "" {
		n.PR = pr
	}
	short := r.Short
	if short == "" {
		short = FleetIDCode(r.ID)
	}
	body, _ := json.Marshal(map[string]any{
		"text": TaskNoticeText(short, title, n.State, n.Summary, n.PR, n.Artifacts, r.Machine),
		"task_notice": map[string]string{"task": short, "fid": r.ID, "state": n.State, "title": oneLine(title, 120)},
	})
	at := now.UTC().Format(rfc)
	res, err := tx.Exec(`INSERT INTO fleet_relays
		(id, kind, from_wid, to_wid, from_endpoint, target_endpoint, payload, status, created, updated)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO NOTHING`,
		id, "message", from, fleet+"/"+p.FromFID, TaskNoticeEndpoint, dEP, string(body), RelayPending, at, at)
	if err != nil {
		return "", err
	}
	if k, _ := res.RowsAffected(); k == 0 {
		return "", nil // the same notice again: a late or repeated event
	}
	return dEP, nil
}

// dispatcherFleet is the fleet on endpoint ep that holds the dispatcher's
// window: the present one listing it, else the present one, else any.
func dispatcherFleet(tx *sql.Tx, ep, fid string) (string, error) {
	rows, err := tx.Query(`SELECT f.fleet_id, f.present, f.workers_json FROM fleet_fleets f
		JOIN fleet_machines m ON m.machine_id = f.machine_id WHERE m.endpoint_id = ?
		ORDER BY f.observed_at DESC, f.fleet_id`, ep)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	best, rank := "", 0
	for rows.Next() {
		var id, workers string
		var present int
		if err := rows.Scan(&id, &present, &workers); err != nil {
			return "", err
		}
		k := 1
		if present == 1 {
			k = 2
			if strings.Contains(workers, fid) {
				k = 3
			}
		}
		if k > rank {
			best, rank = id, k
		}
	}
	return best, rows.Err()
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s != "" {
			return s
		}
	}
	return ""
}

// noticeArtifacts reads an event's artifacts list (strings only, at most 5).
func noticeArtifacts(ev map[string]any) []string {
	var out []string
	if l, ok := ev["artifacts"].([]any); ok {
		for _, v := range l {
			if s, ok := v.(string); ok && strings.TrimSpace(s) != "" && len(out) < 5 {
				out = append(out, oneLine(s, 300))
			}
		}
	}
	return out
}

// noticeOn raises n for the ID r and remembers the endpoint to push to.
func (s *Store) noticeOn(tx *sql.Tx, r *idRow, n taskNotice) error {
	ep, err := raiseTaskNotice(tx, r, n, time.Now())
	if err != nil {
		return err
	}
	if ep != "" {
		r.noticeEPs = append(r.noticeEPs, ep)
	}
	return nil
}

// writeTaskNote writes a turn's conclusion onto the record the ID carries:
// note = the reply's first words, pr = its PR when the record has none.
func writeTaskNote(tx *sql.Tx, r *idRow, note, pr string, now time.Time) error {
	q := `UPDATE fleet_tasks SET note = CASE WHEN ? <> '' THEN ? ELSE note END,
		pr = CASE WHEN ? <> '' THEN ? ELSE pr END, updated_at = ? WHERE owner = ? AND (fid = ?`
	args := []any{note, note, pr, pr, now.UTC().Format(rfc), r.Owner, r.ID}
	if r.taskID != "" && r.taskID != r.ID {
		q += ` OR fid = ?`
		args = append(args, r.taskID)
	}
	_, err := tx.Exec(q+`)`, args...)
	return err
}
