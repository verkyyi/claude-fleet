//go:build unix

package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// chanLink hands what the agent writes to a channel (a follow writes from its
// own goroutine).
type chanLink struct{ ch chan control.Message }

func (l *chanLink) write(_ context.Context, m control.Message) error { l.ch <- m; return nil }
func (l *chanLink) read(context.Context) (control.Message, error)    { return control.Message{}, nil }
func (l *chanLink) ping(context.Context) error                       { return nil }
func (l *chanLink) close(string)                                     {}
func (l *chanLink) closeNow()                                        {}

func (l *chanLink) next(t *testing.T) control.Message {
	t.Helper()
	select {
	case m := <-l.ch:
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("no answer")
	}
	return control.Message{}
}

func linesOf(t *testing.T, m control.Message) control.ServiceLogLines {
	t.Helper()
	if m.Type != control.TypeServiceLogLines {
		t.Fatalf("answer = %s %+v", m.Type, m.Error)
	}
	var l control.ServiceLogLines
	if err := json.Unmarshal(m.Payload, &l); err != nil {
		t.Fatal(err)
	}
	return l
}

// svcLogAgent is alice's tenant on a machine whose register lists daily (its
// log under <dir>/log/logins/alice/), odd (a log path the daemon would never
// write) and linked (its log a link to a secret).
func svcLogAgent(t *testing.T) (*Agent, string) {
	t.Helper()
	dir := t.TempDir()
	logdir := filepath.Join(dir, "log", "logins", "alice")
	if err := os.MkdirAll(logdir, 0o755); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(dir, "secret")
	os.WriteFile(secret, []byte("root-only secret\n"), 0o600)
	os.Symlink(secret, filepath.Join(logdir, "linked.log"))
	state, _ := json.Marshal(map[string]any{"services": []map[string]any{
		{"name": "daily", "login": "alice", "status": "running", "log": filepath.Join(logdir, "daily.log")},
		{"name": "odd", "login": "alice", "status": "running", "log": secret},
		{"name": "linked", "login": "alice", "status": "running", "log": filepath.Join(logdir, "linked.log")},
		{"name": "theirs", "login": "bob", "status": "running", "log": filepath.Join(dir, "log", "logins", "bob", "theirs.log")},
	}})
	sf := filepath.Join(dir, "state.json")
	os.WriteFile(sf, state, 0o644)
	a := &Agent{machine: &machineLink{}, cfg: Config{RunAs: &RunAs{Login: "alice", UID: uint32(os.Getuid())}, ServicesFile: sf}}
	return a, filepath.Join(logdir, "daily.log")
}

func askLog(a *Agent, l *chanLink, op string, req control.ServiceLog) {
	m, _ := control.New(control.TypeServiceLog, req)
	m.OpID = op
	a.serviceLog(context.Background(), l, m)
}

// The node reads only the register's file for the lane's own login: another
// login, an unregistered name, a path not shaped like the daemon's, a link —
// each refused or empty, never read (claude-fleet#2797 节点一侧).
func TestServiceLogOnlyTheRegisteredFile(t *testing.T) {
	a, logf := svcLogAgent(t)
	var b strings.Builder
	for i := 1; i <= 250; i++ {
		fmt.Fprintf(&b, "line %d\n", i)
	}
	os.WriteFile(logf, []byte(b.String()), 0o644)
	l := &chanLink{ch: make(chan control.Message, 16)}

	askLog(a, l, "p1", control.ServiceLog{Login: "alice", Name: "daily", Tail: 200})
	m := l.next(t)
	page := linesOf(t, m)
	if m.OpID != "p1" || !page.Done || len(page.Lines) != 200 || page.Lines[0].Text != "line 51" || page.Lines[199].Text != "line 250" || page.Start {
		t.Fatalf("page = op %s done %v %d lines [%v … %v] start %v", m.OpID, page.Done, len(page.Lines), page.Lines[0], page.Lines[len(page.Lines)-1], page.Start)
	}
	// The page before it: the first 50, and nothing earlier.
	askLog(a, l, "p2", control.ServiceLog{Name: "daily", Tail: 200, Before: &page.From})
	prev := linesOf(t, l.next(t))
	if len(prev.Lines) != 50 || prev.Lines[0].Text != "line 1" || prev.Lines[49].Text != "line 50" || !prev.Start || prev.From != 0 {
		t.Fatalf("previous page = %d lines start %v from %d", len(prev.Lines), prev.Start, prev.From)
	}

	for _, c := range []struct {
		req  control.ServiceLog
		code string
	}{
		{control.ServiceLog{Login: "bob", Name: "theirs"}, control.CodeWrongLogin},
		{control.ServiceLog{Name: "theirs"}, "NOT_FOUND"}, // bob's entry is not alice's
		{control.ServiceLog{Name: "nosuch"}, "NOT_FOUND"},
		{control.ServiceLog{Name: "../../etc/passwd"}, control.CodeBadArgs},
		{control.ServiceLog{Name: "odd"}, control.CodeRefused},
		{control.ServiceLog{Name: "nosuch", Renew: true}, "NOT_FOUND"},
	} {
		askLog(a, l, "x", c.req)
		if m := l.next(t); m.Type != control.TypeError || m.Error == nil || m.Error.Code != c.code {
			t.Fatalf("%+v answered %s %+v, want %s", c.req, m.Type, m.Error, c.code)
		}
	}
	askLog(a, l, "p3", control.ServiceLog{Name: "linked"})
	if got := linesOf(t, l.next(t)); len(got.Lines) != 0 {
		t.Fatalf("a linked log was read: %+v", got.Lines)
	}
	// Not the machine program: nothing is read.
	plain := &Agent{cfg: a.cfg}
	askLog(plain, l, "p4", control.ServiceLog{Name: "daily"})
	if m := l.next(t); m.Type != control.TypeError || m.Error.Code != "UNAVAILABLE" {
		t.Fatalf("a plain agent answered %s %+v", m.Type, m.Error)
	}
}

// A follow starts with the last lines, then sends each new line with the time
// it was read; a stop ends it; a follow nobody renews ends on its own.
func TestServiceLogFollow(t *testing.T) {
	defer func(p, l time.Duration) { svcLogPoll, svcLogLease = p, l }(svcLogPoll, svcLogLease)
	svcLogPoll, svcLogLease = 20*time.Millisecond, time.Hour
	a, logf := svcLogAgent(t)
	os.WriteFile(logf, []byte("one\ntwo\nhalf"), 0o644)
	l := &chanLink{ch: make(chan control.Message, 64)}
	askLog(a, l, "f1", control.ServiceLog{Name: "daily", Tail: 200, Follow: true})
	first := linesOf(t, l.next(t))
	if len(first.Lines) != 2 || first.Lines[1].Text != "two" || !first.Start || first.Done {
		t.Fatalf("first = %+v", first)
	}
	f, _ := os.OpenFile(logf, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("-done\nthree\n")
	f.Close()
	got := []string{}
	for len(got) < 2 {
		nl := linesOf(t, l.next(t))
		for _, x := range nl.Lines {
			if x.TS == nil {
				t.Fatalf("a new line without its time: %+v", x)
			}
			got = append(got, x.Text)
		}
	}
	if strings.Join(got, "|") != "half-done|three" {
		t.Fatalf("new lines = %q", got)
	}
	// Rotated: the new file is read from its start.
	os.Rename(logf, logf+".1")
	os.WriteFile(logf, []byte("fresh\n"), 0o644)
	if nl := linesOf(t, l.next(t)); !nl.Rotated || len(nl.Lines) != 1 || nl.Lines[0].Text != "fresh" {
		t.Fatalf("after rotation = %+v", nl)
	}
	if a.svcLogs.count() != 1 {
		t.Fatalf("follows = %d", a.svcLogs.count())
	}
	if !a.svcLogs.stop("f1") {
		t.Fatal("stop found no follow")
	}
	waitUntil(t, func() bool { return a.svcLogs.count() == 0 })

	// No renew within the lease: it ends by itself, saying so.
	svcLogLease = 150 * time.Millisecond
	askLog(a, l, "f2", control.ServiceLog{Name: "daily", Follow: true})
	linesOf(t, l.next(t))
	time.Sleep(80 * time.Millisecond)
	askLog(a, l, "f2", control.ServiceLog{Name: "daily", Renew: true})
	start := time.Now()
	for {
		nl := linesOf(t, l.next(t))
		if nl.Done {
			break
		}
	}
	if time.Since(start) < 50*time.Millisecond {
		t.Fatal("a renewed follow ended at its first lease")
	}
	waitUntil(t, func() bool { return a.svcLogs.count() == 0 })
}

func waitUntil(t *testing.T, ok func() bool) {
	t.Helper()
	for i := 0; i < 250; i++ {
		if ok() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out")
}

// A burst past the rate keeps its head and its tail and counts the middle;
// a line is cut at ServiceLogLineMax.
func TestReadNewLinesRate(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "x.log")
	var b strings.Builder
	for i := 0; i < 5000; i++ {
		fmt.Fprintf(&b, "%04d %s\n", i, strings.Repeat("x", 95))
	}
	b.WriteString(strings.Repeat("y", 5000) + "\n")
	os.WriteFile(p, []byte(b.String()), 0o644)
	f, _ := os.Open(p)
	defer f.Close()
	fi, _ := f.Stat()
	out, off, rest := readNewLines(f, 0, fi.Size(), nil)
	if off != fi.Size() || len(rest) != 0 {
		t.Fatalf("off %d of %d, rest %d", off, fi.Size(), len(rest))
	}
	total := 0
	for _, l := range out.Lines {
		total += len(l.Text)
	}
	if total > control.ServiceLogRate || out.Skipped == 0 || len(out.Lines)+out.Skipped != 5001 {
		t.Fatalf("%d lines, %d bytes, %d skipped", len(out.Lines), total, out.Skipped)
	}
	if !strings.HasPrefix(out.Lines[0].Text, "0000 ") || len(out.Lines[len(out.Lines)-1].Text) != control.ServiceLogLineMax {
		t.Fatalf("head %q, last %d bytes", out.Lines[0].Text[:5], len(out.Lines[len(out.Lines)-1].Text))
	}
}
