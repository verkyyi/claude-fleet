package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The entry port's keys follow the hub's push on the machine link
// (claude-fleet#3070): the hello lists CapEntryKeys only where the entry is
// on, a push runs `entry pull --version N`, a failed pull is run again on the
// next beat, and an applied version is not run again.
func entryHub(t *testing.T) (*httptest.Server, chan control.Hello, chan *websocket.Conn) {
	t.Helper()
	hellos := make(chan control.Hello, 4)
	conns := make(chan *websocket.Conn, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		var m control.Message
		if wsjson.Read(r.Context(), c, &m) != nil {
			return
		}
		var h control.Hello
		_ = json.Unmarshal(m.Payload, &h)
		hellos <- h
		welcome, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true})
		_ = wsjson.Write(r.Context(), c, welcome)
		conns <- c
		for {
			if wsjson.Read(context.Background(), c, &m) != nil {
				return
			}
		}
	}))
	return srv, hellos, conns
}

func TestEntryOffListsNothing(t *testing.T) {
	srv, hellos, _ := entryHub(t)
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go newMachineLink(MachineConfig{HubURL: srv.URL, Token: "m", LiveInterval: time.Hour}).run(ctx)
	h := <-hellos
	for _, c := range h.Capabilities {
		if c == control.CapEntryKeys {
			t.Fatalf("no entry, yet the hello lists %v", h.Capabilities)
		}
	}
}

func TestEntryPushPullsAndRetries(t *testing.T) {
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	fail := filepath.Join(dir, "fail")
	script := filepath.Join(dir, "sup")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho \"$*\" >> "+calls+"\n[ -e "+fail+" ] && { echo 'the hub: 503'; exit 1; }\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fail, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	srv, hellos, conns := entryHub(t)
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ml := newMachineLink(MachineConfig{HubURL: srv.URL, Token: "m", LiveInterval: 100 * time.Millisecond, EntryCtl: script})
	go ml.run(ctx)
	h := <-hellos
	listed := false
	for _, c := range h.Capabilities {
		listed = listed || c == control.CapEntryKeys
	}
	if !listed {
		t.Fatalf("entry on, the hello lists %v", h.Capabilities)
	}
	c := <-conns
	push, _ := control.New(control.TypeEntryKeys, control.EntryKeys{Version: 7})
	if err := wsjson.Write(ctx, c, push); err != nil {
		t.Fatal(err)
	}
	read := func() []string {
		b, _ := os.ReadFile(calls)
		return strings.Fields(strings.ReplaceAll(strings.TrimSpace(string(b)), "\n", " | "))
	}
	waitFor := func(what string, ok func() bool) {
		t.Helper()
		for i := 0; i < 50; i++ {
			if ok() {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Fatalf("%s: calls %q", what, read())
	}
	waitFor("the push ran a pull", func() bool { return strings.Contains(strings.Join(read(), " "), "entry pull --version 7") })
	// failing: the beat runs it again
	waitFor("a failed pull is retried", func() bool { return strings.Count(strings.Join(read(), " "), "--version 7") >= 2 })
	os.Remove(fail)
	time.Sleep(400 * time.Millisecond)
	n := strings.Count(strings.Join(read(), " "), "--version 7")
	time.Sleep(500 * time.Millisecond)
	if m := strings.Count(strings.Join(read(), " "), "--version 7"); m != n {
		t.Fatalf("an applied version ran again (%d → %d)", n, m)
	}
}

// The reach report (claude-fleet#3072) runs off the beat: a router that never
// answers (the report hangs) or a failed mapping (it exits 1) does not hold a
// single heartbeat up; it runs once per entryReachEvery, never twice at once;
// with the entry off it never runs.
func TestEntryReachNeverHoldsTheBeat(t *testing.T) {
	old := entryReachEvery
	entryReachEvery = 300 * time.Millisecond
	t.Cleanup(func() { entryReachEvery = old })
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	script := filepath.Join(dir, "sup")
	// `entry reach` hangs 3 s then fails, the way a silent router + a dead hub would
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho \"$*\" >> "+calls+"\n[ \"$2\" = reach ] && { sleep 3; echo 'portmap: no answer from 192.168.1.1'; exit 1; }\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	beats := make(chan time.Time, 100)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		var m control.Message
		if wsjson.Read(r.Context(), c, &m) != nil {
			return
		}
		welcome, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true})
		_ = wsjson.Write(r.Context(), c, welcome)
		for {
			if wsjson.Read(context.Background(), c, &m) != nil {
				return
			}
			if m.Type == control.TypeHeartbeat {
				beats <- time.Now()
			}
		}
	}))
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go newMachineLink(MachineConfig{HubURL: srv.URL, Token: "m", LiveInterval: 100 * time.Millisecond, EntryCtl: script}).run(ctx)
	deadline := time.After(2500 * time.Millisecond)
	n := 0
	prev := time.Time{}
	for n < 15 {
		select {
		case at := <-beats:
			if !prev.IsZero() && at.Sub(prev) > 600*time.Millisecond {
				t.Fatalf("a beat waited %v behind the reach report", at.Sub(prev))
			}
			prev = at
			n++
		case <-deadline:
			t.Fatalf("only %d beats in 2.5 s while the reach report hung", n)
		}
	}
	b, _ := os.ReadFile(calls)
	if got := strings.Count(string(b), "entry reach"); got != 1 {
		t.Fatalf("the hung report ran %d times (want once — never twice at once): %q", got, b)
	}

}
