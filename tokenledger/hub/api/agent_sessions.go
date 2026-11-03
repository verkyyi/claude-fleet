package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The console's session tools over /mcp (task T4DN): a person's own agent —
// Claude Code, Codex, Gemini CLI, claude.ai, through the agent door
// (agent_door.go), or the person's own cookie / bearer — manages their sessions
// the way the console does, through the SAME roads the console takes:
//
//	sessions_list · session_get · wait   the one session list (buildBoard,
//	                                     off the hub's cached inventory — never
//	                                     a live machine call)
//	session_read                         /v1/chat/view?worker= (the read-along
//	                                     view's first frame), else its copy
//	session_say / answer / stop          /v1/chat/say|answer|stop?worker=
//	session_new                          /v1/chat/open (the console's 新会话)
//	task_list · task_get                 the task records (tasksBody / ownTask)
//
// Each road is called INSIDE the hub: an internal request carrying the caller's
// own context (person, door, grant) and headers, run through handleChat — so
// who may talk to which session is decided exactly where it is for the page
// (termPerson · termTarget · the session's own gate), never re-implemented
// here. The operator's shared door is nobody's conversation: those roads refuse
// it («sign in as yourself»). A connected agent's writes are also held to the
// scopes its person ticked (authorize → p.Grant).

// SessionTools are the tools CallSessionTool serves.
var SessionTools = []string{"sessions_list", "session_get", "session_read", "session_say", "session_answer",
	"session_stop", "session_new", "task_list", "task_get", "wait"}

// IsSessionTool is whether name is one of SessionTools.
func IsSessionTool(name string) bool {
	for _, t := range SessionTools {
		if t == name {
			return true
		}
	}
	return false
}

// sessionToolScope is the fleet scope each tool needs.
var sessionToolScope = map[string]string{
	"sessions_list": "fleet:read", "session_get": "fleet:read", "session_read": "fleet:read",
	"task_list": "fleet:read", "task_get": "fleet:read", "wait": "fleet:read",
	"session_say": "worker:message", "session_answer": "worker:answer",
	"session_stop": "worker:stop", "session_new": "worker:start",
}

// CallSessionTool runs one session tool for the caller of r.
func (s *Server) CallSessionTool(r *http.Request, name string, args map[string]any) (any, error) {
	scope, ok := sessionToolScope[name]
	if !ok {
		return nil, fault("INVALID_ARGUMENT", "Unknown session tool")
	}
	if args == nil {
		args = map[string]any{}
	}
	// The daily page's cut: an admin's own sessions, as on the console's list.
	r = r.WithContext(context.WithValue(r.Context(), ownViewKey{}, true))
	p, err := s.FleetPrincipal(r)
	if err != nil {
		return nil, err
	}
	if err := s.authorize(p, scope, ""); err != nil {
		return nil, err
	}
	if scope != "fleet:read" && bearer(r) == "" && !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		// a cookie's write must come as JSON, which no cross-site form can send
		return nil, fault("FORBIDDEN", "send the call as application/json")
	}
	switch name {
	case "sessions_list":
		return s.sessionsListTool(r, args)
	case "session_get":
		return s.sessionGetTool(r, args)
	case "session_read":
		return s.sessionReadTool(r, args)
	case "session_say":
		return s.sessionSayTool(r, p, args)
	case "session_answer":
		return s.sessionAnswerTool(r, args)
	case "session_stop":
		return s.sessionStopTool(r, args)
	case "session_new":
		return s.sessionNewTool(r, p, args)
	case "task_list":
		return s.taskListTool(p, args)
	case "task_get":
		return s.taskGetTool(p, args)
	case "wait":
		return s.waitTool(r, p, args)
	}
	return nil, fault("INVALID_ARGUMENT", "Unknown session tool")
}

// --- the list ----------------------------------------------------------------

// SessionAsk is what a session is asking, as the inventory says it.
type SessionAsk struct {
	Kind string `json:"kind"`
	Text string `json:"text,omitempty"`
}

// SessionRow is one session as these tools show it.
type SessionRow struct {
	// ID is what every other tool takes: the session's worker id while it is
	// live (the one the console talks to it by), else the list's own id.
	ID       string      `json:"id"`
	WorkerID string      `json:"worker_id,omitempty"`
	Task     string      `json:"task,omitempty"`
	Title    string      `json:"title"`
	Repo     string      `json:"repo,omitempty"`
	Agent    string      `json:"agent,omitempty"`
	Machine  string      `json:"machine,omitempty"`
	Status   string      `json:"status"` // needs_you · working · idle · ended
	State    string      `json:"state"`  // the list's own word (asking, turn_done, parked, …)
	Asking   *SessionAsk `json:"asking,omitempty"`
	Why      string      `json:"why,omitempty"`
	CanTalk  bool        `json:"can_talk"`
	Lost     bool        `json:"machine_lost,omitempty"`
	Updated  string      `json:"updated,omitempty"`
	URL      string      `json:"url"`

	ref     string
	histID  string // the session's own ID, for an ended one's history
	tokens  int64
	aliases []string
}

// sessionStatus folds the list's tag into four words.
func sessionStatus(group, tag string) string {
	if group == "gone" {
		return "ended"
	}
	switch tag {
	case "asking", "failed", "stopped", "parked", "waiting_you":
		return "needs_you"
	case "working", "looping":
		return "working"
	}
	return "idle"
}

// sessionSnapshot is the caller's sessions, from the hub's cached inventory.
func (s *Server) sessionSnapshot(r *http.Request) ([]SessionRow, error) {
	res, err := s.FleetSessions(r)
	if err != nil {
		return nil, err
	}
	live, _ := res["sessions"].([]FleetSession)
	byWID := map[string]FleetSession{}
	for _, fs := range live {
		if fs.WorkerID != nil {
			byWID[*fs.WorkerID] = fs
		}
	}
	base := s.nodeHubURL(r) + AppPrefix + "/s/"
	var out []SessionRow
	b, _ := res["board"].(*Board)
	if b == nil {
		// no list (an admin's everyone view): the live windows alone
		for _, fs := range live {
			if fs.WorkerID == nil || fs.Worker == nil || fs.Worker["test"] == true {
				continue
			}
			st := wstr(fs.Worker, "state")
			tag := boardStateTag(st)
			row := SessionRow{ID: *fs.WorkerID, WorkerID: *fs.WorkerID, Title: wstr(fs.Worker, "title"), Repo: wstr(fs.Worker, "repo"),
				Agent: wstr(fs.Worker, "agent"), Machine: fs.MachineName, State: tag, Status: sessionStatus("", tag),
				Lost: fs.Availability == "lost", ref: *fs.WorkerID, tokens: fs.TokensToday}
			row.CanTalk = !row.Lost
			fillAsk(&row, fs.Worker)
			row.URL = base + url.PathEscape(row.ref)
			out = append(out, row)
		}
		return out, nil
	}
	for _, br := range b.Rows {
		row := SessionRow{ID: br.ID, WorkerID: br.WorkerID, Task: br.Task, Title: br.Title, Repo: br.Repo, Agent: br.Agent,
			Machine: br.Machine, State: br.Tag, Status: sessionStatus(br.Group, br.Tag), CanTalk: br.CanTalk, Lost: br.Lost}
		if br.Group == "pin" && br.State != "" {
			row.Status = sessionStatus("", boardStateTag(br.State))
		}
		if br.WorkerID != "" {
			row.ID = br.WorkerID
		}
		if len(br.Why) == 2 {
			row.Why = br.Why[1]
		}
		at := br.ActivityAt
		if br.At > at {
			at = br.At
		}
		if at > 0 {
			row.Updated = time.Unix(at, 0).UTC().Format(time.RFC3339)
		}
		// the console's own reference for its page (session-list.ts rowRef)
		row.ref = br.WorkerID
		for _, c := range []string{br.TaskID, br.Task, br.Code, br.ID} {
			if row.ref == "" {
				row.ref = c
			}
		}
		row.URL = base + url.PathEscape(row.ref)
		row.aliases = []string{br.ID, br.WorkerID, br.Task, br.TaskID, br.Code}
		row.histID = br.ID
		if br.History != nil && br.History.ID != "" {
			row.histID = br.History.ID
			row.aliases = append(row.aliases, br.History.ID)
		}
		if fs, ok := byWID[br.WorkerID]; ok && br.WorkerID != "" {
			fillAsk(&row, fs.Worker)
			row.tokens = fs.TokensToday
		}
		out = append(out, row)
	}
	return out, nil
}

// fillAsk is what the inventory says the session asks: the agent's own words
// first (status_kind / status_msg, OSC 7501), else the hooks' subtype.
func fillAsk(row *SessionRow, w map[string]any) {
	if row.Status != "needs_you" || w == nil {
		return
	}
	kind, text := wstr(w, "status_kind"), wstr(w, "status_msg")
	if kind == "" {
		kind = wstr(w, "needs")
	}
	if kind == "" && text == "" {
		return
	}
	row.Asking = &SessionAsk{Kind: kind, Text: clip(text, 500)}
}

// sessionFind is the caller's session id names: its worker id, the list's id,
// fid:<id>, or its task's T<n> / code.
func sessionFind(rows []SessionRow, id string) (SessionRow, bool) {
	id = strings.TrimSpace(id)
	if id == "" {
		return SessionRow{}, false
	}
	bare := strings.TrimPrefix(id, "fid:")
	for _, r := range rows {
		if r.ID == id || r.ref == id {
			return r, true
		}
	}
	for _, r := range rows {
		for _, a := range r.aliases {
			if a != "" && (a == id || a == bare) {
				return r, true
			}
		}
	}
	return SessionRow{}, false
}

func sessionCounts(rows []SessionRow) map[string]int {
	c := map[string]int{"needs_you": 0, "working": 0, "idle": 0, "ended": 0, "total": 0}
	for _, r := range rows {
		c[r.Status]++
		if r.Status != "ended" {
			c["total"]++
		}
	}
	return c
}

func sessionSummary(c map[string]int) string {
	if c["total"] == 0 {
		return fmt.Sprintf("No live sessions (%d ended in the last %d days).", c["ended"], boardGoneDays)
	}
	return fmt.Sprintf("%d live: %d need you, %d working, %d idle (%d ended in the last %d days).",
		c["total"], c["needs_you"], c["working"], c["idle"], c["ended"], boardGoneDays)
}

func repoMatches(have, want string) bool {
	if want == "" {
		return true
	}
	have, want = strings.ToLower(have), strings.ToLower(want)
	return have == want || strings.HasSuffix(have, "/"+want)
}

func (s *Server) sessionsListTool(r *http.Request, args map[string]any) (any, error) {
	if err := checkFields(args, nil, "view", "repo"); err != nil {
		return nil, err
	}
	view, _ := args["view"].(string)
	if view == "" {
		view = "needs_you"
	}
	switch view {
	case "needs_you", "live", "ended", "all":
	default:
		return nil, fault("INVALID_ARGUMENT", "view is needs_you, live, ended or all")
	}
	repo, _ := args["repo"].(string)
	rows, err := s.sessionSnapshot(r)
	if err != nil {
		return nil, err
	}
	counts := sessionCounts(rows)
	kept := []SessionRow{}
	for _, row := range rows {
		if !repoMatches(row.Repo, repo) {
			continue
		}
		switch {
		case view == "needs_you" && row.Status != "needs_you":
			continue
		case view == "live" && row.Status == "ended":
			continue
		case view == "ended" && row.Status != "ended":
			continue
		}
		kept = append(kept, row)
	}
	return map[string]any{"view": view, "sessions": kept, "counts": counts, "summary": sessionSummary(counts)}, nil
}

func (s *Server) sessionGetTool(r *http.Request, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"id"}); err != nil {
		return nil, err
	}
	id, _ := args["id"].(string)
	rows, err := s.sessionSnapshot(r)
	if err != nil {
		return nil, err
	}
	row, ok := sessionFind(rows, id)
	if !ok {
		return nil, fault("NOT_FOUND", "no such session of yours")
	}
	out := map[string]any{"session": row}
	if row.tokens > 0 {
		out["tokens_today"] = row.tokens
	}
	// what it asks, with the fingerprint session_answer takes: the session's
	// own gate, read along — only for a session that asks, never otherwise
	if row.Status == "needs_you" && row.WorkerID != "" {
		snap, err := s.sessionView(r, row.WorkerID, true)
		switch {
		case err != nil:
			out["pending_error"] = err.Error()
		case snap.ask != nil:
			out["pending"] = pendingOf(snap.ask)
		}
	}
	return out, nil
}

// pendingOf is the view's ask as session_answer takes it.
func pendingOf(ask map[string]any) map[string]any {
	out := map[string]any{"pending_id": ask["fp"], "kind": ask["kind"]}
	if out["kind"] == nil || out["kind"] == "" {
		out["kind"] = "question"
	}
	for _, k := range []string{"tool", "summary", "questions"} {
		if v, ok := ask[k]; ok {
			out[k] = v
		}
	}
	return out
}

// --- the conversation ----------------------------------------------------------

// sessionCapture is a ResponseWriter an internal call writes into, read while
// it is still writing (the view is a stream).
type sessionCapture struct {
	mu     sync.Mutex
	header http.Header
	status int
	buf    bytes.Buffer
}

func (c *sessionCapture) Header() http.Header { return c.header }
func (c *sessionCapture) WriteHeader(code int) {
	c.mu.Lock()
	if c.status == 0 {
		c.status = code
	}
	c.mu.Unlock()
}
func (c *sessionCapture) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.status == 0 {
		c.status = http.StatusOK
	}
	if c.buf.Len() > 4<<20 {
		return 0, errors.New("too large")
	}
	return c.buf.Write(b)
}
func (c *sessionCapture) Flush() {}
func (c *sessionCapture) read() (int, []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status, append([]byte(nil), c.buf.Bytes()...)
}

// sessionRequest is an internal request to a chat road, as the caller: their
// context and headers (cookie or bearer), the page's own header.
func sessionRequest(ctx context.Context, r *http.Request, method, route string, q url.Values, body any) *http.Request {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	u := ChatPathPrefix + route
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, _ := http.NewRequestWithContext(ctx, method, u, rd)
	req.Header = r.Header.Clone()
	for _, k := range []string{"Accept-Encoding", "If-None-Match", "Content-Length"} {
		req.Header.Del(k)
	}
	req.Header.Set("X-Fleet-Webchat", "1")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Host, req.RemoteAddr, req.TLS = r.Host, r.RemoteAddr, r.TLS
	return req
}

// chatFault is a chat road's refusal as a tool error: its code and words.
func chatFault(status int, body []byte) error {
	var e struct {
		Code  string `json:"code"`
		Error any    `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	code := e.Code
	if code == "" {
		code = "HTTP_" + strconv.Itoa(status)
	}
	msg := ""
	switch v := e.Error.(type) {
	case string:
		msg = v
	case map[string]any:
		msg, _ = v["message"].(string)
		if c, _ := v["code"].(string); c != "" && e.Code == "" {
			code = c
		}
	}
	if msg == "" {
		msg = strings.TrimSpace(clip(string(body), 300))
	}
	return &FleetFault{Code: code, Message: msg}
}

// chatCall runs one chat road and answers its JSON.
func (s *Server) chatCall(r *http.Request, route string, q url.Values, body any, wait time.Duration) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(r.Context(), wait)
	defer cancel()
	cw := &sessionCapture{header: http.Header{}}
	func() {
		defer func() {
			if v := recover(); v != nil && v != http.ErrAbortHandler {
				panic(v)
			}
		}()
		s.handleChat(cw, sessionRequest(ctx, r, http.MethodPost, route, q, body))
	}()
	status, raw := cw.read()
	if status < 200 || status > 299 {
		return nil, chatFault(status, raw)
	}
	out := map[string]any{}
	if len(bytes.TrimSpace(raw)) > 0 && json.Unmarshal(raw, &out) != nil {
		return nil, fault("INTERNAL", "the session's answer was not JSON")
	}
	return out, nil
}

// viewSnap is what a read-along view said in its first moments.
type viewSnap struct {
	items  []map[string]any
	state  map[string]any
	ask    map[string]any
	source string // live · copy
	copyAt string
}

// sessionViewWait bounds one read-along: its first frame, and the session
// gate's first word on it (the ask).
var sessionViewWait = 8 * time.Second

// sessionView reads a session's conversation the way its page does — the
// view's stream, held only until its first items and (wantAsk) its gate's word
// have come — and falls back to the copy beside the entry.
func (s *Server) sessionView(r *http.Request, wid string, wantAsk bool) (viewSnap, error) {
	ctx, cancel := context.WithTimeout(r.Context(), sessionViewWait)
	defer cancel()
	cw := &sessionCapture{header: http.Header{}}
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer func() { _ = recover() }() // a proxy cut short panics ErrAbortHandler
		s.handleChat(cw, sessionRequest(ctx, r, http.MethodGet, chatViewRoute, url.Values{"worker": {wid}}, nil))
	}()
	var snap viewSnap
	var itemsAt time.Time
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	finished := false
	for !finished {
		select {
		case <-done:
			finished = true
		case <-ctx.Done():
			finished = true
		case <-tick.C:
		}
		status, raw := cw.read()
		if status != 0 && status != http.StatusOK {
			cancel()
			<-done
			return s.sessionViewCopy(r, wid, chatFault(status, raw))
		}
		snap.items, snap.state = nil, nil
		for _, ev := range bytes.Split(raw, []byte("\n\n")) {
			for _, line := range bytes.Split(ev, []byte("\n")) {
				data, ok := bytes.CutPrefix(line, []byte("data: "))
				if !ok {
					continue
				}
				var f map[string]any
				if json.Unmarshal(data, &f) != nil {
					continue
				}
				switch f["t"] {
				case "state":
					snap.state = f
				case "reset":
					snap.items = nil
				case "items":
					list, _ := f["items"].([]any)
					if f["replace"] == true {
						snap.items = nil
					}
					for _, it := range list {
						if m, ok := it.(map[string]any); ok {
							snap.items = append(snap.items, m)
						}
					}
					if itemsAt.IsZero() {
						itemsAt = time.Now()
					}
				}
			}
		}
		gated := snap.state != nil && snap.state["talk_reason"] != "checking"
		switch {
		case !itemsAt.IsZero() && (!wantAsk || gated):
			finished = true
		case !itemsAt.IsZero() && time.Since(itemsAt) > 2*time.Second:
			finished = true // its gate is slow: what the view has
		case wantAsk && gated && snap.state["session"] == "":
			finished = true // a session with no record yet: nothing to wait for
		}
	}
	cancel()
	<-done
	if itemsAt.IsZero() && snap.state == nil {
		return s.sessionViewCopy(r, wid, fault("TIMEOUT", "the session's machine did not answer in time"))
	}
	if snap.state != nil {
		snap.ask, _ = snap.state["ask"].(map[string]any)
	}
	snap.source = "live"
	return snap, nil
}

// sessionViewCopy is the copy beside the entry (chat_view.go), when the live
// read could not be had; live's error when there is none.
func (s *Server) sessionViewCopy(r *http.Request, wid string, liveErr error) (viewSnap, error) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	cw := &sessionCapture{header: http.Header{}}
	s.handleChat(cw, sessionRequest(ctx, r, http.MethodGet, chatViewRoute, url.Values{"worker": {wid}, "cached": {"1"}}, nil))
	status, raw := cw.read()
	var c struct {
		Items  []map[string]any `json:"items"`
		Mirror *struct {
			At string `json:"at"`
		} `json:"mirror"`
	}
	if status != http.StatusOK || json.Unmarshal(raw, &c) != nil || c.Mirror == nil {
		return viewSnap{}, liveErr
	}
	return viewSnap{items: c.Items, source: "copy", copyAt: c.Mirror.At}, nil
}

// clipTurn cuts s to n characters, saying so.
func clipTurn(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n]) + "… [clipped]"
}

// turnsOf is a view's items as turns: a reply's pieces joined, a step one line,
// a step's output never (the page opens it on demand; so may the person).
func turnsOf(items []map[string]any) []map[string]any {
	out := []map[string]any{}
	add := func(role, kind, text string) {
		out = append(out, map[string]any{"role": role, "kind": kind, "text": clipTurn(text, 2000)})
	}
	var reply strings.Builder
	flush := func() {
		if reply.Len() > 0 {
			add("assistant", "message", strings.TrimSpace(reply.String()))
			reply.Reset()
		}
	}
	for _, it := range items {
		t, _ := it["t"].(string)
		if t == "text" {
			d, _ := it["d"].(string)
			reply.WriteString(d)
			continue
		}
		if t == "tool_result" || t == "image_more" {
			continue
		}
		flush()
		switch t {
		case "user":
			text, _ := it["text"].(string)
			if pics, _ := it["images"].([]any); len(pics) > 0 {
				text = strings.TrimSpace(text + fmt.Sprintf(" [%d picture(s)]", len(pics)))
			}
			add("user", "message", text)
		case "tool":
			sum, _ := it["summary"].(string)
			if sum == "" {
				sum, _ = it["name"].(string)
			}
			add("assistant", "tool", sum)
		case "note":
			text, _ := it["text"].(string)
			add("system", "note", text)
		case "error":
			msg, _ := it["msg"].(string)
			add("system", "error", msg)
		case "stopped":
			add("system", "stopped", "the turn was stopped")
		case "image":
			add("assistant", "image", "[a picture]")
		case "page":
			title, _ := it["title"].(string)
			u, _ := it["url"].(string)
			add("assistant", "page", strings.TrimSpace(title+" "+u))
		}
	}
	flush()
	return out
}

func (s *Server) sessionReadTool(r *http.Request, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"id"}, "limit"); err != nil {
		return nil, err
	}
	limit := 20
	if v, ok := args["limit"]; ok {
		n, err := argInt(v, "limit", 1, 50)
		if err != nil {
			return nil, err
		}
		limit = n
	}
	row, err := s.sessionOf(r, args)
	if err != nil {
		return nil, err
	}
	wid := row.WorkerID
	if wid == "" {
		wid = "fid:" + row.histID // an ended session's history (closedHistory takes a full ID only)
	}
	snap, err := s.sessionView(r, wid, false)
	if err != nil {
		return nil, err
	}
	turns := turnsOf(snap.items)
	more := len(turns) > limit
	if more {
		turns = turns[len(turns)-limit:]
	}
	out := map[string]any{"id": row.ID, "turns": turns, "more_before": more, "source": snap.source,
		"note": "Each turn's text is clipped to 2000 characters; a step's output is never included. Open url for the whole conversation."}
	if snap.copyAt != "" {
		out["copy_at"] = snap.copyAt
	}
	out["url"] = row.URL
	return out, nil
}

// sessionOf is the session args["id"] names, among the caller's own.
func (s *Server) sessionOf(r *http.Request, args map[string]any) (SessionRow, error) {
	id, _ := args["id"].(string)
	rows, err := s.sessionSnapshot(r)
	if err != nil {
		return SessionRow{}, err
	}
	row, ok := sessionFind(rows, id)
	if !ok {
		return SessionRow{}, fault("NOT_FOUND", "no such session of yours")
	}
	return row, nil
}

// liveSession is sessionOf for a write: a session with a live window.
func (s *Server) liveSession(r *http.Request, args map[string]any) (SessionRow, error) {
	row, err := s.sessionOf(r, args)
	if err != nil {
		return row, err
	}
	if row.WorkerID == "" || row.Status == "ended" {
		return row, fault("INVALID_STATE", "this session has no live window to talk to (it ended); start a new one with session_new")
	}
	return row, nil
}

// --- talking -------------------------------------------------------------------

// sessionIdem remembers a write's answer under (person, key) for a day, so a
// retried call never acts twice; a concurrent retry waits for the first.
type sessionIdem struct {
	mu    sync.Mutex
	byKey map[string]*idemEntry
}

type idemEntry struct {
	done chan struct{}
	args string
	out  any
	err  error
	at   time.Time
}

var sessionIdems = &sessionIdem{byKey: map[string]*idemEntry{}}

const sessionIdemKeep = 24 * time.Hour

// once runs fn for key at most once (a failure is forgotten: it may be retried).
func (c *sessionIdem) once(key, args string, fn func() (any, error)) (any, error, bool) {
	now := time.Now()
	c.mu.Lock()
	for k, e := range c.byKey {
		if now.Sub(e.at) > sessionIdemKeep {
			delete(c.byKey, k)
		}
	}
	if e, ok := c.byKey[key]; ok {
		c.mu.Unlock()
		<-e.done
		if e.args != args {
			return nil, fault("IDEMPOTENCY_CONFLICT", "this idempotency_key was used with other arguments"), true
		}
		if e.err == nil {
			return e.out, nil, true
		}
		return nil, e.err, true
	}
	e := &idemEntry{done: make(chan struct{}), args: args, at: now}
	c.byKey[key] = e
	c.mu.Unlock()
	e.out, e.err = fn()
	if e.err != nil {
		c.mu.Lock()
		delete(c.byKey, key)
		c.mu.Unlock()
	}
	close(e.done)
	return e.out, e.err, false
}

// deliveryID is the line's id the session's door dedups on (a UUID's shape),
// made from the caller's key — the same key is the same line, on every replica.
func deliveryID(actor, key string) string {
	h := sha256.Sum256([]byte("T4DN say\x00" + actor + "\x00" + key))
	x := hex.EncodeToString(h[:16])
	return x[:8] + "-" + x[8:12] + "-4" + x[13:16] + "-a" + x[17:20] + "-" + x[20:32]
}

func idemKey(args map[string]any) (string, error) {
	k, _ := args["idempotency_key"].(string)
	if !idemRE.MatchString(k) {
		return "", fault("INVALID_ARGUMENT", "idempotency_key: 1–128 of [A-Za-z0-9_.:-]")
	}
	return k, nil
}

func argsDigest(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func (s *Server) sessionSayTool(r *http.Request, p fleetPrincipal, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"id", "text", "idempotency_key"}); err != nil {
		return nil, err
	}
	key, err := idemKey(args)
	if err != nil {
		return nil, err
	}
	text, _ := args["text"].(string)
	if strings.TrimSpace(text) == "" {
		return nil, fault("INVALID_ARGUMENT", "text is empty")
	}
	if utf8.RuneCountInString(text) > 20000 {
		return nil, fault("INVALID_ARGUMENT", "text is at most 20000 characters")
	}
	id, _ := args["id"].(string)
	out, err, replay := sessionIdems.once("say\x00"+p.Actor+"\x00"+key, argsDigest([]string{id, text}), func() (any, error) {
		row, err := s.liveSession(r, args)
		if err != nil {
			return nil, err
		}
		a, err := s.chatCall(r, "say", url.Values{"worker": {row.WorkerID}},
			map[string]any{"id": deliveryID(p.Actor, key), "text": text}, chatWorkerRoutes["say"].wait)
		if err != nil {
			return nil, err
		}
		res := map[string]any{"id": row.ID, "delivery": a["delivery"], "state": a["state"], "url": row.URL}
		if v, ok := a["reason"]; ok {
			res["reason"] = v
		}
		switch a["state"] {
		case "sent":
			res["meaning"] = "The session took the line as its next turn (a parked session is being woken). Read it with session_read or wait."
		case "queued":
			res["meaning"] = "Queued: the session is busy (a turn running, or someone typing in its terminal); it goes in when that ends."
		case "refused":
			res["meaning"] = "Refused by the session's gate; nothing was sent. See reason."
		}
		return res, nil
	})
	if replay && err == nil {
		if m, ok := out.(map[string]any); ok {
			c := map[string]any{"replayed": true}
			for k, v := range m {
				c[k] = v
			}
			return c, nil
		}
	}
	return out, err
}

func (s *Server) sessionAnswerTool(r *http.Request, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"id"}, "pending_id", "option", "decision", "text", "answers"); err != nil {
		return nil, err
	}
	row, err := s.liveSession(r, args)
	if err != nil {
		return nil, err
	}
	fp, _ := args["pending_id"].(string)
	var ask map[string]any
	_, isNum := args["option"].(float64)
	if _, ok := args["option"].(json.Number); ok {
		isNum = true
	}
	if fp == "" || isNum {
		// what it asks now, from its own gate: the fingerprint, the options
		snap, err := s.sessionView(r, row.WorkerID, true)
		if err != nil {
			return nil, err
		}
		if snap.ask == nil {
			return nil, fault("INVALID_STATE", "this session is not asking anything right now")
		}
		ask = snap.ask
		if fp == "" {
			fp, _ = ask["fp"].(string)
		} else if f, _ := ask["fp"].(string); f != fp {
			return nil, fault("INVALID_STATE", "that question is no longer the one it asks (pending_id "+f+" now); read session_get again")
		}
	}
	body := map[string]any{"fp": fp}
	switch d, _ := args["decision"].(string); {
	case d == "allow" || d == "deny":
		body["allow"] = d == "allow"
	case d != "":
		return nil, fault("INVALID_ARGUMENT", "decision is allow or deny")
	case args["answers"] != nil:
		m, ok := args["answers"].(map[string]any)
		if !ok || len(m) == 0 {
			return nil, fault("INVALID_ARGUMENT", "answers is {<question text>: <option label>}")
		}
		body["answers"] = m
	case args["option"] != nil:
		var pick string
		switch v := args["option"].(type) {
		case string:
			pick = v
		default:
			n, err := argInt(v, "option", 1, 50)
			if err != nil {
				return nil, err
			}
			qs, _ := ask["questions"].([]any)
			if len(qs) == 0 {
				return nil, fault("INVALID_ARGUMENT", "this ask has no numbered options; give the option's words")
			}
			q0, _ := qs[0].(map[string]any)
			opts, _ := q0["options"].([]any)
			if n > len(opts) {
				return nil, fault("INVALID_ARGUMENT", fmt.Sprintf("option is 1–%d", len(opts)))
			}
			o, _ := opts[n-1].(map[string]any)
			pick, _ = o["label"].(string)
		}
		if strings.TrimSpace(pick) == "" {
			return nil, fault("INVALID_ARGUMENT", "option is empty")
		}
		body["picks"] = []string{pick}
	case args["text"] != nil:
		t, _ := args["text"].(string)
		if strings.TrimSpace(t) == "" {
			return nil, fault("INVALID_ARGUMENT", "text is empty")
		}
		body["picks"] = []string{t}
	default:
		return nil, fault("INVALID_ARGUMENT", "give decision (allow|deny), option, answers or text")
	}
	if !regexpFP(fp) {
		return nil, fault("INVALID_ARGUMENT", "pending_id is the 16-hex fingerprint session_get gives")
	}
	a, err := s.chatCall(r, "answer", url.Values{"worker": {row.WorkerID}}, body, chatWorkerRoutes["answer"].wait)
	if err != nil {
		return nil, err
	}
	a["id"], a["url"] = row.ID, row.URL
	return a, nil
}

func regexpFP(fp string) bool {
	if len(fp) != 16 {
		return false
	}
	_, err := hex.DecodeString(fp)
	return err == nil && strings.ToLower(fp) == fp
}

func (s *Server) sessionStopTool(r *http.Request, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"id"}); err != nil {
		return nil, err
	}
	row, err := s.liveSession(r, args)
	if err != nil {
		return nil, err
	}
	a, err := s.chatCall(r, "stop", url.Values{"worker": {row.WorkerID}}, map[string]any{}, chatWorkerRoutes["stop"].wait)
	if err != nil {
		return nil, err
	}
	a["id"], a["url"] = row.ID, row.URL
	a["meaning"] = "The session's current turn was stopped (Esc); the session itself stays open."
	return a, nil
}

// sessionNewMax is how many sessions one session_new may open.
const sessionNewMax = 8

func (s *Server) sessionNewTool(r *http.Request, p fleetPrincipal, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"items", "idempotency_key"}); err != nil {
		return nil, err
	}
	key, err := idemKey(args)
	if err != nil {
		return nil, err
	}
	items, ok := args["items"].([]any)
	if !ok || len(items) == 0 || len(items) > sessionNewMax {
		return nil, fault("INVALID_ARGUMENT", fmt.Sprintf("items is a list of 1–%d {text, agent, repo?, machine?}", sessionNewMax))
	}
	type item struct {
		Text, Agent, Repo, Machine string
	}
	parsed := make([]item, len(items))
	for i, raw := range items {
		m, ok := raw.(map[string]any)
		if !ok {
			return nil, fault("INVALID_ARGUMENT", fmt.Sprintf("items[%d] is an object", i))
		}
		if err := checkFields(m, []string{"text"}, "agent", "repo", "machine"); err != nil {
			return nil, fault("INVALID_ARGUMENT", fmt.Sprintf("items[%d]: text is required; agent, repo, machine optional", i))
		}
		it := item{}
		it.Text, _ = m["text"].(string)
		it.Agent, _ = m["agent"].(string)
		it.Repo, _ = m["repo"].(string)
		it.Machine, _ = m["machine"].(string)
		if strings.TrimSpace(it.Text) == "" || utf8.RuneCountInString(it.Text) > 20000 {
			return nil, fault("INVALID_ARGUMENT", fmt.Sprintf("items[%d].text: 1–20000 characters", i))
		}
		if it.Agent == "" {
			it.Agent = "claude"
		}
		if it.Agent != "claude" && it.Agent != "codex" {
			return nil, fault("INVALID_ARGUMENT", fmt.Sprintf("items[%d].agent is claude or codex", i))
		}
		parsed[i] = it
	}
	results := make([]map[string]any, len(parsed))
	var wg sync.WaitGroup
	for i, it := range parsed {
		wg.Add(1)
		go func(i int, it item) {
			defer wg.Done()
			ik := key + "#" + strconv.Itoa(i)
			out, err, replay := sessionIdems.once("new\x00"+p.Actor+"\x00"+ik, argsDigest(it), func() (any, error) {
				a, err := s.chatCall(r, "open", nil, map[string]any{"agent": it.Agent, "text": it.Text}, 60*time.Second)
				if err != nil {
					return nil, err
				}
				if a["state"] == "refused" {
					why, _ := a["reason"].(string)
					if why == "" {
						why, _ = a["error"].(string)
					}
					return nil, &FleetFault{Code: "refused", Message: why}
				}
				return a, nil
			})
			res := map[string]any{"index": i, "agent": it.Agent}
			if err != nil {
				e := errorObject(err)
				res["state"], res["error"] = "failed", e
				results[i] = res
				return
			}
			a, _ := out.(map[string]any)
			worker, _ := a["worker"].(string)
			if worker == "" {
				worker, _ = a["worker_id"].(string)
			}
			fid, _ := a["fid"].(string)
			ref := worker
			if ref == "" && fid != "" {
				ref = "fid:" + fid
			}
			res["state"], res["id"] = "opened", ref
			if fid != "" {
				res["fid"] = fid
			}
			if ref != "" {
				res["url"] = s.nodeHubURL(r) + AppPrefix + "/s/" + url.PathEscape(ref)
			}
			if v, ok := a["task"].(string); ok && v != "" {
				res["task"] = v
			}
			if v, ok := a["notice"].(string); ok && v != "" {
				res["notice"] = v
			}
			if replay {
				res["replayed"] = true
			}
			var notes []string
			if it.Repo != "" {
				notes = append(notes, "repo "+it.Repo+" was not used: a session opened here starts on your home with no repo, as the console's 新会话 does (worker_start opens an issue in a repo)")
			}
			if it.Machine != "" && it.Machine != "auto" {
				notes = append(notes, "machine "+it.Machine+" was not used: a session opened here starts on your home machine")
			}
			if len(notes) > 0 {
				res["note"] = strings.Join(notes, "; ")
			}
			results[i] = res
		}(i, it)
	}
	wg.Wait()
	opened := 0
	for _, res := range results {
		if res["state"] == "opened" {
			opened++
		}
	}
	return map[string]any{"sessions": results, "opened": opened, "failed": len(results) - opened,
		"meaning": "Each opened session has its first line as its first turn. A session's row can take a few seconds to reach sessions_list."}, nil
}

// --- tasks ---------------------------------------------------------------------

func (s *Server) taskListTool(p fleetPrincipal, args map[string]any) (any, error) {
	if err := checkFields(args, nil, "limit"); err != nil {
		return nil, err
	}
	limit := 50
	if v, ok := args["limit"]; ok {
		n, err := argInt(v, "limit", 1, 500)
		if err != nil {
			return nil, err
		}
		limit = n
	}
	owner := ""
	if p.Person != "" {
		owner = p.Actor
	}
	return s.tasksBody(owner, limit)
}

func (s *Server) taskGetTool(p fleetPrincipal, args map[string]any) (any, error) {
	if err := checkFields(args, []string{"ref"}); err != nil {
		return nil, err
	}
	ref, _ := args["ref"].(string)
	t, err := s.ownTask(p, strings.TrimSpace(ref))
	if err != nil {
		return nil, fault("NOT_FOUND", "no such task of yours (or a code naming several — give it longer)")
	}
	views, err := s.taskViews([]store.FleetTask{t})
	if err != nil {
		return nil, err
	}
	return views[0], nil
}

// --- waiting -------------------------------------------------------------------

// waitSlots bounds one person's waits in flight.
const waitSlots = 3

var sessionWaits = struct {
	mu sync.Mutex
	n  map[string]int
}{n: map[string]int{}}

// waitPoll is how often a wait reads the list again with no heartbeat.
var waitPoll = 2 * time.Second

// waitMark is one session's word in a cursor.
type waitMark struct {
	S string `json:"s"` // status
	T string `json:"t"` // tag
}

func encodeCursor(m map[string]waitMark) string {
	b, _ := json.Marshal(m)
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodeCursor(c string) (map[string]waitMark, error) {
	b, err := base64.RawURLEncoding.DecodeString(c)
	m := map[string]waitMark{}
	if err != nil || json.Unmarshal(b, &m) != nil {
		return nil, fault("INVALID_ARGUMENT", "cursor is one a wait returned")
	}
	return m, nil
}

func (s *Server) waitTool(r *http.Request, p fleetPrincipal, args map[string]any) (any, error) {
	if err := checkFields(args, nil, "ids", "until", "cursor", "timeout_s"); err != nil {
		return nil, err
	}
	until, _ := args["until"].(string)
	if until == "" {
		until = "needs_you"
	}
	if until != "needs_you" && until != "done" && until != "any" {
		return nil, fault("INVALID_ARGUMENT", "until is needs_you, done or any")
	}
	timeout := 60
	if v, ok := args["timeout_s"]; ok {
		n, err := argInt(v, "timeout_s", 1, 300)
		if err != nil {
			return nil, err
		}
		timeout = n
	}
	var ids []string
	if v, ok := args["ids"]; ok {
		list, ok := v.([]any)
		if !ok || len(list) > 100 {
			return nil, fault("INVALID_ARGUMENT", "ids is a list of session ids (≤100)")
		}
		for _, x := range list {
			if id, ok := x.(string); ok && id != "" {
				ids = append(ids, id)
			}
		}
	}
	var prev map[string]waitMark
	if c, _ := args["cursor"].(string); c != "" {
		m, err := decodeCursor(c)
		if err != nil {
			return nil, err
		}
		prev = m
	}
	who := p.Actor
	sessionWaits.mu.Lock()
	if sessionWaits.n[who] >= waitSlots {
		sessionWaits.mu.Unlock()
		return nil, fault("AT_CAPACITY", fmt.Sprintf("too many waits: at most %d at once", waitSlots))
	}
	sessionWaits.n[who]++
	sessionWaits.mu.Unlock()
	defer func() {
		sessionWaits.mu.Lock()
		if sessionWaits.n[who]--; sessionWaits.n[who] <= 0 {
			delete(sessionWaits.n, who)
		}
		sessionWaits.mu.Unlock()
	}()

	// the sessions watched: those ids name, else every one of the caller's
	read := func() (map[string]waitMark, map[string]SessionRow, error) {
		rows, err := s.sessionSnapshot(r)
		if err != nil {
			return nil, nil, err
		}
		marks, byID := map[string]waitMark{}, map[string]SessionRow{}
		if len(ids) > 0 {
			for _, id := range ids {
				if row, ok := sessionFind(rows, id); ok {
					marks[row.ID], byID[row.ID] = waitMark{row.Status, row.State}, row
				}
			}
		} else {
			for _, row := range rows {
				if row.Status == "ended" && (prev == nil || prev[row.ID] == (waitMark{})) {
					continue // a long-ended row is not news
				}
				marks[row.ID], byID[row.ID] = waitMark{row.Status, row.State}, row
			}
		}
		return marks, byID, nil
	}
	matches := func(from, to waitMark) bool {
		if from == to {
			return false
		}
		switch until {
		case "needs_you":
			return to.S == "needs_you" && from.S != "needs_you"
		case "done":
			return from.S == "working" && to.S != "working"
		}
		return true
	}
	deadline := time.NewTimer(time.Duration(timeout) * time.Second)
	defer deadline.Stop()
	poll := time.NewTicker(waitPoll)
	defer poll.Stop()
	for {
		changed := s.sessionsChanged.wait() // subscribe before reading
		marks, byID, err := read()
		if err != nil {
			return nil, err
		}
		base := prev
		if base == nil {
			base = map[string]waitMark{}
			if until == "needs_you" {
				// no cursor: what already needs you is news at once
				for id, m := range marks {
					if m.S != "needs_you" {
						base[id] = m
					}
				}
			} else {
				for id, m := range marks {
					base[id] = m
				}
			}
		}
		var events []map[string]any
		keys := make([]string, 0, len(marks))
		for id := range marks {
			keys = append(keys, id)
		}
		sort.Strings(keys)
		now := time.Now().UTC().Format(time.RFC3339)
		for _, id := range keys {
			from, to := base[id], marks[id]
			if !matches(from, to) {
				continue
			}
			row := byID[id]
			ev := map[string]any{"id": id, "title": row.Title, "from": from.S, "to": to.S, "state": to.T, "at": now, "url": row.URL}
			if row.Asking != nil {
				ev["asking"] = row.Asking
			}
			events = append(events, ev)
		}
		if len(events) > 0 {
			return map[string]any{"events": events, "cursor": encodeCursor(marks), "timed_out": false}, nil
		}
		if prev == nil {
			prev = marks // the baseline every later read is held to
		}
		select {
		case <-r.Context().Done():
			return nil, fault("TIMEOUT", "the call was cancelled")
		case <-deadline.C:
			return map[string]any{"events": []any{}, "cursor": encodeCursor(marks), "timed_out": true}, nil
		case <-changed:
		case <-poll.C:
		}
	}
}
