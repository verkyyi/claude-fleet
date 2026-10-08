package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
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

// A person's own computer (claude-fleet#1721, EPIC #1718 C3).
//
// `fleet node compute on --personal` — a laptop's default — writes
// CCQUOTA_FLEET_PERSONAL=1 into node.env; the agent re-reads it every hello
// and beat (Personal), and the hub then places on this login only what is
// asked from it.
//
// A personal machine also says when it sleeps. bin/fleet-node-sleepwatch.sh
// prints `sleep` just before the system sleeps and `wake` after; on `sleep`
// the agent flags its machine 维护中 with reason "sleep" (POST
// /v1/node/maintenance) and, when sessions are still running here, tells the
// person's client how many (POST /v1/node/client/actions, a notify); on
// `wake` it clears that flag — and only that one (if_reason), so an
// operator's maintenance outlives a nap. The agent also notices a wake by
// itself: across a sleep its wall clock jumps and its monotonic clock does
// not, so a missing or broken watch never leaves the machine flagged. And a
// personal login clears a sleep flag once at start, for the machine that went
// down asleep and came back by a reboot.

// sleepGap is how far the wall clock must outrun the monotonic one between
// two ticks of sleepTick for the agent to call it a wake.
const (
	sleepTick = 15 * time.Second
	sleepGap  = 30 * time.Second
	// wakeRetry / wakeTries: right after a wake the network may not be up —
	// the leave is retried for a few minutes.
	wakeRetry = 10 * time.Second
	wakeTries = 30
)

// sleepWatchScripts are where bin/fleet-node-sleepwatch.sh lives, like
// probeScripts.
var sleepWatchScripts = []string{
	filepath.Join(".claude", "fleet", "bin", "fleet-node-sleepwatch.sh"),
	filepath.Join(".local", "share", "claude-fleet", "bin", "fleet-node-sleepwatch.sh"),
}

// personalNow is this login's own word: node.env's CCQUOTA_FLEET_PERSONAL=1
// while compute is on. A login that only coordinates takes no session at all,
// so it is never called personal.
func (a *Agent) personalNow() bool {
	env, ok := a.nodeEnv()
	return ok && env["CCQUOTA_FLEET_PERSONAL"] == "1" && env["CCQUOTA_FLEET_COMPUTE"] != "0"
}

func (a *Agent) sleepWatchScript() string {
	for _, rel := range sleepWatchScripts {
		p := filepath.Join(a.cfg.Home, rel)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

// runSleepWatch feeds sleepLoop from the watch script and the clock.
func (a *Agent) runSleepWatch(ctx context.Context) {
	ev := make(chan string, 4)
	go a.watchScript(ctx, ev)
	go watchClock(ctx, ev, sleepTick)
	a.sleepLoop(ctx, ev)
}

// watchScript runs the watch and forwards its lines, starting it again a
// minute after it stops — unless it said it cannot run here (exit 3).
func (a *Agent) watchScript(ctx context.Context, ev chan<- string) {
	for ctx.Err() == nil {
		if !a.personalNow() {
			// Only a personal login watches; `--personal` may come later.
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Minute):
			}
			continue
		}
		script := a.sleepWatchScript()
		if script == "" {
			return
		}
		cmd := exec.CommandContext(ctx, script)
		if err := prepCmd(ctx, cmd); err != nil {
			log.Printf("sleepwatch: %v", err)
			return
		}
		out, err := cmd.StdoutPipe()
		if err != nil {
			return
		}
		if err := cmd.Start(); err != nil {
			log.Printf("sleepwatch: %v", err)
			return
		}
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			switch line := strings.TrimSpace(sc.Text()); line {
			case "sleep", "wake":
				select {
				case ev <- line:
				case <-ctx.Done():
				}
			}
		}
		err = cmd.Wait()
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 3 {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Minute):
		}
	}
}

// watchClock sends a wake when the wall clock outran the monotonic one —
// the machine slept between two ticks.
func watchClock(ctx context.Context, ev chan<- string, tick time.Duration) {
	t := time.NewTicker(tick)
	defer t.Stop()
	prev := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		now := time.Now()
		if slept(prev, now) {
			select {
			case ev <- "wake":
			case <-ctx.Done():
				return
			}
		}
		prev = now
	}
}

// slept: between prev and now the wall clock moved sleepGap more than the
// monotonic clock, which stands still while the machine sleeps.
func slept(prev, now time.Time) bool {
	return now.Round(0).Sub(prev.Round(0))-now.Sub(prev) > sleepGap
}

// sleepLoop acts on sleep / wake events. It starts by clearing a sleep flag a
// previous run left behind.
func (a *Agent) sleepLoop(ctx context.Context, ev <-chan string) {
	asleep := false
	leave := a.personalNow() // a reboot from asleep: clear what is left
	for {
		if leave && a.sleepLeave(ctx) {
			leave, asleep = false, false
		}
		var retry <-chan time.Time
		if leave {
			retry = time.After(time.Minute) // the hub was out: try again
		}
		select {
		case <-ctx.Done():
			return
		case <-retry:
		case e := <-ev:
			switch {
			case e == "sleep" && a.personalNow():
				a.sleepEnter(ctx)
				asleep = true
			case e == "wake" && (asleep || a.personalNow()):
				leave = true
			}
		}
	}
}

// sleepEnter flags the machine and warns the person — one quick try each: the
// machine is going down in seconds.
func (a *Agent) sleepEnter(ctx context.Context) {
	if err := a.nodePost(ctx, "/v1/node/maintenance", map[string]any{"action": "enter", "reason": "sleep"}, 5*time.Second); err != nil {
		log.Printf("sleepwatch: maintenance enter: %v", err)
	}
	n := a.lastSessions.Load()
	if n <= 0 {
		return
	}
	host, _ := os.Hostname()
	if i := strings.IndexByte(host, '.'); i > 0 {
		host = host[:i]
	}
	body := map[string]any{"kind": "notify", "title": host + " 要睡了",
		"body": fmt.Sprintf("还有 %d 个会话在跑：睡着时它们会停下，醒来接着跑。这台已标「维护中」，醒来自动恢复。", n)}
	if err := a.nodePost(ctx, "/v1/node/client/actions", body, 5*time.Second); err != nil {
		log.Printf("sleepwatch: notify: %v", err)
	}
}

// sleepLeave clears the sleep flag, retrying while the network comes back;
// true once the hub answered.
func (a *Agent) sleepLeave(ctx context.Context) bool {
	for i := 0; i < wakeTries; i++ {
		err := a.nodePost(ctx, "/v1/node/maintenance", map[string]any{"action": "leave", "if_reason": "sleep"}, 10*time.Second)
		if err == nil {
			return true
		}
		if i == wakeTries-1 {
			log.Printf("sleepwatch: maintenance leave: %v", err)
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(a.wakeRetry()):
		}
	}
	return false
}

func (a *Agent) wakeRetry() time.Duration {
	if a.cfg.SleepRetry > 0 {
		return a.cfg.SleepRetry
	}
	return wakeRetry
}

// nodePost POSTs body to the hub with this node's token.
func (a *Agent) nodePost(ctx context.Context, path string, body any, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.HubURL+path, bytes.NewReader(b))
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
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return errors.New("HTTP " + resp.Status + ": " + strings.TrimSpace(string(msg)))
	}
	return nil
}
