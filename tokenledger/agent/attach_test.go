package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The agent's half of a writing area's attachments (claude-fleet#2393): each
// file a worker_start names is downloaded with this node's token and checked
// against its sha256 before the write may go on; a start naming none, or any
// other write, is left alone.
func TestFetchAttachments(t *testing.T) {
	shot := []byte("\x89PNG the error")
	sum := sha256.Sum256(shot)
	good := strings.Repeat("a", 32)
	gets := 0
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/v1/node/attachment/" + good, "/v1/node/attachment/" + strings.Repeat("b", 32):
			gets++
			_, _ = w.Write(shot)
		default:
			http.NotFound(w, r)
		}
	}))
	defer hub.Close()
	dir := filepath.Join(t.TempDir(), "attachments")
	a := &Agent{cfg: Config{HubURL: hub.URL, Token: "tok"}, attachDir: dir}
	env := func(action string, list ...map[string]any) json.RawMessage {
		params := map[string]any{"kind": "new"}
		if len(list) > 0 {
			params["attachments"] = list
		}
		b, _ := json.Marshal(map[string]any{"action": action, "params": params})
		return b
	}
	one := func(id, name, sha string) map[string]any {
		return map[string]any{"id": id, "name": name, "sha256": sha, "size": len(shot), "from": "/c/" + name}
	}
	if code, _ := a.fetchAttachments(context.Background(), env("worker_start")); code != "" || gets != 0 {
		t.Fatalf("a start naming no file: %s, %d gets", code, gets)
	}
	if code, msg := a.fetchAttachments(context.Background(), env("worker_start", one(good, "shot.png", hex.EncodeToString(sum[:])))); code != "" {
		t.Fatalf("fetch = %s %s", code, msg)
	}
	if b, err := os.ReadFile(filepath.Join(dir, good, "shot.png")); err != nil || string(b) != string(shot) {
		t.Fatalf("landed %q %v; want the file's bytes at <attach>/<id>/<name>", b, err)
	}
	if code, _ := a.fetchAttachments(context.Background(), env("worker_start", one(good, "shot.png", hex.EncodeToString(sum[:])))); code != "" || gets != 1 {
		t.Fatalf("a retried start re-downloaded (%d gets, %s)", gets, code)
	}
	if code, _ := a.fetchAttachments(context.Background(), env("worker_start", one(strings.Repeat("b", 32), "x.png", strings.Repeat("0", 64)))); code != "UNAVAILABLE" {
		t.Fatalf("a corrupted file = %q; want UNAVAILABLE", code)
	}
	if _, err := os.Stat(filepath.Join(dir, strings.Repeat("b", 32), "x.png")); err == nil {
		t.Fatal("a corrupted file was kept")
	}
	if code, _ := a.fetchAttachments(context.Background(), env("worker_start", one(strings.Repeat("c", 32), "gone.png", hex.EncodeToString(sum[:])))); code != "UNAVAILABLE" {
		t.Fatalf("a 404 = %q; want UNAVAILABLE", code)
	}
	for _, bad := range []map[string]any{one("../../etc", "x", hex.EncodeToString(sum[:])), one(good, "../x", hex.EncodeToString(sum[:])), one(good, "..", hex.EncodeToString(sum[:]))} {
		if code, _ := a.fetchAttachments(context.Background(), env("worker_start", bad)); code != "INVALID_ARGUMENT" {
			t.Fatalf("%v = %q; want INVALID_ARGUMENT", bad, code)
		}
	}
	old := &Agent{cfg: Config{HubURL: hub.URL, Token: "tok"}}
	if code, _ := old.fetchAttachments(context.Background(), env("worker_start", one(good, "shot.png", hex.EncodeToString(sum[:])))); code != "UNAVAILABLE" {
		t.Fatalf("no attachment directory = %q; want UNAVAILABLE", code)
	}
}
