package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The Fleet Hub write half (claude-fleet#1410).

const writeRepo = "verkyyi/claude-fleet"

// writeNode is a hand-driven node that takes writes: it records every submit
// envelope and answers it with answer(envelope), the way fleet-control.py's
// submit answers — the node's own operation record.
type writeNode struct {
	t      *testing.T
	conn   *websocket.Conn
	mu     sync.Mutex
	writes []map[string]any
	answer func(env map[string]any) (any, *control.Error)
	// opGet answers operation_get (claude-fleet#1586); nil = the operation
	// as submit journalled it, still accepted.
	opGet func(env map[string]any) (any, *control.Error)
}

func connectWriteNode(t *testing.T, h *harness, label string) *writeNode {
	t.Helper()
	return connectWriteNodeTok(t, h, h.enroll(t, label))
}

// connectWriteNodeTok dials with an existing enrollment: the same endpoint
// coming back.
func connectWriteNodeTok(t *testing.T, h *harness, token string) *writeNode {
	t.Helper()
	return connectWriteNodeCaps(t, h, token, control.CapRead, control.CapWrite)
}

// connectWriteNodeCaps is connectWriteNodeTok saying the given capabilities.
func connectWriteNodeCaps(t *testing.T, h *harness, token string, caps ...string) *writeNode {
	t.Helper()
	c := dialNode(t, h, token)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Capabilities: caps})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	n := &writeNode{t: t, conn: c, answer: accepted}
	go n.serve()
	return n
}

// accepted is fleet-control.py's submit answer: the operation, journalled.
func accepted(env map[string]any) (any, *control.Error) {
	return map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"],
		"action": env["action"], "status": "accepted", "result": nil}, nil
}

func (n *writeNode) serve() {
	for {
		var m control.Message
		if err := wsjson.Read(context.Background(), n.conn, &m); err != nil {
			return
		}
		var req control.Request
		_ = json.Unmarshal(m.Payload, &req)
		var env map[string]any
		_ = json.Unmarshal(req.Params, &env)
		var res any
		var e *control.Error
		switch {
		case m.Type == control.TypeRequest && req.Method == "operation_get":
			res, e = n.operation(asString(env["operation_id"]))
		case m.Type != control.TypeWrite:
			continue
		default:
			n.mu.Lock()
			n.writes = append(n.writes, env)
			answer := n.answer
			n.mu.Unlock()
			res, e = answer(env)
		}
		if res == nil && e == nil {
			continue // say nothing: the hub must time out to unknown
		}
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
}

// operation is the node's record of one operation it was sent.
func (n *writeNode) operation(id string) (any, *control.Error) {
	n.mu.Lock()
	get := n.opGet
	var env map[string]any
	for _, w := range n.writes {
		if w["operation_id"] == id {
			env = w
		}
	}
	n.mu.Unlock()
	switch {
	case env == nil:
		return nil, &control.Error{Code: "NOT_FOUND", Message: "Operation has not been accepted by this machine"}
	case get != nil:
		return get(env)
	}
	return accepted(env)
}

func (n *writeNode) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.writes)
}

func (n *writeNode) setOpGet(f func(map[string]any) (any, *control.Error)) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.opGet = f
}

func (n *writeNode) setAnswer(f func(map[string]any) (any, *control.Error)) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.answer = f
}

// beatLoad reports a login with a given load, memory and session count.
func (n *writeNode) beatLoad(host, user, machine string, load1 float64, sessions int, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Load1: load1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: sessions,
		Fleets: fleets, ObservedAt: time.Now()})
}

func postFleet(t *testing.T, h *harness, tool string, args map[string]any, wantStatus int) map[string]any {
	t.Helper()
	body, _ := json.Marshal(args)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/"+tool, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != wantStatus {
		t.Fatalf("%s: HTTP %d (%v), want %d", tool, resp.StatusCode, out, wantStatus)
	}
	return out
}

// twoNodes is the issue's rig: m5 and m4, the same repo on each, both
// connected and accepting writes. m5 is busy (1.0 load per core).
func twoNodes(t *testing.T) (*harness, *writeNode, *writeNode, control.Fleet, control.Fleet) {
	t.Helper()
	h := newFleetHarness(t)
	m5 := connectWriteNode(t, h, "m5")
	m4 := connectWriteNode(t, h, "m4")
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet", 2)
	m5.beatLoad("m5", "verk", machineA, 10, 3, f5)
	m4.beatLoad("m4", "verk", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	return h, m5, m4, f5, f4
}

// The issue's acceptance check: with m5 under load, worker_start(node=auto)
// lands on m4, says why, and a repeat of the same request runs once.
func TestFleetWriteAutoPlacesOnIdleNode(t *testing.T) {
	h, m5, m4, _, f4 := twoNodes(t)
	args := map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "start-7"}
	op := postFleet(t, h, "worker_start", args, 200)
	if op["fleet_id"] != f4.FleetID || op["status"] != "accepted" {
		t.Fatalf("worker_start(node=auto) = %v; want accepted on m4's fleet %s", op, f4.FleetID)
	}
	pl, _ := op["placement"].(map[string]any)
	if pl["machine"] != "m4" || !strings.Contains(pl["reason"].(string), "m5 excluded: load 1.00/core") {
		t.Fatalf("placement = %v; want m4 with m5's exclusion in the reason", pl)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes sent: m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	env := m4.writes[0]
	if env["action"] != "worker_start" || env["actor"] != "operator" || env["operation_id"] != op["operation_id"] {
		t.Fatalf("envelope = %v", env)
	}
	// fleet-control.py's validate_write takes issue/agent/repo and nothing
	// else: node and fleet_id never reach it.
	params := env["params"].(map[string]any)
	if _, ok := params["node"]; ok || params["issue"].(float64) != 7 || params["repo"] != writeRepo {
		t.Fatalf("params = %v", params)
	}

	// The same request again: the same operation, no second write.
	again := postFleet(t, h, "worker_start", args, 200)
	if again["operation_id"] != op["operation_id"] || m4.count() != 1 {
		t.Fatalf("repeat returned %v (m4 writes %d); want the first operation and no second write", again["operation_id"], m4.count())
	}
	// The same key for something else is refused.
	other := map[string]any{"issue": 8, "repo": writeRepo, "idempotency_key": "start-7"}
	if e := postFleet(t, h, "worker_start", other, 409)["error"].(map[string]any); e["code"] != "IDEMPOTENCY_CONFLICT" {
		t.Fatalf("reused key: %v", e)
	}

	// The journal keeps the placement for operation_get.
	got := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+op["operation_id"].(string), 200)
	if got["placement"].(map[string]any)["machine"] != "m4" {
		t.Fatalf("operation_get lost the placement: %v", got)
	}
}

// Concurrent calls with one key: exactly one reaches a node.
func TestFleetWriteIdempotentUnderRace(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	var wg sync.WaitGroup
	ids := make([]string, 8)
	for i := range ids {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			out := postFleet(t, h, "worker_start", map[string]any{"issue": 9, "fleet_id": f4.FleetID,
				"idempotency_key": "race"}, 200)
			ids[i], _ = out["operation_id"].(string)
		}(i)
	}
	wg.Wait()
	for _, id := range ids {
		if id != ids[0] {
			t.Fatalf("operation ids differ: %v", ids)
		}
	}
	if m4.count() != 1 {
		t.Fatalf("m4 received %d writes; want exactly 1", m4.count())
	}
}

// A node that is not connected is refused at once: nothing journalled,
// nothing queued, nothing sent when it comes back.
func TestFleetWriteOfflineFailsWithoutQueueing(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	m4.conn.Close(websocket.StatusNormalClosure, "gone")
	waitFor(t, 3*time.Second, "m4 disconnected", func() bool { return h.srv.nodes.get("ep_m4") == nil })

	start := map[string]any{"issue": 11, "fleet_id": f4.FleetID, "idempotency_key": "off-1"}
	if e := postFleet(t, h, "worker_start", start, 503)["error"].(map[string]any); e["code"] != "UNAVAILABLE" {
		t.Fatalf("start on a disconnected node: %v", e)
	}
	if _, err := h.srv.Store.FleetOperationByIdem("operator", "off-1"); err == nil {
		t.Fatal("a refused write was journalled; the key must stay free for a retry")
	}
	// Placed: m4 is gone and m5 is busy — no machine qualifies.
	auto := map[string]any{"issue": 11, "repo": writeRepo, "idempotency_key": "off-2"}
	e := postFleet(t, h, "worker_start", auto, 503)["error"].(map[string]any)
	if e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "m5: load") {
		t.Fatalf("placed start with no eligible node: %v", e)
	}

	// m4 returns: nothing was waiting for it.
	back := connectWriteNodeTok(t, h, h.tokens["m4"])
	waitFor(t, 3*time.Second, "m4 reconnected", func() bool { return h.srv.nodes.get("ep_m4") != nil })
	time.Sleep(200 * time.Millisecond)
	if m4.count() != 0 || back.count() != 0 {
		t.Fatalf("a refused write was delivered later (m4=%d, reconnect=%d)", m4.count(), back.count())
	}
}

// What the node says decides the status: a structured refusal is failed, an
// unconfirmed outcome or silence is unknown — and unknown is never re-sent.
func TestFleetWriteOutcomes(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	old := fleetWriteWait
	fleetWriteWait = 300 * time.Millisecond
	t.Cleanup(func() { fleetWriteWait = old })
	start := func(key string) map[string]any {
		return postFleet(t, h, "worker_start", map[string]any{"issue": 12, "fleet_id": f4.FleetID, "idempotency_key": key}, 200)
	}

	m4.setAnswer(func(map[string]any) (any, *control.Error) {
		return nil, &control.Error{Code: "NOT_FOUND", Message: "Fleet is not configured"}
	})
	if op := start("o-refused"); op["status"] != "failed" {
		t.Fatalf("a node refusal = %v; want failed", op)
	}
	m4.setAnswer(func(map[string]any) (any, *control.Error) {
		return nil, &control.Error{Code: control.CodeUnknownOutcome, Message: "controller crashed"}
	})
	if op := start("o-crash"); op["status"] != "unknown" {
		t.Fatalf("an unconfirmed write = %v; want unknown", op)
	}
	m4.setAnswer(func(map[string]any) (any, *control.Error) { return nil, nil })
	op := start("o-silent")
	if op["status"] != "unknown" {
		t.Fatalf("a write the node never acknowledged = %v; want unknown", op)
	}
	n := m4.count()
	if again := start("o-silent"); again["operation_id"] != op["operation_id"] || m4.count() != n {
		t.Fatal("retrying an unknown operation's key re-sent it")
	}
}

// The grant: a person needs the tool's scope, and sees only their own logins.
func TestFleetWriteAuthorization(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	p, err := h.srv.Store.AdoptPrincipal("wx-verk", "verk", "Verk", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	as := func(person string) fleetPrincipal {
		r, _ := http.NewRequest(http.MethodGet, "/", nil)
		r = r.WithContext(context.WithValue(withViewer(r.Context(), person), principalKey{}, person))
		pr, err := h.srv.FleetPrincipal(r)
		if err != nil {
			t.Fatal(err)
		}
		return pr
	}
	args := func(key string) map[string]any {
		return map[string]any{"issue": 13, "fleet_id": f4.FleetID, "idempotency_key": key}
	}

	h.srv.FleetPersonScopes = []string{"fleet:read"}
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-verk"), "worker_start", args("a1")); errorObject(err)["code"] != "FORBIDDEN" {
		t.Fatalf("start without worker:start: %v; want FORBIDDEN", err)
	}
	// Every person is refused config:write by default, whatever the key.
	h.srv.FleetPersonScopes = nil
	cfg := map[string]any{"fleet_id": f4.FleetID, "key": "FLEET_AUTOFILL", "value": 1,
		"expected_revision": strings.Repeat("a", 64), "idempotency_key": "c1"}
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-verk"), "config_set", cfg); errorObject(err)["code"] != "FORBIDDEN" {
		t.Fatalf("config_set by a person: %v; want FORBIDDEN", err)
	}
	// Not their login: indistinguishable from no such fleet.
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-someone"), "worker_start", args("a2")); errorObject(err)["code"] != "NOT_FOUND" {
		t.Fatalf("start on someone else's fleet: %v; want NOT_FOUND", err)
	}
	if m4.count() != 0 {
		t.Fatalf("a refused call reached the node (%d writes)", m4.count())
	}
	// With the default grant, their own login works.
	op, err := h.srv.SubmitWrite(context.Background(), as("wx-verk"), "worker_start", args("a3"))
	if err != nil || op["status"] != "accepted" || m4.writes[0]["actor"] != "wx-verk" {
		t.Fatalf("own start: %v %v", op, err)
	}
}

// The per-person cap: at the cap a machine is excluded from placement, and a
// start named at it is refused.
func TestFleetWriteNodeCap(t *testing.T) {
	h, m5, m4, _, f4 := twoNodes(t)
	// No machine has a default cap (claude-fleet#1994): the operator sets one.
	if err := h.srv.Store.SetFleetSetting(NodeCapPrefix+"m4", "6", time.Now()); err != nil {
		t.Fatal(err)
	}
	m5.beatLoad("m5", "verk", machineA, 1, 3, fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1))
	m4.beatLoad("m4", "verk", machineB, 0, 6, f4) // idle, but at m4's cap of 6
	time.Sleep(100 * time.Millisecond)

	op := postFleet(t, h, "worker_start", map[string]any{"issue": 14, "repo": writeRepo, "idempotency_key": "cap-1"}, 200)
	pl := op["placement"].(map[string]any)
	if pl["machine"] != "m5" || !strings.Contains(pl["reason"].(string), "m4 excluded: at the per-person cap (6/6") {
		t.Fatalf("placement = %v; want m5, m4 at its cap", pl)
	}
	e := postFleet(t, h, "worker_start", map[string]any{"issue": 15, "fleet_id": f4.FleetID, "idempotency_key": "cap-2"}, 429)
	if e["error"].(map[string]any)["code"] != "AT_CAPACITY" {
		t.Fatalf("named start at the cap: %v", e)
	}
	// The operator raises it.
	if err := h.srv.Store.SetFleetSetting(NodeCapPrefix+"m4", "8", time.Now()); err != nil {
		t.Fatal(err)
	}
	postFleet(t, h, "worker_start", map[string]any{"issue": 15, "fleet_id": f4.FleetID, "idempotency_key": "cap-3"}, 200)
}

func TestFleetWriteRefusesGETAndBadArgs(t *testing.T) {
	h, _, _, _, f4 := twoNodes(t)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/worker_start?fleet_id="+f4.FleetID, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET worker_start: HTTP %d", resp.StatusCode)
	}
	for _, bad := range []map[string]any{
		{"issue": 1.5, "fleet_id": f4.FleetID, "idempotency_key": "b"},
		{"issue": 1, "fleet_id": f4.FleetID, "idempotency_key": "has space"},
		{"issue": 1, "idempotency_key": "b"}, // placed, but no repo
		{"issue": 1, "fleet_id": f4.FleetID, "idempotency_key": "b", "force": true},
	} {
		postFleet(t, h, "worker_start", bad, 400)
	}
	msg := map[string]any{"worker_id": f4.FleetID + "/issue-2", "text": "hi <!-- fleet:x -->", "idempotency_key": "m"}
	postFleet(t, h, "worker_message", msg, 400)
}

// End to end through a real agent and the REAL fleet-control.py: the hub's
// write reaches the node's controller, which journals it under the same id
// and runs it detached; operation_get reads the executor's outcome back.
func TestFleetWriteIntegrationRealFleetControl(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_control.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}
	h := newFleetHarness(t)
	home := t.TempDir()
	installFakeFleetControl(t, py, bin, home, "fleet-alpha", writeRepo)
	a, err := agent.New(agent.Config{
		HubURL: h.http.URL, Token: h.enroll(t, "m4"), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 150 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, Version: "it-write",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	waitFor(t, 10*time.Second, "fleet registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 1
	})
	fid := getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)[0].(map[string]any)["fleet_id"].(string)

	// The fake adapter's window list holds issue 42, so a start of 42 is
	// observed by the executor and confirmed.
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 42, "fleet_id": fid, "idempotency_key": "it-42"}, 200)
	switch op["status"] {
	case "accepted", "running", "succeeded":
	default:
		t.Fatalf("worker_start through the real controller = %v", op)
	}
	id := op["operation_id"].(string)
	var final map[string]any
	waitFor(t, 15*time.Second, "the executor's outcome", func() bool {
		final = getFleet(t, h, "/v1/fleet/operation_get?operation_id="+id, 200)
		return final["status"] == "succeeded" || final["status"] == "failed"
	})
	if final["status"] != "succeeded" {
		t.Fatalf("operation = %v; want succeeded", final)
	}
	// The node journalled the hub's operation id, not one of its own.
	script := filepath.Join(home, ".claude", "fleet", "bin", "fleet-control.py")
	disc, _ := json.Marshal(map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}})
	cmd := exec.Command(script, "rpc")
	cmd.Stdin = bytes.NewReader(disc)
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var d map[string]any
	_ = json.Unmarshal(out, &d)
	get, _ := json.Marshal(map[string]any{"protocol": 1, "method": "operation_get", "machine_id": d["machine_id"],
		"params": map[string]any{"operation_id": id}})
	cmd = exec.Command(script, "rpc")
	cmd.Stdin = bytes.NewReader(get)
	if out, err = cmd.Output(); err != nil || !strings.Contains(string(out), `"status":"succeeded"`) {
		t.Fatalf("the node's own journal for %s: %s (%v)", id, out, err)
	}
}

// account_class on worker_start (claude-fleet#1540): local / pool reach the
// node's params, any adds nothing, free text is refused.
func TestFleetWriteAccountClass(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	postFleet(t, h, "worker_start", map[string]any{"issue": 7, "fleet_id": f4.FleetID, "account_class": "pool", "idempotency_key": "ac-7"}, 200)
	if m4.count() != 1 {
		t.Fatalf("m4 writes = %d; want 1", m4.count())
	}
	if params := m4.writes[0]["params"].(map[string]any); params["account_class"] != "pool" {
		t.Fatalf("params = %v; want account_class pool", params)
	}
	postFleet(t, h, "worker_start", map[string]any{"issue": 8, "fleet_id": f4.FleetID, "account_class": "any", "idempotency_key": "ac-8"}, 200)
	if m4.count() != 2 {
		t.Fatalf("m4 writes = %d; want 2", m4.count())
	}
	if params := m4.writes[1]["params"].(map[string]any); params["account_class"] != nil {
		t.Fatalf("any must add nothing: %v", params)
	}
	e := postFleet(t, h, "worker_start", map[string]any{"issue": 9, "fleet_id": f4.FleetID, "account_class": "x", "idempotency_key": "ac-9"}, 400)["error"].(map[string]any)
	if e["code"] != "INVALID_ARGUMENT" || m4.count() != 2 {
		t.Fatalf("free text: %v (m4 writes %d); want INVALID_ARGUMENT and nothing sent", e, m4.count())
	}
}

// reap on worker_start (claude-fleet#1902): a reap policy reaches the node's
// params as one word, none adds nothing, anything off the grammar is refused.
func TestFleetWriteReapPolicy(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	postFleet(t, h, "worker_start", map[string]any{"issue": 7, "fleet_id": f4.FleetID, "reap": "merged:48h", "idempotency_key": "rp-7"}, 200)
	if params := m4.writes[0]["params"].(map[string]any); params["reap"] != "merged:48h" {
		t.Fatalf("params = %v; want reap merged:48h", params)
	}
	postFleet(t, h, "worker_start", map[string]any{"issue": 8, "fleet_id": f4.FleetID, "idempotency_key": "rp-8"}, 200)
	if params := m4.writes[1]["params"].(map[string]any); params["reap"] != nil {
		t.Fatalf("no reap must add nothing: %v", params)
	}
	for i, bad := range []string{"never", "keep; rm -rf /", "done:0", "at:soon"} {
		e := postFleet(t, h, "worker_start", map[string]any{"issue": 20 + i, "fleet_id": f4.FleetID, "reap": bad, "idempotency_key": "rp-bad-" + strconv.Itoa(i)}, 400)["error"].(map[string]any)
		if e["code"] != "INVALID_ARGUMENT" || m4.count() != 2 {
			t.Fatalf("reap %q: %v (m4 writes %d); want INVALID_ARGUMENT and nothing sent", bad, e, m4.count())
		}
	}
	for _, ok := range []string{"merged", "done:2h", "loop-end", "keep", "at:2026-10-06T18:00:00Z", "at:18:00"} {
		if !reapPolicyOK(ok) {
			t.Fatalf("reapPolicyOK(%q) = false", ok)
		}
	}
}
