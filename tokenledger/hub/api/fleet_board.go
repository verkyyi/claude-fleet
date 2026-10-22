package api

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
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
//	ask   等你     it asks (needs · blocked), its agent failed, its agent's error
//	                stopped it (E101: exited on a 7501 error, the node's reap_why
//	                error*), or it waits on you — its record asked, or the node
//	                says its ID's result waits (reap_why waiting), with or without
//	                a session; a record parked (停放) with no session; a record that
//	                failed or did not start with no session left is 已收起 (the ✦
//	                messages say it). Waiting and parked rows sit above the rest.
//	work  在干活   working · looping
//	queue 待派发/保留   up, waiting on something not you (idle · its turn ended ·
//	                unknown · its record already ended), or a record whose
//	                session is starting / not seen
//	gone  已收起   ended within boardGoneDays: an agent exited with its window
//	                still up, a closed session, a closed record, a session on a
//	                machine lost past boardLostAfter — never counted
//
// Within a group newest first (a session's birth, a record's creation, an end's
// time); an EPIC member right under its parent while both sit in one group.
// count = the rows of pin · ask · work · queue on a machine not lost.

const (
	boardGoneDays = 7
	boardGoneMax  = 300
	// boardLostAfter: a session last heard on a machine lost this long is put
	// away (gone · lost), never left in 排队中 (T859: a deleted drill login's
	// last inventory sat there for nine days, 21 rows); past boardGoneDays it is
	// not listed. A machine back within it keeps its rows where they were.
	boardLostAfter = 6 * time.Hour
)

// BoardRow is one row of the list.
type BoardRow struct {
	// Agent is accompanied by its evidence basis; planned never means actual.
	Agent       string    `json:"agent,omitempty"`
	AgentBasis  string    `json:"agent_basis,omitempty"`
	AgentWords  [2]string `json:"agent_words"`
	Context     [2]string `json:"context"`
	Coordinator string    `json:"coordinator,omitempty"`
	Outcome     string    `json:"outcome,omitempty"`

	ID       string    `json:"id"`
	Code     string    `json:"code,omitempty"`
	Task     string    `json:"task,omitempty"`    // the record's T<n>
	TaskID   string    `json:"task_id,omitempty"` // the record's ID
	Title    string    `json:"title"`
	Group    string    `json:"group"`
	Tag      string    `json:"tag"`
	Words    [2]string `json:"words"` // the tag in 中文 / English, the same on both sides
	State    string    `json:"state,omitempty"`
	WorkerID string    `json:"worker_id,omitempty"`
	Machine  string    `json:"machine,omitempty"`
	Login    string    `json:"login,omitempty"`
	Repo     string    `json:"repo,omitempty"`
	Parent   string    `json:"parent,omitempty"`
	Depth    int       `json:"depth,omitempty"`
	Lost     bool      `json:"lost,omitempty"`
	At       int64     `json:"at"`
	// Why it is still open (E101), 中文 / English, and its tone — grey · orange ·
	// red: the node's reap_why turned into the card's third line, ONE source for
	// the console and the ⌘P panel. Only on 等你 / 排队中 rows; none when nothing
	// holds it (or an older node says nothing).
	Why     []string `json:"why,omitempty"`
	WhyTone string   `json:"why_tone,omitempty"`
	// 会话合一 (task PQ41): where the session was opened — web (the person's web
	// page opened it: the node's @session_origin) or terminal (anything else) —
	// and whether the web may talk to it now (a live session on a machine not
	// lost, not ended: a terminal one too, by default). A record with no session
	// has neither.
	Origin     string `json:"origin,omitempty"`
	CanTalk    bool   `json:"can_talk"`
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
	// Machines is how many machines the person has (task PQ41): one ⇒ the page
	// names none (a machine's name is only in a session's details then).
	Machines int `json:"machines"`
}

var boardWords = map[string][2]string{
	"asking": {"在问你", "Asking you"}, "failed": {"没做成", "Failed"}, "refused": {"没开成", "Didn't start"},
	"waiting_you": {"在等你", "Waiting on you"}, "working": {"在干活", "Working"}, "looping": {"在循环", "Looping"},
	"completed": {"已完成", "Completed"}, "cancelled": {"已取消", "Cancelled"}, "turn_done": {"本轮结束", "Turn ended"},
	"retained_completed": {"已完成 · 待回收", "Completed · retained"}, "session_parked": {"已停放", "Parked"},
	"idle": {"空闲", "Idle"}, "unknown": {"状态未知", "Unknown"}, "starting": {"正在开", "Starting"},
	"queued": {"未派发", "Not dispatched"}, "not_seen": {"看不到会话", "Session not seen"}, "exited": {"已退出", "Exited"},
	"ended": {"已结束", "Ended"}, "ended_no_result": {"结束·没交回结果", "Ended · no result"},
	"lost":   {"机器失联", "Machine lost"},
	"parked": {"已停放 · 等你", "Parked · waiting on you"}, "stopped": {"出错停住", "Stopped on an error"},
}

// boardWhy turns a node's reap_why (`<code>[:<epoch>]`, bin/fleet-cleanup-idle.py)
// into the card's line (E101's copy table, letter for letter) and its tone. N is
// counted to the epoch at this answer, never below 1. An unknown code says nothing.
func boardWhy(raw string, now time.Time) ([]string, string) {
	code, at := raw, int64(0)
	if i := strings.IndexByte(raw, ':'); i >= 0 {
		code = raw[:i]
		at, _ = strconv.ParseInt(raw[i+1:], 10, 64)
	}
	left := at - now.Unix()
	mins, hours := (left+59)/60, (left+3599)/3600
	if mins < 1 {
		mins = 1
	}
	if hours < 1 {
		hours = 1
	}
	two := func(zh, en string) []string { return []string{zh, en} }
	switch code {
	case "watched":
		return two("先不停放：有人正在看", "Not parking: someone is looking"), "grey"
	case "draft":
		return two("先不停放：输入框有草稿", "Not parking: a draft is in the input box"), "grey"
	case "park-bg":
		return two("先不停放：后台的活还在跑", "Not parking: background work is still running"), "grey"
	case "asking":
		return two("先不停放：选择框还开着", "Not parking: a choice dialog is open"), "grey"
	case "old-wrapper":
		return two("先不停放：旧外壳尚不支持", "Not parking: this older wrapper does not support it"), "grey"
	case "park-gate":
		return two("先不停放：尚未确认能安全停下", "Not parking: safe parking is not yet confirmed"), "grey"
	case "bg":
		return two(fmt.Sprintf("还没收：做完了，后台的活还在跑 · %d 分钟后收", mins),
			fmt.Sprintf("Not closed yet: done, but a background job is still running · closes in %d min", mins)), "grey"
	case "timer":
		return two(fmt.Sprintf("还没收：计时中 · %d 分钟后收", mins), fmt.Sprintf("Not closed yet: closes in %d min", mins)), "grey"
	case "dirty":
		return two("不会自动收：有没提交的改动", "Won't close on its own: uncommitted changes"), "grey"
	case "keep":
		return two("不会自动收：你设了保留", "Won't close on its own: kept by you"), "grey"
	case "task-open":
		return two("还没收：任务还没收口", "Not closed yet: its task is still open"), "grey"
	case "live":
		return two("先不收：有人正在看或在输入", "Not now: someone is looking or typing"), "grey"
	case "moving":
		return two("先不收：正在换机器", "Not now: moving to another machine"), "grey"
	case "waiting":
		return two(fmt.Sprintf("在等你回话 · %d 小时后停放，回话即唤醒", hours),
			fmt.Sprintf("Waiting for your reply · parks in %d h — reply to wake it", hours)), "orange"
	case "parked":
		return two("已停放 · 在等你点头，回话即唤醒", "Parked · waiting for your go-ahead — reply to wake it"), "orange"
	case "error-retry":
		return two(fmt.Sprintf("出错停住：服务端临时出错 · %d 分钟后自动重试", mins),
			fmt.Sprintf("Stopped on an error: a temporary server error · retrying in %d min", mins)), "red"
	case "error-retried":
		return two("出错停住：自动重试过 1 次仍出错 · 要你看一下", "Stopped on an error: retried once, still failing · needs a look"), "red"
	case "error":
		return two("出错停住：要你看一下", "Stopped on an error: needs a look"), "red"
	}
	return nil, ""
}

// boardAskRank: within 等你, a session waiting on its person's reply (asking ·
// waiting · parked) sits above a failed or stopped one (E101's list).
func boardAskRank(tag string) int {
	switch tag {
	case "asking", "waiting_you", "parked":
		return 0
	}
	return 1
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
		if t.State == store.TaskClosed {
			return store.TaskClosed // a settled record (fleet_task_settle), whatever its outcome word
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
			r.Agent = b.Agent
			if r.Agent != "" {
				r.AgentBasis = "native"
			}
		}
		if t != nil {
			r.Task, r.TaskID, r.parentTask = t.Ref, t.FID, t.ParentTask
			r.Outcome = taskEnd(*t)
			if r.Agent == "" && t.ActualAgent != "" {
				r.Agent, r.AgentBasis = t.ActualAgent, "actual"
			}
			p := byFID[t.ParentTask]
			if p == nil {
				p = byRef[t.ParentTask]
			}
			if p != nil && p != t {
				r.Coordinator = p.Short
				if r.Coordinator == "" {
					r.Coordinator = p.Ref
				}
			}
			if r.Coordinator == "" && t.ParentSession != "" {
				id := t.ParentSession
				if i := strings.LastIndexByte(id, '/'); i >= 0 {
					id = id[i+1:]
				}
				if parent := idBy[id]; parent != nil {
					r.Coordinator = parent.Short
				}
			}
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
		lostFor := fs.Availability == "lost" && !fs.ObservedAt.IsZero() && now.Sub(fs.ObservedAt) > boardLostAfter
		if lostFor && fs.ObservedAt.Before(since) {
			continue // not listed; its record (if any) is listed on its own below
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
		// Inventory is runtime evidence; a native ledger segment is preferred.
		if r.Agent == "" && wstr(w, "agent") != "" {
			r.Agent, r.AgentBasis = wstr(w, "agent"), "runtime"
		}
		r.Lost = fs.Availability == "lost"
		if v, ok := w["born"].(float64); ok {
			r.At = int64(v)
		}
		end := ""
		if t != nil {
			end = taskEnd(*t)
		}
		why := wstr(w, "reap_why")
		code := why
		if i := strings.IndexByte(why, ':'); i >= 0 {
			code = why[:i]
		}
		switch st := r.State; {
		case lostFor:
			r.Group, r.Tag, r.At = "gone", "lost", fs.ObservedAt.Unix()
		case w["pin"] == true:
			r.Group, r.Tag = "pin", boardStateTag(st)
		case st == "needs" || st == "blocked":
			r.Group, r.Tag = "ask", "asking"
		case st == "failed" || st == "error":
			r.Group, r.Tag = "ask", "failed"
		case st == "exited" && strings.HasPrefix(code, "error"):
			// its agent's error stopped it, its window still up (E101: FQBW sat 16 h
			// in 已收起): yours to look at, or the wrapper's one retry to come
			r.Group, r.Tag = "ask", "stopped"
		case st == "exited":
			r.Group, r.Tag = "gone", "exited"
		case st == "working":
			r.Group, r.Tag = "work", "working"
		case st == "looping":
			r.Group, r.Tag = "work", "looping"
		case end == store.TaskSucceeded:
			r.Group, r.Tag = "queue", "retained_completed"
		case end == store.TaskCancelled:
			r.Group, r.Tag = "queue", "cancelled"
		case end == "" && (code == "waiting" || (t != nil && t.Asked != "")):
			// its turn over, it waits on you (E101: B2XT and CRFW sat in 排队中)
			r.Group, r.Tag = "ask", "waiting_you"
		default:
			r.Group, r.Tag = "queue", boardStateTag(st)
		}
		if r.Group == "ask" || r.Group == "queue" {
			r.Why, r.WhyTone = boardWhy(why, now)
		}
		r.Origin = "terminal"
		if wstr(w, "origin") == "web" {
			r.Origin = "web"
		}
		r.CanTalk = r.Group != "gone" && !r.Lost && wid != "" && fs.Availability != "maintenance" && fs.Availability != MachineAvailDisabled
		if v, ok := w["can_talk"].(bool); ok && !v {
			r.CanTalk = false // the home's session gate says no (task HHV0 ①)
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
		case end == "" && t.Parked != "":
			// parked while it waited on you (E101): its window closed, its row stays
			// in 等你 — 接回 brings it back where it was
			r.Group, r.Tag = "ask", "parked"
			r.Why, r.WhyTone = boardWhy("parked", now)
		case end == "" && t.Asked != "":
			r.Group, r.Tag = "ask", "waiting_you"
		case end == "" && b != nil && b.Seq > 0 && b.Closed == 0:
			r.Group, r.Tag, r.Lost = "queue", "not_seen", true
		case end == "" && b != nil && b.Seq > 0:
			r.Group, r.Tag, r.At = "gone", "ended_no_result", b.Closed
		case end == "" && t.AuthorityVersion == store.TaskAuthorityVersion:
			r.Group, r.Tag = "queue", "not_seen"
			if t.State == store.TaskAccepted && t.WorkerID == "" && r.Agent == "" {
				r.Tag = "queued"
			}
			if t.State == store.TaskStarting {
				r.Tag = "starting"
			}
			if (r.Tag == "queued" || r.Tag == "starting") && r.Agent == "" && t.WorkerID == "" && (b == nil || b.Seq == 0) {
				for _, a := range []string{t.ResolvedAgent, t.RequestedAgent, t.Agent} {
					if a == "codex" || a == "claude" || a == "gemini" {
						r.Agent, r.AgentBasis = a, "planned"
						break
					}
				}
			}
		case end == "":
			if t.UpdatedAt.Before(since) {
				continue
			}
			r.Group, r.Tag = "gone", "ended"
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
			if end == store.TaskSucceeded {
				r.Tag = "completed"
			}
			if r.Group == "gone" && end == store.TaskRefused {
				r.Tag = "refused"
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
	case "starting":
		return "starting"
	case "parked", "sleeping":
		return "session_parked"
	case "idle":
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
		if rows[a].Group == "ask" {
			if ra, rb := boardAskRank(rows[a].Tag), boardAskRank(rows[b].Tag); ra != rb {
				return ra < rb
			}
		}
		if rows[a].At != rows[b].At {
			return rows[a].At > rows[b].At
		}
		return rows[a].ID < rows[b].ID
	})
	byTask := map[string]int{}
	for i, r := range rows {
		if r.Task != "" {
			byTask[r.Task] = i
		}
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
		r.AgentWords = [2]string{"未知", "Unknown"}
		if r.Agent != "" {
			name := strings.ToUpper(r.Agent[:1]) + r.Agent[1:]
			r.AgentWords = [2]string{name, name}
			if r.AgentBasis == "planned" {
				r.AgentWords = [2]string{name + "（计划）", name + " (planned)"}
			}
		}
		if r.Tag == "queued" {
			r.Context = [2]string{"尚未启动", "Not started"}
		}
		if r.Coordinator != "" && (r.Tag == "queued" || r.Tag == "starting") {
			r.Context[0] += " · 协调负责人：" + r.Coordinator + "（后续派发请由其确认）"
			r.Context[1] += " · Coordinator: " + r.Coordinator + " (confirm dispatch with them)"
		}
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
	encRows, _ := json.Marshal(b.Rows)
	h.Write(encRows)

	enc, _ := json.Marshal(b.Groups)
	h.Write(enc)
	b.Digest = hex.EncodeToString(h.Sum(nil))[:12]
	return b
}
