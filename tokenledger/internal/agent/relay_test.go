package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent's half of relays (claude-fleet#1421): what claude-fleet's script
// says becomes the answer to the hub, and the hub's map becomes the cache file.

func fakeHubNodeScript(t *testing.T, body string) relayPaths {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/bash\ncase \"$1\" in\n  paths) printf 'outbox\\t%s\\nworkers\\t%s\\n' " +
		"'" + filepath.Join(home, "out") + "' '" + filepath.Join(home, "c", "w.tsv") + "' ;;\n  deliver) " + body + " ;;\nesac\n"
	if err := os.WriteFile(filepath.Join(dir, "fleet-hub-node.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	p, ok := relaySetup(context.Background(), home)
	if !ok {
		t.Fatal("relaySetup refused a script that prints both paths")
	}
	return p
}

func TestRelaySetupNeedsTheScript(t *testing.T) {
	if _, ok := relaySetup(context.Background(), t.TempDir()); ok {
		t.Fatal("a login without fleet-hub-node.sh must not list the relay capability")
	}
}

func TestRelayDeliverExitCodes(t *testing.T) {
	for _, c := range []struct {
		body      string
		ok, retry bool
		detail    string
	}{
		{`cat >/dev/null; echo applied >&2; exit 0`, true, false, "applied"},
		{`cat >/dev/null; echo busy >&2; exit 75`, false, true, "busy"},
		{`cat >/dev/null; printf 'one\nno such parent\n' >&2; exit 1`, false, false, "no such parent"},
	} {
		p := fakeHubNodeScript(t, c.body)
		ok, retry, detail := runRelayDeliver(context.Background(), p, []byte(`{}`))
		if ok != c.ok || retry != c.retry || detail != c.detail {
			t.Errorf("%s → ok=%v retry=%v %q; want %v %v %q", c.body, ok, retry, detail, c.ok, c.retry, c.detail)
		}
	}
}

func TestRelayWorkersWritesTheCache(t *testing.T) {
	p := fakeHubNodeScript(t, "exit 0")
	w := control.Workers{Rows: []control.WorkerLoc{
		{WorkerID: "a/issue-1", Node: "m4", OriginWID: "b/issue-2"},
		{WorkerID: "a/issue-3", Node: "m4:lost"},
		{WorkerID: "bad\tid", Node: "m4"},
	}}
	raw, _ := json.Marshal(w)
	if err := relayWorkers(p, control.Message{Payload: raw}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p.workers)
	if err != nil {
		t.Fatal(err)
	}
	if want := "a/issue-1\tm4\tb/issue-2\na/issue-3\tm4:lost\t\n"; string(b) != want {
		t.Fatalf("cache = %q; want %q", b, want)
	}
}
