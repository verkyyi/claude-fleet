package api

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The ONE session list (claude-fleet A4G2): the console's 会话 and the ⌘P panel
// used to build two lists — the console off the task records + the hub's
// session list (web-console work.ts), the panel off windows (fleet_view.py) —
// each with its own filter, groups, order and count, so 18 on one read 10 on
// the other at the same minute. The hub now builds the list once, here, and
// hands it inside every fleet_sessions answer (`board`); both sides draw it as
// it is: its rows, their groups, their order, its count.
//
// A row is one piece of work, keyed by its session's ID (the window's
// @fleet_id; a version-1 record's own ID is the same one), else the session's
// worker_id, else the record's: a record and the session doing it are ONE row.
//
//	pin   置顶     the session is pinned (@pin)
//	ask   等你     it asks (needs · blocked), failed, or its record waits on you
//	                (asked, no session); a record that failed / did not start in
//	                the last boardAskFor
//	work  在干活   working · looping
//	queue 排队中   up, waiting on something not you (idle · its turn ended ·
//	                unknown · its record already ended), or a record whose
//	                session is starting / not seen
//	gone  已收起   ended within boardGoneDays: an agent exited with its window
//	                still up, a closed session, a closed record — never counted
//
// Within a group newest first (a session's birth, a record's creation, an end's
// time); an EPIC member right under its parent while both sit in one group.
// count = the rows of pin · ask · work · queue on a machine not lost.

const (
	boardGoneDays = 7
	boardGoneMax  = 300
	boardAskFor   = 24 * time.Hour
)

// BoardRow is one row of the list.
type BoardRow struct {
	ID         string    `json:"id"`
	Code       string    `json:"code,omitempty"`
	Task       string    `json:"task,omitempty"`    // the record's T<n>
	TaskID     string    `json:"task_id,omitempty"` // the record's ID
	Title      string    `json:"title"`
	Group      string    `json:"group"`
	Tag        string    `json:"tag"`
	Words      [2]string `json:"words"` // the tag in 中文 / English, the same on both sides
	State      string    `json:"state,omitempty"`
	WorkerID   string    `json:"worker_id,omitempty"`
	Machine    string    `json:"machine,omitempty"`
	Login      string    `json:"login,omitempty"`
	Repo       string    `json:"repo,omitempty"`
	Parent     string    `json:"parent,omitempty"`
	Depth      int       `json:"depth,omitempty"`
	Lost       bool      `json:"lost,omitempty"`
	At         int64     `json:"at"`
	parentTask string
}

// Board is the list: its rows in order, the count, each group's size.
type Board struct {
	Rows     []BoardRow     `json:"rows"`
	Count    int            `json:"count"`
	Groups   map[string]int `json:"groups"`
	GoneDays int            `json:"gone_days"`
	GoneMore int            `json:"gone_more,omitempty"` // older than the cap, not listed
	Digest   string         `json:"digest"`
}

var boardWords = map[string][2]string{
	"asking": {"在问你", "Asking you"}, "failed": {"没做成", "Failed"}, "refused": {"没开成", "Didn't start"},
	"waiting_you": {"在等你", "Waiting on you"}, "working": {"在干活", "Working"}, "looping": {"在循环", "Looping"},
	"completed": {"已完成", "Completed"}, "cancelled": {"已取消", "Cancelled"}, "turn_done": {"本轮结束", "Turn ended"},
	"idle": {"空闲", "Idle"}, "unknown": {"状态未知", "Unknown"}, "starting": {"正在开", "Starting"},
	"queued": {"排着", "Queued"}, "not_seen": {"看不到会话", "Session not seen"}, "exited": {"已退出", "Exited"},
	"ended": {"已结束", "Ended"}, "ended_no_result": {"结束·没交回结果", "Ended · no result"},
}

var boardGroupOrder = map[string]int{"pin": 0, "ask": 1, "work": 2, "queue": 3, "gone": 4}

// taskEnd is a record's committed end ("" while open) — the console's
// taskStatus: a version-1 record's outcome, an old one's refusal.
func taskEnd(t store.FleetTask) string {
	if t.AuthorityVersion == store.TaskAuthorityVersion {
		switch t.Outcome {
		case store.TaskSucceeded, store.TaskFailed, store.TaskCancelled, store.TaskRefused:
			return t.Outcome
		}
		return ""
	}
	switch t.State {
	case store.TaskRefused, store.TaskClosed:
		return t.State
	}
	return ""
}

func wstr(w map[string]any, k string) string {
	v, _ := w[k].(string)
	return v
}

// buildBoard is the list for owner ("" = the operator's door: everything) over
// the live sessions this answer already holds.
func (s *Server) buildBoard(owner string, live []FleetSession, now time.Time) (*Board, error) {
	since := now.Add(-boardGoneDays * 24 * time.Hour)
	ts, err := s.Store.FleetTasksFor(owner, 500)
	if err != nil {
		return nil, err
	}
	ids, err := s.Store.BoardIDs(owner, since.Unix())
	if err != nil {
		return nil, err
	}
	idBy := map[string]*store.BoardID{}
	for i := range ids {
		idBy[ids[i].ID] = &ids[i]
	}
	byFID, byRef, byWID := map[string]*store.FleetTask{}, map[string]*store.FleetTask{}, map[string]*store.FleetTask{}
	for i := range ts {
		t := &ts[i]
		if t.FID != "" {
			byFID[t.FID] = t
		}
		byRef[t.Ref] = t
		if t.WorkerID != "" {
			byWID[t.WorkerID] = t
		}
	}
	taskOfID := func(b *store.BoardID) *store.FleetTask {
		if b == nil {
			return nil
		}
		if t := byFID[b.ID]; t != nil {
			return t
		}
		if t := byFID[b.TaskID]; t != nil && b.TaskID != "" {
			return t
		}
		return byRef[b.Task]
	}
	var rows []BoardRow
	usedTask, usedID := map[*store.FleetTask]bool{}, map[string]bool{}
	row := func(t *store.FleetTask, b *store.BoardID) BoardRow {
		r := BoardRow{}
		if b != nil {
			r.Code, r.Title, r.Machine, r.Login, r.Repo = b.Short, b.Title, b.Machine, b.Login, b.Repo
		}
		if t != nil {
			r.Task, r.TaskID, r.parentTask = t.Ref, t.FID, t.ParentTask
			if t.Title != "" {
				r.Title = t.Title
			}
			if r.Code == "" {
				r.Code = t.Short
			}
			if r.Repo == "" {
				r.Repo = t.Repo
			}
		}
		return r
	}
	for _, fs := range live {
		w := fs.Worker
		if w == nil || w["test"] == true {
			continue
		}
		ident := identityOf(w)
		wid := ""
		if fs.WorkerID != nil {
			wid = *fs.WorkerID
		}
		b := idBy[ident]
		t := taskOfID(b)
		if t == nil && ident != "" {
			t = byFID[ident]
		}
		if t == nil && wid != "" {
			t = byWID[wid]
		}
		r := row(t, b)
		r.ID = ident
		if r.ID == "" {
			r.ID = wid
		}
		if r.ID == "" {
			continue
		}
		if t != nil {
			if usedTask[t] {
				t = nil // a second window on the same record is its own row
				r.Task, r.TaskID = "", ""
			} else {
				usedTask[t] = true
			}
		}
		usedID[ident] = true
		if r.Title == "" || t == nil {
			if v := wstr(w, "title"); v != "" && t == nil {
				r.Title = v
			}
			if r.Title == "" {
				r.Title = wstr(w, "name")
			}
		}
		if r.Repo == "" {
			r.Repo = wstr(w, "repo")
		}
		r.WorkerID, r.Machine, r.Login = wid, fs.MachineName, fs.OSUser
		r.State = wstr(w, "state")
		r.Lost = fs.Availability == "lost"
		if v, ok := w["born"].(float64); ok {
			r.At = int64(v)
		}
		end := ""
		if t != nil {
			end = taskEnd(*t)
		}
		switch st := r.State; {
		case w["pin"] == true:
			r.Group, r.Tag = "pin", boardStateTag(st)
		case st == "needs" || st == "blocked":
			r.Group, r.Tag = "ask", "asking"
		case st == "failed" || st == "error":
			r.Group, r.Tag = "ask", "failed"
		case st == "exited":
			r.Group, r.Tag = "gone", "exited"
		case end == store.TaskSucceeded:
			r.Group, r.Tag = "queue", "completed"
		case end == store.TaskCancelled:
			r.Group, r.Tag = "queue", "cancelled"
		case st == "working":
			r.Group, r.Tag = "work", "working"
		case st == "looping":
			r.Group, r.Tag = "work", "looping"
		default:
			r.Group, r.Tag = "queue", boardStateTag(st)
		}
		rows = append(rows, r)
	}
	// the records no live session holds
	for i := range ts {
		t := &ts[i]
		if usedTask[t] {
			continue
		}
		b := idBy[t.FID]
		r := row(t, b)
		r.ID = t.FID
		if r.ID == "" {
			r.ID = t.Ref
		}
		r.At = t.CreatedAt.Unix()
		end := taskEnd(*t)
		switch {
		case end == "" && t.Asked != "":
			r.Group, r.Tag = "ask", "waiting_you"
		case end == "" && b != nil && b.Seq > 0 && b.Closed == 0:
			r.Group, r.Tag, r.Lost = "queue", "not_seen", true
		case end == "" && b != nil && b.Seq > 0:
			r.Group, r.Tag, r.At = "gone", "ended_no_result", b.Closed
		case end == "" && t.AuthorityVersion == store.TaskAuthorityVersion:
			r.Group, r.Tag = "queue", "queued"
			if t.State == store.TaskStarting {
				r.Tag = "starting"
			}
		case end == "":
			if t.UpdatedAt.Before(since) {
				continue
			}
			r.Group, r.Tag = "gone", "ended"
		case (end == store.TaskFailed || end == store.TaskRefused) && now.Sub(t.UpdatedAt) < boardAskFor:
			r.Group, r.Tag = "ask", end
		default:
			if t.UpdatedAt.Before(since) {
				continue
			}
			r.Group, r.Tag, r.At = "gone", end, t.UpdatedAt.Unix()
			if end == store.TaskCancelled && strings.HasPrefix(t.Evidence, store.TaskEndedNoResult) {
				r.Tag = "ended_no_result"
			}
			if end == store.TaskClosed {
				r.Tag = "ended"
			}
		}
		if b != nil {
			usedID[b.ID] = true
		}
		rows = append(rows, r)
	}
	// the sessions that ended with no record of theirs listed
	for i := range ids {
		b := &ids[i]
		if usedID[b.ID] || b.Seq == 0 || b.Closed == 0 || b.Closed < since.Unix() {
			continue
		}
		if t := taskOfID(b); t != nil && usedTask[t] {
			continue
		}
		r := row(nil, b)
		r.ID, r.Group, r.Tag, r.At = b.ID, "gone", "ended", b.Closed
		rows = append(rows, r)
	}
	return finishBoard(rows), nil
}

func boardStateTag(st string) string {
	switch st {
	case "working", "looping":
		return st
	case "needs", "blocked":
		return "asking"
	case "done", "landed":
		return "turn_done"
	case "idle", "sleeping":
		return "idle"
	}
	return "unknown"
}

// finishBoard orders the rows, nests an EPIC's members, caps 已收起 and counts.
func finishBoard(rows []BoardRow) *Board {
	sort.SliceStable(rows, func(a, b int) bool {
		ga, gb := boardGroupOrder[rows[a].Group], boardGroupOrder[rows[b].Group]
		if ga != gb {
			return ga < gb
		}
		if rows[a].At != rows[b].At {
			return rows[a].At > rows[b].At
		}
		return rows[a].ID < rows[b].ID
	})
	byTask := map[string]int{}
	for i, r := range rows {
		if r.TaskID != "" {
			byTask[r.TaskID] = i
		}
	}
	kids := map[int][]int{}
	nested := map[int]bool{}
	for i, r := range rows {
		if p, ok := byTask[r.parentTask]; ok && r.parentTask != "" && p != i && rows[p].Group == r.Group {
			kids[p] = append(kids[p], i)
			nested[i] = true
		}
	}
	for i := range rows {
		if p, ok := byTask[rows[i].parentTask]; ok && rows[i].parentTask != "" && p != i {
			rows[i].Parent = rows[p].ID
		}
	}
	out := make([]BoardRow, 0, len(rows))
	var put func(i, depth int)
	put = func(i, depth int) {
		r := rows[i]
		r.Depth = depth
		r.Words = boardWords[r.Tag]
		out = append(out, r)
		for _, k := range kids[i] {
			put(k, depth+1)
		}
	}
	for i := range rows {
		if !nested[i] {
			put(i, 0)
		}
	}
	b := &Board{Groups: map[string]int{}, GoneDays: boardGoneDays}
	gone := 0
	for _, r := range out {
		if r.Group == "gone" {
			gone++
			if gone > boardGoneMax {
				b.GoneMore++
				continue
			}
		}
		b.Rows = append(b.Rows, r)
		b.Groups[r.Group]++
		if r.Group != "gone" && !r.Lost {
			b.Count++
		}
	}
	if b.Rows == nil {
		b.Rows = []BoardRow{}
	}
	h := sha1.New()
	for _, r := range b.Rows {
		h.Write([]byte(r.ID + "\x1f" + r.Group + "\x1f" + r.Tag + "\x1f" + r.Code + "\x1f" + r.Title + "\x1f" + r.Parent + "\n"))
	}
	enc, _ := json.Marshal(b.Groups)
	h.Write(enc)
	b.Digest = hex.EncodeToString(h.Sum(nil))[:12]
	return b
}
