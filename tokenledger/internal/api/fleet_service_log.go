package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A service's log, live on its machine's page (claude-fleet#2797, EPIC #2792
// C5).
//
//	GET /v1/nodes/<host>/services/<login>/<name>/log            the stream
//	event: lines  data: {"lines":[{"ts":…,"text":…}], "skipped"?, "from", "start"?, "rotated"?, "at"}
//	event: end    data: {"error"?: …, "at"}                       the node stopped; reconnect
//	event: ping   data: {"at"}                                    every 20 s
//	GET …/log?before=<offset>                                     one page before it, JSON
//	HEAD …/log                                                    may I? (200 · 403 · 404 · 503), nothing asked of a node
//
// The cut is the roster's (共同约定 1): a reader who may not see (host, login)
// is answered 403 — whoever's the login, whatever the name — before anything
// is asked of a node; an admin outside a daily page's route sees every one.
// The page reads only this route (共同约定 2): the node reads the file, the
// hub passes it on. The hub masks every credential-shaped string before a
// line leaves it (the team bundle's own patterns), and however many people
// watch one service, the node is asked once: one follow per (host, login,
// name), its lines fanned out here, renewed every svcLogRenew while anyone
// watches and stopped svcLogLinger after the last one leaves.

// ServiceLogSegment is the path segment after the machine.
const ServiceLogSegment = "services"

var (
	// svcLogRenew is how often a follow is renewed (well inside the node's
	// control.ServiceLogLease); svcLogLinger how long a follow outlives its
	// last viewer — a reload reuses it; svcLogPageWait bounds a page read.
	svcLogRenew    = 20 * time.Second
	svcLogLinger   = 10 * time.Second
	svcLogPageWait = 10 * time.Second
	// svcLogPing keeps an idle stream talking, as the push channel's does.
	svcLogPing = 20 * time.Second
)

// svcLogName is a register entry's name, the daemon's own rule.
var svcLogName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,47}$`)

// svcLogMask is what a credential becomes.
const svcLogMask = "••••"

// svcLogKV is a key that names a credential and the value after it
// (TOKEN=…, "password": "…"): the key stays, a value of 4+ characters with a
// letter in it goes — a count (output_tokens: 5000) stays.
var svcLogKV = regexp.MustCompile(`(?i)([A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|api[_-]?key|private[_-]?key|credential|cookie)[A-Za-z0-9_.-]*"?\s*[=:]\s*"?)([^\s"',;&]*[A-Za-z][^\s"',;&]*)`)

// redactLogLine masks every credential-shaped string in a log line: the
// shapes the hub refuses in a team bundle (secretValREs — sk-ant-, ghp_,
// Bearer, a JWT, a private key…), and the value of a credential-named key.
func redactLogLine(s string) string {
	for _, re := range secretValREs {
		s = re.ReplaceAllString(s, svcLogMask)
	}
	return svcLogKV.ReplaceAllStringFunc(s, func(m string) string {
		sub := svcLogKV.FindStringSubmatch(m)
		if len(sub) < 3 || len([]rune(sub[2])) < 4 || sub[2] == svcLogMask {
			return m
		}
		return sub[1] + svcLogMask
	})
}

// svcLogKey is one register entry.
type svcLogKey struct{ host, login, name string }

// svcLogEvent is one event to a viewer.
type svcLogEvent struct {
	Lines   []control.ServiceLogLine `json:"lines"`
	Skipped int                      `json:"skipped,omitempty"`
	From    int64                    `json:"from"`
	Start   bool                     `json:"start,omitempty"`
	Rotated bool                     `json:"rotated,omitempty"`
	At      time.Time                `json:"at"`
	// end: the follow is over (Error says why when it was not asked).
	end   bool
	Error string `json:"error,omitempty"`
}

// svcLogFeed is one follow on a node and its viewers.
type svcLogFeed struct {
	key      svcLogKey
	op       string
	endpoint string
	nc       *nodeConn
	viewers  map[chan svcLogEvent]struct{}
	// recent is the last ServiceLogTail lines (masked), what a viewer who
	// joins later starts with; from / start describe its first line.
	recent []control.ServiceLogLine
	from   int64
	start  bool
	ready  bool
	done   bool
	linger *time.Timer
	quit   chan struct{}
}

// svcLogHub is every follow and page in flight.
type svcLogHub struct {
	mu    sync.Mutex
	feeds map[svcLogKey]*svcLogFeed
	byOp  map[string]*svcLogFeed
	pages map[string]chan control.Message
}

// opens counts the service_log follows sent (a test's read).
func (h *svcLogHub) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.feeds)
}

// svcLogSend is how a feed talks to its node (a seam: SendNodeWrite).
type svcLogSend func(ctx context.Context, endpoint string, m control.Message) error

// join adds a viewer to key's follow, opening it on endpoint when there is
// none; the returned leave must be called once.
func (h *svcLogHub) join(key svcLogKey, endpoint string, nc *nodeConn, send svcLogSend) (<-chan svcLogEvent, func()) {
	ch := make(chan svcLogEvent, 64)
	h.mu.Lock()
	if h.feeds == nil {
		h.feeds, h.byOp = map[svcLogKey]*svcLogFeed{}, map[string]*svcLogFeed{}
	}
	f := h.feeds[key]
	opened := false
	if f == nil || f.done {
		f = &svcLogFeed{key: key, op: control.NewOpID(), endpoint: endpoint, nc: nc,
			viewers: map[chan svcLogEvent]struct{}{}, quit: make(chan struct{})}
		h.feeds[key], h.byOp[f.op] = f, f
		opened = true
	}
	if f.linger != nil {
		f.linger.Stop()
		f.linger = nil
	}
	f.viewers[ch] = struct{}{}
	if f.ready {
		ch <- svcLogEvent{Lines: append([]control.ServiceLogLine(nil), f.recent...), From: f.from, Start: f.start, At: time.Now().UTC()}
	}
	h.mu.Unlock()

	if opened {
		h.open(f, send)
	}
	var once sync.Once
	return ch, func() { once.Do(func() { h.leave(f, ch, send) }) }
}

// open sends the follow and keeps renewing it until it ends.
func (h *svcLogHub) open(f *svcLogFeed, send svcLogSend) {
	msg, _ := control.New(control.TypeServiceLog, control.ServiceLog{Login: f.key.login, Name: f.key.name,
		Tail: control.ServiceLogTail, Follow: true})
	msg.OpID = f.op
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	err := send(ctx, f.endpoint, msg)
	cancel()
	if err != nil {
		h.end(f, "the machine's node program could not be asked: "+err.Error())
		return
	}
	go func() {
		t := time.NewTicker(svcLogRenew)
		defer t.Stop()
		for {
			select {
			case <-f.quit:
				return
			case <-t.C:
			}
			m, _ := control.New(control.TypeServiceLog, control.ServiceLog{Login: f.key.login, Name: f.key.name, Renew: true})
			m.OpID = f.op
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			if err := send(ctx, f.endpoint, m); err != nil {
				log.Printf("service log %s/%s/%s: renew: %v", f.key.host, f.key.login, f.key.name, err)
			}
			cancel()
		}
	}()
}

// leave drops a viewer; the last one starts the linger, past which the node
// is told to stop.
func (h *svcLogHub) leave(f *svcLogFeed, ch chan svcLogEvent, send svcLogSend) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(f.viewers, ch)
	if f.done || len(f.viewers) > 0 {
		return
	}
	f.linger = time.AfterFunc(svcLogLinger, func() {
		h.mu.Lock()
		if f.done || len(f.viewers) > 0 {
			h.mu.Unlock()
			return
		}
		h.finishLocked(f)
		h.mu.Unlock()
		m := control.Message{Type: control.TypeServiceLogStop, OpID: f.op}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := send(ctx, f.endpoint, m); err != nil {
			log.Printf("service log %s/%s/%s: stop: %v", f.key.host, f.key.login, f.key.name, err)
		}
	})
}

// finishLocked forgets f; its viewers are closed (h.mu held).
func (h *svcLogHub) finishLocked(f *svcLogFeed) {
	if f.done {
		return
	}
	f.done = true
	close(f.quit)
	if f.linger != nil {
		f.linger.Stop()
		f.linger = nil
	}
	if h.feeds[f.key] == f {
		delete(h.feeds, f.key)
	}
	delete(h.byOp, f.op)
	for ch := range f.viewers {
		close(ch)
	}
	f.viewers = map[chan svcLogEvent]struct{}{}
}

// end tells f's viewers it is over (why: what went wrong, "" for a plain
// stop) and forgets it.
func (h *svcLogHub) end(f *svcLogFeed, why string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if f.done {
		return
	}
	for ch := range f.viewers {
		select {
		case ch <- svcLogEvent{end: true, Error: why, At: time.Now().UTC()}:
		default:
		}
	}
	h.finishLocked(f)
}

// deliver takes one TypeServiceLogLines from nc: a page's answer, or lines of
// a follow for its viewers — masked here, before they leave the hub.
func (h *svcLogHub) deliver(nc *nodeConn, m control.Message) {
	var l control.ServiceLogLines
	if json.Unmarshal(m.Payload, &l) != nil {
		return
	}
	for i := range l.Lines {
		l.Lines[i].Text = redactLogLine(l.Lines[i].Text)
	}
	h.mu.Lock()
	if ch := h.pages[m.OpID]; ch != nil {
		delete(h.pages, m.OpID)
		h.mu.Unlock()
		m.Payload, _ = json.Marshal(l)
		ch <- m
		return
	}
	f := h.byOp[m.OpID]
	if f == nil || f.nc != nc {
		h.mu.Unlock()
		return
	}
	if l.Done {
		h.mu.Unlock()
		h.end(f, "")
		return
	}
	if !f.ready || l.Rotated {
		if !f.ready {
			f.from, f.start = l.From, l.Start
		}
		f.ready = true
	}
	f.recent = append(f.recent, l.Lines...)
	if k := len(f.recent) - control.ServiceLogTail; k > 0 {
		f.recent = append([]control.ServiceLogLine(nil), f.recent[k:]...)
		f.start = false
	}
	ev := svcLogEvent{Lines: l.Lines, Skipped: l.Skipped, From: l.From, Start: l.Start, Rotated: l.Rotated, At: l.At}
	var slow []chan svcLogEvent
	for ch := range f.viewers {
		select {
		case ch <- ev:
		default:
			// A viewer that cannot keep up is cut loose; its page reconnects
			// and starts again from the recent lines.
			slow = append(slow, ch)
		}
	}
	for _, ch := range slow {
		delete(f.viewers, ch)
		close(ch)
	}
	h.mu.Unlock()
}

// refused takes a TypeError for a follow or a page; false when it is neither.
func (h *svcLogHub) refused(nc *nodeConn, m control.Message) bool {
	if m.OpID == "" {
		return false
	}
	h.mu.Lock()
	if ch := h.pages[m.OpID]; ch != nil {
		delete(h.pages, m.OpID)
		h.mu.Unlock()
		ch <- m
		return true
	}
	f := h.byOp[m.OpID]
	h.mu.Unlock()
	if f == nil || f.nc != nc {
		return false
	}
	why := "refused"
	if m.Error != nil {
		why = m.Error.Code + ": " + m.Error.Message
	}
	h.end(f, why)
	return true
}

// closeNode ends every follow nc carried: its link is gone.
func (h *svcLogHub) closeNode(nc *nodeConn) {
	h.mu.Lock()
	var gone []*svcLogFeed
	for _, f := range h.feeds {
		if f.nc == nc {
			gone = append(gone, f)
		}
	}
	h.mu.Unlock()
	for _, f := range gone {
		h.end(f, "the machine's link closed")
	}
}

// page asks endpoint for the page before an offset and waits for it.
func (h *svcLogHub) page(ctx context.Context, key svcLogKey, endpoint string, before int64, send svcLogSend) (control.ServiceLogLines, error) {
	op := control.NewOpID()
	ch := make(chan control.Message, 1)
	h.mu.Lock()
	if h.pages == nil {
		h.pages = map[string]chan control.Message{}
	}
	h.pages[op] = ch
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.pages, op)
		h.mu.Unlock()
	}()
	msg, _ := control.New(control.TypeServiceLog, control.ServiceLog{Login: key.login, Name: key.name,
		Tail: control.ServiceLogTail, Before: &before})
	msg.OpID = op
	if err := send(ctx, endpoint, msg); err != nil {
		return control.ServiceLogLines{}, err
	}
	t := time.NewTimer(svcLogPageWait)
	defer t.Stop()
	select {
	case m := <-ch:
		if m.Type == control.TypeError {
			if m.Error != nil {
				return control.ServiceLogLines{}, fault(m.Error.Code, m.Error.Message)
			}
			return control.ServiceLogLines{}, fmt.Errorf("refused")
		}
		var l control.ServiceLogLines
		err := json.Unmarshal(m.Payload, &l)
		return l, err
	case <-t.C:
		return control.ServiceLogLines{}, fmt.Errorf("the machine did not answer within %s", svcLogPageWait)
	case <-ctx.Done():
		return control.ServiceLogLines{}, ctx.Err()
	}
}

// svcLogLane is the open, compatible lane of (host, login) that serves logs
// in THIS process.
func (s *Server) svcLogLane(host, login string) (string, *nodeConn) {
	var id string
	var nc *nodeConn
	s.nodes.each(func(eid string, c *nodeConn) {
		if nc == nil && c.canServiceLog && c.hostname() == host && c.user() == login && control.Compatible(int(c.proto.Load())) {
			id, nc = eid, c
		}
	})
	return id, nc
}

// svcLogPeer is the other replica holding (host, login)'s lane, when this one
// holds none (nil on a single hub).
func (s *Server) svcLogPeer(r *http.Request, host, login string) (store.NodeConn, bool) {
	if s.Replica == nil || s.relayHopped(r) {
		return store.NodeConn{}, false
	}
	peers := s.peerConns()
	if len(peers) == 0 {
		return store.NodeConn{}, false
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		return store.NodeConn{}, false
	}
	for _, n := range nodes {
		pc, ok := peers[n.EndpointID]
		if ok && n.Hostname == host && n.OSUser == login && pc.HasCap(control.CapServiceLog) && control.Compatible(n.Proto) {
			return pc, true
		}
	}
	return store.NodeConn{}, false
}

// parseServiceLogPath splits "<host>/services/<login>/<name>/log"; ok false
// for any other path under NodeDetailPrefix.
func parseServiceLogPath(rest string) (host, login, name string, ok bool) {
	p := strings.Split(strings.Trim(rest, "/"), "/")
	if len(p) != 5 || p[1] != ServiceLogSegment || p[4] != "log" || p[0] == "" || p[2] == "" || p[3] == "" {
		return "", "", "", false
	}
	return p[0], p[2], p[3], true
}

// handleServiceLog serves one register entry's log.
func (s *Server) handleServiceLog(w http.ResponseWriter, r *http.Request, name, login, svc string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	visible, err := s.FleetScope(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	all, err := s.nodesWhere(now, nil)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	host := name
	var mach *MachineView
	for i := range all.Machines {
		if machineMatches(all.Machines[i], name) {
			mach, host = &all.Machines[i], all.Machines[i].Hostname
			break
		}
	}
	// Who may read it comes first, whether or not it exists: a user asking
	// for another login's entry learns nothing but 「只有管理员看得到」.
	if visible != nil && !visible(host, login) {
		httpError(w, http.StatusForbidden, "only an admin sees the logs of another login's services")
		return
	}
	registered := false
	if mach != nil {
		for _, sv := range mach.Services {
			registered = registered || (sv.Login == login && sv.Name == svc)
		}
	}
	if !registered || !svcLogName.MatchString(svc) {
		httpError(w, http.StatusNotFound, "no such service")
		return
	}
	key := svcLogKey{host: host, login: login, name: svc}
	endpoint, nc := s.svcLogLane(host, login)
	if nc == nil {
		if peer, ok := s.svcLogPeer(r, host, login); ok {
			s.proxyRelay(w, r, peer, "a service log on "+host)
			return
		}
		httpError(w, http.StatusServiceUnavailable, "the login's node program is not connected, or too old to read service logs")
		return
	}
	send := s.SendNodeWrite
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodHead {
		// The page's question before it opens the stream — an EventSource
		// cannot read a 403 — answered without asking the node anything.
		w.WriteHeader(http.StatusOK)
		return
	}
	if b := r.URL.Query().Get("before"); b != "" {
		before, err := strconv.ParseInt(b, 10, 64)
		if err != nil || before < 0 {
			httpError(w, http.StatusBadRequest, "before must be a byte offset")
			return
		}
		page, err := s.svcLogs.page(r.Context(), key, endpoint, before, send)
		if err != nil {
			code := http.StatusBadGateway
			if ce, ok := err.(*FleetFault); ok && ce.Code == "NOT_FOUND" {
				code = http.StatusNotFound
			}
			httpError(w, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, svcLogEvent{Lines: page.Lines, From: page.From, Start: page.Start, At: page.At})
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	// The headers now: the reader knows it is admitted before the first line.
	flusher.Flush()
	write := func(event string, v any) bool {
		b, err := json.Marshal(v)
		if err != nil {
			return true
		}
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	ch, leave := s.svcLogs.join(key, endpoint, nc, send)
	defer leave()
	ping := time.NewTicker(svcLogPing)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			if ev.end {
				write("end", map[string]any{"error": ev.Error, "at": ev.At})
				return
			}
			if !write("lines", ev) {
				return
			}
		case <-ping.C:
			if !write("ping", map[string]any{"at": time.Now().UTC()}) {
				return
			}
		}
	}
}
