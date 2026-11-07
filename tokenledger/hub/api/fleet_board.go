package api

import (
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
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
// time); history uses the last native activity when known. An EPIC member sits
// right under its parent while both sit in one group.
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
	archiveSet    bool
	Archived      bool   `json:"archived,omitempty"`
	ScheduleID    string `json:"schedule_id,omitempty"`
	RunID         string `json:"run_id,omitempty"`
	CancelRequest string `json:"cancel_request,omitempty"`
	Generation    int64  `json:"generation,omitempty"`
	// Agent is accompanied by its evidence basis; planned never means actual.
	Agent       string    `json:"agent,omitempty"`
	AgentBasis  string    `json:"agent_basis,omitempty"`
	AgentWords  [2]string `json:"agent_words"`
	Context     [2]string `json:"context"`
	Coordinator string    `json:"coordinator,omitempty"`
	Outcome     string    `json:"outcome,omitempty"`

	ID                string    `json:"id"`
	Code              string    `json:"code,omitempty"`
	Task              string    `json:"task,omitempty"`               // the record's T<n>
	TaskID            string    `json:"task_id,omitempty"`            // the record's ID
	ExecutionEndpoint string    `json:"execution_endpoint,omitempty"` // existing Task binding; independent of live observations
	Title             string    `json:"title"`
	Group             string    `json:"group"`
	Tag               string    `json:"tag"`
	Words             [2]string `json:"words"` // the tag in 中文 / English, the same on both sides
	State             string    `json:"state,omitempty"`
	// Read-only facts for both lists, not a new task lifecycle. Explicit false
	// suppresses older clients' guesses from legacy group/tag words.
	PendingStart bool   `json:"pending_start"`
	StartRetry   bool   `json:"start_retry"`
	StartFailure string `json:"start_failure,omitempty"`
	Running      bool   `json:"running"`
	Active       bool   `json:"active"`
	Loop         *bool  `json:"loop,omitempty"`
	NativeWait   string `json:"native_wait,omitempty"`
	WorkerID     string `json:"worker_id,omitempty"`
	Machine      string `json:"machine,omitempty"`
	Login        string `json:"login,omitempty"`
	Repo         string `json:"repo,omitempty"`
	Parent       string `json:"parent,omitempty"`
	Depth        int    `json:"depth,omitempty"`
	// Who opened it (task PV5W): the ID of the session whose spawn / task tool
	// opened this one (the node's @from_fid, else the record's request_payload
	// from_fid), only when it is one of this person's own sessions; its title,
	// and whether it has ended. Parent / Depth nest the row under it when that
	// session is on this list — never a live row under an ended one. Display
	// only: nothing routes, reports or reaps by it.
	From      string `json:"from,omitempty"`
	FromTitle string `json:"from_title,omitempty"`
	FromEnded bool   `json:"from_ended,omitempty"`
	// TreeAt is the latest activity of the row and every row nested under it —
	// the lists order a tree by it (task PV5W).
	TreeAt int64 `json:"tree_at,omitempty"`
	// EndedOpener: an ended session listed outside 已收起 only because sessions
	// it opened are still at work — drawn ended, never counted (task PV5W).
	EndedOpener bool  `json:"ended_opener,omitempty"`
	Lost        bool  `json:"lost,omitempty"`
	At          int64 `json:"at"`
	ActivityAt  int64 `json:"activity_at,omitempty"` // native turn/state activity, independent of inventory freshness
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
	Origin  string        `json:"origin,omitempty"`
	CanTalk bool          `json:"can_talk"`
	History *BoardHistory `json:"history,omitempty"`
	// Who opened it (task DDBQ), the list's group: agent (a session's task /
	// spawn tool), schedule (a scheduled run), api (a bearer caller of
	// worker_start). Empty = a person's (⌘P, the web, the CLI) — the main list.
	Source     string `json:"source,omitempty"`
	parentTask string
	fromID     string // the opener's ID before it is checked against this person's sessions
	fromKey    string // an older record's opener by key (its dispatch request_id), when it has no ID
	fromAt     int64  // the record's creation: the key's holder must be older, a run started just before
	runName    string // the window name a schedule runner asked a placement for (its record's params.name)
	taskVia    string
	taskAgent  bool
}

// BoardHistory is resolved directly from the owner's FID ledger, independently
// of the legacy ended list's cap, age window, and recycled scratch names.
type BoardHistory struct {
	ID       string `json:"id"`
	Status   string `json:"status"`
	ResumeID string `json:"resume_id,omitempty"`
}

// Board is the list: its rows in order, the count, each group's size.
type SessionListPreferences struct {
	MaxVisible int `json:"max_visible"`
	IdleHours  int `json:"idle_hours"`
}

type Board struct {
	SessionList SessionListPreferences `json:"session_list"`
	Rows        []BoardRow             `json:"rows"`
	Count       int                    `json:"count"`
	// Active includes archived sessions: hiding a row does not free runtime capacity.
	// It is how many of the non-lost rows have an agent running right now
	// (boardActive): what the panel and the console show as the number (AWVX);
	// Count stays the list's size.
	Active   int            `json:"active"`
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
	"retained_completed": {"已完成 · 保留中", "Completed · retained"}, "session_parked": {"已停放", "Parked"},
	"idle": {"空闲", "Idle"}, "unknown": {"状态未知", "Unknown"}, "starting": {"正在开", "Starting"},
	"start_failed": {"启动失败", "Start failed"}, "queued": {"未派发", "Not dispatched"}, "not_seen": {"看不到会话", "Session not seen"}, "exited": {"已退出", "Exited"},
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

// controlledEnded: a controlled record whose result is in keeps its binding after
// its session ends (T539: succeeded, its ID closed, execution_owner still set). It
// is history once nothing runs for it — no current worker, that worker's ID
// closed on the hub, or (its ID not listed) the record older than the board's
// window — never 看不到会话. A worker ID still open stays not_seen.
func controlledEnded(t *store.FleetTask, end, worker string, idBy map[string]*store.BoardID, since time.Time) bool {
	if end == "" {
		return false
	}
	if worker == "" {
		return true
	}
	if _, key, err := fleetid.ParseWorkerID(worker); err == nil {
		if b := idBy[key]; b != nil {
			return b.Closed != 0
		}
	}
	return t.UpdatedAt.Before(since)
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
	archived, err := s.Store.SessionArchivePreferences(owner)
	if err != nil {
		return nil, err
	}
	remembered := func(id string) bool { _, ok := archived[id]; return ok }
	ts, err := s.Store.FleetTasksFor(owner, 500)
	if err != nil {
		return nil, err
	}
	extra, err := s.Store.SessionArchiveTasks(owner)
	if err != nil {
		return nil, err
	}
	seenTasks := map[int64]bool{}
	for _, t := range ts {
		seenTasks[t.ID] = true
	}
	for _, t := range extra {
		if !seenTasks[t.ID] {
			ts = append(ts, t)
		}
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
	currentWorker, controlled := map[*store.FleetTask]string{}, map[*store.FleetTask]bool{}
	for i := range ts {
		t := &ts[i]
		if t.FID != "" {
			byFID[t.FID] = t
		}
		byRef[t.Ref] = t
		currentWorker[t], controlled[t] = s.taskCurrentWorker(t)
		if currentWorker[t] != "" {
			byWID[currentWorker[t]] = t
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
	fleets, err := s.Store.Fleets()
	if err != nil {
		return nil, err
	}
	resumeID := func(b *store.BoardID) string {
		found := ""
		for _, f := range fleets {
			if f.Hostname == b.Machine && f.OSUser == b.Login && f.Present {
				if found != "" {
					return ""
				} // ambiguous placement refuses
				found = f.FleetID + "/" + b.ID
			}
		}
		return found
	}
	var rows []BoardRow
	usedTask, usedID := map[*store.FleetTask]bool{}, map[string]bool{}
	row := func(t *store.FleetTask, b *store.BoardID) BoardRow {
		r := BoardRow{}
		if b != nil {
			r.Code, r.Title, r.Machine, r.Login, r.Repo = b.Short, b.Title, b.Machine, b.Login, b.Repo
			r.Source = b.SessionSource // a live session's own word replaces it below
			r.ActivityAt = b.ActivityAt
			r.Agent = b.Agent
			if r.Agent != "" {
				r.AgentBasis = "native"
			}
		}
		hb := b
		if t != nil {
			ref := t.FID
			if n := strings.LastIndexByte(t.WorkerID, '/'); n >= 0 && store.IsFleetID(t.WorkerID[n+1:]) {
				ref = t.WorkerID[n+1:]
			}
			if store.IsFleetID(ref) && (hb == nil || hb.ID != ref) {
				// A parked task can be older than either list window. Resolve
				// its exact owner's FID directly, never a scratch key or title.
				if rec, err := s.Store.FleetIDOf(t.Owner, ref); err == nil && rec.ClosedAt > 0 {
					hb = &store.BoardID{ID: rec.ID, Machine: rec.Machine, Login: rec.Login, Seq: rec.Seq, Closed: rec.ClosedAt, ActivityAt: rec.ActivityAt}
					if len(rec.Natives) > 0 {
						hb.Agent = rec.Natives[len(rec.Natives)-1].Agent
					}
				}
			}
		}
		if hb != nil {
			r.ActivityAt = hb.ActivityAt
			if hb.Closed > 0 {
				status := "offline_unknown"
				if hb.Seq > 0 && hb.Agent == "" {
					status = "never_started"
				}
				r.History = &BoardHistory{ID: hb.ID, Status: status}
				if hb.Agent != "" {
					r.History.ResumeID = resumeID(hb)
				}
			}
		}
		if t != nil {
			r.Task, r.TaskID, r.parentTask = t.Ref, t.FID, t.ParentTask
			r.fromID, r.fromAt = taskFromID(t), t.CreatedAt.Unix()
			r.runName = taskRunName(t)
			if r.fromID == "" {
				r.fromKey = taskFromKey(t)
			}
			r.taskVia, r.taskAgent = t.Via, t.ParentTask != "" || t.ParentSession != ""
			r.ExecutionEndpoint = t.ExecutionEndpoint
			r.CancelRequest, r.Generation = t.CancelRequest, t.Generation
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
			if t.Title != "" && (b == nil || b.TitleSource != "manual") {
				r.Title = t.Title
			}
			r.Code = t.Short
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
			candidate := byWID[wid]
			if candidate != nil && (candidate.FID == "" || candidate.FID == ident) {
				t = candidate // a recycled key cannot attach another session's task
			}
		}
		if t != nil && controlled[t] && (currentWorker[t] == "" || wid != currentWorker[t]) {
			// Retained wrappers and stale inventory are history, never this Task's
			// current execution. Its ledger remains available through history reads.
			usedID[ident] = true
			continue
		}
		lostFor := fs.Availability == "lost" && !fs.ObservedAt.IsZero() && now.Sub(fs.ObservedAt) > boardLostAfter
		if lostFor && fs.ObservedAt.Before(since) && !remembered(ident) {
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
		if (r.Title == "" || t == nil) && (b == nil || b.TitleSource != "manual") {
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
		if fleet, _, ok := strings.Cut(wid, "/"); ok && store.IsFleetID(ident) {
			r.WorkerID = fleet + "/" + ident // every client enters this generation
		}
		if v := wstr(w, "from"); store.IsFleetID(v) {
			r.fromID = v
		}
		r.State = wstr(w, "state")
		r.NativeWait = wstr(w, "native_wait")
		if loop, ok := w["loop"].(bool); ok {
			r.Loop = &loop
		}
		r.Running = boardRunning(r.State, r.NativeWait)
		r.Active = boardActive(r.State)
		r.PendingStart = r.State == "starting"
		// Inventory is runtime evidence; a native ledger segment is preferred.
		if r.Agent == "" && wstr(w, "agent") != "" {
			r.Agent, r.AgentBasis = wstr(w, "agent"), "runtime"
		}
		r.Lost = fs.Availability == "lost"
		if v, ok := w["born"].(float64); ok {
			r.At = int64(v)
		}
		if r.At <= 0 {
			// no birth stamp (an older wrapper): its last activity, else when it was
			// last heard — never the epoch (「49 万小时前」, task PV5W)
			r.At = r.ActivityAt
			if v, ok := w["activity_at"].(float64); ok && v > 0 && v <= float64(now.Unix()) {
				r.At = int64(v)
			}
			if r.At <= 0 && !fs.ObservedAt.IsZero() {
				r.At = fs.ObservedAt.Unix()
			}
		}
		if v, ok := w["activity_at"].(float64); ok && v > float64(r.ActivityAt) && v <= float64(now.Unix()) {
			r.ActivityAt = int64(v)
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
		default:
			r.Group, r.Tag = "queue", boardStateTag(st)
		}
		if (r.Group == "ask" || r.Group == "queue") && code != "waiting" {
			r.Why, r.WhyTone = boardWhy(why, now)
		}
		r.Origin = "terminal"
		if wstr(w, "origin") == "web" {
			r.Origin = "web"
		}
		switch src := wstr(w, "source"); src {
		case boardSourceAgent, boardSourceSchedule, boardSourceAPI:
			r.Source = src
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
		// opened_at is also stamped when a task ID is merely reserved.
		started := b != nil && (b.Seq > 0 || b.Agent != "")
		switch {
		case s.boardPendingStart(t):
			r.Group, r.Tag = "queue", "starting"
		case controlled[t] && !controlledEnded(t, end, currentWorker[t], idBy, since):
			r.Group, r.Tag = "queue", "not_seen"
			r.Lost = currentWorker[t] != ""
			if currentWorker[t] == "" && t.ExecutionEndpoint == "" {
				r.Group, r.Tag = "gone", "ended"
			}
		case end == "" && t.Parked != "":
			// parked while it waited on you (E101): its window closed, its row stays
			// in 等你 — 接回 brings it back where it was
			r.Group, r.Tag = "ask", "parked"
			r.Why, r.WhyTone = boardWhy("parked", now)
		case end == "" && started && b.Closed == 0:
			r.Group, r.Tag, r.Lost = "queue", "not_seen", true
		case end == "" && started:
			r.Group, r.Tag, r.At = "gone", "ended_no_result", b.Closed
		case end == "" && t.AuthorityVersion == store.TaskAuthorityVersion:
			r.Group, r.Tag = "queue", "not_seen"
			if t.State == store.TaskAccepted && t.WorkerID == "" && t.OperationID == "" && r.Agent == "" {
				r.Tag = "queued"
			}
			if s.boardPendingStart(t) {
				r.Tag = "starting"
			}
			if (r.Tag == "queued" || r.Tag == "starting") && r.Agent == "" && t.WorkerID == "" && !started {
				for _, a := range []string{t.ResolvedAgent, t.RequestedAgent, t.Agent} {
					if a == "codex" || a == "claude" || a == "gemini" {
						r.Agent, r.AgentBasis = a, "planned"
						break
					}
				}
			}
		case end == "":
			if t.UpdatedAt.Before(since) && !remembered(t.FID) {
				continue
			}
			r.Group, r.Tag = "gone", "ended"
		default:
			if t.UpdatedAt.Before(since) && !remembered(t.FID) {
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
		if r.Tag == "starting" && r.Agent == "" && t.WorkerID == "" && !started {
			for _, agent := range []string{t.ResolvedAgent, t.RequestedAgent, t.Agent} {
				if agent == "codex" || agent == "claude" || agent == "gemini" {
					r.Agent, r.AgentBasis = agent, "planned"
					break
				}
			}
		}
		r.PendingStart = r.Tag == "starting"
		if r.Tag == "queued" {
			r.StartRetry, _ = s.Store.TaskStartRetryable(*t)
			r.StartFailure = t.StartFailure()
			if r.StartFailure != "" {
				r.Tag = "start_failed"
				r.Context = [2]string{r.StartFailure, r.StartFailure}
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
		if usedID[b.ID] || (!remembered(b.ID) && (b.Seq == 0 || b.Closed == 0 || b.Closed < since.Unix())) {
			continue
		}
		if t := taskOfID(b); t != nil && usedTask[t] {
			continue
		}
		r := row(nil, b)
		r.ID, r.Group, r.Tag, r.At = b.ID, "gone", "ended", b.Closed
		if b.Closed == 0 {
			r.Group, r.Tag, r.At, r.Lost = "queue", "not_seen", b.Opened, true
		}
		rows = append(rows, r)
	}
	// 看不到会话 on a machine and login that report right now is a session that
	// machine does not list — not a lost machine (PV5W): it never adds the list's
	// 「+?」. A row whose machine reports nothing stays unknown.
	reporting := map[string]bool{}
	for _, fs := range live {
		if fs.Availability == "online" {
			reporting[fs.MachineName+"\x00"+fs.OSUser] = true
		}
	}
	for i := range rows {
		if rows[i].Tag == "not_seen" && rows[i].Lost && rows[i].Machine != "" && reporting[rows[i].Machine+"\x00"+rows[i].Login] {
			rows[i].Lost = false
		}
	}
	hidden, err := s.Store.HiddenHistory(owner, s.historyMirrorSession)
	if err != nil {
		return nil, err
	}
	kept := rows[:0]
	for _, r := range rows {
		if r.Group == "gone" && r.History != nil && hidden[r.History.ID] && !usedIDLive(live, r.History.ID) {
			continue
		}
		kept = append(kept, r)
	}
	sources, err := s.Store.ScheduleSessions(owner)
	if err != nil {
		return nil, err
	}
	var runs *runIndex // read only when a row needs it
	for i := range kept {
		r := &kept[i]
		r.Archived = archived[r.ID]
		r.archiveSet = remembered(r.ID)
		fid := r.ID
		if r.History != nil {
			fid = r.History.ID
		}
		run, ok := sources[fid]
		if !ok && r.runName != "" {
			if runs == nil {
				runs = newRunIndex(s.Store, owner)
			}
			run, ok = runs.match(r.runName, r.fromAt)
		}
		if ok {
			r.ScheduleID, r.RunID = run.ScheduleID, run.ID
			if b := idBy[fid]; run.Title != "" && (b == nil || b.TitleSource != "manual") {
				r.Title = run.Title
			}
		}
		r.Source = boardSource(*r)
	}
	s.boardFrom(owner, kept, live, ids)
	if owner != "" {
		kept = append(kept, boardOpeners(kept, func(id string) *store.FleetIDRecord {
			rec, err := s.Store.FleetIDOf(owner, id)
			if err != nil {
				return nil
			}
			return &rec
		})...)
	}
	b := finishBoard(kept)
	b.SessionList = SessionListPreferences{MaxVisible: 10, IdleHours: 24}
	if owner != "" {
		if personal, err := s.Store.PersonBundle(owner, 0); err == nil {
			var data struct {
				SessionList *SessionListPreferences `json:"session_list"`
			}
			if json.Unmarshal([]byte(personal.Bundle), &data) == nil && data.SessionList != nil {
				p := *data.SessionList
				if (p.MaxVisible == 5 || p.MaxVisible == 10 || p.MaxVisible == 15) && (p.IdleHours == 0 || p.IdleHours == 12 || p.IdleHours == 24 || p.IdleHours == 72) {
					b.SessionList = p
				}
			}
		}
	}
	// Preferences change the response even when no session moved.
	b.Digest += fmt.Sprintf("-%d-%d", b.SessionList.MaxVisible, b.SessionList.IdleHours)
	return b, nil
}

func usedIDLive(live []FleetSession, id string) bool {
	for _, fs := range live {
		if identityOf(fs.Worker) == id {
			return true
		}
	}
	return false
}

// A looping observation also covers background tools and waiting for people.
// Only explicit recurring-plan metadata is a Loop; bg/tool prove ongoing work.
func boardRunning(state, wait string) bool {
	if state == "working" {
		return true
	}
	if state == "looping" {
		for _, reason := range strings.Split(wait, ",") {
			if reason == "bg" || reason == "tool" {
				return true
			}
		}
	}
	return false
}

// boardActive: the session's agent process is up — not parked or sleeping (its
// window holds a conversation, no process), not exited, failed or still starting.
// A record with no session has no state and is never active.
func boardActive(state string) bool {
	switch state {
	case "working", "looping", "needs", "blocked", "idle", "done", "landed":
		return true
	}
	return false
}

// Only a recorded, still-pending start is evidence. An operation ID alone can
// name an already failed or settled start. No-session and reserved IDs are not
// pending requests. Live observations take precedence in buildBoard above.
func (s *Server) boardPendingStart(t *store.FleetTask) bool {
	if t == nil || t.CancelRequest != "" {
		return false
	}
	if t.OperationID == "" {
		return t.AuthorityVersion == 0 && t.State == store.TaskStarting
	}
	if t.AuthorityVersion != 0 {
		return s.Store.TaskStartPending(*t)
	}
	op, err := s.Store.FleetOperation(t.OperationID)
	if err != nil || op.Action != "worker_start" || (op.TaskOwner != t.Owner && op.Actor != t.Owner) {
		return false
	}
	return op.Status == "pending" || op.Status == "sent" || op.Status == "running"
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
	// All surfaces consume this title. Never infer historical text from a body,
	// another window's key, a native transcript or another person's record.
	for i := range rows {
		r := &rows[i]
		r.Title = store.FleetTitle(r.Title)
		if r.Title == "" {
			code := r.Code
			if code == "" {
				code = r.ID
			}
			r.Title = "会话 " + code
		}
	}

	// An ended session that opened sessions still at work is lifted out of
	// 已收起 into the most urgent group of those it opened (task PV5W): they hang
	// under it, and it is not counted (nothing of its own runs).
	at := map[string]int{}
	for i := range rows {
		at[rows[i].ID] = i
	}
	for i := range rows {
		r := rows[i]
		if r.From == "" || r.Group == "gone" || r.Group == "pin" {
			continue
		}
		seen := map[int]bool{}
		for p, ok := at[r.From]; ok && !seen[p]; p, ok = at[rows[p].From] {
			seen[p] = true
			q := &rows[p]
			if q.Archived != r.Archived {
				break
			}
			if (q.Group == "gone" || q.EndedOpener) && (!q.EndedOpener || boardGroupOrder[r.Group] < boardGroupOrder[q.Group]) {
				q.Group, q.EndedOpener = r.Group, true
			}
			if q.From == "" {
				break
			}
		}
	}

	sort.SliceStable(rows, func(a, b int) bool {
		ga, gb := boardGroupOrder[rows[a].Group], boardGroupOrder[rows[b].Group]
		if ga != gb {
			return ga < gb
		}
		// Every group uses the same completed-turn clock across machines and
		// parked records. Lifecycle and inventory timestamps never affect order.
		if rows[a].ActivityAt != rows[b].ActivityAt {
			return rows[a].ActivityAt > rows[b].ActivityAt
		}
		return rows[a].ID < rows[b].ID
	})
	byTask, byID := map[string]int{}, map[string]int{}
	for i, r := range rows {
		if r.Task != "" {
			byTask[r.Task] = i
		}
		if r.TaskID != "" {
			byTask[r.TaskID] = i
		}
		byID[r.ID] = i
	}
	// Who it nests under (task PV5W): the session that opened it, when that is on
	// this list — whatever either one's group, never a live row under an ended
	// one, never across archived / not. Else an old record's parent task, in its
	// own group (an EPIC's members).
	par := make([]int, len(rows))
	for i, r := range rows {
		par[i] = -1
		if r.From != "" {
			if p, ok := byID[r.From]; ok && p != i {
				rows[i].FromTitle = rows[p].Title
				if rows[p].Archived == r.Archived && (rows[p].Group != "gone" || r.Group == "gone") {
					par[i] = p
				}
			}
			continue
		}
		if p, ok := byTask[r.parentTask]; ok && r.parentTask != "" && p != i && rows[p].Group == r.Group {
			par[i] = p
		}
	}
	for i := range rows {
		// a loop of openers (a moved or forged ID) is cut where it closes, so no
		// row drops off the list
		seen := map[int]bool{i: true}
		for j := par[i]; j >= 0; j = par[j] {
			if seen[j] {
				if j == i {
					par[i] = -1
				}
				break
			}
			seen[j] = true
		}
	}
	kids := map[int][]int{}
	nested := map[int]bool{}
	for i := range rows {
		if par[i] >= 0 {
			kids[par[i]] = append(kids[par[i]], i)
			nested[i] = true
		}
	}
	for i := range rows {
		if par[i] >= 0 {
			rows[i].Parent = rows[par[i]].ID
		} else if p, ok := byTask[rows[i].parentTask]; ok && rows[i].From == "" && rows[i].parentTask != "" && p != i {
			rows[i].Parent = rows[p].ID
		}
	}
	// A tree uses the latest completed turn of itself and its descendants.
	// A child starting, asking or closing does not change this timestamp.
	treeAt, signal := make([]int64, len(rows)), make([]int64, len(rows))
	var tree func(i int) int64
	tree = func(i int) int64 {
		if treeAt[i] != 0 {
			return treeAt[i]
		}
		own := rows[i].ActivityAt
		sig := own
		treeAt[i], signal[i] = own, sig
		for _, k := range kids[i] {
			tree(k)
			if signal[k] > own {
				own = signal[k]
			}
			if signal[k] > sig {
				sig = signal[k]
			}
		}
		treeAt[i], signal[i] = own, sig
		return own
	}
	for i := range rows {
		tree(i)
	}
	for p := range kids {
		ks := kids[p]
		sort.SliceStable(ks, func(a, b int) bool {
			if signal[ks[a]] != signal[ks[b]] {
				return signal[ks[a]] > signal[ks[b]]
			}
			return rows[ks[a]].ID < rows[ks[b]].ID
		})
	}
	out := make([]BoardRow, 0, len(rows))
	var put func(i, depth int)
	put = func(i, depth int) {
		r := rows[i]
		r.Depth = depth
		r.TreeAt = treeAt[i]
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
	roots := make([]int, 0, len(rows))
	for i := range rows {
		if !nested[i] {
			roots = append(roots, i)
		}
	}
	sort.SliceStable(roots, func(a, b int) bool {
		i, j := roots[a], roots[b]
		if ga, gb := boardGroupOrder[rows[i].Group], boardGroupOrder[rows[j].Group]; ga != gb {
			return ga < gb
		}
		if treeAt[i] != treeAt[j] {
			return treeAt[i] > treeAt[j]
		}
		return rows[i].ID < rows[j].ID
	})
	for _, i := range roots {
		put(i, 0)
	}
	b := &Board{Groups: map[string]int{}, GoneDays: boardGoneDays}
	gone := 0
	for _, r := range out {
		if r.Group == "gone" && !r.Archived && !r.archiveSet {
			gone++
			if gone > boardGoneMax {
				b.GoneMore++
				continue
			}
		}
		b.Rows = append(b.Rows, r)
		if r.Archived {
			b.Groups["archived"]++
		} else {
			b.Groups[r.Group]++
		}
		if r.Group != "gone" && !r.Lost && !r.EndedOpener {
			if !r.Archived {
				b.Count++
			}
			if r.Active {
				b.Active++
			}
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

// taskFromID is the session a record was dispatched from (task PV5W): the node's
// fleet-task-record.sh puts the calling session's ID in request_payload.from_fid.
func taskFromID(t *store.FleetTask) string {
	if t == nil || !strings.Contains(t.RequestPayload, "from_fid") {
		return ""
	}
	var p struct {
		FromFID string `json:"from_fid"`
	}
	if json.Unmarshal([]byte(t.RequestPayload), &p) != nil || !store.IsFleetID(p.FromFID) {
		return ""
	}
	return p.FromFID
}

// taskRunName is the window name an older schedule runner asked the hub to place
// (task PV5W): its record is a worker_start whose params.name is
// `schedule-<sha256(schedule:slot:attempt)[:24]>` or the run's title. "" else.
func taskRunName(t *store.FleetTask) string {
	if t == nil || !strings.Contains(t.RequestPayload, `"worker_start"`) {
		return ""
	}
	var p struct {
		Action string `json:"action"`
		Params struct {
			Name string `json:"name"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(t.RequestPayload), &p) != nil || p.Action != "worker_start" {
		return ""
	}
	return strings.TrimSpace(p.Params.Name)
}

// runIndex recognises a schedule run whose session the hub never learned (task
// PV5W): runners before the run → session link placed their sessions through the
// hub, so the record names its run only by the runner's window name.
type runIndex struct {
	byKey map[string]store.ScheduleRun
	runs  []store.ScheduleRun
	names map[string]string // schedule ID → its name
}

var runKeyRE = regexp.MustCompile(`^schedule-([0-9a-f]{24})$`)

func newRunIndex(st *store.Store, owner string) *runIndex {
	x := &runIndex{byKey: map[string]store.ScheduleRun{}, names: map[string]string{}}
	if owner == "" {
		return x
	}
	x.runs, _ = st.RecentScheduleRuns(owner)
	for _, r := range x.runs {
		sum := sha256.Sum256([]byte(r.ScheduleID + ":" + r.Slot + ":" + strconv.Itoa(r.Attempt)))
		x.byKey[hex.EncodeToString(sum[:])[:24]] = r
	}
	if all, err := st.Schedules(owner); err == nil {
		for _, s := range all {
			x.names[s.Spec.ID] = s.Spec.Name
		}
	}
	return x
}

// runStem is a run title's leading words — before its clip mark, a bracket or
// its day: 「活页模板现做（每… 11-01」 → 活页模板现做.
func runStem(title string) string {
	if i := strings.IndexAny(title, "…（("); i >= 0 {
		title = title[:i]
	}
	return strings.TrimSpace(scheduleDayRE.ReplaceAllString(title, ""))
}

var scheduleDayRE = regexp.MustCompile(`\s+\d{2}-\d{2}(\s+#\d+)?$`)

// match finds the one run a record was for: the window-name key exactly, else a
// run of a schedule whose name starts with the record title's stem, admitted at
// most 5 minutes before the record was made. Two candidates are none.
func (x *runIndex) match(name string, made int64) (store.ScheduleSession, bool) {
	toSession := func(r store.ScheduleRun) store.ScheduleSession {
		var snap struct {
			Title string `json:"session_title"`
		}
		_ = json.Unmarshal(r.Delivery, &snap)
		title := snap.Title
		if title == "" && x.names[r.ScheduleID] != "" && len(r.Day) == 10 {
			title = x.names[r.ScheduleID] + " " + r.Day[5:]
		}
		return store.ScheduleSession{ID: r.ID, ScheduleID: r.ScheduleID, Title: title}
	}
	if m := runKeyRE.FindStringSubmatch(name); m != nil {
		r, ok := x.byKey[m[1]]
		if !ok {
			return store.ScheduleSession{}, false
		}
		return toSession(r), true
	}
	stem := runStem(name)
	if len([]rune(stem)) < 2 || made <= 0 {
		return store.ScheduleSession{}, false
	}
	var hit *store.ScheduleRun
	for i := range x.runs {
		r := &x.runs[i]
		if r.Started > made || r.Started < made-300 {
			continue
		}
		var snap struct {
			Title string `json:"session_title"`
		}
		_ = json.Unmarshal(r.Delivery, &snap)
		if !strings.HasPrefix(x.names[r.ScheduleID], stem) && !strings.HasPrefix(snap.Title, stem) {
			continue
		}
		if hit != nil {
			return store.ScheduleSession{}, false
		}
		hit = r
	}
	if hit == nil {
		return store.ScheduleSession{}, false
	}
	return toSession(*hit), true
}

// fleetOrchRE reads a task tool's dispatch request_id: `orch:<caller key>:<16
// hex>`, a blank session's with `-<n>` after it (fleet-task-record.sh dispatch).
var fleetOrchRE = regexp.MustCompile(`^orch:(.+):[0-9a-f]{16}(?:-[0-9]+)?$`)

// taskFromKey is the caller's key a record dispatched before from_fid existed
// carries in its dispatch request_id (task PV5W): `<repo slug>:scratch-<N>`, a bare
// key, or the caller's own ID; "" for anything else (⌘P, the web, `hub`).
func taskFromKey(t *store.FleetTask) string {
	if t == nil || !strings.Contains(t.RequestPayload, `"orch:`) {
		return ""
	}
	var p struct {
		Dispatch struct {
			RequestID string `json:"request_id"`
		} `json:"dispatch"`
	}
	if json.Unmarshal([]byte(t.RequestPayload), &p) != nil {
		return ""
	}
	m := fleetOrchRE.FindStringSubmatch(p.Dispatch.RequestID)
	if m == nil || m[1] == "hub" {
		return ""
	}
	return m[1]
}

// fromByKey finds the live session that held a record's caller key when the
// record was made (task PV5W): exactly one of this person's live sessions
// answers to the key (a bare key: also `<slug>:<key>`) and was born before the
// record. A recycled scratch number born after it, or two candidates, is
// nothing — the row stays flat rather than hang under a guess.
func fromByKey(key string, at int64, self string, live []FleetSession) string {
	found := ""
	for _, fs := range live {
		w := fs.Worker
		if w == nil {
			continue
		}
		k, id := wstr(w, "key"), identityOf(w)
		if id == "" || id == self || !sameKey(k, key) {
			continue
		}
		if born, ok := w["born"].(float64); !ok || born <= 0 || int64(born) > at {
			continue
		}
		if found != "" && found != id {
			return ""
		}
		found = id
	}
	return found
}

// sameKey: a session key as a record wrote it and as a session holds it — one
// repo whatever its case (a record keeps the repo lower-cased), a bare key also
// matching `<slug>:<key>`.
func sameKey(held, want string) bool {
	if held == "" || want == "" {
		return false
	}
	if strings.EqualFold(held, want) {
		return true
	}
	return !strings.Contains(want, ":") && strings.HasSuffix(strings.ToLower(held), ":"+strings.ToLower(want))
}

// fromByLedgerKey is fromByKey over the person's ID ledger (PV5W): the one ID
// that opened under the key before the record was made and had not closed by
// then — a caller with no window now (a cold park, or ended) is still found.
func fromByLedgerKey(key string, at int64, self string, ids []store.BoardID) string {
	found := ""
	for _, b := range ids {
		if b.ID == self || !sameKey(b.Key, key) || b.Opened <= 0 || b.Opened > at || (b.Closed > 0 && b.Closed < at) {
			continue
		}
		if found != "" && found != b.ID {
			return ""
		}
		found = b.ID
	}
	return found
}

// boardFrom checks each row's opener against this person's own sessions (task
// PV5W): a row on this list, else the person's ID ledger. Another person's ID, an
// unknown one and the operator's door ("" — everyone's rows) draw no relation. A
// record from before from_fid names its caller by key: resolved through the
// person's live sessions (fromByKey) first.
func (s *Server) boardFrom(owner string, rows []BoardRow, live []FleetSession, ids []store.BoardID) {
	if owner == "" {
		return
	}
	for i := range rows {
		r := &rows[i]
		if r.fromID != "" || r.fromKey == "" {
			continue
		}
		if store.IsFleetID(r.fromKey) {
			r.fromID = r.fromKey
		} else {
			r.fromID = fromByKey(r.fromKey, r.fromAt, r.ID, live)
			if r.fromID == "" {
				r.fromID = fromByLedgerKey(r.fromKey, r.fromAt, r.ID, ids)
			}
			if r.fromID == "" && strings.Contains(r.fromKey, ":") {
				// ended past the list's window: the ledger whatever its age (a bare
				// key over any age would be a guess)
				if old, err := s.Store.BoardIDsByKey(owner, r.fromKey); err == nil {
					r.fromID = fromByLedgerKey(r.fromKey, r.fromAt, r.ID, old)
				}
			}
		}
	}
	byID := map[string]*BoardRow{}
	for i := range rows {
		byID[rows[i].ID] = &rows[i]
	}
	looked := map[string]*store.FleetIDRecord{}
	for i := range rows {
		r := &rows[i]
		id := r.fromID
		if id == "" || id == r.ID {
			continue
		}
		if p := byID[id]; p != nil {
			r.From, r.FromTitle, r.FromEnded = p.ID, p.Title, p.Group == "gone"
			continue
		}
		rec, seen := looked[id]
		if !seen {
			if got, err := s.Store.FleetIDOf(owner, id); err == nil {
				rec = &got
			}
			looked[id] = rec
		}
		if rec != nil {
			r.From, r.FromTitle, r.FromEnded = rec.ID, store.FleetTitle(rec.Title), rec.ClosedAt > 0
		}
	}
}

// boardOpeners lists the ended sessions that opened a session still on the list
// but are themselves off it (closed past boardGoneDays, or past the cap): one
// 已结束 row each, so the list can hang what they opened under them (task PV5W).
func boardOpeners(rows []BoardRow, looked func(id string) *store.FleetIDRecord) []BoardRow {
	on := map[string]bool{}
	for _, r := range rows {
		on[r.ID] = true
	}
	var out []BoardRow
	for _, r := range rows {
		if r.From == "" || on[r.From] || r.Group == "gone" || r.Archived {
			continue
		}
		rec := looked(r.From)
		if rec == nil || rec.ClosedAt == 0 {
			continue
		}
		on[r.From] = true
		row := BoardRow{ID: rec.ID, Code: rec.Short, Title: rec.Title, Machine: rec.Machine, Login: rec.Login, Repo: rec.Repo,
			Group: "gone", Tag: "ended", At: rec.ClosedAt, ActivityAt: rec.ActivityAt}
		row.History = &BoardHistory{ID: rec.ID, Status: "offline_unknown"}
		out = append(out, row)
	}
	return out
}

// The list's groups (task DDBQ): who opened a session. Empty is a person's.
const (
	boardSourceAgent    = "agent"
	boardSourceSchedule = "schedule"
	boardSourceAPI      = "api"
)

// boardSource is the ONE place a row's source is decided: a scheduled run's
// session is the schedule's; else what the node stamped at the spawn
// (@session_source); else the task record's word — via `api` (a bearer
// worker_start), via 编排 or a parent (a session's task tool). Anything else,
// and every row an older node or hub sends, is a person's.
func boardSource(r BoardRow) string {
	switch {
	case r.ScheduleID != "":
		return boardSourceSchedule
	case r.Source != "":
		return r.Source
	case r.taskVia == boardSourceAPI:
		return boardSourceAPI
	case r.taskVia == "编排" || r.taskAgent:
		return boardSourceAgent
	}
	return ""
}
