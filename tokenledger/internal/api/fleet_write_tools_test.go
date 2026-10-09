package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// The row tools of claude-fleet#1487 (EPIC #1479 C8): worker_answer and
// worker_reap are journalled writes like the other lifecycle tools — listed,
// parsed to the letter of fleet_hub_common.validate_write, scoped one scope
// each, deduplicated by key, and sent to the worker's node with exactly the
// arguments the node's whitelist accepts.
func TestFleetWriteAnswerAndReap(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	wid := f4.FleetID + "/issue-2"
	for _, tool := range []string{"worker_answer", "worker_reap"} {
		if !hasString(FleetTools, tool) || !fleetWriteTools[tool] {
			t.Fatalf("%s is not a listed write tool", tool)
		}
	}
	if fleetScopeOf["worker_answer"] != "worker:answer" || fleetScopeOf["worker_reap"] != "worker:reap" ||
		!hasString(FleetScopes, "worker:answer") || !hasString(FleetScopes, "worker:reap") {
		t.Fatal("each row tool must have its own scope")
	}

	// An answer: accepted, journalled, the node gets worker_id + answer and nothing else.
	op := postFleet(t, h, "worker_answer", map[string]any{"worker_id": wid, "answer": "yes", "idempotency_key": "a1"}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("worker_answer = %v; want accepted", op)
	}
	waitFor(t, 2*time.Second, "the node took the answer", func() bool { return m4.count() == 1 })
	env := m4.writes[0]
	params, _ := env["params"].(map[string]any)
	if env["action"] != "worker_answer" || params["worker_id"] != wid || params["answer"] != "yes" || len(params) != 2 {
		t.Fatalf("the node was sent %v", env)
	}
	// The same key is the same operation, not a second keystroke.
	if again := postFleet(t, h, "worker_answer", map[string]any{"worker_id": wid, "answer": "yes", "idempotency_key": "a1"}, 200); again["operation_id"] != op["operation_id"] || m4.count() != 1 {
		t.Fatal("a repeated answer key was sent again")
	}
	// The grammar: yes / no / picks; anything else never reaches a node.
	for i, good := range []string{"no", "2", "1,3", "2 1,3", "12 3 4,5,6"} {
		postFleet(t, h, "worker_answer", map[string]any{"worker_id": wid, "answer": good, "idempotency_key": fmt.Sprintf("ok-%d", i)}, 200)
	}
	before := m4.count()
	for _, bad := range []any{"yes; rm -rf /", "", "0", "y", "1,,2", "YES", 2, true, "1 2 3 4 5 6 7 8 9"} {
		postFleet(t, h, "worker_answer", map[string]any{"worker_id": wid, "answer": bad, "idempotency_key": "bad"}, 400)
	}
	postFleet(t, h, "worker_answer", map[string]any{"worker_id": wid, "idempotency_key": "no-answer"}, 400)
	postFleet(t, h, "worker_answer", map[string]any{"worker_id": wid, "answer": "yes", "text": "x", "idempotency_key": "extra"}, 400)
	if m4.count() != before {
		t.Fatalf("a refused answer reached the node (%d → %d writes)", before, m4.count())
	}

	// A reap: worker_id only.
	op = postFleet(t, h, "worker_reap", map[string]any{"worker_id": wid, "idempotency_key": "r1"}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("worker_reap = %v; want accepted", op)
	}
	waitFor(t, 2*time.Second, "the node took the reap", func() bool { return m4.count() == before+1 })
	env = m4.writes[len(m4.writes)-1]
	params, _ = env["params"].(map[string]any)
	if env["action"] != "worker_reap" || params["worker_id"] != wid || len(params) != 1 {
		t.Fatalf("the node was sent %v", env)
	}
	postFleet(t, h, "worker_reap", map[string]any{"worker_id": wid, "answer": "yes", "idempotency_key": "r2"}, 400)
	postFleet(t, h, "worker_reap", map[string]any{"worker_id": "issue-2", "idempotency_key": "r3"}, 400)

	// Each tool needs its own scope: a person granted the others is refused;
	// the default person grant holds both (their own workers are theirs to
	// answer and reap); another person's worker is NOT_FOUND.
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
	h.srv.FleetPersonScopes = []string{"fleet:read", "worker:stop", "worker:resume", "worker:message"}
	for _, tool := range []string{"worker_answer", "worker_reap"} {
		args := map[string]any{"worker_id": wid, "idempotency_key": "p-" + tool}
		if tool == "worker_answer" {
			args["answer"] = "no"
		}
		if _, err := h.srv.SubmitWrite(context.Background(), as("wx-verk"), tool, args); errorObject(err)["code"] != "FORBIDDEN" {
			t.Fatalf("%s without its scope: %v; want FORBIDDEN", tool, err)
		}
	}
	h.srv.FleetPersonScopes = nil
	n := m4.count()
	if _, err := h.srv.SubmitWrite(context.Background(), as("wx-someone"), "worker_reap", map[string]any{"worker_id": wid, "idempotency_key": "p-other"}); errorObject(err)["code"] != "NOT_FOUND" {
		t.Fatalf("reap of someone else's worker: %v; want NOT_FOUND", err)
	}
	if m4.count() != n {
		t.Fatal("a refused person call reached the node")
	}
	op, err = h.srv.SubmitWrite(context.Background(), as("wx-verk"), "worker_answer", map[string]any{"worker_id": wid, "answer": "no", "idempotency_key": "p-own"})
	if err != nil || op["status"] != "accepted" {
		t.Fatalf("own answer with the default grant: %v %v", op, err)
	}
	waitFor(t, 2*time.Second, "the person's answer reached the node", func() bool { return m4.count() == n+1 })
	if m4.writes[len(m4.writes)-1]["actor"] != "wx-verk" {
		t.Fatalf("the journal actor = %v; want the person", m4.writes[len(m4.writes)-1]["actor"])
	}
}

// A write by connection certificate (claude-fleet#1487 ⑤): the holder acts as
// their person — on their OWN workers only, journalled under their principal —
// and the signature binds the write: another tool, other arguments, another
// namespace, a stale clock or a missing proof is refused before anything is
// sent. operation_get reads the result back through the same door; the viewer
// token still works here as the operator.
func TestFleetWriteByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	m5 := connectWriteNode(t, h, "m5")
	m4 := connectWriteNode(t, h, "m4")
	f5 := fakeFleet(t, machineA, "alice-fleet", writeRepo, "/u/alice/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "bob-fleet", writeRepo, "/u/bob/claude-fleet", 7)
	m5.beatLoad("m5", "alice", machineA, 1, 1, f5)
	m4.beatLoad("m4", "bob", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	p, _ := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", time.Now())
	h.srv.Store.AdoptAccount(p, "m5", time.Now())
	now := time.Now()
	good := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))

	signed := func(c *ssh.Certificate, ns string, ts int64, tool, signedArgs, sentArgs string) WriteRequest {
		sum := sha256.Sum256([]byte(signedArgs))
		return WriteRequest{Cert: string(ssh.MarshalAuthorizedKey(c)), TS: ts, Tool: tool, ArgsJSON: sentArgs,
			Sig: sshsig(t, k.user, ns, []byte(control.WriteSigMessage(ts, tool, hex.EncodeToString(sum[:]))))}
	}
	post := func(body any, auth string) (int, map[string]any) {
		b, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+control.WritePath, bytes.NewReader(b))
		req.Header.Set("Content-Type", "application/json")
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	// m5 answers with a finished operation, so operation_get below reads the
	// journal and never waits on a reconcile.
	m5.setAnswer(func(env map[string]any) (any, *control.Error) {
		return map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"],
			"action": env["action"], "status": "succeeded", "result": map[string]any{"answered": "yes"}}, nil
	})
	mine := `{"worker_id":"` + f5.FleetID + `/issue-1","answer":"yes","idempotency_key":"c1"}`
	bobs := `{"worker_id":"` + f4.FleetID + `/issue-7","idempotency_key":"c2"}`

	// Her own worker: accepted, journalled as her, m5 got it with her actor.
	code, out := post(signed(good, control.WriteSigNamespace, now.Unix(), "worker_answer", mine, mine), "")
	if code != 200 || out["status"] != "succeeded" {
		t.Fatalf("alice answers her worker: HTTP %d %v", code, out)
	}
	waitFor(t, 2*time.Second, "m5 took the write", func() bool { return m5.count() == 1 })
	if m5.writes[0]["actor"] != "wx-alice" || m5.writes[0]["action"] != "worker_answer" {
		t.Fatalf("m5 was sent %v", m5.writes[0])
	}
	// …and reads it back through the same door.
	get := `{"operation_id":"` + out["operation_id"].(string) + `"}`
	if code, got := post(signed(good, control.WriteSigNamespace, now.Unix(), "operation_get", get, get), ""); code != 200 || got["operation_id"] != out["operation_id"] {
		t.Fatalf("operation_get by certificate: HTTP %d %v", code, got)
	}
	// Bob's worker is not hers: NOT_FOUND, and m4 never hears of it.
	if code, got := post(signed(good, control.WriteSigNamespace, now.Unix(), "worker_reap", bobs, bobs), ""); code != 404 {
		t.Fatalf("alice reaps bob's worker: HTTP %d %v; want 404", code, got)
	}
	// The proof must be THIS write's.
	tampered := `{"worker_id":"` + f5.FleetID + `/issue-1","answer":"no","idempotency_key":"c1"}`
	for name, req := range map[string]WriteRequest{
		"other args": signed(good, control.WriteSigNamespace, now.Unix(), "worker_answer", mine, tampered),
		"other tool": func() WriteRequest {
			r := signed(good, control.WriteSigNamespace, now.Unix(), "worker_answer", mine, mine)
			r.Tool = "worker_reap"
			return r
		}(),
		"sessions namespace": signed(good, control.SessionsSigNamespace, now.Unix(), "worker_answer", mine, mine),
		"stale timestamp":    signed(good, control.WriteSigNamespace, now.Add(-10*time.Minute).Unix(), "worker_answer", mine, mine),
		"expired cert":       signed(k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-13*time.Hour), now.Add(-time.Hour)), control.WriteSigNamespace, now.Unix(), "worker_answer", mine, mine),
		"no signature":       {Cert: string(ssh.MarshalAuthorizedKey(good)), TS: now.Unix(), Tool: "worker_answer", ArgsJSON: mine},
	} {
		if code, got := post(req, ""); code != 401 {
			t.Fatalf("%s: HTTP %d %v; want 401", name, code, got)
		}
	}
	// Only writes (and operation_get) pass this door; a read is not a write.
	if code, _ := post(signed(good, control.WriteSigNamespace, now.Unix(), "fleet_list", `{}`, `{}`), ""); code != 400 {
		t.Fatalf("fleet_list through the write door: HTTP %d; want 400", code)
	}
	if m4.count() != 0 || m5.count() != 1 {
		t.Fatalf("a refused signed write reached a node (m5=%d m4=%d)", m5.count(), m4.count())
	}
	// The operator's token through the same door sees every login.
	if code, got := post(WriteRequest{Tool: "worker_reap", ArgsJSON: bobs}, viewerToken); code != 200 || got["status"] != "accepted" {
		t.Fatalf("operator reaps bob's worker through the write door: HTTP %d %v", code, got)
	}
	waitFor(t, 2*time.Second, "m4 took the operator's reap", func() bool { return m4.count() == 1 })
	if m4.writes[0]["actor"] != "operator" {
		t.Fatalf("the operator's write was journalled as %v", m4.writes[0]["actor"])
	}
	// GET is not a door.
	resp, err := http.Get(h.http.URL + control.WritePath)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET %s: HTTP %d", control.WritePath, resp.StatusCode)
	}
}

// worker_rename (claude-fleet#2358): the sidebar's 「改名…」 on a row on another
// machine. A journalled write under worker:message's authority; the node gets
// worker_id and the name — nothing else, and no name with a control character.
func TestFleetWriteRename(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	wid := f4.FleetID + "/issue-2"
	if !hasString(FleetTools, "worker_rename") || !fleetWriteTools["worker_rename"] || fleetScopeOf["worker_rename"] != "worker:message" {
		t.Fatal("worker_rename must be a listed write tool under worker:message")
	}
	op := postFleet(t, h, "worker_rename", map[string]any{"worker_id": wid, "name": "登录页 · 重做", "idempotency_key": "r1"}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("worker_rename = %v; want accepted", op)
	}
	waitFor(t, 2*time.Second, "the node took the rename", func() bool { return m4.count() == 1 })
	env := m4.writes[0]
	params, _ := env["params"].(map[string]any)
	if env["action"] != "worker_rename" || params["worker_id"] != wid || params["name"] != "登录页 · 重做" || len(params) != 2 {
		t.Fatalf("the node was sent %v", env)
	}
	for i, bad := range []any{"", "   ", "a\tb", "a\nb", strings.Repeat("x", 65), 3, nil} {
		postFleet(t, h, "worker_rename", map[string]any{"worker_id": wid, "name": bad, "idempotency_key": fmt.Sprintf("bad-%d", i)}, 400)
	}
	postFleet(t, h, "worker_rename", map[string]any{"worker_id": wid, "idempotency_key": "no-name"}, 400)
	postFleet(t, h, "worker_rename", map[string]any{"worker_id": wid, "name": "x", "text": "x", "idempotency_key": "extra"}, 400)
	if m4.count() != 1 {
		t.Fatalf("a refused rename reached the node (%d writes)", m4.count())
	}
}

// worker_reap_policy (claude-fleet#2368): the sidebar's 「改回收方式…」 on a row
// on another machine. A journalled write under worker:reap's authority; the node
// gets worker_id and the policy — fleet_reap_policy.py's grammar, nothing else.
func TestFleetWriteReapPolicyTool(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	wid := f4.FleetID + "/issue-2"
	if !hasString(FleetTools, "worker_reap_policy") || !fleetWriteTools["worker_reap_policy"] || fleetScopeOf["worker_reap_policy"] != "worker:reap" {
		t.Fatal("worker_reap_policy must be a listed write tool under worker:reap")
	}
	good := []string{"merged", "merged:30m", "done", "done:2h", "loop-end", "keep",
		"at:2026-10-06T18:00:00Z", "at:2026-10-06T18:00+08:00", "at:18:00", "at:1791000000", "done:366d"}
	for i, p := range good {
		op := postFleet(t, h, "worker_reap_policy", map[string]any{"worker_id": wid, "policy": p, "idempotency_key": fmt.Sprintf("ok-%d", i)}, 200)
		if op["status"] != "accepted" {
			t.Fatalf("worker_reap_policy %q = %v; want accepted", p, op)
		}
	}
	waitFor(t, 2*time.Second, "the node took every policy", func() bool { return m4.count() == len(good) })
	env := m4.writes[0]
	params, _ := env["params"].(map[string]any)
	if env["action"] != "worker_reap_policy" || params["worker_id"] != wid || params["policy"] != "merged" || len(params) != 2 {
		t.Fatalf("the node was sent %v", env)
	}
	for i, bad := range []any{"", "never", "keep:1h", "loop-end:", "merged:", "done:0", "done:2w", "done:367d",
		"at:", "at:25:00", "at:tomorrow", "done 2h", strings.Repeat("k", 49), 3, nil} {
		postFleet(t, h, "worker_reap_policy", map[string]any{"worker_id": wid, "policy": bad, "idempotency_key": fmt.Sprintf("bad-%d", i)}, 400)
	}
	postFleet(t, h, "worker_reap_policy", map[string]any{"worker_id": wid, "idempotency_key": "no-policy"}, 400)
	postFleet(t, h, "worker_reap_policy", map[string]any{"worker_id": wid, "policy": "keep", "name": "x", "idempotency_key": "extra"}, 400)
	if m4.count() != len(good) {
		t.Fatalf("a refused policy reached the node (%d writes)", m4.count())
	}
}

// worker_switch (claude-fleet#2102): the sidebar's 「换到可用订阅」 on a row on
// another machine. A journalled write under worker:stop's authority (a switch is
// a stop + resume of the same conversation); the node gets worker_id and, when
// named, the account label — nothing else, and no label that is not one argv word.
func TestFleetWriteSwitch(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	wid := f4.FleetID + "/issue-2"
	if !hasString(FleetTools, "worker_switch") || !fleetWriteTools["worker_switch"] || fleetScopeOf["worker_switch"] != "worker:stop" {
		t.Fatal("worker_switch must be a listed write tool under worker:stop")
	}
	op := postFleet(t, h, "worker_switch", map[string]any{"worker_id": wid, "idempotency_key": "s1"}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("worker_switch = %v; want accepted", op)
	}
	waitFor(t, 2*time.Second, "the node took the switch", func() bool { return m4.count() == 1 })
	env := m4.writes[0]
	params, _ := env["params"].(map[string]any)
	if env["action"] != "worker_switch" || params["worker_id"] != wid || len(params) != 1 {
		t.Fatalf("the node was sent %v", env)
	}
	postFleet(t, h, "worker_switch", map[string]any{"worker_id": wid, "account": "gmail", "idempotency_key": "s2"}, 200)
	waitFor(t, 2*time.Second, "the node took the named switch", func() bool { return m4.count() == 2 })
	params, _ = m4.writes[1]["params"].(map[string]any)
	if params["account"] != "gmail" || len(params) != 2 {
		t.Fatalf("the node was sent %v", m4.writes[1])
	}
	for i, bad := range []any{"", "a b", "x;rm", "../x", 3, true} {
		postFleet(t, h, "worker_switch", map[string]any{"worker_id": wid, "account": bad, "idempotency_key": fmt.Sprintf("bad-%d", i)}, 400)
	}
	postFleet(t, h, "worker_switch", map[string]any{"worker_id": wid, "text": "x", "idempotency_key": "extra"}, 400)
	if m4.count() != 2 {
		t.Fatalf("a refused switch reached the node (%d writes)", m4.count())
	}
}

// orch_ensure (claude-fleet#2616): ⌘N on a client found no orchestrating
// session. A journalled write under worker:start's authority; with no fleet_id
// the hub sends it to the holder machine's fleet (fleet.orchestrator_host.<owner>),
// else the online fleet with the most sessions, then by name — and the node is
// sent no params at all.
func TestFleetWriteOrchEnsure(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	if !hasString(FleetTools, "orch_ensure") || !fleetWriteTools["orch_ensure"] || fleetScopeOf["orch_ensure"] != "worker:start" {
		t.Fatal("orch_ensure must be a listed write tool under worker:start")
	}
	// No holder yet, one session each: by name — m4.
	op := postFleet(t, h, "orch_ensure", map[string]any{"idempotency_key": "o1"}, 200)
	if op["status"] != "accepted" || op["fleet_id"] != f4.FleetID {
		t.Fatalf("orch_ensure = %v; want accepted on m4's fleet %s", op, f4.FleetID)
	}
	waitFor(t, 2*time.Second, "m4 took it", func() bool { return m4.count() == 1 })
	env := m4.writes[0]
	if params, _ := env["params"].(map[string]any); env["action"] != "orch_ensure" || len(params) != 0 {
		t.Fatalf("the node was sent %v", env)
	}
	// The holder wins over the name.
	if err := h.srv.Store.SetFleetSetting(OrchestratorHostPrefix+"login:verk", "m5", time.Now()); err != nil {
		t.Fatal(err)
	}
	op = postFleet(t, h, "orch_ensure", map[string]any{"idempotency_key": "o2"}, 200)
	if op["fleet_id"] != f5.FleetID {
		t.Fatalf("orch_ensure with m5 holding = %v; want m5's fleet %s", op, f5.FleetID)
	}
	waitFor(t, 2*time.Second, "m5 took it", func() bool { return m5.count() == 1 })
	// A named fleet is that fleet; anything else never reaches a node.
	if op = postFleet(t, h, "orch_ensure", map[string]any{"fleet_id": f4.FleetID, "idempotency_key": "o3"}, 200); op["fleet_id"] != f4.FleetID {
		t.Fatalf("orch_ensure(fleet_id=m4) = %v", op)
	}
	postFleet(t, h, "orch_ensure", map[string]any{"session": "x", "idempotency_key": "bad"}, 400)
	postFleet(t, h, "orch_ensure", map[string]any{}, 400)
}
