package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"reflect"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"net/http"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func continueFixture(t *testing.T) (*harness, *writeNode, store.FleetTask, store.TaskExecutionSnapshot, string) {
	t.Helper()
	h, _, task, snapshot := sessionExitFixture(t)
	st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/execution/exit", sessionExitBody(snapshot))
	if st != 200 {
		t.Fatalf("exit: %d %v", st, out)
	}
	node := connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution, control.CapTaskContinuation)
	waitFor(t, 3*time.Second, "continuation connection", func() bool { return h.srv.canTaskContinuation(context.Background(), snapshot.ExecutionEndpoint) })
	return h, node, task, snapshot, out["operation"].(map[string]any)["operation_id"].(string)
}

func continueBody(snapshot store.TaskExecutionSnapshot, key string) map[string]any {
	return map[string]any{"idempotency_key": key, "expected_stop_operation_id": snapshot.CancelRequest, "expected_generation": snapshot.Generation}
}

func TestTaskContinueAPIHappyAndReplay(t *testing.T) {
	h, node, task, snapshot, exitID := continueFixture(t)
	body := continueBody(snapshot, "continue-one")
	body["agent"] = "claude"
	out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	if out["agent"] != "claude" || out["exit_operation_id"] != exitID || out["authorized_generation"] != float64(snapshot.Generation+1) {
		t.Fatalf("continuation: %v", out)
	}
	again := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	if again["operation"].(map[string]any)["operation_id"] != out["operation"].(map[string]any)["operation_id"] || node.count() != 1 {
		t.Fatalf("replay: %v writes=%d", again, node.count())
	}
}

func TestTaskContinueAPIImmutableProviderAndCurrentStart(t *testing.T) {
	h, node, task, snapshot, exitID := continueFixture(t)
	before, _ := h.srv.Store.FleetTask(task.ID)
	body := continueBody(snapshot, "change-provider")
	body["agent"] = "claude"
	out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	got, _ := h.srv.Store.FleetTask(task.ID)
	if got.RequestPayload != before.RequestPayload || got.ResolvedAgent != before.ResolvedAgent || got.RequestedAgent != before.RequestedAgent || got.Title != before.Title || got.FID != before.FID {
		t.Fatal("initial acceptance changed")
	}
	node.mu.Lock()
	env := node.writes[0]
	node.mu.Unlock()
	continuation := env["params"].(map[string]any)["continuation"].(map[string]any)
	if len(continuation) != 2 || continuation["version"] != float64(1) || continuation["exit_operation_id"] != exitID || env["continuation_intent"] != nil {
		t.Fatalf("node metadata: %v", env)
	}
	for _, path := range []string{"execution", "execution/start"} {
		status, view := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/"+path, nil)
		if status != 200 {
			t.Fatalf("%s: %d %v", path, status, view)
		}
		if path == "execution" {
			if len(view) != 9 || view["agent"] != nil || view["operation_id"] != got.OperationID {
				t.Fatalf("snapshot schema changed: %v", view)
			}
		} else {
			start := view["start"].(map[string]any)
			if start["agent"] != "claude" || start["operation_id"] != got.OperationID || view["task_execution"].(map[string]any)["operation_id"] != got.OperationID {
				t.Fatalf("current provider: %v", view)
			}
		}
	}
	if st, v := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/execution/start", nil); st != 404 {
		t.Fatalf("sibling metadata: %d %v", st, v)
	}
	// Existing receipt retry remains a historical answer; a fresh key with an
	// old proof cannot clear this new authorization.
	st, proof := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/execution/exit", sessionExitBody(snapshot))
	if st != 200 || proof["operation"].(map[string]any)["operation_id"] != exitID {
		t.Fatalf("old receipt replay: %d %v", st, proof)
	}
	old := sessionExitBody(snapshot)
	old["idempotency_key"] = "late-old-proof"
	if st, v := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/execution/exit", old); st != 409 {
		t.Fatalf("old proof: %d %v", st, v)
	}
	postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": "native-stop"}, 409)
	fresh, _ := h.srv.Store.FleetTask(task.ID)
	if fresh.OperationID != got.OperationID || fresh.CancelRequest != "" || fresh.Generation != got.Generation {
		t.Fatal("old stop/exit changed new binding")
	}
	// Same request still returns the immutable start after a subsequent stop.
	postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": "second-stop"}, 202)
	again := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	if again["operation"].(map[string]any)["operation_id"] != out["operation"].(map[string]any)["operation_id"] || again["task_execution"] != nil {
		t.Fatalf("historical replay changed meaning: %v", again)
	}
}

func TestTaskContinueAPIExactIdempotency(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprint(explicit), func(t *testing.T) {
			h, node, task, snapshot, _ := continueFixture(t)
			body := continueBody(snapshot, "precise-key")
			if explicit {
				body["agent"] = "codex"
			}
			out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
			if out["agent"] != "codex" {
				t.Fatal("omission did not retain previous provider")
			}
			for _, change := range []string{"agent", "omission", "stop", "generation"} {
				changed := map[string]any{}
				for k, v := range body {
					changed[k] = v
				}
				switch change {
				case "agent":
					changed["agent"] = "claude"
				case "omission":
					if explicit {
						delete(changed, "agent")
					} else {
						changed["agent"] = "codex"
					}
				case "stop":
					changed["expected_stop_operation_id"] = "different-stop"
				case "generation":
					changed["expected_generation"] = snapshot.Generation + 2
				}
				postFleet(t, h, "tasks/"+task.Ref+"/continue", changed, 409)
			}
			another, e := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: task.Owner, Title: "other", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "other-task", time.Now())
			if e != nil {
				t.Fatal(e)
			}
			postFleet(t, h, "tasks/"+another.Ref+"/continue", body, 409)
			if node.count() != 1 {
				t.Fatal("changed key dispatched")
			}
		})
	}
}

func TestTaskContinueAPIRequiresProofAndExpectedBinding(t *testing.T) {
	t.Run("stop alone", func(t *testing.T) {
		h, node, task, snapshot := sessionExitFixture(t)
		before := node.count()
		postFleet(t, h, "tasks/"+task.Ref+"/continue", continueBody(snapshot, "too-early"), 409)
		if node.count() != before {
			t.Fatal("unconfirmed exit dispatched")
		}
	})
	for _, change := range []string{"wrong-stop", "old-generation", "outcome"} {
		t.Run(change, func(t *testing.T) {
			h, node, task, snapshot, _ := continueFixture(t)
			body := continueBody(snapshot, "invalid-binding")
			switch change {
			case "wrong-stop":
				body["expected_stop_operation_id"] = "native-stop-alias"
			case "old-generation":
				body["expected_generation"] = snapshot.Generation + 1
			case "outcome":
				if _, err := h.srv.Store.DB().Exec("UPDATE fleet_tasks SET outcome='done' WHERE id=?", task.ID); err != nil {
					t.Fatal(err)
				}
			}
			postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 409)
			if node.count() != 0 {
				t.Fatal("invalid binding dispatched")
			}
		})
	}
}

func TestTaskContinueAPIConcurrentProvider(t *testing.T) {
	for _, sameKey := range []bool{false, true} {
		t.Run(fmt.Sprint(sameKey), func(t *testing.T) {
			h, node, task, snapshot, _ := continueFixture(t)
			type result struct {
				status int
				err    error
				out    map[string]any
			}
			results := make(chan result, 2)
			barrier := make(chan struct{})
			for i, agent := range []string{"claude", "codex"} {
				go func(i int, agent string) {
					key := fmt.Sprintf("race-%d", i)
					if sameKey {
						key = "same-race"
					}
					body := continueBody(snapshot, key)
					body["agent"] = agent
					raw, _ := json.Marshal(body)
					req, _ := http.NewRequest(http.MethodPost, h.http.URL+FleetTasksPath+"/"+task.Ref+"/continue", bytes.NewReader(raw))
					req.Header.Set("Authorization", "Bearer "+viewerToken)
					req.Header.Set("Content-Type", "application/json")
					<-barrier
					response, err := h.http.Client().Do(req)
					if err != nil {
						results <- result{err: err}
						return
					}
					defer response.Body.Close()
					var out map[string]any
					err = json.NewDecoder(response.Body).Decode(&out)
					results <- result{response.StatusCode, err, out}
				}(i, agent)
			}
			close(barrier)
			statuses := map[int]int{}
			for i := 0; i < 2; i++ {
				r := <-results
				if r.err != nil {
					t.Fatal(r.err)
				}
				statuses[r.status]++
				if r.status != 202 && r.status != 409 {
					t.Fatalf("race: %d %v", r.status, r.out)
				}
			}
			if statuses[202] != 1 || statuses[409] != 1 || node.count() != 1 {
				t.Fatalf("race statuses=%v writes=%d", statuses, node.count())
			}
		})
	}
}

func TestTaskContinueAPICapabilityDisconnectAndSendGate(t *testing.T) {
	for _, mode := range []string{"old-node", "offline"} {
		t.Run(mode, func(t *testing.T) {
			h, node, task, snapshot, _ := continueFixture(t)
			before, _ := h.srv.Store.FleetTask(task.ID)
			if mode == "old-node" {
				connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution)
				waitFor(t, 3*time.Second, "old connection", func() bool {
					c := h.srv.nodes.get(snapshot.ExecutionEndpoint)
					return c != nil && !c.canTaskContinuation
				})
			} else {
				node.conn.CloseNow()
				waitFor(t, 3*time.Second, "node disconnect", func() bool { return h.srv.nodes.get(snapshot.ExecutionEndpoint) == nil })
			}
			body := continueBody(snapshot, "retry-when-ready")
			postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 503)
			after, _ := h.srv.Store.FleetTask(task.ID)
			if !reflect.DeepEqual(before, after) || node.count() != 0 {
				t.Fatal("unavailable node reserved or dispatched")
			}
			replacement := connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution, control.CapTaskContinuation)
			waitFor(t, 3*time.Second, "new connection", func() bool { return h.srv.canTaskContinuation(context.Background(), snapshot.ExecutionEndpoint) })
			postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
			if replacement.count() != 1 {
				t.Fatal("key was consumed before availability")
			}
		})
	}
	t.Run("replacement after authorization", func(t *testing.T) {
		h, _, task, snapshot, _ := continueFixture(t)
		source, e := h.srv.Store.TaskContinuationSource(task.ID, task.Owner)
		if e != nil {
			t.Fatal(e)
		}
		target, e := h.srv.Store.Fleet(source.Start.FleetID)
		if e != nil {
			t.Fatal(e)
		}
		intent := store.TaskContinuationIntent{Task: task.Ref, ExpectedStopOperationID: snapshot.CancelRequest, ExpectedGeneration: snapshot.Generation}
		params, request, e := continuationStart(source, "send-gate", "codex", intent, target)
		if e != nil {
			t.Fatal(e)
		}
		now := time.Now()
		op := store.FleetOperation{ID: newOperationID(), FleetID: target.FleetID, Action: "worker_start", Request: request, Actor: task.Owner, TaskOwner: task.Owner, Idem: "send-gate", Status: "pending", Created: now, Updated: now}
		if _, e := h.srv.Store.ContinueTaskExecution(op, target.EndpointID); e != nil {
			t.Fatal(e)
		}
		old := connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution)
		waitFor(t, 3*time.Second, "old final connection", func() bool {
			c := h.srv.nodes.get(snapshot.ExecutionEndpoint)
			return c != nil && !c.canTaskContinuation
		})
		status, result := h.srv.sendWrite(context.Background(), target, op, map[string]any{"operation_id": op.ID, "params": params})
		if status != "failed" || !strings.Contains(result, "continuation") || old.count() != 0 {
			t.Fatalf("final capability gate: %s %s writes=%d", status, result, old.count())
		}
	})
}

func TestTaskContinueAPIAuthAndStrictBody(t *testing.T) {
	s := &Server{Store: openTestStore(t), LiveStore: NewLive(), ViewerToken: viewerToken, Fleet: true}
	if e := s.Store.EnsureNodes(); e != nil {
		t.Fatal(e)
	}
	enablePeople(t, &harness{srv: s}, pAlice, pBob, pCarol)
	task, e := s.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "owned", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "owned", time.Now())
	if e != nil {
		t.Fatal(e)
	}
	valid := `{"idempotency_key":"continue","expected_stop_operation_id":"stop","expected_generation":2}`
	call := func(cookie *http.Cookie, body, method, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://fleet.test"+FleetTasksPath+"/"+task.Ref+"/continue", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Accept", "application/json")
		r.Header.Set("Origin", "http://fleet.test")
		if cookie != nil {
			r.AddCookie(cookie)
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		return w
	}
	owner := personCookie(pAlice, "alice")
	for _, tc := range []struct {
		name   string
		cookie *http.Cookie
		token  string
		want   int
	}{
		{"anonymous", nil, "", 401}, {"other", personCookie(pBob, "bob"), "", 404}, {"operator-other-task", nil, viewerToken, 404},
		{"read-only", &http.Cookie{Name: authz.CookieName, Value: authz.SignReadOnly(store.IdentityGitHub, pAlice, "alice", roleUser, s.sessionKey(), time.Now(), time.Hour)}, "", 403},
	} {
		w := call(tc.cookie, valid, http.MethodPost, tc.token)
		if w.Code != tc.want {
			t.Fatalf("%s: %d %s", tc.name, w.Code, w.Body.String())
		}
	}
	for _, body := range []string{"null", "{}", valid + " {}", strings.Replace(valid, `"stop"`, `"stop","worktree":"/tmp/spoof"`, 1), strings.Replace(valid, `"stop"`, `"stop","agent":"auto"`, 1)} {
		if w := call(owner, body, http.MethodPost, ""); w.Code != 400 {
			t.Fatalf("strict %q: %d %s", body, w.Code, w.Body.String())
		}
	}
	if w := call(owner, valid, http.MethodGet, ""); w.Code != 405 {
		t.Fatalf("GET: %d", w.Code)
	}
	if w := call(owner, valid, http.MethodPost, ""); w.Code != 409 {
		t.Fatalf("own unproved: %d %s", w.Code, w.Body.String())
	}
	s.FleetPersonScopes = []string{"fleet:read"}
	if w := call(owner, valid, http.MethodPost, ""); w.Code != 403 {
		t.Fatalf("missing start grant: %d", w.Code)
	}
	r := httptest.NewRequest(http.MethodPost, "/continue", strings.NewReader(valid))
	w := httptest.NewRecorder()
	s.continueFleetTask(w, r, fleetPrincipal{Actor: pAlice, Worker: &workerClaims{}}, task.Ref)
	if w.Code != 403 {
		t.Fatalf("worker continuation: %d", w.Code)
	}
}

func TestTaskContinueAPISameRequestConcurrentReplay(t *testing.T) {
	h, node, task, snapshot, _ := continueFixture(t)
	body := continueBody(snapshot, "shared-request")
	raw, _ := json.Marshal(body)
	start := make(chan struct{})
	done := make(chan int, 8)
	for i := 0; i < 8; i++ {
		go func() {
			req, _ := http.NewRequest(http.MethodPost, h.http.URL+FleetTasksPath+"/"+task.Ref+"/continue", bytes.NewReader(raw))
			req.Header.Set("Authorization", "Bearer "+viewerToken)
			req.Header.Set("Content-Type", "application/json")
			<-start
			response, e := h.http.Client().Do(req)
			if e != nil {
				done <- 0
				return
			}
			defer response.Body.Close()
			done <- response.StatusCode
		}()
	}
	close(start)
	for i := 0; i < 8; i++ {
		if status := <-done; status != 202 {
			t.Fatalf("same request raced: %d", status)
		}
	}
	if node.count() != 1 {
		t.Fatalf("same request created %d writes", node.count())
	}
}

func TestTaskContinueAPIRepeatedCycleKeepsLatestProvider(t *testing.T) {
	h, node, task, snapshot, _ := continueFixture(t)
	first := continueBody(snapshot, "first-claude")
	first["agent"] = "claude"
	postFleet(t, h, "tasks/"+task.Ref+"/continue", first, 202)
	got, _ := h.srv.Store.FleetTask(task.ID)
	op, _ := h.srv.Store.FleetOperation(got.OperationID)
	claim := map[string]any{"control_version": 1, "operation_id": op.ID, "worker_id": op.FleetID + "/44444444-4444-4444-8444-444444444444", "generation": got.Generation, "attempt_id": got.AttemptID}
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/execution/claim", claim); st != 200 {
		t.Fatalf("claim: %d %v", st, out)
	}
	postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": "stop-second"}, 202)
	secondStop, e := h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if e != nil {
		t.Fatal(e)
	}
	body := sessionExitBody(secondStop)
	body["idempotency_key"] = "second-exit"
	proof := body["proof"].(map[string]any)
	proof["provider"] = "claude"
	proof["launch_id"] = "launch-2"
	proof["launches"] = []map[string]any{{"launch_id": "launch-2", "roots": []map[string]any{
		{"component": "supervisor", "pid": 72001, "birth": "kernel-1", "evidence": "pid_absent"},
		{"component": "child", "pid": 72002, "birth": "kernel-2", "evidence": "pid_absent"},
		{"component": "agent", "pid": 72003, "birth": "kernel-3", "evidence": "pid_absent"},
	}}}
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/execution/exit", body); st != 200 {
		t.Fatalf("second proof: %d %v", st, out)
	}
	before := node.count()
	omitted := continueBody(secondStop, "same-provider")
	out := postFleet(t, h, "tasks/"+task.Ref+"/continue", omitted, 202)
	if out["agent"] != "claude" || node.count() != before+1 {
		t.Fatalf("default reverted to initial Task provider: %v", out)
	}
	status, metadata := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/execution/start", nil)
	if status != 200 {
		t.Fatalf("second source: %d %v", status, metadata)
	}
	source := metadata["source_start"].(map[string]any)
	if len(source) != 4 || source["operation_id"] != op.ID || source["agent"] != "claude" || source["continuation"] != nil {
		t.Fatalf("second source reverted to initial start or forwarded old instructions: %v", source)
	}
	// A previous-cycle intent with a fresh key is never authority for this one.
	stale := continueBody(snapshot, "old-source-new-key")
	postFleet(t, h, "tasks/"+task.Ref+"/continue", stale, 409)
	// Original-key replay still names its own generation/provider after 2 cycles.
	replay := postFleet(t, h, "tasks/"+task.Ref+"/continue", first, 202)
	if replay["authorized_generation"] != float64(snapshot.Generation+1) || replay["agent"] != "claude" || node.count() != before+1 {
		t.Fatalf("old replay: %v", replay)
	}
}

func TestTaskContinueAPIUnknownNeverRedispatches(t *testing.T) {
	h, node, task, snapshot, _ := continueFixture(t)
	priorWait := fleetWriteWait
	fleetWriteWait = 100 * time.Millisecond
	t.Cleanup(func() { fleetWriteWait = priorWait })
	node.setAnswer(func(map[string]any) (any, *control.Error) { node.conn.CloseNow(); return nil, nil })
	body := continueBody(snapshot, "lost-ack")
	out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	operation := out["operation"].(map[string]any)
	if operation["status"] != "unknown" {
		t.Fatalf("lost ack advertised definite result: %v", out)
	}
	again := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	if again["operation"].(map[string]any)["operation_id"] != operation["operation_id"] || node.count() != 1 {
		t.Fatalf("unknown was redispatched: %v", again)
	}
	current, _ := h.srv.Store.FleetTask(task.ID)
	if current.ExecutionEndpoint == "" || current.OperationID != operation["operation_id"] {
		t.Fatal("unknown released execution authority")
	}
}

func TestTaskContinuePeerCapabilityGate(t *testing.T) {
	a, b := newReplicaPair(t)
	node := connectWriteNodeCaps(t, b, b.enroll(t, "mac-c"), control.CapRead, control.CapWrite, control.CapTaskExecution)
	fleet := fakeFleet(t, machineB, "fleet-mac-c", writeRepo, "/u/frank/claude-fleet", 2)
	node.beatLoad("mac-c", "frank", machineB, 1, 1, fleet)
	waitFor(t, 3*time.Second, "peer registered", func() bool {
		_, e := a.srv.Store.Fleet(fleet.FleetID)
		return e == nil && holder(t, a, "ep_mac-c") == "hub-b"
	})
	target, e := a.srv.Store.Fleet(fleet.FleetID)
	if e != nil {
		t.Fatal(e)
	}
	if a.srv.canTaskContinuation(context.Background(), target.EndpointID) {
		t.Fatal("peer's task_execution advertised continuation")
	}
	op := store.FleetOperation{ID: newOperationID(), FleetID: fleet.FleetID, Action: "worker_start", Request: `{"control_version":1,"params":{"continuation":{"version":1,"exit_operation_id":"exit"}}}`}
	status, result := a.srv.sendWrite(context.Background(), target, op, map[string]any{"operation_id": op.ID, "action": op.Action})
	if status != "failed" || !strings.Contains(result, "continuation") || node.count() != 0 {
		t.Fatalf("peer gate: %s %s writes=%d", status, result, node.count())
	}
}

func TestTaskContinueAPILocalSourceWithoutNodeJournal(t *testing.T) {
	h, _, node, _, fleet := twoNodesCaps(t, control.CapTaskExecution, control.CapTaskContinuation)
	input := map[string]any{"kind": "scratch", "repo": writeRepo, "fleet_id": fleet.FleetID, "node": "mac-c", "idempotency_key": "local-source", "coding_agent": "codex", "control_version": 1, "local_dispatch": true}
	status, out := placeCall(t, h, h.tokens["mac-c"], input)
	if status != 200 || out["local"] != true || node.count() != 0 {
		t.Fatalf("LOCAL start: %d %v writes=%d", status, out, node.count())
	}
	var initial store.TaskExecutionSnapshot
	raw, _ := json.Marshal(out["task_execution"])
	if e := json.Unmarshal(raw, &initial); e != nil {
		t.Fatal(e)
	}
	path := NodeTasksPath + "/" + initial.TaskRef
	status, metadata := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, path+"/execution/start", nil)
	if status != 200 || metadata["source_start"] != nil {
		t.Fatalf("initial metadata: %d %v", status, metadata)
	}
	claim := map[string]any{"control_version": 1, "operation_id": initial.OperationID, "worker_id": fleet.FleetID + "/" + wrFid, "generation": initial.Generation, "attempt_id": initial.AttemptID}
	if st, v := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path+"/execution/claim", claim); st != 200 {
		t.Fatalf("LOCAL claim: %d %v", st, v)
	}
	postFleet(t, h, "tasks/"+initial.TaskRef+"/stop", map[string]any{"idempotency_key": "local-stop"}, 202)
	task, e := h.srv.Store.FleetTask(store.ParseTaskRef(initial.TaskRef))
	if e != nil {
		t.Fatal(e)
	}
	stopped, e := h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if e != nil {
		t.Fatal(e)
	}
	if st, v := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path+"/execution/exit", sessionExitBody(stopped)); st != 200 {
		t.Fatalf("LOCAL proof: %d %v", st, v)
	}
	body := continueBody(stopped, "continue-local")
	body["agent"] = "claude"
	postFleet(t, h, "tasks/"+initial.TaskRef+"/continue", body, 202)
	status, metadata = nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, path+"/execution/start", nil)
	if status != 200 {
		t.Fatalf("continued metadata: %d %v", status, metadata)
	}
	source := metadata["source_start"].(map[string]any)
	if len(source) != 4 || source["operation_id"] != initial.OperationID || source["agent"] != "codex" || source["repo"] != writeRepo || source["no_repo"] != false {
		t.Fatalf("source not original immutable start: %v", source)
	}
	if metadata["start"].(map[string]any)["agent"] != "claude" {
		t.Fatal("source provider replaced current provider")
	}
	node.mu.Lock()
	defer node.mu.Unlock()
	for _, write := range node.writes {
		if write["operation_id"] == initial.OperationID {
			t.Fatal("test incorrectly populated a node journal for the LOCAL start")
		}
	}
}
