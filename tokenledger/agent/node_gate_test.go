package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The heartbeat's gate (claude-fleet#3574): the script's --local JSON, an
// exit 1 (an item red) still read; no script or no JSON ⇒ no gate.
func TestGateJudge(t *testing.T) {
	home := t.TempDir()
	ctx := context.Background()
	if got := gateJudge(ctx, home); got != nil {
		t.Fatalf("no script: %+v", got)
	}
	script := filepath.Join(home, gateScript)
	os.MkdirAll(filepath.Dir(script), 0o755)
	os.WriteFile(script, []byte(`[ "$1" = --local ] || exit 2
echo '{"pass":0,"total":1,"items":[{"n":2,"id":"root-core","pass":false,"why":"root: x"}]}'
exit 1
`), 0o755)
	got := gateJudge(ctx, home)
	if len(got) != 1 || got[0].ID != "root-core" || got[0].Pass || got[0].Why != "root: x" {
		t.Fatalf("red item: %+v", got)
	}
	var p gateProbe
	now := time.Now()
	p.reading(ctx, home, now)
	os.WriteFile(script, []byte("echo not json\n"), 0o755)
	if got := p.reading(ctx, home, now.Add(time.Minute)); len(got) != 1 {
		t.Fatalf("cached reading: %+v", got)
	}
	if got := p.reading(ctx, home, now.Add(gateInterval+time.Second)); got != nil {
		t.Fatalf("garbage: %+v", got)
	}
}
