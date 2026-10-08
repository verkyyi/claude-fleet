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
	"testing"
)

// The agent's half of a hub move (claude-fleet#1426): a worker_move_in's
// bundle is downloaded — with this node's token, checked against the hub's
// sha256 — before the write may go on; any other write is left alone.

func TestFetchMoveBundle(t *testing.T) {
	body := []byte("transcript tar")
	sum := sha256.Sum256(body)
	var gotAuth string
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		switch r.URL.Path {
		case "/v1/node/move/bundle/" + "0123456789abcdef0123456789abcdef":
			w.Header().Set("X-Bundle-Sha256", hex.EncodeToString(sum[:]))
			_, _ = w.Write(body)
		case "/v1/node/move/bundle/" + "ffffffffffffffffffffffffffffffff":
			w.Header().Set("X-Bundle-Sha256", "00")
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	defer hub.Close()
	dir := filepath.Join(t.TempDir(), "move-in")
	a := &Agent{cfg: Config{HubURL: hub.URL, Token: "tok"}, moveIn: dir}
	env := func(action, id string) json.RawMessage {
		b, _ := json.Marshal(map[string]any{"action": action, "params": map[string]any{"move_id": id}})
		return b
	}

	if code, msg := a.fetchMoveBundle(context.Background(), env("worker_start", "x")); code != "" {
		t.Fatalf("another write was held up: %s %s", code, msg)
	}
	if code, msg := a.fetchMoveBundle(context.Background(), env("worker_move_in", "0123456789abcdef0123456789abcdef")); code != "" {
		t.Fatalf("download refused: %s %s", code, msg)
	}
	if gotAuth != "Bearer tok" {
		t.Fatalf("Authorization = %q; want this node's token", gotAuth)
	}
	if got, err := os.ReadFile(filepath.Join(dir, "0123456789abcdef0123456789abcdef.tar")); err != nil || string(got) != string(body) {
		t.Fatalf("bundle on disk = %q %v", got, err)
	}
	if code, _ := a.fetchMoveBundle(context.Background(), env("worker_move_in", "ffffffffffffffffffffffffffffffff")); code != "UNAVAILABLE" {
		t.Fatalf("a corrupted bundle was accepted: %q", code)
	}
	if _, err := os.Stat(filepath.Join(dir, "ffffffffffffffffffffffffffffffff.tar")); err == nil {
		t.Fatal("a corrupted bundle was kept")
	}
	if code, _ := a.fetchMoveBundle(context.Background(), env("worker_move_in", "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")); code != "UNAVAILABLE" {
		t.Fatalf("a missing bundle was accepted: %q", code)
	}
	if code, _ := a.fetchMoveBundle(context.Background(), env("worker_move_in", "../../etc/passwd")); code != "INVALID_ARGUMENT" {
		t.Fatalf("a path-shaped id was accepted: %q", code)
	}
	old := &Agent{cfg: Config{HubURL: hub.URL, Token: "tok"}}
	if code, _ := old.fetchMoveBundle(context.Background(), env("worker_move_in", "0123456789abcdef0123456789abcdef")); code != "UNAVAILABLE" {
		t.Fatalf("a claude-fleet without a move-in dir took a move: %q", code)
	}
}

func TestRelaySetupReadsMoveIn(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/bash\nprintf 'outbox\\t%s\\nworkers\\t%s\\nmovein\\t%s\\n' /o /w.tsv /m\n"
	if err := os.WriteFile(filepath.Join(dir, "fleet-hub-node.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	p, ok := relaySetup(context.Background(), home)
	if !ok || p.movein != "/m" || p.attach != "" {
		t.Fatalf("relaySetup = %+v %v; want movein /m and no attach (an older claude-fleet)", p, ok)
	}
	// claude-fleet#2393: the attach line is what makes the node say CapAttach.
	script = "#!/bin/bash\nprintf 'outbox\\t%s\\nworkers\\t%s\\nmovein\\t%s\\nattach\\t%s\\n' /o /w.tsv /m /a\n"
	if err := os.WriteFile(filepath.Join(dir, "fleet-hub-node.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if p, ok = relaySetup(context.Background(), home); !ok || p.attach != "/a" {
		t.Fatalf("relaySetup = %+v %v; want attach /a", p, ok)
	}
}
