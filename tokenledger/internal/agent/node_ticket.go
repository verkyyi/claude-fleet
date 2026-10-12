package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A hub ticket's comment, pushed into its session (claude-fleet#3597, EPIC
// #3570 C4).
//
// The hub sends TypeTicket the moment one of this login's person's hub tickets
// moves (claude-fleet#2677). A comment is handed to this login's claude-fleet
// bin/fleet-issue-bridge.sh --event <repo> <N> <comment id>, which reads it
// through the ticket door and types it into the ticket's worker window when
// that window is on this login — the dedup, the echo rule (a comment the fleet
// wrote is never sent back) and the worker-only rule are the bridge's, never
// re-done here. A state change, a claim or an edit carries nothing for a
// session and is ignored. An event the bridge cannot take now (the worker
// busy, the hub not answering) is left to the bridge's own backstop poll,
// which lists what moved since its watermark — so a missed push costs one
// poll tick, never the comment. Without the script the agent never lists
// CapTicket, so the hub sends nothing and nothing changes.

var fleetBridgeScript = filepath.Join(".claude", "fleet", "bin", "fleet-issue-bridge.sh")

// fleetBridgeTimeout bounds one delivery: a hub read (10 s by default) plus
// the paste into the pane.
const fleetBridgeTimeout = 60 * time.Second

// bridgeCommand is the injection point for tests, like fleetCommand.
var bridgeCommand = fleetCommand

// ticketCapable reports whether this login can take a pushed ticket comment.
func (a *Agent) ticketCapable() bool {
	if a.cfg.Home == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(a.cfg.Home, fleetBridgeScript))
	return err == nil
}

// handleTicket takes the hub's TypeTicket: a comment goes to the bridge, off
// the read loop.
func (a *Agent) handleTicket(ctx context.Context, m control.Message) {
	var t control.Ticket
	if err := json.Unmarshal(m.Payload, &t); err != nil || t.Kind != "comment" ||
		t.CommentID <= 0 || t.Number <= 0 || t.Repo == "" {
		return
	}
	go a.bridgeEvent(ctx, t)
}

// bridgeEvent runs fleet-issue-bridge.sh --event once. Exit 0 = done; 75 =
// not now and 4 = the hub did not answer — both left to the bridge's backstop.
func (a *Agent) bridgeEvent(ctx context.Context, t control.Ticket) {
	script := filepath.Join(a.cfg.Home, fleetBridgeScript)
	if _, err := os.Stat(script); err != nil {
		return
	}
	// Not the connection's: a link that drops mid-paste must not cut it short.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), fleetBridgeTimeout)
	defer cancel()
	cmd := bridgeCommand(ctx, "bash", script, "--event", t.Repo,
		strconv.FormatInt(t.Number, 10), strconv.FormatInt(t.CommentID, 10))
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	if err == nil {
		return
	}
	code := -1
	if cmd.ProcessState != nil {
		code = cmd.ProcessState.ExitCode()
	}
	if code == 75 || code == 4 {
		return
	}
	last := strings.TrimSpace(out.String())
	if i := strings.LastIndexByte(last, '\n'); i >= 0 {
		last = last[i+1:]
	}
	if last == "" {
		last = err.Error()
	}
	log.Printf("ticket %s#%d c%d: bridge: %s", t.Repo, t.Number, t.CommentID, last)
}
