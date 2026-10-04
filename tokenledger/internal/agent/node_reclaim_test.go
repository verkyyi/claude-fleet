package agent

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Reclaim (claude-fleet#1428): the hub is told first, with the node's own
// token; then the evacuation runs under the deadline, its output logged line
// by line; a run that overstays is cut — the whole process group, not just
// the shell.
func TestReclaimTellsHubThenEvacuates(t *testing.T) {
	var told atomic.Int32
	var auth string
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/node/reclaim" || r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		auth = r.Header.Get("Authorization")
		told.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"sp1","state":"reclaiming","grace_seconds":300}`))
	}))
	defer hub.Close()

	home := t.TempDir()
	mark := filepath.Join(home, "evacuated")
	script := filepath.Join(home, "evacuate.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho \"evacuate: fleet=$CCQUOTA_FLEET secs=$FLEET_SPOT_EVACUATE_SECS home=$HOME\"\ntouch \"$1\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)

	a := &Agent{cfg: Config{Fleet: true, FleetEphemeral: true, HubURL: hub.URL, Token: "tok", Home: home,
		FleetReclaimCmd: script + " " + mark, FleetReclaimTimeout: 10 * time.Second}}
	if !a.Ephemeral() {
		t.Fatal("Ephemeral() false with Fleet and FleetEphemeral set")
	}
	a.Reclaim(context.Background())
	if told.Load() != 1 || auth != "Bearer tok" {
		t.Fatalf("hub told %d times, auth %q", told.Load(), auth)
	}
	if _, err := os.Stat(mark); err != nil {
		t.Fatalf("the evacuation did not run: %v", err)
	}
	out := buf.String()
	for _, want := range []string{"hub told", "│ evacuate: fleet=1 secs=10 home=" + home, "evacuation done"} {
		if !strings.Contains(out, want) {
			t.Errorf("log lacks %q:\n%s", want, out)
		}
	}
}

func TestReclaimDeadlineCutsTheEvacuation(t *testing.T) {
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"off"}`, http.StatusNotImplemented)
	}))
	defer hub.Close()
	home := t.TempDir()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)

	a := &Agent{cfg: Config{Fleet: true, FleetEphemeral: true, HubURL: hub.URL, Token: "tok", Home: home,
		FleetReclaimCmd: "echo started; sleep 30; echo never", FleetReclaimTimeout: 500 * time.Millisecond}}
	start := time.Now()
	a.Reclaim(context.Background())
	if took := time.Since(start); took > 5*time.Second {
		t.Fatalf("Reclaim took %s; the deadline did not cut the sleep", took)
	}
	out := buf.String()
	if !strings.Contains(out, "hub not told") || !strings.Contains(out, "│ started") || !strings.Contains(out, "cut at the deadline") || strings.Contains(out, "│ never") {
		t.Fatalf("log:\n%s", out)
	}
}

// With no evacuation installed, Reclaim says so and returns — the hub's
// record carries what was lost.
func TestReclaimWithoutFleetInstalled(t *testing.T) {
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{}`))
	}))
	defer hub.Close()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	a := &Agent{cfg: Config{Fleet: true, FleetEphemeral: true, HubURL: hub.URL, Token: "tok", Home: t.TempDir()}}
	a.Reclaim(context.Background())
	if !strings.Contains(buf.String(), "no evacuation") {
		t.Fatalf("log:\n%s", buf.String())
	}
	if (&Agent{cfg: Config{Fleet: false, FleetEphemeral: true}}).Ephemeral() {
		t.Fatal("Ephemeral() true with the fleet module off")
	}
}
