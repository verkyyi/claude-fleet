package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
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
		if d < b.cur-b.cur/5 || d > b.cur {
			t.Fatalf("step %d: delay %s outside [%s, %s]", i, d, b.cur-b.cur/5, b.cur)
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

// The ladder the issue promises (claude-fleet#1630): 5, 10, 20, 30, 30 s —
// and no jittered wait ever above the 30 s cap, so network back → node online
// stays inside 30 s.
func TestNodeBackoffLadder(t *testing.T) {
	var b nodeBackoff
	want := []time.Duration{5, 10, 20, 30, 30, 30}
	for i, w := range want {
		d := b.next()
		if b.cur != w*time.Second {
			t.Fatalf("rung %d = %s, want %s", i, b.cur, w*time.Second)
		}
		if d > 30*time.Second || d < b.cur*4/5 {
			t.Fatalf("rung %d: jittered wait %s outside [%s, 30s]", i, d, b.cur*4/5)
		}
	}
}

// A change in this machine's network cuts the wait short: against a hub that
// refuses every dial, a network wake makes the agent dial again at once
// instead of sitting out a backoff far longer than the test.
func TestNodeNetChangeSkipsBackoff(t *testing.T) {
	oldMin, oldMax, oldSettle, oldFeed := nodeBackoffMin, nodeBackoffMax, netChangeSettle, netChangeFeed
	nodeBackoffMin, nodeBackoffMax, netChangeSettle = time.Hour, time.Hour, 10*time.Millisecond
	feed := make(chan struct{}, 1)
	netChangeFeed = func(context.Context) <-chan struct{} { return feed }
	t.Cleanup(func() {
		nodeBackoffMin, nodeBackoffMax, netChangeSettle, netChangeFeed = oldMin, oldMax, oldSettle, oldFeed
	})
	var dials atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == control.Path {
			dials.Add(1)
			http.Error(w, "down", http.StatusServiceUnavailable)
		}
	}))
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	a := nodeTestAgent(t, srv.URL, true)
	go func() {
		for i := 0; i < 3; i++ {
			time.Sleep(300 * time.Millisecond)
			feed <- struct{}{}
		}
	}()
	a.Run(ctx)
	if n := dials.Load(); n < 3 {
		t.Fatalf("dials = %d with a one-hour backoff and three network changes; want a dial per change", n)
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
	fleetReadErrs = &sync.Map{}
	var logged bytes.Buffer
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

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
	// The reason is logged once per distinct failure, not once per beat
	// (claude-fleet#1460): three beats, one line, naming the fleet and the fault.
	readFleets(context.Background(), home)
	readFleets(context.Background(), home)
	if n := strings.Count(logged.String(), "tmux down"); n != 1 || !strings.Contains(logged.String(), "fleet-b") {
		t.Fatalf("unreadable-fleet log lines = %d, want 1 naming fleet-b:\n%s", n, logged.String())
	}
}

// discover's capacity (claude-fleet#1587) rides the snapshot: the login's own
// cap and the count its gate reads. A claude-fleet older than that sends none.
func TestReadFleetsCarriesCapacity(t *testing.T) {
	home := t.TempDir()
	script := filepath.Join(home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)
	capacity := `,"capacity":{"sessions":9,"max_sessions":8,"admit":false,"admit_why":"内存紧张","room":0}`
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		var req map[string]any
		json.Unmarshal(stdin, &req)
		if req["method"] == "discover" {
			return []byte(`{"result":{"machine_id":"m-1","fleets":[{"fleet_id":"f-a","name":"fleet-a","repo":"o/a"}]` + capacity + `}}`), nil
		}
		return []byte(`{"result":{"state":"running","workers":[]}}`), nil
	}
	t.Cleanup(func() { fleetControlCommand = old })

	snap, err := readFleets(context.Background(), home)
	if err != nil || snap.capacity == nil || snap.capacity.Sessions != 9 || snap.capacity.MaxSessions != 8 {
		t.Fatalf("snapshot capacity = %+v (%v); want 9/8", snap.capacity, err)
	}
	// The gate's own verdict rides along (claude-fleet#1836).
	if c := snap.capacity; c.Admit == nil || *c.Admit || c.AdmitWhy != "内存紧张" || c.Room == nil || *c.Room != 0 {
		t.Fatalf("snapshot capacity = %+v; want admit false 内存紧张, room 0", c)
	}
	capacity = `,"capacity":{"sessions":9,"max_sessions":8}`
	if snap, _ := readFleets(context.Background(), home); snap.capacity == nil || snap.capacity.Admit != nil || snap.capacity.Room != nil || snap.capacity.AdmitWhy != "" {
		t.Fatalf("a claude-fleet older than #1836 said no verdict, got %+v", snap.capacity)
	}
	capacity = ""
	if snap, _ := readFleets(context.Background(), home); snap.capacity != nil {
		t.Fatalf("an older claude-fleet sent no capacity, got %+v", snap.capacity)
	}
}

// The heartbeat carries the login's own admission verdict (claude-fleet#1836)
// whatever its count cap says — with FLEET_GLOBAL_MAX_SESSIONS=0 (the default
// since #1831) the cap fields stay off and admit / admit_why / room still ride;
// a discover without them leaves them unsaid.
func TestNodeHeartbeatCarriesAdmit(t *testing.T) {
	a := nodeTestAgent(t, "http://unused", true)
	script := filepath.Join(a.cfg.Home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)
	var mu sync.Mutex
	capacity := `,"capacity":{"sessions":3,"max_sessions":0,"admit":false,"admit_why":"内存紧张","room":0}`
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		var req map[string]any
		json.Unmarshal(stdin, &req)
		mu.Lock()
		c := capacity
		mu.Unlock()
		switch req["method"] {
		case "discover":
			return []byte(`{"result":{"machine_id":"m-1","fleets":[{"fleet_id":"f-a","name":"fleet-a","repo":"o/a"}]` + c + `}}`), nil
		case "ready":
			return []byte(`{"result":{"ready":true,"missing":[]}}`), nil
		}
		return []byte(`{"result":{"state":"running","workers":[]}}`), nil
	}
	t.Cleanup(func() { fleetControlCommand = old })

	hb := a.nodeHeartbeat(context.Background(), &fleetProbe{})
	if hb.MaxSessions != 0 || hb.CapSessions != nil {
		t.Fatalf("beat = max %d cap %v; want no cap fields with max_sessions 0", hb.MaxSessions, hb.CapSessions)
	}
	if hb.Admit == nil || *hb.Admit || hb.AdmitWhy != "内存紧张" || hb.Room == nil || *hb.Room != 0 {
		t.Fatalf("beat = admit %v %q room %v; want false 内存紧张 0", hb.Admit, hb.AdmitWhy, hb.Room)
	}
	if paused, why := hb.Paused(); !paused || why != "内存紧张" {
		t.Fatalf("Paused() = %v %q; want true 内存紧张", paused, why)
	}
	mu.Lock()
	capacity = `,"capacity":{"sessions":3,"max_sessions":0,"admit":true,"room":4}`
	mu.Unlock()
	hb = a.nodeHeartbeat(context.Background(), &fleetProbe{})
	if hb.Admit == nil || !*hb.Admit || hb.AdmitWhy != "" || hb.Room == nil || *hb.Room != 4 {
		t.Fatalf("beat = admit %v %q room %v; want true, no why, 4", hb.Admit, hb.AdmitWhy, hb.Room)
	}
	if paused, _ := hb.Paused(); paused {
		t.Fatal("a machine with room 4 reads as paused")
	}
	mu.Lock()
	capacity = `,"capacity":{"sessions":3,"max_sessions":0}`
	mu.Unlock()
	hb = a.nodeHeartbeat(context.Background(), &fleetProbe{})
	if hb.Admit != nil || hb.AdmitWhy != "" || hb.Room != nil {
		t.Fatalf("an older claude-fleet: beat = admit %v %q room %v; want all unsaid", hb.Admit, hb.AdmitWhy, hb.Room)
	}
	if paused, _ := hb.Paused(); paused {
		t.Fatal("a beat without the fields reads as paused")
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
	if !h.HasCap(control.CapRead) || !h.HasCap(control.CapWrite) {
		t.Fatalf("hello capabilities = %v, want %q and %q", h.Capabilities, control.CapRead, control.CapWrite)
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
		a.answerRequest(ctx, wsLink{conn}, m)
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

// answerWrite runs fleet-control.py's submit and nothing else, and never
// reports more certainty than it has: a structured refusal passes through as
// a definite refusal, while a controller that ran and did not answer in a
// form that says — or failed INTERNALly — is UNKNOWN_OUTCOME, so the hub
// journals it unknown and never re-sends it (claude-fleet#1410).
func TestAnswerWriteServesSubmitOnly(t *testing.T) {
	a := nodeTestAgent(t, "http://unused", true)
	script := filepath.Join(a.cfg.Home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)

	var mu sync.Mutex
	var ran []map[string]any
	mode := "ok"
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		var req map[string]any
		json.Unmarshal(stdin, &req)
		mu.Lock()
		ran = append(ran, req)
		m := mode
		mu.Unlock()
		if req["method"] == "discover" {
			return []byte(`{"protocol":1,"machine_id":"m-1","result":{"machine_id":"m-1","fleets":[]}}`), nil
		}
		switch m {
		case "refuse":
			return []byte(`{"error":{"code":"INVALID_ARGUMENT","message":"bad"}}`), nil
		case "internal":
			return []byte(`{"error":{"code":"INTERNAL","message":"Local controller failed"}}`), nil
		case "garbage":
			return []byte(`Traceback (most recent call last)`), nil
		case "dead":
			return nil, errors.New("signal: killed")
		}
		return []byte(`{"protocol":1,"machine_id":"m-1","result":{"operation_id":"o","status":"accepted"}}`), nil
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

	write := func(method, params, m string) control.Message {
		mu.Lock()
		mode = m
		mu.Unlock()
		msg, _ := control.New(control.TypeWrite, control.Request{Method: method, Params: json.RawMessage(params)})
		a.answerWrite(ctx, wsLink{conn}, msg)
		select {
		case r := <-replies:
			if r.OpID != msg.OpID {
				t.Fatalf("reply op_id %s, want %s", r.OpID, msg.OpID)
			}
			return r
		case <-ctx.Done():
			t.Fatal("no reply")
		}
		return control.Message{}
	}
	env := `{"operation_id":"o","fleet_id":"f","action":"worker_start","params":{"issue":1},"actor":"x"}`

	// Every write leaves one line in the agent's log, taken or refused
	// (claude-fleet#1606). log is process-global: no t.Parallel here.
	var logged bytes.Buffer
	var logMu sync.Mutex
	log.SetOutput(writerFunc(func(p []byte) (int, error) { logMu.Lock(); defer logMu.Unlock(); return logged.Write(p) }))
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	logOf := func() string { logMu.Lock(); defer logMu.Unlock(); return logged.String() }

	r := write("submit", env, "ok")
	if l := logOf(); !strings.Contains(l, "control: write worker_start operation o journalled: accepted") {
		t.Fatalf("agent log after a taken start = %q; want its journalled line", l)
	}
	var res control.Result
	json.Unmarshal(r.Payload, &res)
	if r.Type != control.TypeResult || res.MachineID != "m-1" || !strings.Contains(string(res.Result), `"accepted"`) {
		t.Fatalf("submit = %+v / %s", r, res.Result)
	}
	mu.Lock()
	last := ran[len(ran)-1]
	mu.Unlock()
	if last["method"] != "submit" || last["machine_id"] != "m-1" {
		t.Fatalf("controller called with %v; want submit under the node's own machine_id", last)
	}
	for m, want := range map[string]string{
		"refuse":   "INVALID_ARGUMENT",
		"internal": control.CodeUnknownOutcome,
		"garbage":  control.CodeUnknownOutcome,
		"dead":     control.CodeUnknownOutcome,
	} {
		if r := write("submit", env, m); r.Type != control.TypeError || r.Error.Code != want {
			t.Errorf("controller %s: %+v; want %s", m, r, want)
		}
	}
	if l := logOf(); !strings.Contains(l, "control: write worker_start operation o refused INVALID_ARGUMENT: bad") {
		t.Fatalf("agent log after a refused start = %q; want its refused line", l)
	}

	mu.Lock()
	before := len(ran)
	mu.Unlock()
	if r := write("fleet_status", `{"fleet_id":"f"}`, "ok"); r.Type != control.TypeError || r.Error.Code != control.CodeRefused {
		t.Fatalf("a read sent as a write = %+v; want REFUSED", r)
	}
	if r := write("submit", `["not","an","object"]`, "ok"); r.Type != control.TypeError || r.Error.Code != control.CodeBadMessage {
		t.Fatalf("non-object params = %+v; want BAD_MESSAGE", r)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(ran) != before {
		t.Fatalf("a refused write still ran fleet-control.py: %v", ran[before:])
	}
}

// The heartbeat carries fleet-control.py's readiness verdict
// (claude-fleet#1475), asked at most once a minute; a controller without
// `ready` leaves it unsaid.
func TestNodeHeartbeatCarriesReadiness(t *testing.T) {
	a := nodeTestAgent(t, "http://unused", true)
	script := filepath.Join(a.cfg.Home, fleetControlScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)

	var mu sync.Mutex
	asked, mode := 0, "not-ready"
	old := fleetControlCommand
	fleetControlCommand = func(ctx context.Context, s string, stdin []byte) ([]byte, error) {
		var req map[string]any
		json.Unmarshal(stdin, &req)
		switch req["method"] {
		case "discover":
			return []byte(`{"protocol":1,"machine_id":"m-1","result":{"machine_id":"m-1","fleets":[]}}`), nil
		case "ready":
			mu.Lock()
			asked++
			m := mode
			mu.Unlock()
			if m == "old-controller" {
				return []byte(`{"error":{"code":"INVALID_ARGUMENT","message":"Unsupported method"}}`), nil
			}
			return []byte(`{"protocol":1,"machine_id":"m-1","result":{"ready":false,"missing":["gh","checkout:x"]}}`), nil
		}
		return nil, errors.New("unexpected method")
	}
	t.Cleanup(func() { fleetControlCommand = old })

	probe := &fleetProbe{}
	hb := a.nodeHeartbeat(context.Background(), probe)
	if hb.Ready == nil || *hb.Ready || hb.NotReady != "gh, checkout:x" {
		t.Fatalf("ready = %v %q; want false with both reasons", hb.Ready, hb.NotReady)
	}
	hb = a.nodeHeartbeat(context.Background(), probe)
	mu.Lock()
	n := asked
	mu.Unlock()
	if n != 1 || hb.Ready == nil || *hb.Ready {
		t.Fatalf("second beat: ready asked %d times (want 1), carries %v", n, hb.Ready)
	}
	mu.Lock()
	mode = "old-controller"
	mu.Unlock()
	if hb := a.nodeHeartbeat(context.Background(), &fleetProbe{}); hb.Ready != nil || hb.NotReady != "" {
		t.Fatalf("an old controller: ready = %v %q; want unsaid", hb.Ready, hb.NotReady)
	}
}

// writerFunc is an io.Writer from a function.
type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }
