package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// fakeControlHub accepts control channels and closes each one after the first
// heartbeat — a hub that keeps going away.
type fakeControlHub struct {
	srv     *httptest.Server
	dials   atomic.Int64
	mu      sync.Mutex
	hellos  []control.Message
	beats   []control.Heartbeat
	other   atomic.Int64 // requests to anything but the control path
	welcome control.Welcome
}

func newFakeControlHub(t *testing.T) *fakeControlHub {
	t.Helper()
	f := &fakeControlHub{welcome: control.Welcome{Accepted: true, HubProto: control.Proto, MinProto: control.MinProto}}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != control.Path {
			f.other.Add(1)
			w.WriteHeader(http.StatusOK)
			w.Write([]byte(`{}`))
			return
		}
		if r.Header.Get("Authorization") != "Bearer tok" {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		f.dials.Add(1)
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		var h control.Message
		if wsjson.Read(ctx, c, &h) != nil {
			return
		}
		f.mu.Lock()
		f.hellos = append(f.hellos, h)
		f.mu.Unlock()
		reply, _ := control.New(control.TypeWelcome, f.welcome)
		reply.OpID = h.OpID
		if wsjson.Write(ctx, c, reply) != nil {
			return
		}
		var m control.Message
		if wsjson.Read(ctx, c, &m) != nil {
			return
		}
		var hb control.Heartbeat
		json.Unmarshal(m.Payload, &hb)
		f.mu.Lock()
		f.beats = append(f.beats, hb)
		f.mu.Unlock()
		// The server goes away.
		c.Close(websocket.StatusGoingAway, "hub restarting")
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func shrinkBackoff(t *testing.T) {
	t.Helper()
	oldMin, oldMax := nodeBackoffMin, nodeBackoffMax
	nodeBackoffMin, nodeBackoffMax = 10*time.Millisecond, 40*time.Millisecond
	t.Cleanup(func() { nodeBackoffMin, nodeBackoffMax = oldMin, oldMax })
}

func nodeTestAgent(t *testing.T, hub string, fleet bool) *Agent {
	t.Helper()
	home := t.TempDir()
	a, err := New(Config{
		HubURL: hub, Token: "tok", Home: home, Sources: "claude",
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		LiveInterval: 50 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Version: "test", Fleet: fleet,
	})
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func runFor(t *testing.T, a *Agent, d time.Duration) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	a.Run(ctx)
}

// The hub closing the connection is answered by a reconnect, every time.
func TestNodeReconnectsAfterServerClose(t *testing.T) {
	shrinkBackoff(t)
	f := newFakeControlHub(t)
	runFor(t, nodeTestAgent(t, f.srv.URL, true), 1500*time.Millisecond)

	if n := f.dials.Load(); n < 3 {
		t.Fatalf("agent dialled %d times in 1.5s against a hub that closes every connection; want it to keep reconnecting", n)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	h := f.hellos[0]
	var hp control.Hello
	json.Unmarshal(h.Payload, &hp)
	if h.Proto != control.Proto || h.OpID == "" || hp.HeartbeatMS != 50 {
		t.Fatalf("hello = %+v / %+v", h, hp)
	}
	hb := f.beats[0]
	if hb.Hostname == "" || hb.NCPU <= 0 || hb.ObservedAt.IsZero() {
		t.Fatalf("heartbeat missing its basics: %+v", hb)
	}
}

// A hub that refuses writes to this node still gets its heartbeats.
func TestNodeKeepsReportingWhenNotAccepted(t *testing.T) {
	shrinkBackoff(t)
	f := newFakeControlHub(t)
	f.welcome = control.Welcome{Accepted: false, HubProto: 9, MinProto: 9, Reason: control.CodeProtoMismatch}
	runFor(t, nodeTestAgent(t, f.srv.URL, true), 500*time.Millisecond)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.beats) == 0 {
		t.Fatal("a node the hub will not write to stopped reporting; it must stay listed")
	}
}

// CCQUOTA_FLEET off: no control channel is ever attempted.
func TestNodeOffNeverDials(t *testing.T) {
	f := newFakeControlHub(t)
	runFor(t, nodeTestAgent(t, f.srv.URL, false), 400*time.Millisecond)
	if n := f.dials.Load(); n != 0 {
		t.Fatalf("agent with Fleet off dialled the control channel %d times", n)
	}
	if f.other.Load() == 0 {
		t.Fatal("the agent sent nothing at all; the test is not exercising Run")
	}
}

func TestNodeBackoffDoublesCapsAndJitters(t *testing.T) {
	var b nodeBackoff
	prev := time.Duration(0)
	for i := 0; i < 12; i++ {
		d := b.next()
		if d < b.cur/2 || d > b.cur {
			t.Fatalf("step %d: delay %s outside [%s, %s]", i, d, b.cur/2, b.cur)
		}
		if b.cur > nodeBackoffMax {
			t.Fatalf("step %d: ceiling %s above the %s cap", i, b.cur, nodeBackoffMax)
		}
		if b.cur < prev {
			t.Fatalf("step %d: ceiling shrank from %s to %s", i, prev, b.cur)
		}
		prev = b.cur
	}
	if b.cur != nodeBackoffMax {
		t.Fatalf("ceiling after 12 failures = %s, want the %s cap", b.cur, nodeBackoffMax)
	}
	b.reset()
	if d := b.next(); d > nodeBackoffMin {
		t.Fatalf("after reset the first delay is %s, want at most %s", d, nodeBackoffMin)
	}
}

func TestNodeURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://hub.example.com":  "wss://hub.example.com" + control.Path,
		"https://hub.example.com/": "wss://hub.example.com" + control.Path,
		"http://127.0.0.1:8787":    "ws://127.0.0.1:8787" + control.Path,
	} {
		if got := nodeURL(in); got != want {
			t.Errorf("nodeURL(%q) = %q, want %q", in, got, want)
		}
	}
}

// The fleet snapshot is fleet-control.py's discover + fleet_status, relayed.
func TestReadFleetsThroughFleetControl(t *testing.T) {
	home := t.TempDir()
	script := filepath.Join(home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)

	var calls []string
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		var req map[string]any
		json.Unmarshal(stdin, &req)
		calls = append(calls, req["method"].(string))
		switch req["method"] {
		case "discover":
			return []byte(`{"protocol":1,"machine_id":"m-1","result":{"machine_id":"m-1","fleets":[
				{"fleet_id":"f-a","name":"fleet-a","repo":"o/a"},{"fleet_id":"f-b","name":"fleet-b","repo":"o/b"}]}}`), nil
		case "fleet_status":
			if req["machine_id"] != "m-1" {
				return []byte(`{"error":{"code":"IDENTITY_MISMATCH","message":"x"}}`), nil
			}
			if req["params"].(map[string]any)["fleet_id"] == "f-a" {
				return []byte(`{"result":{"state":"running","workers":[{"key":"1"},{"key":"2"}]}}`), nil
			}
			return []byte(`{"error":{"code":"UNAVAILABLE","message":"tmux down"}}`), nil
		}
		return nil, nil
	}
	t.Cleanup(func() { fleetControlCommand = old })

	snap, err := readFleets(context.Background(), home)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(calls, ",") != "discover,fleet_status,fleet_status" {
		t.Fatalf("calls = %v", calls)
	}
	if snap.machineID != "m-1" || len(snap.fleets) != 2 {
		t.Fatalf("snapshot = %+v", snap)
	}
	a, b := snap.fleets[0], snap.fleets[1]
	if a.State != "running" || a.Count != 2 || !strings.Contains(string(a.Workers), `"key":"2"`) {
		t.Fatalf("fleet a = %+v", a)
	}
	if b.State != "unknown" || b.Count != 0 {
		t.Fatalf("an unreadable fleet must say unknown, not zero sessions running: %+v", b)
	}
}

func TestReadFleetsWithoutClaudeFleet(t *testing.T) {
	if _, err := readFleets(context.Background(), t.TempDir()); err != errNoFleet {
		t.Fatalf("err = %v, want errNoFleet", err)
	}
}

func TestReadSysInfo(t *testing.T) {
	si := readSysInfo()
	switch runtime.GOOS {
	case "darwin", "linux":
		if si.MemTotal == 0 || si.MemFree == 0 || si.MemFree > si.MemTotal {
			t.Fatalf("memory reading implausible: %+v", si)
		}
		if si.Load1 < 0 {
			t.Fatalf("negative load: %+v", si)
		}
	}
}

// The hello advertises live reads (claude-fleet#1409), so the hub knows it may
// ask this node for fleet_status instead of serving its last heartbeat.
func TestNodeHelloAdvertisesReads(t *testing.T) {
	shrinkBackoff(t)
	f := newFakeControlHub(t)
	runFor(t, nodeTestAgent(t, f.srv.URL, true), 300*time.Millisecond)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.hellos) == 0 {
		t.Fatal("no hello")
	}
	var h control.Hello
	json.Unmarshal(f.hellos[0].Payload, &h)
	if !h.HasCap(control.CapRead) {
		t.Fatalf("hello capabilities = %v, want %q", h.Capabilities, control.CapRead)
	}
}

// answerRequest runs only the read methods, through fleet-control.py, with
// the node's OWN machine_id; anything else is refused before it runs.
func TestAnswerRequestServesReadsOnly(t *testing.T) {
	a := nodeTestAgent(t, "http://unused", true)
	script := filepath.Join(a.cfg.Home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)

	var mu sync.Mutex
	var ran []string
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		var req map[string]any
		json.Unmarshal(stdin, &req)
		mu.Lock()
		ran = append(ran, req["method"].(string))
		mu.Unlock()
		switch req["method"] {
		case "discover":
			return []byte(`{"protocol":1,"machine_id":"m-1","result":{"machine_id":"m-1","fleets":[]}}`), nil
		case "fleet_status":
			if req["machine_id"] != "m-1" {
				return []byte(`{"error":{"code":"IDENTITY_MISMATCH","message":"x"}}`), nil
			}
			return []byte(`{"protocol":1,"machine_id":"m-1","result":{"state":"running","workers":[]}}`), nil
		case "config_get":
			return []byte(`{"error":{"code":"NOT_FOUND","message":"gone"}}`), nil
		}
		return nil, nil
	}
	t.Cleanup(func() { fleetControlCommand = old })

	replies := make(chan control.Message, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		for {
			var m control.Message
			if wsjson.Read(context.Background(), c, &m) != nil {
				return
			}
			replies <- m
		}
	}))
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	ask := func(method string) control.Message {
		m, _ := control.New(control.TypeRequest, control.Request{Method: method, Params: json.RawMessage(`{"fleet_id":"f"}`)})
		a.answerRequest(ctx, conn, m)
		select {
		case r := <-replies:
			if r.OpID != m.OpID {
				t.Fatalf("reply op_id %s, want %s", r.OpID, m.OpID)
			}
			return r
		case <-ctx.Done():
			t.Fatal("no reply")
		}
		return control.Message{}
	}

	r := ask("fleet_status")
	var res control.Result
	json.Unmarshal(r.Payload, &res)
	if r.Type != control.TypeResult || res.MachineID != "m-1" || !strings.Contains(string(res.Result), `"running"`) {
		t.Fatalf("fleet_status reply = %+v / %s", r, res.Result)
	}
	if r := ask("config_get"); r.Type != control.TypeError || r.Error.Code != "NOT_FOUND" {
		t.Fatalf("config_get refusal = %+v; want fleet-control.py's own code passed through", r)
	}
	mu.Lock()
	before := len(ran)
	mu.Unlock()
	if r := ask("submit"); r.Type != control.TypeError || r.Error.Code != control.CodeRefused {
		t.Fatalf("submit = %+v; want REFUSED", r)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(ran) != before {
		t.Fatalf("a refused method still ran fleet-control.py: %v", ran[before:])
	}
}
