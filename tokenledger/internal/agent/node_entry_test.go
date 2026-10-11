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
