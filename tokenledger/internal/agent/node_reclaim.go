package agent

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// A SPOT node being taken back (claude-fleet#1428). The kubelet's SIGTERM is
// the only warning a pod gets, with terminationGracePeriodSeconds to act on
// it. Reclaim spends that time on two things, in order:
//
//  1. tell the hub (POST /v1/node/reclaim) — from that moment placement
//     avoids this node, so every `move plan` the evacuation asks answers
//     with another machine;
//  2. run the evacuation: claude-fleet's bin/fleet-spot-evacuate.sh, which
//     moves every idle session off through the ordinary hub move
//     (fleet-move.sh --rebalance --max all); a session mid-turn is never
//     cut, and what cannot move in time is what the hub records as lost.
//
// Then the agent exits and the pod goes; the hub's next tick sees it gone,
// releases the leases that were still held and closes the record.

// reclaimEvacuateScript is claude-fleet's evacuation, relative to the home.
var reclaimEvacuateScript = filepath.Join(".claude", "fleet", "bin", "fleet-spot-evacuate.sh")

// Ephemeral reports whether this agent runs a SPOT node.
func (a *Agent) Ephemeral() bool { return a.cfg.Fleet && a.cfg.FleetEphemeral }

// Reclaim runs the reclaim sequence, bounded by FleetReclaimTimeout. It
// never returns an error: there is nothing a caller could do with one, and
// every step is logged.
func (a *Agent) Reclaim(ctx context.Context) {
	timeout := a.cfg.FleetReclaimTimeout
	if timeout <= 0 {
		timeout = 240 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	start := time.Now()

	if err := a.reclaimNotify(ctx); err != nil {
		log.Printf("reclaim: hub not told (%v) — evacuating anyway; the hub sees the pod go either way", err)
	} else {
		log.Printf("reclaim: hub told; placement now avoids this node")
	}

	cmd := a.cfg.FleetReclaimCmd
	if cmd == "" {
		p := filepath.Join(a.cfg.Home, reclaimEvacuateScript)
		if _, err := os.Stat(p); err != nil {
			log.Printf("reclaim: no evacuation (%s not installed); sessions on this node are left to the hub's record", p)
			return
		}
		cmd = p
	}
	log.Printf("reclaim: running %s (deadline %s)", cmd, timeout-time.Since(start).Round(time.Second))
	c := exec.CommandContext(ctx, "/bin/sh", "-c", cmd)
	c.Dir = a.cfg.Home
	c.Env = append(os.Environ(), "HOME="+a.cfg.Home, "CCQUOTA_FLEET=1",
		"FLEET_SPOT_EVACUATE_SECS="+fmt.Sprint(int(timeout.Seconds())))
	c.Stdin = nil
	// The script runs a tmux-driven move per session; a deadline that kills
	// only the shell would leave those running. One process group, killed
	// together.
	setProcessGroup(c)
	c.Cancel = func() error { return killProcessGroup(c) }
	c.WaitDelay = 5 * time.Second
	if err := prepCmd(ctx, c); err != nil {
		log.Printf("reclaim: %v", err)
		return
	}
	out, err := c.StdoutPipe()
	if err != nil {
		log.Printf("reclaim: %v", err)
		return
	}
	c.Stderr = c.Stdout
	if err := c.Start(); err != nil {
		log.Printf("reclaim: start evacuation: %v", err)
		return
	}
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		log.Printf("reclaim: │ %s", sc.Text())
	}
	err = c.Wait()
	switch {
	case err == nil:
		log.Printf("reclaim: evacuation done in %s", time.Since(start).Round(time.Second))
	case ctx.Err() != nil:
		log.Printf("reclaim: evacuation cut at the deadline (%s); what is still here is lost with the node", timeout)
	default:
		log.Printf("reclaim: evacuation exited: %v", err)
	}
}

// reclaimNotify is the POST.
func (a *Agent) reclaimNotify(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.HubURL+"/v1/node/reclaim", strings.NewReader("{}"))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return errors.New("HTTP " + resp.Status + ": " + strings.TrimSpace(string(body)))
	}
	return nil
}
