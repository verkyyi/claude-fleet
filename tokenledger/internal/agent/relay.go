package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent half of node-to-node relays (claude-fleet#1421, EPIC #1419 C2).
//
// claude-fleet's scripts cannot hold the hub's token, and should not dial the
// network from a child's ship path anyway. So they talk to the hub through
// THIS agent, over files, through one claude-fleet script
// (bin/fleet-hub-node.sh) that owns every path and every rule:
//
//   - outbox: a report or message for a worker on another machine is a JSON
//     file (control.Relay) the script drops in a directory. The agent sends
//     each one as a TypeRelay and deletes it when the hub acks — the hub has
//     stored it then. A refusal moves it to refused/; anything unanswered is
//     sent again, so a hub that is down only delays it.
//   - inbox: a relay the hub pushes down is handed to `fleet-hub-node.sh
//     deliver` on stdin; its exit code is the answer (0 applied, 75 try again
//     later, anything else refused for good).
//   - worker map: each TypeWorkers push is written, atomically, as the TSV
//     claude-fleet's fleet_worker_locate reads (`<worker_id>\t<node>\t<origin
//     worker_id>`), so routing never asks the network.
//
// A login without that script (no claude-fleet, or an install older than
// #1421) never lists CapRelay, so the hub sends it none of this.

// fleetHubNodeScript is the one claude-fleet entry point for relays, relative
// to the login's home.
var fleetHubNodeScript = filepath.Join(".claude", "fleet", "bin", "fleet-hub-node.sh")

// relayCommand is the injection point for tests, like fleetCommand.
var relayCommand = exec.CommandContext

// Relay pacing. Variables so tests can shrink them.
var (
	// relayPollEvery is how often the outbox is listed: a report should
	// leave within a second or two of being written.
	relayPollEvery = 1 * time.Second
	// relayResendAfter is how long a sent, unacked outbox file waits before
	// it is sent again.
	relayResendAfterAgent = 30 * time.Second
)

// relayDeliverTimeout bounds one inbox apply: a ledger append plus one
// delivery into a pane.
const relayDeliverTimeout = 45 * time.Second

// relayExitRetry is the deliver script's "not now" (EX_TEMPFAIL).
const relayExitRetry = 75

// relayPaths is where claude-fleet keeps the outbox and the worker map.
type relayPaths struct {
	script  string
	outbox  string
	workers string
}

// relayState is the outbox's in-flight table, kept across reconnects so a
// file sent just before a drop is resent on the next link, not twice on this.
type relayState struct {
	mu       sync.Mutex
	inflight map[string]relayInflight // relay id → file + when it was sent
}

type relayInflight struct {
	file string
	at   time.Time
}

// relaySetup asks claude-fleet where its relay files live. ok false when the
// login has no relay-capable claude-fleet.
func relaySetup(ctx context.Context, home string) (relayPaths, bool) {
	script := filepath.Join(home, fleetHubNodeScript)
	if _, err := os.Stat(script); err != nil {
		return relayPaths{}, false
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := relayCommand(ctx, script, "paths").Output()
	if err != nil {
		return relayPaths{}, false
	}
	p := relayPaths{script: script}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		k, v, _ := strings.Cut(sc.Text(), "\t")
		switch k {
		case "outbox":
			p.outbox = v
		case "workers":
			p.workers = v
		}
	}
	if !filepath.IsAbs(p.outbox) || !filepath.IsAbs(p.workers) {
		return relayPaths{}, false
	}
	return p, true
}

func (a *Agent) relays() *relayState {
	a.relayOnce.Do(func() { a.relay = &relayState{inflight: map[string]relayInflight{}} })
	return a.relay
}

// relayOutbox runs for one connection: it sends what claude-fleet left in the
// outbox until ctx ends.
func (a *Agent) relayOutbox(ctx context.Context, conn *websocket.Conn, p relayPaths) {
	st := a.relays()
	st.mu.Lock()
	// A new link: whatever was in flight on the last one is resent now.
	st.inflight = map[string]relayInflight{}
	st.mu.Unlock()
	t := time.NewTicker(relayPollEvery)
	defer t.Stop()
	for {
		a.relayOutboxOnce(ctx, conn, p)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (a *Agent) relayOutboxOnce(ctx context.Context, conn *websocket.Conn, p relayPaths) {
	ents, err := os.ReadDir(p.outbox)
	if err != nil {
		return
	}
	names := []string{}
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") && !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names) // oldest first: the names start with a timestamp
	st := a.relays()
	now := time.Now()
	for _, n := range names {
		file := filepath.Join(p.outbox, n)
		raw, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		var r control.Relay
		if err := json.Unmarshal(raw, &r); err != nil || r.ID == "" {
			relayQuarantine(p, file, "not a relay: unreadable JSON or no id")
			continue
		}
		st.mu.Lock()
		f, sent := st.inflight[r.ID]
		st.mu.Unlock()
		if sent && now.Sub(f.at) < relayResendAfterAgent {
			continue
		}
		r.FromNode = "" // the hub names the sender, never the sender itself
		m, err := control.New(control.TypeRelay, r)
		if err != nil {
			relayQuarantine(p, file, err.Error())
			continue
		}
		m.OpID = r.ID
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		err = wsjson.Write(wctx, conn, m)
		cancel()
		if err != nil {
			return // the link is gone; the next one resends
		}
		st.mu.Lock()
		st.inflight[r.ID] = relayInflight{file: file, at: now}
		st.mu.Unlock()
	}
}

// relayAcked settles an outbox file the hub has stored. ok false when opID
// is not an outbox relay (an account-op ack, say).
func (a *Agent) relayAcked(opID string) bool {
	st := a.relays()
	st.mu.Lock()
	f, ok := st.inflight[opID]
	delete(st.inflight, opID)
	st.mu.Unlock()
	if ok {
		_ = os.Remove(f.file)
	}
	return ok
}

// relayRefused settles an outbox file the hub refused for good: kept under
// refused/ with the reason beside it, never sent again.
func (a *Agent) relayRefused(p relayPaths, opID string, e *control.Error) bool {
	st := a.relays()
	st.mu.Lock()
	f, ok := st.inflight[opID]
	delete(st.inflight, opID)
	st.mu.Unlock()
	if !ok {
		return false
	}
	why := "refused"
	if e != nil {
		why = e.Code + ": " + e.Message
	}
	log.Printf("relay %s: hub refused it: %s", opID, why)
	relayQuarantine(p, f.file, why)
	return true
}

func relayQuarantine(p relayPaths, file, why string) {
	dir := filepath.Join(p.outbox, "refused")
	if os.MkdirAll(dir, 0o700) != nil {
		_ = os.Remove(file)
		return
	}
	dst := filepath.Join(dir, filepath.Base(file))
	if os.Rename(file, dst) != nil {
		_ = os.Remove(file)
		return
	}
	_ = os.WriteFile(dst+".why", []byte(why+"\n"), 0o600)
}

// relayDeliver applies one relay the hub pushed, through claude-fleet, and
// answers.
func (a *Agent) relayDeliver(ctx context.Context, conn *websocket.Conn, p relayPaths, m control.Message) {
	res := control.RelayResult{}
	var r control.Relay
	if err := json.Unmarshal(m.Payload, &r); err != nil || r.ID == "" {
		res.ID, res.Detail = m.OpID, "malformed relay"
	} else {
		res.ID = r.ID
		res.OK, res.Retry, res.Detail = runRelayDeliver(ctx, p, m.Payload)
	}
	out, err := control.New(control.TypeRelayResult, res)
	if err != nil {
		return
	}
	out.OpID = m.OpID
	wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
	defer cancel()
	_ = wsjson.Write(wctx, conn, out)
}

func runRelayDeliver(ctx context.Context, p relayPaths, payload []byte) (ok, retry bool, detail string) {
	ctx, cancel := context.WithTimeout(ctx, relayDeliverTimeout)
	defer cancel()
	cmd := relayCommand(ctx, p.script, "deliver")
	cmd.Stdin = bytes.NewReader(payload)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	detail = lastLine(stderr.String())
	if err == nil {
		return true, false, detail
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) && ee.ExitCode() == relayExitRetry {
		return false, true, detail
	}
	if ctx.Err() != nil {
		// Killed mid-apply: it may or may not have landed. The script is
		// idempotent on the relay id, so pushing it again is safe.
		return false, true, "timed out"
	}
	if detail == "" {
		detail = err.Error()
	}
	return false, false, detail
}

func lastLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		s = s[i+1:]
	}
	if len(s) > 300 {
		s = s[:300]
	}
	return s
}

// relayWorkers writes the hub's worker map as claude-fleet's cache file.
func relayWorkers(p relayPaths, m control.Message) error {
	var w control.Workers
	if err := json.Unmarshal(m.Payload, &w); err != nil {
		return err
	}
	var b strings.Builder
	for _, r := range w.Rows {
		if bad(r.WorkerID) || bad(r.Node) || bad(r.OriginWID) || r.WorkerID == "" {
			continue
		}
		fmt.Fprintf(&b, "%s\t%s\t%s\n", r.WorkerID, r.Node, r.OriginWID)
	}
	if err := os.MkdirAll(filepath.Dir(p.workers), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p.workers), ".hub-workers-*")
	if err != nil {
		return err
	}
	if _, err := tmp.WriteString(b.String()); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), p.workers)
}

// bad is a field that would break the TSV.
func bad(s string) bool { return strings.ContainsAny(s, "\t\n\r") }
