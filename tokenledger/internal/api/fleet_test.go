package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The Fleet Hub read half (claude-fleet#1409).

const (
	machineA = "11111111-1111-4111-8111-111111111111"
	machineB = "22222222-2222-4222-8222-222222222222"
)

// fakeFleet builds one heartbeat fleet whose ids derive the way
// fleet-control.py derives them, with one worker per issue.
func fakeFleet(t *testing.T, machine, session, repo, checkout string, issues ...int) control.Fleet {
	t.Helper()
	fid, err := fleetid.FleetID(machine, session, repo, checkout)
	if err != nil {
		t.Fatal(err)
	}
	ws := []map[string]any{}
	for _, n := range issues {
		key := fleetid.WorkerKey(n, false, "", "")
		ws = append(ws, map[string]any{"worker_id": fleetid.WorkerID(fid, key), "key": key,
			"window_id": "@" + string(rune('0'+n%10)), "issue": n, "state": "working"})
	}
	raw, _ := json.Marshal(ws)
	return control.Fleet{FleetID: fid, Name: session, Repo: repo, Checkout: checkout, Agent: "claude",
		State: "running", Workers: raw, Count: len(ws)}
}

// fakeNode is a hand-driven control-channel client: hello (optionally
// advertising reads), heartbeats, and a responder for hub read requests.
type fakeNode struct {
	t    *testing.T
	conn *websocket.Conn
}

func connectFakeNode(t *testing.T, h *harness, label string, canRead bool) *fakeNode {
	t.Helper()
	c := dialNode(t, h, h.enroll(t, label))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	hp := control.Hello{HeartbeatMS: 60000, AgentVersion: "test"}
	if canRead {
		hp.Capabilities = []string{control.CapRead}
	}
	m, _ := control.New(control.TypeHello, hp)
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	return &fakeNode{t: t, conn: c}
}

func (n *fakeNode) beat(host, user, machine string, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Fleets: fleets, ObservedAt: time.Now()})
}

// serve answers every read request with answer(method, params) until the
// connection ends. A nil result is sent back as a TypeError.
func (n *fakeNode) serve(answer func(method string, params json.RawMessage) (any, *control.Error)) {
	go func() {
		for {
			var m control.Message
			if err := wsjson.Read(context.Background(), n.conn, &m); err != nil {
				return
			}
			if m.Type != control.TypeRequest {
				continue
			}
			var req control.Request
			_ = json.Unmarshal(m.Payload, &req)
			res, e := answer(req.Method, req.Params)
			var out control.Message
			if e != nil {
				out = control.Message{Type: control.TypeError, Proto: control.Proto, Error: e}
			} else {
				raw, _ := json.Marshal(res)
				out, _ = control.New(control.TypeResult, control.Result{Result: raw})
			}
			out.OpID = m.OpID
			_ = wsjson.Write(context.Background(), n.conn, out)
		}
	}()
}

func getFleet(t *testing.T, h *harness, path string, wantStatus int) map[string]any {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != wantStatus {
		t.Fatalf("%s: HTTP %d (%v), want %d", path, resp.StatusCode, out, wantStatus)
	}
	return out
}

func fleetIDs(out map[string]any) []string {
	ids := []string{}
	for _, f := range out["fleets"].([]any) {
		ids = append(ids, f.(map[string]any)["fleet_id"].(string))
	}
	sort.Strings(ids)
	return ids
}

func TestFleetRoutesAbsentWhenModuleOff(t *testing.T) {
	h := newHarness(t)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/fleet_list", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	// The UI's catch-all may still answer the path; what must not exist is
	// the fleet tool behind it.
	var out map[string]any
	if json.NewDecoder(resp.Body).Decode(&out) == nil && out["fleets"] != nil {
		t.Fatal("/v1/fleet/fleet_list answered with the fleet module off")
	}
}

func TestFleetListFromHeartbeats(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "m5", false)
	b := connectFakeNode(t, h, "m4", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	fb := fakeFleet(t, machineB, "fleet-b", "", "", 7)
	a.beat("m5", "alice", machineA, fa)
	b.beat("m4", "bob", machineB, fb)

	want := []string{fa.FleetID, fb.FleetID}
	sort.Strings(want)
	var out map[string]any
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		out = getFleet(t, h, "/v1/fleet/fleet_list", 200)
		return strings.Join(fleetIDs(out), ",") == strings.Join(want, ",")
	})
	for _, f := range out["fleets"].([]any) {
		f := f.(map[string]any)
		if f["availability"] != "online" || f["registered"] != true {
			t.Errorf("fleet %v: want online + registered", f)
		}
	}

	s := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
	if s["count"].(float64) != 3 {
		t.Fatalf("fleet_sessions count = %v, want 3: %v", s["count"], s)
	}
	if got := s["machines"].([]any); len(got) != 2 || got[0] != "m4" || got[1] != "m5" {
		t.Fatalf("machines = %v, want [m4 m5]", got)
	}
	ids := map[string]bool{}
	for _, row := range s["sessions"].([]any) {
		ids[row.(map[string]any)["worker_id"].(string)] = true
		// 我的会话 says how old a lost machine's rows are (claude-fleet#1429).
		if age, ok := row.(map[string]any)["age_sec"].(float64); !ok || age < 0 {
			t.Errorf("session %v: want a non-negative age_sec", row)
		}
		if _, ok := row.(map[string]any)["observed_at"].(string); !ok {
			t.Errorf("session %v: want observed_at", row)
		}
	}
	for _, w := range []string{fa.FleetID + "/issue-1", fa.FleetID + "/issue-2", fb.FleetID + "/issue-7"} {
		if !ids[w] {
			t.Errorf("worker %s missing from fleet_sessions", w)
		}
	}

	// A fleet the machine stops reporting stays listed, unregistered.
	a.beat("m5", "alice", machineA)
	waitFor(t, 3*time.Second, "fleet-a unregistered", func() bool {
		for _, f := range getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any) {
			f := f.(map[string]any)
			if f["fleet_id"] == fa.FleetID {
				return f["registered"] == false
			}
		}
		return false
	})
	getFleet(t, h, "/v1/fleet/fleet_status?fleet_id="+fa.FleetID, 404)
}

func TestFleetHeartbeatIdentityChecks(t *testing.T) {
	h := newFleetHarness(t)
	n := connectFakeNode(t, h, "m5", true)
	good := fakeFleet(t, machineA, "good", "o/r", "/c", 3)
	forged := fakeFleet(t, machineA, "forged", "o/r", "/c", 4)
	forged.FleetID = fakeFleet(t, machineA, "other", "", "", 0).FleetID
	// A worker_id pointing at another fleet keeps its row but loses its id.
	var ws []map[string]any
	_ = json.Unmarshal(good.Workers, &ws)
	ws = append(ws, map[string]any{"worker_id": forged.FleetID + "/issue-9", "key": "issue-9"})
	good.Workers, _ = json.Marshal(ws)
	good.Count = len(ws)
	n.beat("m5", "alice", machineA, good, forged)

	waitFor(t, 3*time.Second, "good registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 1
	})
	if ids := fleetIDs(getFleet(t, h, "/v1/fleet/fleet_list", 200)); ids[0] != good.FleetID {
		t.Fatalf("registered %v; want only the fleet whose UUID derives from its machine", ids)
	}
	st := getFleet(t, h, "/v1/fleet/fleet_status?fleet_id="+good.FleetID, 200)
	var nilled, kept int
	for _, w := range st["workers"].([]any) {
		if w.(map[string]any)["worker_id"] == nil {
			nilled++
		} else {
			kept++
		}
	}
	if nilled != 1 || kept != 1 {
		t.Fatalf("workers = %v; want the borrowed worker_id nulled and the real one kept", st["workers"])
	}

	// The same fleet UUID claimed by another machine is refused — even from
	// an agent too old to be re-derived (no CapRead), by the registry itself.
	other := connectFakeNode(t, h, "m4", false)
	steal := good
	other.beat("m4", "bob", machineB, steal)
	time.Sleep(200 * time.Millisecond)
	r, err := h.srv.Store.Fleet(good.FleetID)
	if err != nil || r.MachineID != machineA {
		t.Fatalf("fleet %s now on %s (%v); a second machine must not take it over", good.FleetID, r.MachineID, err)
	}
}

func TestFleetStatusLiveThenHeartbeat(t *testing.T) {
	h := newFleetHarness(t)
	live := connectFakeNode(t, h, "m5", true)
	old := connectFakeNode(t, h, "m4", false)
	fl := fakeFleet(t, machineA, "live", "", "", 1)
	fo := fakeFleet(t, machineB, "old", "", "", 2)
	live.serve(func(method string, params json.RawMessage) (any, *control.Error) {
		switch method {
		case "fleet_status":
			return map[string]any{"state": "running", "observed_at": 1.0, "workers": []map[string]any{
				{"worker_id": fl.FleetID + "/issue-1", "key": "issue-1"},
				{"worker_id": fl.FleetID + "/issue-5", "key": "issue-5"}}}, nil
		case "config_get":
			return map[string]any{"values": map[string]int{"FLEET_MAX_SESSIONS": 8}, "revision": strings.Repeat("a", 64)}, nil
		case "operation_get":
			var p map[string]string
			_ = json.Unmarshal(params, &p)
			return map[string]any{"operation_id": p["operation_id"], "fleet_id": fl.FleetID,
				"action": "worker_start", "status": "succeeded", "result": map[string]any{"ok": true}}, nil
		}
		return nil, &control.Error{Code: "INVALID_ARGUMENT", Message: "no"}
	})
	live.beat("m5", "alice", machineA, fl)
	old.beat("m4", "bob", machineB, fo)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})

	st := getFleet(t, h, "/v1/fleet/fleet_status?fleet_id="+fl.FleetID, 200)
	if st["source"] != "live" || len(st["workers"].([]any)) != 2 {
		t.Fatalf("live fleet_status = %v; want source=live with the node's two workers", st)
	}
	// The live answer is stored: fleet_list now counts 2.
	for _, f := range getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any) {
		if f.(map[string]any)["fleet_id"] == fl.FleetID && f.(map[string]any)["count"].(float64) != 2 {
			t.Fatalf("fleet_list count not refreshed by the live read: %v", f)
		}
	}
	st = getFleet(t, h, "/v1/fleet/fleet_status?fleet_id="+fo.FleetID, 200)
	if st["source"] != "heartbeat" || len(st["workers"].([]any)) != 1 {
		t.Fatalf("pre-#1409 node fleet_status = %v; want source=heartbeat", st)
	}

	cfg := getFleet(t, h, "/v1/fleet/config_get?fleet_id="+fl.FleetID, 200)
	if cfg["revision"] != strings.Repeat("a", 64) {
		t.Fatalf("config_get = %v", cfg)
	}
	getFleet(t, h, "/v1/fleet/config_get?fleet_id="+fo.FleetID, 503)

	// operation_get: a pending row reconciles with the live node; one on
	// a node that cannot be asked reads unknown, never retried.
	now := time.Now()
	opLive, opOld := "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"
	for _, o := range []store.FleetOperation{
		{ID: opLive, FleetID: fl.FleetID, Action: "worker_start", Request: "{}", Actor: "operator", Idem: "k1", Status: "accepted", Created: now, Updated: now},
		{ID: opOld, FleetID: fo.FleetID, Action: "worker_start", Request: "{}", Actor: "operator", Idem: "k2", Status: "accepted", Created: now, Updated: now},
		{ID: "55555555-5555-4555-8555-555555555555", FleetID: fl.FleetID, Action: "worker_start", Request: "{}", Actor: "carol", Idem: "k3", Status: "succeeded", Created: now, Updated: now},
	} {
		if err := h.srv.Store.InsertFleetOperation(o); err != nil {
			t.Fatal(err)
		}
	}
	op := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+opLive, 200)
	if op["status"] != "succeeded" {
		t.Fatalf("operation_get live = %v; want reconciled to succeeded", op)
	}
	op = getFleet(t, h, "/v1/fleet/operation_get?operation_id="+opOld, 200)
	if op["status"] != "unknown" || op["reconciliation_error"] == nil {
		t.Fatalf("operation_get unreachable = %v; want unknown + reconciliation_error", op)
	}
	getFleet(t, h, "/v1/fleet/operation_get?operation_id=66666666-6666-4666-8666-666666666666", 404)
}

// The scope seam: whatever fleetScope returns decides every read. Here a
// caller naming itself in a test header stands in for a WeCom principal whose
// active account is alice@m5 (C4's FleetScope gives exactly this shape).
func TestFleetScopedToPrincipal(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.fleetScopeHook = func(r *http.Request) (func(string, string) bool, error) {
		switch r.Header.Get("X-Test-Principal") {
		case "":
			return nil, nil
		case "alice":
			return func(host, user string) bool { return host == "m5" && user == "alice" }, nil
		}
		return func(string, string) bool { return false }, nil
	}
	a := connectFakeNode(t, h, "m5", false)
	b := connectFakeNode(t, h, "m4", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 2)
	a.beat("m5", "alice", machineA, fa)
	b.beat("m4", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	as := func(who, path string, want int) map[string]any {
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		if who != "" {
			req.Header.Set("X-Test-Principal", who)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		if resp.StatusCode != want {
			t.Fatalf("%s as %q: HTTP %d %v, want %d", path, who, resp.StatusCode, out, want)
		}
		return out
	}
	if ids := fleetIDs(as("alice", "/v1/fleet/fleet_list", 200)); len(ids) != 1 || ids[0] != fa.FleetID {
		t.Errorf("alice sees %v, want only her own fleet", ids)
	}
	if ids := fleetIDs(as("stranger", "/v1/fleet/fleet_list", 200)); len(ids) != 0 {
		t.Errorf("a principal with no account sees %v, want nothing", ids)
	}
	if ids := fleetIDs(as("", "/v1/fleet/fleet_list", 200)); len(ids) != 2 {
		t.Errorf("the operator sees %v, want both", ids)
	}
	// Another login's fleet is NOT_FOUND, exactly like one that does not exist.
	as("alice", "/v1/fleet/fleet_status?fleet_id="+fb.FleetID, 404)
	as("alice", "/v1/fleet/config_get?fleet_id="+fb.FleetID, 404)
	if s := as("alice", "/v1/fleet/fleet_sessions", 200); s["count"].(float64) != 1 {
		t.Errorf("alice's sessions = %v; want her one", s)
	}
	// A journalled operation is read back only by whoever made it.
	now := time.Now()
	op := "77777777-7777-4777-8777-777777777777"
	if err := h.srv.Store.InsertFleetOperation(store.FleetOperation{ID: op, FleetID: fb.FleetID, Action: "worker_start",
		Request: "{}", Actor: "bob@corp", Idem: "k", Status: "succeeded", Created: now, Updated: now}); err != nil {
		t.Fatal(err)
	}
	as("alice", "/v1/fleet/operation_get?operation_id="+op, 404)
	as("", "/v1/fleet/operation_get?operation_id="+op, 200)
}

// Without the hook, the operator's doors see everything.
func TestFleetScopeOperatorDoors(t *testing.T) {
	h := newFleetHarness(t)
	req, _ := http.NewRequest(http.MethodGet, "/", nil)
	if sc, err := h.srv.fleetScope(req); err != nil || sc != nil {
		t.Fatalf("operator: scope set=%v err=%v; want nil (sees all)", sc != nil, err)
	}
}

// Through C4's real FleetScope: a WeCom principal with an ACTIVE account on
// m5 sees m5's fleet for that login and nothing else.
func TestFleetScopeWeComPrincipal(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "m5", false)
	b := connectFakeNode(t, h, "m4", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "alice-on-m4", "", "", 2)
	a.beat("m5", "alice", machineA, fa)
	b.beat("m4", "alice", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	p, err := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m5", time.Now()); err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodGet, "/", nil)
	req = req.WithContext(context.WithValue(req.Context(), principalKey{}, "wx-alice"))
	out, err := h.srv.FleetList(req, false)
	if err != nil {
		t.Fatal(err)
	}
	got := out["fleets"].([]FleetView)
	if len(got) != 1 || got[0].FleetID != fa.FleetID {
		t.Fatalf("wx-alice sees %+v; want only alice@m5 (no account on m4 yet)", got)
	}
}

// TestFleetIntegrationRealFleetControl is the issue's integration check: two
// agents, each with its own fake fleet behind the REAL fleet-control.py (only
// the tmux-reading adapter is faked), and fleet_status through the hub must
// return both machines' windows with the very worker_ids each node's own
// fleet-control.py prints.
func TestFleetIntegrationRealFleetControl(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_control.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}
	h := newFleetHarness(t)
	const every = 150 * time.Millisecond

	type node struct{ label, host, session, repo string }
	nodes := []node{{"m5", "m5", "fleet-alpha", "verkyyi/claude-fleet"}, {"m4", "m4", "fleet-beta", ""}}
	scripts := map[string]string{}
	for _, n := range nodes {
		home := t.TempDir()
		script := installFakeFleetControl(t, py, bin, home, n.session, n.repo)
		scripts[n.session] = script
		a, err := agent.New(agent.Config{
			HubURL: h.http.URL, Token: h.enroll(t, n.label), Home: home,
			StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
			Sources: "claude", LiveInterval: every, ScanInterval: time.Hour, LimitsInterval: time.Hour,
			Fleet: true, Version: "it-" + n.label,
		})
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() { a.Run(ctx); close(done) }()
		t.Cleanup(func() { cancel(); <-done })
	}

	waitFor(t, 10*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})

	// What each node's own fleet-control.py says, asked directly.
	rpc := func(script string, req map[string]any) map[string]any {
		in, _ := json.Marshal(req)
		cmd := exec.Command(script, "rpc")
		cmd.Stdin = strings.NewReader(string(in))
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s rpc: %v: %s", script, err, out)
		}
		var resp map[string]any
		if err := json.Unmarshal(out, &resp); err != nil || resp["result"] == nil {
			t.Fatalf("%s rpc: %s", script, out)
		}
		return resp
	}
	machines := map[string]bool{}
	for _, f := range getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any) {
		f := f.(map[string]any)
		// Both test agents share this host's real hostname; the endpoint is
		// what tells the two "machines" apart here.
		machines[f["endpoint_id"].(string)] = true
		fid := f["fleet_id"].(string)
		st := getFleet(t, h, "/v1/fleet/fleet_status?fleet_id="+fid, 200)
		if st["source"] != "live" {
			t.Errorf("fleet %s answered from %v, want a live read through the control channel (%v)", fid, st["source"], st["live_error"])
		}
		script := scripts[f["name"].(string)]
		disc := rpc(script, map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}})
		local := rpc(script, map[string]any{"protocol": 1, "method": "fleet_status",
			"machine_id": disc["machine_id"], "params": map[string]any{"fleet_id": fid}})
		want := workerIDs(local["result"].(map[string]any)["workers"])
		got := workerIDs(st["workers"])
		if len(want) == 0 || strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("fleet %s worker_ids via hub = %v; the node's fleet-control.py says %v", fid, got, want)
		}
		// And the hub re-derives the fleet UUID itself.
		if again, _ := fleetid.FleetID(f["machine_id"].(string), f["name"].(string), f["repo"].(string), f["checkout"].(string)); again != fid {
			t.Errorf("fleet %s does not re-derive (got %s)", fid, again)
		}
	}
	if !machines["ep_m5"] || !machines["ep_m4"] {
		t.Fatalf("endpoints = %v, want ep_m5 and ep_m4", machines)
	}
	s := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
	if s["count"].(float64) != 4 {
		t.Fatalf("fleet_sessions = %v; want 2 sessions on each machine", s["count"])
	}
}

func workerIDs(v any) []string {
	out := []string{}
	for _, w := range v.([]any) {
		if id, ok := w.(map[string]any)["worker_id"].(string); ok {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

// installFakeFleetControl lays out <home>/.claude/fleet/bin/ with the real
// fleet_control.py + its imports, a wrapper entry point pinning
// FLEET_CONF_DIR to this home (so two "machines" in one test process each mint
// their own machine_id), and a fake fleet-control-read.sh standing in for
// tmux: one fleet, an issue worker and a scratch session.
func installFakeFleetControl(t *testing.T, py, src, home, session, repo string) string {
	t.Helper()
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"fleet_control.py", "fleet_hub_common.py", "fleet_config_write.py"} {
		b, err := os.ReadFile(filepath.Join(src, f))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, f), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	conf := filepath.Join(home, ".config", "claude-fleet")
	entry := "#!" + py + `
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
os.environ["FLEET_CONF_DIR"] = ` + pyQuote(conf) + `
sys.path.insert(0, here)
from fleet_control import main
sys.exit(main())
`
	checkout := filepath.Join(home, "checkout")
	adapter := `#!/bin/bash
case "$1" in
  inventory) printf '%s\0' ` + shQuote(session) + ` ` + shQuote(repo) + ` ` + shQuote(checkout) + ` claude ` + shQuote(filepath.Join(conf, "fleet.conf")) + ` ` + shQuote(repo) + ` ;;
  workers) printf '@1\t42\t\t/w/x-issue-42\tworking\tclaude\tw1\t\t\n@2\t\t1\t/w/x-scratch-3\tidle\tclaude\tw2\t\t\n' ;;
  config) printf '%s\0' 8 0 1 ;;
  start) exit 0 ;;
  *) exit 2 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "fleet-control.py"), []byte(entry), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fleet-control-read.sh"), []byte(adapter), 0o755); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "fleet-control.py")
}

func pyQuote(s string) string { b, _ := json.Marshal(s); return string(b) }

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// 我的会话 (claude-fleet#1429) is its own page, served from the embedded UI,
// and only when the fleet module is on.
func TestFleetSessionsPage(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.UI = fstest.MapFS{
		"sessions.html": &fstest.MapFile{Data: []byte("<!doctype html><title>我的会话</title>")},
		"index.html":    &fstest.MapFile{Data: []byte("<!doctype html><title>dashboard</title>")},
	}
	resp, body := h.get(t, "/sessions")
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "我的会话") {
		t.Fatalf("GET /sessions = %d %q; want sessions.html", resp.StatusCode, body)
	}

	off := newHarness(t)
	off.srv.UI = h.srv.UI
	if _, body := off.get(t, "/sessions"); strings.Contains(string(body), "我的会话") {
		t.Errorf("GET /sessions served the page with the fleet module off")
	}
}

// fleet_sessions carries a validator (claude-fleet#1481): the same answer
// twice is a 304 for a poller that sends the ETag back, and any heartbeat
// moves it.
func TestFleetSessionsETag(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "m5", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	a.beat("m5", "alice", machineA, fa)
	waitFor(t, 3*time.Second, "fleet registered", func() bool {
		return getFleet(t, h, "/v1/fleet/fleet_sessions", 200)["count"].(float64) == 2
	})
	get := func(ifNoneMatch string) (int, string, map[string]any) {
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/fleet_sessions", nil)
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		if ifNoneMatch != "" {
			req.Header.Set("If-None-Match", ifNoneMatch)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, resp.Header.Get("ETag"), out
	}
	st, tag, out := get("")
	if st != 200 || tag == "" || !strings.HasPrefix(tag, `"`) {
		t.Fatalf("GET: %d ETag=%q, want 200 with a quoted ETag", st, tag)
	}
	if out["etag"] != tag {
		t.Fatalf("body etag %v != header %q", out["etag"], tag)
	}
	if st2, tag2, out2 := get(tag); st2 != 304 || tag2 != tag || len(out2) != 0 {
		t.Fatalf("If-None-Match %q: %d ETag=%q body=%v, want 304, same tag, no body", tag, st2, tag2, out2)
	}
	if st3, _, _ := get(`"stale-0-0"`); st3 != 200 {
		t.Fatalf("a stale validator: %d, want 200", st3)
	}
	// A new heartbeat — a window changed state — moves the validator.
	fa.Workers = []byte(`[{"worker_id":"` + fa.FleetID + `/issue-1","key":"issue-1","issue":1,"state":"needs"}]`)
	fa.Count = 1
	a.beat("m5", "alice", machineA, fa)
	waitFor(t, 3*time.Second, "the validator moved", func() bool {
		st4, tag4, _ := get(tag)
		return st4 == 200 && tag4 != tag
	})
	// The POST form (the certificate path of #1475 asks this way) honours the
	// validator too: a tool read is a read whichever verb carried it.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/fleet_sessions", strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	_, tag5, _ := get("")
	req.Header.Set("If-None-Match", tag5)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 304 {
		t.Fatalf("POST with a matching If-None-Match: %d, want 304", resp.StatusCode)
	}
}

// fleet_sessions long-polls (claude-fleet#1526): with `wait` and a matching
// If-None-Match the hub holds the request and answers 200 the moment a
// heartbeat moves the validator; with nothing new it answers 304 at the
// deadline. Without `wait` nothing changes — TestFleetSessionsETag's immediate
// 304 is the degenerate case, asserted again here.
func TestFleetSessionsLongPoll(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "m5", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	a.beat("m5", "alice", machineA, fa)
	waitFor(t, 3*time.Second, "fleet registered", func() bool {
		return getFleet(t, h, "/v1/fleet/fleet_sessions", 200)["count"].(float64) == 2
	})
	type answer struct {
		status int
		tag    string
		at     time.Time
	}
	ask := func(method, query, body, inm string) answer {
		req, _ := http.NewRequest(method, h.http.URL+"/v1/fleet/fleet_sessions"+query, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return answer{resp.StatusCode, resp.Header.Get("ETag"), time.Now()}
	}
	tag := ask(http.MethodGet, "", "", "").tag

	// Degenerate: no wait → the immediate 304 of #1481.
	t0 := time.Now()
	if got := ask(http.MethodGet, "", "", tag); got.status != 304 || got.at.Sub(t0) > 500*time.Millisecond {
		t.Fatalf("no wait: %d after %v, want an immediate 304", got.status, got.at.Sub(t0))
	}
	// A stale validator is answered at once, wait or not.
	t0 = time.Now()
	if got := ask(http.MethodGet, "?wait=5", "", `"stale-0-0"`); got.status != 200 || got.at.Sub(t0) > 500*time.Millisecond {
		t.Fatalf("stale validator with wait: %d after %v, want an immediate 200", got.status, got.at.Sub(t0))
	}

	// Nothing new: held to the deadline, then 304 — by GET ?wait= and by the
	// POST body's wait (the certificate door's form).
	t0 = time.Now()
	if got := ask(http.MethodGet, "?wait=1", "", tag); got.status != 304 || got.at.Sub(t0) < 900*time.Millisecond {
		t.Fatalf("GET wait=1, nothing new: %d after %v, want 304 after ~1 s", got.status, got.at.Sub(t0))
	}
	t0 = time.Now()
	if got := ask(http.MethodPost, "", `{"wait":1}`, tag); got.status != 304 || got.at.Sub(t0) < 900*time.Millisecond {
		t.Fatalf("POST wait=1, nothing new: %d after %v, want 304 after ~1 s", got.status, got.at.Sub(t0))
	}

	// A heartbeat while held: 200 with the new validator, ≤ 50 ms after the
	// hub recorded it — not at the recheck, not at the deadline.
	done := make(chan answer, 1)
	t0 = time.Now()
	go func() { done <- ask(http.MethodGet, "?wait=20", "", tag) }()
	time.Sleep(300 * time.Millisecond)
	select {
	case got := <-done:
		t.Fatalf("held request answered %d before any heartbeat", got.status)
	default:
	}
	fa.Workers = []byte(`[{"worker_id":"` + fa.FleetID + `/issue-1","key":"issue-1","issue":1,"state":"needs"}]`)
	fa.Count = 1
	a.beat("m5", "alice", machineA, fa)
	select {
	case got := <-done:
		fired := h.srv.sessionsChanged.lastFired()
		if got.status != 200 || got.tag == tag {
			t.Fatalf("after a heartbeat: %d ETag=%q, want 200 with a new validator", got.status, got.tag)
		}
		if d := got.at.Sub(fired); fired.Before(t0) || d > 50*time.Millisecond {
			t.Fatalf("answered %v after the heartbeat was recorded, want ≤ 50 ms", d)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("held request not answered within 3 s of a heartbeat")
	}
}

func TestFleetSessionsWaitArg(t *testing.T) {
	for _, c := range []struct {
		in   any
		want time.Duration
	}{
		{nil, 0}, {"", 0}, {"x", 0}, {"-3", 0}, {"0", 0},
		{"2", 2 * time.Second}, {json.Number("1.5"), 1500 * time.Millisecond},
		{float64(9), 9 * time.Second}, {"600", fleetSessionsMaxWait}, {"1e300", fleetSessionsMaxWait},
	} {
		if got := fleetSessionsWaitArg(c.in); got != c.want {
			t.Errorf("fleetSessionsWaitArg(%#v) = %v, want %v", c.in, got, c.want)
		}
	}
}
