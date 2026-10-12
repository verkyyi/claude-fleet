package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The heartbeat's gate (claude-fleet#3574, EPIC #3569 C4): this machine's
// half of the public gate — every conf/public-gate.tsv row judged where=node.
// The ONE judgement is the claude-fleet script's (`fleet-gate-check.sh
// --local`, read-only: ps, users, groups), never a second copy here; the hub
// folds every machine's into /v1/fleet/gate.

var gateScript = filepath.Join(".claude", "fleet", "bin", "fleet-gate-check.sh")

const (
	// gateInterval: the answer changes when a release lands, not per beat.
	gateInterval = 10 * time.Minute
	gateTimeout  = 20 * time.Second
)

// gateCommand is the seam the tests replace.
var gateCommand = credsepCommand

type gateProbe struct {
	at    time.Time
	items []control.GateItem
}

// reading is the machine's gate items; nil when the script is missing or
// said nothing readable (the beat then carries no gate, like an older agent).
func (p *gateProbe) reading(ctx context.Context, home string, now time.Time) []control.GateItem {
	if !p.at.IsZero() && now.Sub(p.at) < gateInterval {
		return p.items
	}
	p.at, p.items = now, gateJudge(ctx, home)
	return p.items
}

func gateJudge(ctx context.Context, home string) []control.GateItem {
	script := filepath.Join(home, gateScript)
	if _, err := os.Stat(script); err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, gateTimeout)
	defer cancel()
	cmd := gateCommand(ctx, "/bin/bash", script, "--local")
	cmd.Env = append(os.Environ(), "HOME="+home)
	if err := prepCmd(ctx, cmd); err != nil {
		return nil
	}
	// exit 1 is "an item is red" — the answer, not a failure
	out, _ := cmd.Output()
	var got struct {
		Items []control.GateItem `json:"items"`
	}
	if json.Unmarshal(out, &got) != nil || len(got.Items) == 0 {
		return nil
	}
	return got.Items
}
