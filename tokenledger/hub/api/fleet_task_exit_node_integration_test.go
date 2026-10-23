package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Use the real Node proof/journal/curl path against the real authenticated Hub
// API and Store. Only the detached window-cleanup spawn is suppressed: this
// test owns one temporary child process and never contacts a fleet tmux socket.
const nativeExitNodeFixture = `
import hashlib,json,os,subprocess,sys
from unittest.mock import Mock,patch
sys.path.insert(0,sys.argv[1])
from fleet_control import Control
from fleet_hub_common import canonical
from fleet_task_execution import _kernel_process
snapshot=json.load(sys.stdin)
control=Control(sys.argv[2])
stop=snapshot['cancel_request']
phase=sys.argv[3]
if phase=='prepare':
    grant=dict(snapshot,generation=snapshot['binding_generation'],cancel_request='')
    control.execution.bind(grant,authorized=True)
    child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(20)'])
    try:
        root=_kernel_process(child.pid)
        with control.execution.admission(grant) as permit:
            permit.reserve_launch('node-integration',root,wrapper=_kernel_process(os.getpid()))
            permit.register_child('node-integration',root)
            for component in ('server','client'):
                permit.register_native('node-integration',component,root)
    finally:
        child.terminate()
        child.wait(timeout=3)
    req=dict(operation_id=stop,fleet_id=snapshot['execution_owner'].split('/')[0],
             action='worker_stop',actor='integration-node',control_version=1,task_execution=snapshot,
             params=dict(task=snapshot['task_ref'],worker_id=snapshot['execution_owner'],
                         execution_endpoint=snapshot['execution_endpoint'],start_operation_id=snapshot['operation_id'],
                         generation=snapshot['binding_generation'],attempt_id=snapshot['attempt_id']))
    with patch('fleet_control.subprocess.Popen',return_value=Mock(wait=Mock(return_value=0))):
        control.submit(req)
    control.prepare_native_exit(stop)
    sent=None
else:
    # Recreated Control is a restarted Node. Proving again or replaying stop
    # cleanup would violate the saved-packet contract and fails this fixture.
    with patch('fleet_task_execution.prove_native_session_exit',side_effect=AssertionError('proof regenerated')), \
         patch.object(control,'_execute_once',side_effect=AssertionError('cleanup replayed')):
        sent=control.submit_native_exit(stop)
with control.store.connect() as db:
    result=json.loads(db.execute('SELECT result FROM operations WHERE id=?',(stop,)).fetchone()[0])
receipt=result['native_exit_receipt']
raw=canonical(receipt['payload']).encode()
assert control.execution.read(snapshot['task_ref']) == snapshot, 'local stop fence changed'
print(canonical(dict(sent=sent,confirmed=receipt.get('confirmed',False),
                     receipt_id=receipt.get('operation_id',''),sha256=hashlib.sha256(raw).hexdigest())))
`

func TestTaskSessionExitRealNodeLostAckAndNewBinding(t *testing.T) {
	for _, tool := range []string{"python3", "bash", "curl"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("native exit integration requires " + tool)
		}
	}
	bin, err := filepath.Abs("../../../bin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(bin, "fleet_task_exit_submit.py")); err != nil {
		t.Skip("native exit integration requires the repo bin/ beside tokenledger/")
	}
	h, _, task, snapshot := sessionExitFixture(t)
	var mu sync.Mutex
	var bodies [][]byte
	var ids []string
	// This fault injector does not fabricate a receipt: it forwards the exact
	// body and node credential, waits for the real Store to accept, then drops
	// only the first successful HTTP response before curl can observe it.
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, taskSessionExitBodyLimit+1))
		if err != nil {
			http.Error(w, "fixture request read", 500)
			return
		}
		upstream, err := http.NewRequestWithContext(r.Context(), r.Method, h.http.URL+r.URL.RequestURI(), bytes.NewReader(body))
		if err != nil {
			http.Error(w, "fixture request construction", 500)
			return
		}
		upstream.Header = r.Header.Clone()
		response, err := h.http.Client().Do(upstream)
		if err != nil {
			http.Error(w, "fixture upstream", 502)
			return
		}
		defer response.Body.Close()
		out, err := io.ReadAll(response.Body)
		if err != nil {
			http.Error(w, "fixture response read", 502)
			return
		}
		if response.StatusCode == http.StatusOK {
			var receipt struct {
				Operation struct {
					ID string `json:"operation_id"`
				} `json:"operation"`
			}
			if err := json.Unmarshal(out, &receipt); err != nil || receipt.Operation.ID == "" {
				http.Error(w, "fixture invalid real receipt", 502)
				return
			}
			mu.Lock()
			bodies = append(bodies, body)
			ids = append(ids, receipt.Operation.ID)
			first := len(bodies) == 1
			mu.Unlock()
			if first {
				conn, _, err := w.(http.Hijacker).Hijack()
				if err == nil {
					_ = conn.Close()
				}
				return
			}
		}
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(out)
	}))
	t.Cleanup(proxy.Close)
	home := t.TempDir()
	conf := filepath.Join(home, "conf")
	if err := os.MkdirAll(conf, 0700); err != nil {
		t.Fatal(err)
	}
	// Ephemeral credentials minted by this isolated httptest Hub, never a real
	// login's node.env. The Node reads them through its ordinary auth helper.
	if err := os.WriteFile(filepath.Join(conf, "node.env"), []byte("CCQUOTA_HUB_URL="+proxy.URL+"\nCCQUOTA_TOKEN="+h.tokens["mac-c"]+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	rawSnapshot, _ := json.Marshal(snapshot)
	type nodeResult struct {
		Sent      *bool  `json:"sent"`
		Confirmed bool   `json:"confirmed"`
		ReceiptID string `json:"receipt_id"`
		SHA256    string `json:"sha256"`
	}
	run := func(phase string) nodeResult {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "python3", "-c", nativeExitNodeFixture, bin, conf, phase)
		cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "FLEET_CONF_DIR=" + conf,
			"TMPDIR=" + home, "PYTHONDONTWRITEBYTECODE=1", "CCQUOTA_NODE_KEY=off", "CCQUOTA_HUB_SOCK=off"}
		cmd.Stdin = bytes.NewReader(rawSnapshot)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("Node %s: %v\n%s", phase, err, out)
		}
		var result nodeResult
		if err := json.Unmarshal(out, &result); err != nil {
			t.Fatalf("Node %s response: %v\n%s", phase, err, out)
		}
		return result
	}
	prepared := run("prepare")
	if prepared.Confirmed || prepared.Sent != nil || prepared.SHA256 == "" {
		t.Fatalf("proof was not saved before submission: %+v", prepared)
	}
	first := run("submit")
	if first.Sent == nil || *first.Sent || first.Confirmed || first.SHA256 != prepared.SHA256 {
		t.Fatalf("lost ACK was treated as confirmed: %+v", first)
	}
	released, err := h.srv.Store.FleetTask(task.ID)
	if err != nil || released.ExecutionOwner != "" || released.ExecutionEndpoint != "" || released.CancelRequest != snapshot.CancelRequest {
		t.Fatalf("real Hub did not release original binding: %+v %v", released, err)
	}
	mu.Lock()
	if len(ids) != 1 {
		mu.Unlock()
		t.Fatal("first real receipt was not accepted")
	}
	exitID := ids[0]
	mu.Unlock()
	resumed, start, worker := resumeSessionExitForTest(t, h, task.ID, exitID, snapshot.ExecutionEndpoint)
	replayed := run("replay")
	if replayed.Sent == nil || !*replayed.Sent || !replayed.Confirmed || replayed.ReceiptID != exitID || replayed.SHA256 != prepared.SHA256 {
		t.Fatalf("restarted Node did not confirm original packet: %+v", replayed)
	}
	got, err := h.srv.Store.FleetTask(task.ID)
	if err != nil || got.OperationID != start.ID || got.ExecutionOwner != worker || got.Generation != resumed.Generation || got.CancelRequest != "" {
		t.Fatalf("old Node receipt changed newer binding: %+v %v", got, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(ids) != 2 || ids[0] != ids[1] || !bytes.Equal(bodies[0], bodies[1]) {
		t.Fatal("retry did not use identical bytes and historical Hub receipt")
	}
	digest := sha256.Sum256(bodies[0])
	if hex.EncodeToString(digest[:]) != prepared.SHA256 {
		t.Fatal("HTTP proof differs from Node's durable original packet")
	}
	var count int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action='task_session_exit'`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("replay created another receipt: count=%d err=%v", count, err)
	}
}
