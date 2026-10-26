package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
	"regexp"
	"sync"
	"sync/atomic"
)

// The Fleet Hub read half (claude-fleet#1409).

const (
	machineA = "11111111-1111-4111-8111-111111111111"
	machineB = "22222222-2222-4222-8222-222222222222"
	machineC = "33333333-3333-4333-8333-333333333333"
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
	a := connectFakeNode(t, h, "mac-d", false)
	b := connectFakeNode(t, h, "mac-c", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	fb := fakeFleet(t, machineB, "fleet-b", "", "", 7)
	a.beat("mac-d", "alice", machineA, fa)
	b.beat("mac-c", "bob", machineB, fb)

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
	if got := s["machines"].([]any); len(got) != 2 || got[0] != "mac-c" || got[1] != "mac-d" {
		t.Fatalf("machines = %v, want [mac-c mac-d]", got)
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
	a.beat("mac-d", "alice", machineA)
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
	n := connectFakeNode(t, h, "mac-d", true)
	good := fakeFleet(t, machineA, "good", "o/r", "/c", 3)
	forged := fakeFleet(t, machineA, "forged", "o/r", "/c", 4)
	forged.FleetID = fakeFleet(t, machineA, "other", "", "", 0).FleetID
	// A worker_id pointing at another fleet keeps its row but loses its id.
	var ws []map[string]any
	_ = json.Unmarshal(good.Workers, &ws)
	ws = append(ws, map[string]any{"worker_id": forged.FleetID + "/issue-9", "key": "issue-9"})
	good.Workers, _ = json.Marshal(ws)
	good.Count = len(ws)
	n.beat("mac-d", "alice", machineA, good, forged)

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
	other := connectFakeNode(t, h, "mac-c", false)
	steal := good
	other.beat("mac-c", "bob", machineB, steal)
	time.Sleep(200 * time.Millisecond)
	r, err := h.srv.Store.Fleet(good.FleetID)
	if err != nil || r.MachineID != machineA {
		t.Fatalf("fleet %s now on %s (%v); a second machine must not take it over", good.FleetID, r.MachineID, err)
	}
}

func TestFleetStatusLiveThenHeartbeat(t *testing.T) {
	h := newFleetHarness(t)
	live := connectFakeNode(t, h, "mac-d", true)
	old := connectFakeNode(t, h, "mac-c", false)
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
	live.beat("mac-d", "alice", machineA, fl)
	old.beat("mac-c", "bob", machineB, fo)
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
// caller naming itself in a test header stands in for a signed-in principal whose
// active account is alice@mac-d (C4's FleetScope gives exactly this shape).
func TestFleetScopedToPrincipal(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.fleetScopeHook = func(r *http.Request) (func(string, string) bool, error) {
		switch r.Header.Get("X-Test-Principal") {
		case "":
			return nil, nil
		case "alice":
			return func(host, user string) bool { return host == "mac-d" && user == "alice" }, nil
		}
		return func(string, string) bool { return false }, nil
	}
	a := connectFakeNode(t, h, "mac-d", false)
	b := connectFakeNode(t, h, "mac-c", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 2)
	a.beat("mac-d", "alice", machineA, fa)
	b.beat("mac-c", "bob", machineB, fb)
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

// Through C4's real FleetScope: a signed-in principal with an ACTIVE account on
// mac-d sees mac-d's fleet for that login and nothing else.
func TestFleetScopeSignedInPrincipal(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "mac-d", false)
	b := connectFakeNode(t, h, "mac-c", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "alice-on-mac-c", "", "", 2)
	a.beat("mac-d", "alice", machineA, fa)
	b.beat("mac-c", "alice", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	p, err := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mac-d", time.Now()); err != nil {
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
		t.Fatalf("wx-alice sees %+v; want only alice@mac-d (no account on mac-c yet)", got)
	}
}

// Config (claude-fleet#1989) was its own page; 设置 took it over
// (claude-fleet#3931) and the old page is gone (claude-fleet#3939).
func TestFleetConfigPage(t *testing.T) {
	h := newFleetHarness(t)
	// 设置 took it over (claude-fleet#3931): the old address is one 301 to it.
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/config", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMovedPermanently || resp.Header.Get("Location") != AppPrefix+settingsPagePath {
		t.Fatalf("GET /config = %d → %q; want 301 %s", resp.StatusCode, resp.Header.Get("Location"), AppPrefix+settingsPagePath)
	}
	if resp, _ := h.get(t, "/u/alice"); resp.StatusCode != http.StatusNotFound {
		t.Errorf("GET /u/alice = %d; want 404", resp.StatusCode)
	}
}

// fleet_sessions carries a validator (claude-fleet#1481): the same answer
// twice is a 304 for a poller that sends the ETag back, and any heartbeat
// moves it.
func TestFleetSessionsETag(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "mac-d", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	a.beat("mac-d", "alice", machineA, fa)
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
	a.beat("mac-d", "alice", machineA, fa)
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

// A session that waits on you says what it asks (claude-fleet#2538): the
// node's status_kind / status_msg ride the worker verbatim into
// fleet_sessions — the session page and the client read them there.
func TestFleetSessionsCarryStatusKindMsg(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "mac-d", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	fa.Workers = []byte(`[{"worker_id":"` + fa.FleetID + `/issue-1","key":"issue-1","issue":1,"state":"needs","needs":"perm",` +
		`"status_kind":"permission","status_msg":"Bash: git push origin issue-1"},` +
		`{"worker_id":"` + fa.FleetID + `/issue-2","key":"issue-2","issue":2,"state":"working"}]`)
	fa.Count = 2
	a.beat("mac-d", "alice", machineA, fa)
	var got map[string]any
	waitFor(t, 3*time.Second, "fleet registered", func() bool {
		got = getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
		return got["count"].(float64) == 2
	})
	by := map[string]map[string]any{}
	for _, s := range got["sessions"].([]any) {
		w := s.(map[string]any)["worker"].(map[string]any)
		by[w["key"].(string)] = w
	}
	if w := by["issue-1"]; w["status_kind"] != "permission" || w["status_msg"] != "Bash: git push origin issue-1" {
		t.Fatalf("issue-1 worker = %v, want status_kind permission + its words", w)
	}
	if w := by["issue-2"]; w["status_kind"] != nil || w["status_msg"] != nil {
		t.Fatalf("issue-2 worker = %v, want no status_kind / status_msg", w)
	}
}

// fleet_sessions long-polls (claude-fleet#1526): with `wait` and a matching
// If-None-Match the hub holds the request and answers 200 the moment a
// heartbeat moves the validator; with nothing new it answers 304 at the
// deadline. Without `wait` nothing changes — TestFleetSessionsETag's immediate
// 304 is the degenerate case, asserted again here.
func TestFleetSessionsLongPoll(t *testing.T) {
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "mac-d", false)
	fa := fakeFleet(t, machineA, "fleet-a", "o/a", "/srv/a", 1, 2)
	a.beat("mac-d", "alice", machineA, fa)
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
	var logMu sync.Mutex
	var logged []string
	h.srv.LogWriter = func(l string) { logMu.Lock(); logged = append(logged, l); logMu.Unlock() }
	lastLine := func() string {
		logMu.Lock()
		defer logMu.Unlock()
		for i := len(logged) - 1; i >= 0; i-- {
			if strings.Contains(logged[i], "/v1/fleet/fleet_sessions") {
				return logged[i]
			}
		}
		return ""
	}

	// Degenerate: no wait → the immediate 304 of #1481.
	t0 := time.Now()
	if got := ask(http.MethodGet, "", "", tag); got.status != 304 || got.at.Sub(t0) > 500*time.Millisecond {
		t.Fatalf("no wait: %d after %v, want an immediate 304", got.status, got.at.Sub(t0))
	}
	if l := lastLine(); strings.Contains(l, " held=") {
		t.Fatalf("a request that was not held logs held=: %q", l)
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
	// The wait is logged apart from the work: held=<~1s> beside the total.
	if l := lastLine(); !regexp.MustCompile(` 304 [0-9.]+m?s held=(9\d\dms|1(\.\d+)?s)`).MatchString(l) {
		t.Fatalf("a held request's log line = %q, want held=~1s after the total", l)
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
	a.beat("mac-d", "alice", machineA, fa)
	select {
	case got := <-done:
		fired := h.srv.sessionsChanged.lastFired()
		if got.status != 200 || got.tag == tag {
			t.Fatalf("after a heartbeat: %d ETag=%q, want 200 with a new validator", got.status, got.tag)
		}
		// well under the 5 s recheck; 50 ms was missed by 0.1 ms on a -race Postgres runner (claude-fleet#3703)
		if d := got.at.Sub(fired); fired.Before(t0) || d > 500*time.Millisecond {
			t.Fatalf("answered %v after the heartbeat was recorded, want ≤ 500 ms", d)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("held request not answered within 3 s of a heartbeat")
	}
}

// A held request wakes at once for a beat from a login its caller sees, and
// re-reads for anyone else's beats at most every fleetSessionsOtherEvery
// (task PNWW): another person's busy machines no longer rebuild it each beat.
func TestFleetSessionsLongPollScopedWake(t *testing.T) {
	h := newFleetHarness(t)
	var reads atomic.Int64
	h.srv.fleetScopeHook = func(r *http.Request) (func(string, string) bool, error) {
		if r.Header.Get("X-Test-Principal") != "alice" {
			return nil, nil
		}
		reads.Add(1)
		return func(host, user string) bool { return host == "mac-d" && user == "alice" }, nil
	}
	a := connectFakeNode(t, h, "mac-d", false)
	b := connectFakeNode(t, h, "mac-c", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 2)
	a.beat("mac-d", "alice", machineA, fa)
	b.beat("mac-c", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	type answer struct {
		status int
		tag    string
		at     time.Time
	}
	ask := func(query, inm string) answer {
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/fleet_sessions"+query, nil)
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		req.Header.Set("X-Test-Principal", "alice")
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
	tag := ask("", "").tag
	reads.Store(0)
	done := make(chan answer, 1)
	go func() { done <- ask("?wait=10", tag) }()
	// bob's machine beats every 50 ms for 1.5 s: ~30 wake-ups.
	for i := 0; i < 30; i++ {
		time.Sleep(50 * time.Millisecond)
		b.beat("mac-c", "bob", machineB, fb)
	}
	if n := reads.Load(); n > 4 {
		t.Fatalf("%d reads of a held request during 30 out-of-scope beats in 1.5 s, want ≤ 4 (one, then one a second)", n)
	}
	select {
	case got := <-done:
		t.Fatalf("held request answered %d on out-of-scope beats", got.status)
	default:
	}
	// alice's own beat: answered at once with the new validator.
	fa.Workers = []byte(`[{"worker_id":"` + fa.FleetID + `/issue-1","key":"issue-1","issue":1,"state":"needs"}]`)
	t0 := time.Now()
	a.beat("mac-d", "alice", machineA, fa)
	select {
	case got := <-done:
		if got.status != 200 || got.tag == tag {
			t.Fatalf("after alice's beat: %d ETag=%q, want 200 with a new validator", got.status, got.tag)
		}
		if d := got.at.Sub(t0); d > 500*time.Millisecond {
			t.Fatalf("in-scope beat answered after %v, want at once", d)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("held request not answered within 3 s of an in-scope beat")
	}
}

func TestChangeBroadcastFiredSince(t *testing.T) {
	var b changeBroadcast
	_, seq := b.waitSeq()
	b.fireFor(loginKey("mac-c", "bob"))
	alice := func(k string) bool { h, u, _ := splitLoginKey(k); return h == "mac-d" && u == "alice" }
	if b.firedSince(seq, alice) {
		t.Fatal("bob's beat concerns alice")
	}
	b.fireFor(loginKey("mac-d", "alice"))
	if !b.firedSince(seq, alice) {
		t.Fatal("alice's beat does not concern alice")
	}
	_, seq = b.waitSeq()
	b.fire()
	if !b.firedSince(seq, alice) {
		t.Fatal("a fire() naming nobody must concern everyone")
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
