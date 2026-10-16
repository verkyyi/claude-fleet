package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

func TestTaskReceiptOutboxAckAndExpiry(t *testing.T) {
	dir := t.TempDir()
	a := &Agent{}
	p := relayPaths{outbox: dir}
	link := &capLink{}
	write := func(name string, expiry int64) string {
		payload, _ := json.Marshal(map[string]any{"task_recovery": name, "expires_at": expiry})
		raw, _ := json.Marshal(control.Relay{ID: name, Kind: "child_report", Payload: payload})
		path := filepath.Join(dir, name+".json")
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	active := write("active", time.Now().Add(time.Hour).Unix())
	expired := write("expired", time.Now().Add(-time.Hour).Unix())
	a.relayOutboxOnce(context.Background(), link, p)
	if len(link.got) != 1 || link.got[0].OpID != "active" {
		t.Fatalf("sent %v", link.got)
	}
	if _, err := os.Stat(expired); err != nil {
		t.Fatal("expired receipt disappeared", err)
	}
	if why, err := os.ReadFile(expired + ".why"); err != nil || !strings.Contains(string(why), "reconciliation") {
		t.Fatalf("expired reason: %q %v", why, err)
	}
	if !a.relayAcked("active") {
		t.Fatal("ack not recognized")
	}
	if ack, err := os.ReadFile(active + ".acked"); err != nil || string(ack) != "active" {
		t.Fatalf("ack %q %v", ack, err)
	}
	if _, err := os.Stat(active); !os.IsNotExist(err) {
		t.Fatalf("acked outbox still present: %v", err)
	}
	if a.relayAcked("active") {
		t.Fatal("duplicate ack settled twice")
	}
}

func TestTaskReceiptReconnectCapabilityAndOnePass(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "fleet-hub-node.sh")
	count := filepath.Join(home, "passes")
	body := "#!/bin/bash\ncase $1 in\npaths) printf 'outbox\\t/tmp/out\\nworkers\\t/tmp/workers\\ntask_recovery_v1\\t1\\n';;\nreplay) echo replay >> '" + count + "';;\nesac\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	p, ok := relaySetup(context.Background(), home)
	if !ok || !p.taskRecovery {
		t.Fatalf("missing recovery capability: %+v", p)
	}
	a := &Agent{}
	a.replayTaskReceipts(context.Background(), p.script)
	b, err := os.ReadFile(count)
	if err != nil || string(b) != "replay\n" {
		t.Fatalf("passes %q %v", b, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a.replayTaskReceipts(ctx, p.script)
	b, _ = os.ReadFile(count)
	if string(b) != "replay\n" {
		t.Fatalf("cancelled connection ran helper: %q", b)
	}
}
