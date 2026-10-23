package api

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Lazy skip by default. DRY_RUN uses isolated configuration and real Control
// inventory, with no native processes, credentials or model requests.
// The websocket test peer transports real business messages to Control; it
// is not the production connector and proves no production reconnect SLO.
func TestTaskCycleNativeOptIn(t *testing.T) {
	live := os.Getenv("FLEET_NATIVE_TASK_CYCLE") == "1"
	dry := os.Getenv("FLEET_NATIVE_TASK_CYCLE_DRY_RUN") == "1"
	if !live && !dry {
		t.Skip("opt-in native acceptance; no credentials inspected")
	}
	if live && dry {
		t.Fatal("choose live or dry-run, never both")
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Fatal(err)
	}
	helper, _ := filepath.Abs("testdata/task_cycle_native.py")
	bin, _ := filepath.Abs("../../../bin")
	if dry {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, python, helper, "--dry-run").CombinedOutput()
		if err != nil {
			t.Fatalf("structural dry-run: %v %s", err, out)
		}
		var facts map[string]any
		if json.Unmarshal(out, &facts) != nil || facts["model_requests"] != float64(0) || facts["tmux_started"] != false || facts["credentials_minted"] != false || facts["real_control_inventory"] != true {
			t.Fatal("dry-run boundaries not proven")
		}
		nativeCycleOwnerSandbox(t)
		t.Log("dry-run: real Control inventory and owner HTTP auth; zero tmux/native starts, credentials or model requests")
		return
	}
	root, err := os.MkdirTemp("", "t970-native-cycle-")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	t.Logf("private acceptance evidence/workspace: %s", root)
	h := newFleetHarness(t)
	owner := fmt.Sprintf("gh:%d", time.Now().UnixNano())
	enablePeople(t, h, owner)
	h.srv.GitHub.ClientSecret = nativeCycleRandom(t)
	mapLogins(t, h.srv, map[string]string{owner: "acceptance"})
	cookie := &http.Cookie{Name: authz.CookieName, Value: authz.SignRole(store.IdentityGitHub, owner, "native acceptance", roleUser, h.srv.sessionKey(), time.Now(), 20*time.Minute)}
	token := h.enroll(t, "native-cycle")
	var ackMu sync.Mutex
	var receiptHashes []string
	// Exact node HTTP forwarding; drop just the first accepted exit ACK. Only
	// payload hashes survive: never log raw headers, credentials or requests.
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, e := io.ReadAll(io.LimitReader(r.Body, 2<<20))
		if e != nil {
			http.Error(w, "read", 500)
			return
		}
		req, e := http.NewRequestWithContext(r.Context(), r.Method, h.http.URL+r.URL.RequestURI(), bytes.NewReader(body))
		if e != nil {
			http.Error(w, "request", 500)
			return
		}
		req.Header = r.Header.Clone()
		response, e := h.http.Client().Do(req)
		if e != nil {
			http.Error(w, "upstream", 502)
			return
		}
		defer response.Body.Close()
		out, e := io.ReadAll(response.Body)
		if e != nil {
			http.Error(w, "response", 502)
			return
		}
		if response.StatusCode == 200 && r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/execution/exit") {
			sum := sha256.Sum256(body)
			ackMu.Lock()
			receiptHashes = append(receiptHashes, hex.EncodeToString(sum[:]))
			first := len(receiptHashes) == 1
			ackMu.Unlock()
			if first {
				c, _, e := w.(http.Hijacker).Hijack()
				if e == nil {
					_ = c.Close()
				}
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(out)
	}))
	defer proxy.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 11*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, python, helper)
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 30 * time.Second
	stdin, e := cmd.StdinPipe()
	if e != nil {
		t.Fatal(e)
	}
	stdout, e := cmd.StdoutPipe()
	if e != nil {
		t.Fatal(e)
	}
	cmd.Stderr = io.Discard // provider stderr/ambient environment never enter test output
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	var mu sync.Mutex
	decoder := json.NewDecoder(bufio.NewReader(stdout))
	encoder := json.NewEncoder(stdin)
	exchange := func(input map[string]any) (map[string]any, error) {
		mu.Lock()
		defer mu.Unlock()
		if e := encoder.Encode(input); e != nil {
			return nil, e
		}
		var env struct {
			OK     bool           `json:"ok"`
			Result map[string]any `json:"result"`
			Error  string         `json:"error"`
		}
		if e := decoder.Decode(&env); e != nil {
			return nil, e
		}
		if !env.OK {
			return nil, fmt.Errorf("native peer: %s", env.Error)
		}
		return env.Result, nil
	}
	var taskRef string
	defer func() {
		if taskRef != "" {
			b, _ := json.Marshal(map[string]any{"idempotency_key": "native-final-cleanup"})
			req, _ := http.NewRequest("POST", h.http.URL+FleetTasksPath+"/"+taskRef+"/stop", bytes.NewReader(b))
			req.AddCookie(cookie)
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Origin", h.http.URL)
			c := *h.http.Client()
			c.Timeout = 15 * time.Second
			if r, e := c.Do(req); e == nil {
				r.Body.Close()
			}
		}
		result, e := exchange(map[string]any{"action": "close"})
		if e != nil {
			t.Errorf("fixture cleanup not confirmed: %v", e)
		} else if errors, ok := result["cleanup_errors"].([]any); result["closed"] != true || !ok || len(errors) != 0 {
			t.Errorf("fixture cleanup incomplete (details in private manifest)")
		} else if result["fixture_forced_cleanup"] == true {
			t.Errorf("fixture forced cleanup; not normal stop proof")
		}
		_ = stdin.Close()
		_ = cmd.Wait()
	}()
	info, e := exchange(map[string]any{"root": root, "bin": bin, "url": proxy.URL, "token": token, "fleet": machineA, "live": true})
	if e != nil {
		t.Fatal(e)
	}
	call := func(action string, input map[string]any) map[string]any {
		input["action"] = action
		out, e := exchange(input)
		if e != nil {
			t.Fatalf("native %s: %v", action, e)
		}
		return out
	}
	call("activate", map[string]any{})
	f := control.Fleet{FleetID: info["fleet"].(string), Name: info["socket"].(string), Repo: "native/fixture", Repos: []string{"native/fixture"}, Checkout: filepath.Join(root, "repo"), Agent: "codex", State: "running", Workers: json.RawMessage(`[]`)}
	n := connectWriteNodeCaps(t, h, token, control.CapRead, control.CapWrite, control.CapTask, control.CapTaskExecution, control.CapTaskContinuation)
	n.setAnswer(func(request map[string]any) (any, *control.Error) {
		out, e := exchange(map[string]any{"action": "submit", "request": request})
		if e != nil {
			return nil, &control.Error{Code: "UNAVAILABLE", Message: "isolated native peer refused operation"}
		}
		return out, nil
	})
	n.setOpGet(func(request map[string]any) (any, *control.Error) {
		out, e := exchange(map[string]any{"action": "operation", "id": request["operation_id"]})
		if e != nil {
			return nil, &control.Error{Code: "UNAVAILABLE", Message: "isolated operation read unavailable"}
		}
		return out, nil
	})
	n.beatLoad("native-cycle", "acceptance", info["machine_id"].(string), 0, 0, f)
	waitFor(t, 5*time.Second, "isolated fleet", func() bool { hb, _, _ := h.srv.nodeStatusOf("ep_native-cycle", time.Now()); return len(hb.Fleets) == 1 })
	h.srv.onPrincipalSignIn(owner, "native acceptance")
	ownerPost := func(path string, body map[string]any, want int) map[string]any {
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequest("POST", h.http.URL+"/v1/fleet/"+path, bytes.NewReader(raw))
		req.AddCookie(cookie)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", h.http.URL)
		c := *h.http.Client()
		c.Timeout = 30 * time.Second
		r, e := c.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer r.Body.Close()
		var out map[string]any
		if json.NewDecoder(r.Body).Decode(&out) != nil {
			t.Fatal("owner response malformed")
		}
		if r.StatusCode != want {
			t.Fatalf("owner %s: HTTP %d, expected %d (body withheld)", path, r.StatusCode, want)
		}
		return out
	}
	nonce1, nonce2, fact := nativeCycleRandom(t), nativeCycleRandom(t), nativeCycleRandom(t)
	call("seed", map[string]any{"nonces": []string{nonce1, nonce2}, "fact": fact})
	prompt := "This is a bounded isolated acceptance fixture. Do not use subagents, external network, git push, deployment or MCP. First turn: make no tool calls and reply exactly: " + nonce1 + " FACT=" + fact + ". If explicitly continued in a fresh Session, read acceptance-next.txt in this worktree, then read the exact previous native transcript identified by your continuation seed and follow acceptance-next.txt. Do not repeat this first reply."
	start := ownerPost("worker_start", map[string]any{"kind": "scratch", "repo": "native/fixture", "fleet_id": f.FleetID, "node": "native-cycle", "idempotency_key": "native-first", "coding_agent": "codex", "control_version": 1, "body": prompt}, 200)
	n.mu.Lock()
	writes := append([]map[string]any(nil), n.writes...)
	n.mu.Unlock()
	if len(writes) != 1 {
		t.Fatal("initial start did not deliver exactly once")
	}
	taskRef = writes[0]["task_execution"].(map[string]any)["task_ref"].(string)
	initial, e := h.srv.Store.FleetTask(store.ParseTaskRef(taskRef))
	if e != nil || initial.Owner != owner {
		t.Fatal("Task not created by normal owner route")
	}
	awaitTurn := func(nonce string) map[string]any {
		deadline := time.Now().Add(150 * time.Second)
		for time.Now().Before(deadline) {
			out := call("observe", map[string]any{"task": taskRef})
			if replies, ok := out["nonce_replies"].(map[string]any); ok && replies[nonce] == float64(1) && out["user_turns"] == float64(1) && out["completed_turns"] == float64(1) {
				components, _ := json.Marshal(out["components"])
				if string(components) != `["client","server"]` {
					t.Fatal("private runtime server/client not both registered")
				}
				return out
			}
			time.Sleep(500 * time.Millisecond)
		}
		t.Fatal("native turn did not complete once within deadline; not provider acceptance")
		return nil
	}
	first := awaitTurn(nonce1)
	firstFID := strings.Split(first["snapshot"].(map[string]any)["execution_owner"].(string), "/")[1]
	call("sentinel", map[string]any{"task": taskRef, "first": true})
	var firstStop string
	for cycle := 0; cycle < 2; cycle++ {
		stopped := ownerPost("tasks/"+taskRef+"/stop", map[string]any{"idempotency_key": fmt.Sprintf("native-stop-%d", cycle)}, 202)
		stop := stopped["operation"].(map[string]any)["operation_id"].(string)
		if cycle == 0 {
			firstStop = stop
		}
		deadline := time.Now().Add(90 * time.Second)
		var savedHash string
		var receipt map[string]any
		for time.Now().Before(deadline) {
			receipt = call("receipt", map[string]any{"id": stop})
			if hash, ok := receipt["payload_hash"].(string); ok {
				if savedHash != "" && hash != savedHash {
					t.Fatal("exit proof changed across retry")
				}
				savedHash = hash
			}
			if receipt["confirmed"] == true {
				break
			}
			if savedHash != "" {
				call("retry", map[string]any{"id": stop})
			}
			time.Sleep(500 * time.Millisecond)
		}
		if receipt["confirmed"] != true {
			t.Fatal("real native exit unconfirmed")
		}
		if cycle == 1 {
			break
		}
		ackMu.Lock()
		hashes := append([]string(nil), receiptHashes...)
		ackMu.Unlock()
		if len(hashes) < 2 || hashes[0] != hashes[1] {
			t.Fatal("lost ACK did not replay identical body")
		}
		current, e := h.srv.Store.FleetTask(initial.ID)
		if e != nil || current.ExecutionEndpoint != "" {
			t.Fatal("first receipt did not release binding")
		}
		ownerPost("tasks/"+taskRef+"/continue", map[string]any{"idempotency_key": "native-continue", "expected_stop_operation_id": stop, "expected_generation": current.Generation, "agent": "codex"}, 202)
		second := awaitTurn(nonce2)
		if second["history"].(map[string]any)["sid"] == first["history"].(map[string]any)["sid"] || second["snapshot"].(map[string]any)["execution_owner"] == first["snapshot"].(map[string]any)["execution_owner"] {
			t.Fatal("explicit continuation reused native session")
		}
		if second["context_fact_seen"] != true || second["exact_history_read_confirmed"] != true {
			t.Fatal("second turn did not prove exact history/context handoff")
		}
		kept := call("sentinel", map[string]any{"task": taskRef})
		for _, key := range []string{"workspace_preserved", "sentinel_preserved", "git_status_preserved", "old_history_preserved"} {
			if kept[key] != true {
				t.Fatal(key + " failed")
			}
		}
		if call("old", map[string]any{"fid": firstFID, "stop": firstStop})["old_stopped"] != true {
			t.Fatal("old FID escaped stop")
		}
		call("retry", map[string]any{"id": firstStop})
		if _, e := exchange(map[string]any{"action": "submit", "request": nativeCycleWrite(n, firstStop)}); e != nil {
			t.Fatal("canonical old stop replay refused")
		}
		after, e := h.srv.Store.FleetTask(initial.ID)
		if e != nil || after.FID != initial.FID || after.CancelRequest != "" || after.OperationID == start["operation_id"] {
			t.Fatal("old replay changed successor authorization")
		}
	}
	t.Log("Codex two native sessions/turns: same Task/worktree; real Control/spawner/tmux; two exit proofs; lost ACK replay; old FID fenced")
	t.Log("Claude switch: BLOCKED by known quota, not run or passed; no global capabilities changed")
}
func nativeCycleRandom(t *testing.T) string {
	t.Helper()
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		t.Fatal(e)
	}
	return hex.EncodeToString(b)
}
func nativeCycleWrite(n *writeNode, id string) map[string]any {
	n.mu.Lock()
	defer n.mu.Unlock()
	for _, r := range n.writes {
		if r["operation_id"] == id {
			return r
		}
	}
	return nil
}

// Structural preparation only: real owner authentication and placement; node
// records delivery without Control/native start. No fabricated exit evidence.
func nativeCycleOwnerSandbox(t *testing.T) {
	h := newFleetHarness(t)
	owner := fmt.Sprintf("gh:%d", time.Now().UnixNano())
	enablePeople(t, h, owner)
	h.srv.GitHub.ClientSecret = nativeCycleRandom(t)
	mapLogins(t, h.srv, map[string]string{owner: "acceptance"})
	tok := h.enroll(t, "native-cycle")
	node := connectWriteNodeCaps(t, h, tok, control.CapRead, control.CapWrite, control.CapTask, control.CapTaskExecution, control.CapTaskContinuation)
	f := fakeFleet(t, machineA, "native-cycle-sandbox", "native/fixture", "/isolated/repo")
	node.beatLoad("native-cycle", "acceptance", machineA, 0, 0, f)
	waitFor(t, 5*time.Second, "sandbox fleet", func() bool { hb, _, _ := h.srv.nodeStatusOf("ep_native-cycle", time.Now()); return len(hb.Fleets) == 1 })
	h.srv.onPrincipalSignIn(owner, "native acceptance")
	cookie := &http.Cookie{Name: authz.CookieName, Value: authz.SignRole(store.IdentityGitHub, owner, "native acceptance", roleUser, h.srv.sessionKey(), time.Now(), time.Minute)}
	request := func(path string, body map[string]any, credential *http.Cookie) (int, map[string]any) {
		raw, _ := json.Marshal(body)
		r, _ := http.NewRequest("POST", h.http.URL+"/v1/fleet/"+path, bytes.NewReader(raw))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", h.http.URL)
		if credential != nil {
			r.AddCookie(credential)
		}
		res, e := h.http.Client().Do(r)
		if e != nil {
			t.Fatal(e)
		}
		defer res.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(res.Body).Decode(&out)
		return res.StatusCode, out
	}
	body := map[string]any{"kind": "scratch", "repo": "native/fixture", "fleet_id": f.FleetID, "node": "native-cycle", "idempotency_key": "sandbox-owner", "coding_agent": "codex", "control_version": 1, "body": "sandbox only; no execution"}
	if code, _ := request("worker_start", body, nil); code == 200 {
		t.Fatal("anonymous start admitted")
	}
	code, out := request("worker_start", body, cookie)
	if code != 200 {
		t.Fatalf("sandbox ordinary owner start: HTTP %d %v", code, out)
	}
	node.mu.Lock()
	defer node.mu.Unlock()
	if len(node.writes) != 1 {
		t.Fatal("sandbox expected one start")
	}
	ref := node.writes[0]["task_execution"].(map[string]any)["task_ref"].(string)
	task, e := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if e != nil || task.Owner != owner {
		t.Fatal("sandbox owner attribution")
	}
}
