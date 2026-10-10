package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// service_log (claude-fleet#2797, EPIC #2792 C5): one entry's log, a page at a
// time or followed, for the hub's log view. The machine program runs as root,
// so what it may open is narrow on purpose: the lane's OWN login (never the
// hub's word), an entry the daemon registered (state.json's services[], the
// path service_log() computed — never a path from the wire), a path shaped
// <log>/logins/<login>/<name>.log, opened without following a link and only
// when it is a regular file the login owns (openOwnedLog, the beat's own rule
// for the last line). An entry that is not there is refused NOT_FOUND.
//
// A follow is bound to the session it was asked on: a dropped link ends it,
// and so does the hub's service_log_stop, or ServiceLogLease with no renew.

// svcLogPoll is how often a follow looks for new lines; svcLogLease how long a
// follow lives with no renew (seams for the tests).
var (
	svcLogPoll  = time.Second
	svcLogLease = control.ServiceLogLease
)

// svcLogPageMax bounds how far back one page reads.
const svcLogPageMax = (control.ServiceLogTail + 2) * control.ServiceLogLineMax

// svcLogFollows are a lane's open follows, by op_id.
type svcLogFollows struct {
	mu sync.Mutex
	m  map[string]*svcLogFollow
}

type svcLogFollow struct {
	cancel  context.CancelFunc
	renewed atomic.Int64 // UnixNano
}

func (f *svcLogFollows) put(op string, fl *svcLogFollow) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.m == nil {
		f.m = map[string]*svcLogFollow{}
	}
	if old := f.m[op]; old != nil {
		old.cancel()
	}
	f.m[op] = fl
}

func (f *svcLogFollows) get(op string) *svcLogFollow {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.m[op]
}

// stop ends op's follow; true when there was one.
func (f *svcLogFollows) stop(op string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	fl := f.m[op]
	if fl == nil {
		return false
	}
	fl.cancel()
	delete(f.m, op)
	return true
}

func (f *svcLogFollows) drop(op string, fl *svcLogFollow) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.m[op] == fl {
		delete(f.m, op)
	}
}

// count is how many follows are open (a test's read).
func (f *svcLogFollows) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.m)
}

// serviceLogCapable: this agent is a tenant of the machine program and knows
// the register.
func (a *Agent) serviceLogCapable() bool {
	return a.machine != nil && a.cfg.RunAs != nil && a.cfg.ServicesFile != ""
}

var errSvcNotRegistered = errors.New("not registered")

// serviceLogPath is the log of login's entry name as the register records it,
// or why not. The path must be <dir>/logins/<login>/<name>.log.
func serviceLogPath(stateFile, login, name string) (string, error) {
	b, err := os.ReadFile(stateFile)
	if err != nil {
		return "", errSvcNotRegistered
	}
	var st struct {
		Services []supervisorService `json:"services"`
	}
	if json.Unmarshal(b, &st) != nil {
		return "", errSvcNotRegistered
	}
	for _, r := range st.Services {
		if r.Login != login || r.Name != name {
			continue
		}
		p := filepath.Clean(r.Log)
		if r.Log == "" || !filepath.IsAbs(p) || filepath.Base(p) != name+".log" ||
			filepath.Base(filepath.Dir(p)) != login || filepath.Base(filepath.Dir(filepath.Dir(p))) != "logins" {
			return "", errors.New("the register's log path for this entry is not <log>/logins/<login>/<name>.log")
		}
		return p, nil
	}
	return "", errSvcNotRegistered
}

// serviceLog answers one TypeServiceLog on conn.
func (a *Agent) serviceLog(ctx context.Context, conn nodeLink, m control.Message) {
	send := func(msg control.Message) error {
		msg.OpID, msg.Proto = m.OpID, control.Proto
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		return conn.write(wctx, msg)
	}
	fail := func(code, msg string) {
		log.Printf("control: service_log %s refused %s: %s", m.OpID, code, msg)
		_ = send(control.Message{Type: control.TypeError, Error: &control.Error{Code: code, Message: msg}})
	}
	var req control.ServiceLog
	if json.Unmarshal(m.Payload, &req) != nil {
		fail(control.CodeBadMessage, "malformed service_log")
		return
	}
	if !a.serviceLogCapable() {
		fail("UNAVAILABLE", "service logs need the machine's node program (ccquota agent --machine, a managed machine)")
		return
	}
	login := a.cfg.RunAs.Login
	if req.Login != "" && req.Login != login {
		fail(control.CodeWrongLogin, "this lane is "+login+"'s, not "+req.Login+"'s")
		return
	}
	if req.Renew {
		fl := a.svcLogs.get(m.OpID)
		if fl == nil {
			fail("NOT_FOUND", "no such follow")
			return
		}
		fl.renewed.Store(time.Now().UnixNano())
		return
	}
	if !svcNameRE.MatchString(req.Name) {
		fail(control.CodeBadArgs, "bad service name")
		return
	}
	path, err := serviceLogPath(a.cfg.ServicesFile, login, req.Name)
	if err != nil {
		if errors.Is(err, errSvcNotRegistered) {
			fail("NOT_FOUND", req.Name+" is not registered for "+login)
		} else {
			fail(control.CodeRefused, err.Error())
		}
		return
	}
	uid := int(a.cfg.RunAs.UID)
	n := req.Tail
	if n <= 0 || n > control.ServiceLogTail {
		n = control.ServiceLogTail
	}
	if !req.Follow {
		page, _, ok := readLogPage(path, uid, req.Before, n)
		if !ok {
			// No log yet (a service that never ran), or one that is not the
			// login's own: an empty page, never someone else's file.
			page = control.ServiceLogLines{Lines: []control.ServiceLogLine{}, Start: true}
		}
		page.Done, page.At = true, time.Now().UTC()
		if out, err := control.New(control.TypeServiceLogLines, page); err == nil {
			_ = send(out)
		}
		return
	}
	fctx, cancel := context.WithCancel(ctx)
	fl := &svcLogFollow{cancel: cancel}
	fl.renewed.Store(time.Now().UnixNano())
	a.svcLogs.put(m.OpID, fl)
	go func() {
		defer cancel()
		defer a.svcLogs.drop(m.OpID, fl)
		followLog(fctx, path, uid, n, fl, func(l control.ServiceLogLines) error {
			out, err := control.New(control.TypeServiceLogLines, l)
			if err != nil {
				return err
			}
			return send(out)
		})
	}()
}

// logFile is one open log: its identity and how far it has been read.
type logFile struct {
	f   *os.File
	ino uint64
	dev uint64
}

func openLog(path string, uid int) (*logFile, int64, bool) {
	f, fi, ok := openOwnedLog(path, uid)
	if !ok {
		return nil, 0, false
	}
	lf := &logFile{f: f}
	lf.dev, lf.ino = fileID(fi)
	return lf, fi.Size(), true
}

// replaced: the path now names another file (rotated), or none.
func (lf *logFile) replaced(path string) bool {
	fi, err := os.Lstat(path)
	if err != nil {
		return true
	}
	dev, ino := fileID(fi)
	return ino != lf.ino || dev != lf.dev
}

// logText is one line as it is sent: valid UTF-8, no CR, at most
// ServiceLogLineMax bytes.
func logText(b []byte) string {
	return clipUTF8(strings.ToValidUTF8(strings.TrimRight(string(b), "\r"), "�"), control.ServiceLogLineMax)
}

// readLogPage is the last n lines of path ending at before (nil: the end), the
// offset just past them, and whether the file could be read.
func readLogPage(path string, uid int, before *int64, n int) (control.ServiceLogLines, int64, bool) {
	lf, size, ok := openLog(path, uid)
	if !ok {
		return control.ServiceLogLines{}, 0, false
	}
	defer lf.f.Close()
	end := size
	if before != nil && *before >= 0 && *before < size {
		end = *before
	}
	start := end - svcLogPageMax
	if start < 0 {
		start = 0
	}
	buf, err := io.ReadAll(io.NewSectionReader(lf.f, start, end-start))
	if err != nil {
		return control.ServiceLogLines{}, 0, false
	}
	// A page asked with no before ends at the last full line: what follows
	// it is a line still being written, the follow's to send.
	if before == nil {
		if i := bytes.LastIndexByte(buf, '\n'); i >= 0 {
			buf = buf[:i+1]
		} else if start == 0 {
			buf = buf[:0]
		}
	}
	stop := start + int64(len(buf))
	off := start
	if start > 0 {
		// The window began mid-line: that line starts before it.
		i := bytes.IndexByte(buf, '\n')
		if i < 0 {
			return control.ServiceLogLines{Lines: []control.ServiceLogLine{}, From: end}, stop, true
		}
		buf, off = buf[i+1:], off+int64(i+1)
	}
	var offs []int64
	var lines [][]byte
	for len(buf) > 0 {
		i := bytes.IndexByte(buf, '\n')
		if i < 0 {
			i = len(buf)
		}
		offs, lines = append(offs, off), append(lines, buf[:i])
		if i == len(buf) {
			off += int64(i)
			break
		}
		buf, off = buf[i+1:], off+int64(i+1)
	}
	if len(lines) > n {
		offs, lines = offs[len(lines)-n:], lines[len(lines)-n:]
	}
	page := control.ServiceLogLines{Lines: make([]control.ServiceLogLine, 0, len(lines)), From: end}
	if len(offs) > 0 {
		page.From = offs[0]
	}
	for _, l := range lines {
		page.Lines = append(page.Lines, control.ServiceLogLine{Text: logText(l)})
	}
	page.Start = page.From == 0
	return page, stop, true
}

// followLog sends the last n lines of path, then every new line, until ctx
// ends, send fails or nobody renewed fl for svcLogLease. Each tick sends at
// most ServiceLogRate bytes: the middle of a burst is dropped and counted.
func followLog(ctx context.Context, path string, uid, n int, fl *svcLogFollow, send func(control.ServiceLogLines) error) {
	page, off, ok := readLogPage(path, uid, nil, n)
	if !ok {
		page = control.ServiceLogLines{Lines: []control.ServiceLogLine{}, Start: true}
	}
	page.At = time.Now().UTC()
	if send(page) != nil {
		return
	}
	var lf *logFile
	if ok {
		lf, _, ok = openLog(path, uid)
		if !ok {
			lf = nil
		}
	}
	defer func() {
		if lf != nil {
			lf.f.Close()
		}
	}()
	var partial []byte
	t := time.NewTicker(svcLogPoll)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if time.Since(time.Unix(0, fl.renewed.Load())) > svcLogLease {
			_ = send(control.ServiceLogLines{Lines: []control.ServiceLogLine{}, Done: true, At: time.Now().UTC()})
			return
		}
		rotated := false
		if lf == nil || lf.replaced(path) {
			// First written, or rotated: read the new file from its start.
			var nf *logFile
			if nf, _, ok = openLog(path, uid); !ok {
				continue
			}
			if lf != nil {
				lf.f.Close()
				rotated = true
			}
			lf, off, partial = nf, 0, nil
		}
		fi, err := lf.f.Stat()
		if err != nil {
			continue
		}
		if fi.Size() < off {
			// Truncated in place.
			off, partial, rotated = 0, nil, true
		}
		if fi.Size() == off && !rotated {
			continue
		}
		batch, next, rest := readNewLines(lf.f, off, fi.Size(), partial)
		off, partial = next, rest
		if len(batch.Lines) == 0 && batch.Skipped == 0 && !rotated {
			continue
		}
		batch.Rotated, batch.At = rotated, time.Now().UTC()
		if send(batch) != nil {
			return
		}
	}
}

// readNewLines reads [off, size) after partial (a line not finished last
// time) and returns its complete lines within the rate, the new offset and
// what is left unfinished.
func readNewLines(f *os.File, off, size int64, partial []byte) (control.ServiceLogLines, int64, []byte) {
	half := control.ServiceLogRate / 2
	out := control.ServiceLogLines{Lines: []control.ServiceLogLine{}, From: off - int64(len(partial))}
	now := time.Now().UTC()
	var head []control.ServiceLogLine
	var tail []control.ServiceLogLine
	headBytes, tailBytes := 0, 0
	add := func(b []byte) {
		l := control.ServiceLogLine{TS: &now, Text: logText(b)}
		if out.Skipped == 0 && len(tail) == 0 && headBytes+len(l.Text) <= half {
			head, headBytes = append(head, l), headBytes+len(l.Text)
			return
		}
		tail, tailBytes = append(tail, l), tailBytes+len(l.Text)
		for tailBytes > half && len(tail) > 1 {
			tailBytes -= len(tail[0].Text)
			tail = tail[1:]
			out.Skipped++
		}
	}
	r := io.NewSectionReader(f, off, size-off)
	chunk := make([]byte, 64<<10)
	line := partial
	for {
		k, err := r.Read(chunk)
		b := chunk[:k]
		for len(b) > 0 {
			i := bytes.IndexByte(b, '\n')
			if i < 0 {
				line = append(line, b...)
				if len(line) > control.ServiceLogLineMax*4 {
					// A line with no end in sight: send what there is.
					add(line)
					line = nil
				}
				break
			}
			add(append(line, b[:i]...))
			line, b = nil, b[i+1:]
		}
		off += int64(k)
		if err != nil {
			break
		}
	}
	out.Lines = append(head, tail...)
	if out.Lines == nil {
		out.Lines = []control.ServiceLogLine{}
	}
	return out, off, append([]byte(nil), line...)
}
