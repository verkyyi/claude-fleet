package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
	"golang.org/x/crypto/ssh"
)

func continueWriteCall(t *testing.T, h *harness, req WriteRequest, token, worker string) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(req)
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+control.WritePath, bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if worker != "" {
		r.Header.Set("X-Fleet-Worker", worker)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}
func TestTaskContinueEntryViewerReplayAndWorkerDenial(t *testing.T) {
	h, node, task, snapshot, _ := continueFixture(t)
	body := continueBody(snapshot, "terminal-continue")
	body["task"] = task.Ref
	b, _ := json.Marshal(body)
	req := WriteRequest{Tool: "task_continue", ArgsJSON: string(b)}
	for _, auth := range []struct{ token, worker string }{{h.tokens["mac-c"], ""}, {"fcp-h2.session-worker", ""}, {viewerToken, "assertion"}} {
		status, out := continueWriteCall(t, h, req, auth.token, auth.worker)
		if status != 401 && status != 403 {
			t.Fatalf("node/worker accepted: %d %v", status, out)
		}
	}
	if node.count() != 0 {
		t.Fatal("denied request reached node")
	}
	status, out := continueWriteCall(t, h, req, viewerToken, "")
	if status != 202 {
		t.Fatalf("viewer: %d %v", status, out)
	}
	status, again := continueWriteCall(t, h, req, viewerToken, "")
	if status != 202 || node.count() != 1 || again["operation"].(map[string]any)["operation_id"] != out["operation"].(map[string]any)["operation_id"] {
		t.Fatalf("replay %d %v writes=%d", status, again, node.count())
	}
	req.ArgsJSON = string(b) + " {}"
	if status, out = continueWriteCall(t, h, req, viewerToken, ""); status != 400 {
		t.Fatalf("trailing input: %d %v", status, out)
	}
	body["extra"] = "not allowed"
	b, _ = json.Marshal(body)
	req.ArgsJSON = string(b)
	if status, out = continueWriteCall(t, h, req, viewerToken, ""); status != 400 {
		t.Fatalf("extra field: %d %v", status, out)
	}
}
func TestTaskContinueEntryCertificateBindsPayload(t *testing.T) {
	h, node, task, snapshot, _ := continueFixture(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	_, err := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	if err != nil {
		t.Fatal(err)
	}
	cert := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(time.Hour))
	body := continueBody(snapshot, "signed-terminal-continue")
	body["task"] = task.Ref
	b, _ := json.Marshal(body)
	signed := func(raw string) WriteRequest {
		sum := sha256.Sum256([]byte(raw))
		return WriteRequest{Tool: "task_continue", ArgsJSON: raw, TS: now.Unix(), Cert: string(ssh.MarshalAuthorizedKey(cert)), Sig: sshsig(t, k.user, control.WriteSigNamespace, []byte(control.WriteSigMessage(now.Unix(), "task_continue", hex.EncodeToString(sum[:]))))}
	}
	req := signed(string(b))
	req.ArgsJSON = `{"task":"T999"}`
	if st, out := continueWriteCall(t, h, req, "", ""); st != 401 {
		t.Fatalf("tamper: %d %v", st, out)
	}
	req = signed(string(b))
	if st, out := continueWriteCall(t, h, req, "", ""); st != 404 {
		t.Fatalf("another owner: %d %v", st, out)
	}
	own, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: "wx-alice", Title: "own", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "own-cert-task", now)
	if err != nil {
		t.Fatal(err)
	}
	body["task"] = own.Ref
	b, _ = json.Marshal(body)
	if st, out := continueWriteCall(t, h, signed(string(b)), "", ""); st != 409 {
		t.Fatalf("own unproved: %d %v", st, out)
	}
	if st, out := continueWriteCall(t, h, WriteRequest{Tool: "task_continue", ArgsJSON: string(b)}, viewerToken, ""); st != 404 {
		t.Fatalf("operator not owner: %d %v", st, out)
	}
	if node.count() != 0 {
		t.Fatal("unproved or wrong-owner task launched")
	}

}

func TestTaskContinueEntryReadOnlySessionDenied(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob, pCarol)
	task, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "owned", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "ro-continue", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(map[string]any{"task": task.Ref, "idempotency_key": "read-only-continue", "expected_stop_operation_id": "stop", "expected_generation": 2})
	token := authz.SignReadOnly(store.IdentityGitHub, pAlice, "alice", roleUser, h.srv.sessionKey(), time.Now(), time.Hour)
	body, _ := json.Marshal(WriteRequest{Tool: "task_continue", ArgsJSON: string(raw)})
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+control.WritePath, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: authz.CookieName, Value: token})
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("read-only session: %d", resp.StatusCode)
	}

}
