package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent half of the terminal relay (claude-fleet#3838, EPIC #3836 C1) — the
// chat relay's road (node_chat_relay.go: the same dial, the same first-frame
// rule) to a different end: the stream is admitted only after the hub's
// terminal grant verifies with THIS login's token hash, for this login, this
// relay and a target word; then `ccquota term-pty` runs AS the login (prepCmd)
// and opens the terminal there. Frames: binary = keystrokes / output, text =
// the bounded controls (control.TermControl). Each relay holds its own PTY and
// its own grouped tmux view; neither outlives the stream.

const (
	// termRelayMaxPerLogin bounds one login's terminals at once on this agent
	// — the hub's per-person cap is the first one, this the backstop.
	termRelayMaxPerLogin = 4
	// termGrantSpentTTL is how long a spent relay id is remembered: longer
	// than a grant can live.
	termGrantSpentTTL = 2 * control.TermGrantMaxTTL
)

// relaySlots counts one kind of relay in flight, up to max.
type relaySlots struct {
	mu sync.Mutex
	n  int
}

func (c *relaySlots) take(max int) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.n >= max {
		return false
	}
	c.n++
	return true
}

func (c *relaySlots) give() {
	c.mu.Lock()
	c.n--
	c.mu.Unlock()
}

func (c *relaySlots) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

// spentGrants remembers every relay id a terminal was opened for: a grant is
// single-use, so an id seen once is refused again for as long as any grant
// for it could still hold.
type spentGrants struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func (g *spentGrants) spend(id string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.seen == nil {
		g.seen = map[string]time.Time{}
	}
	for k, at := range g.seen {
		if now.Sub(at) > termGrantSpentTTL {
			delete(g.seen, k)
		}
	}
	if _, ok := g.seen[id]; ok {
		return false
	}
	g.seen[id] = now
	return true
}

// termHelper is one running `ccquota term-pty`: writes go to its stdin (the
// framed protocol), reads are the terminal's output. Close hangs it up.
type termHelper interface {
	io.ReadWriteCloser
}

// startTermHelper starts the helper as the login. A variable only so the tests
// can run the helper in-process with a throwaway command.
var startTermHelper = func(ctx context.Context, view, target string, cols, rows int) (termHelper, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	args := []string{TermPtyCmd, "--view", view, "--target", target}
	if cols > 0 && rows > 0 {
		args = append(args, "--cols", fmt.Sprint(cols), "--rows", fmt.Sprint(rows))
	}
	cmd := exec.Command(self, args...)
	if err := prepCmd(ctx, cmd); err != nil {
		return nil, err
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	outR, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderr, n: 512}
	if err := cmd.Start(); err != nil {
		return nil, startWhy(ctx, cmd, err)
	}
	p := &chatPipe{cmd: cmd, in: in, out: bufio.NewReader(outR)}
	b, err := p.out.ReadByte()
	if err == nil && b != termPtyReady {
		err = fmt.Errorf("unexpected first byte %#x", b)
	}
	if err != nil {
		p.Close()
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return nil, errors.New(msg)
		}
		return nil, err
	}
	return &termProc{chatPipe: p}, nil
}

// termProc closes the helper gently: its stdin first (it hangs the terminal
// up and its tmux view goes), then, past termPtyHangup, the kill chatPipe does.
type termProc struct {
	*chatPipe
	once sync.Once
}

func (t *termProc) Close() error {
	t.once.Do(func() {
		t.in.Close()
		done := make(chan struct{})
		go func() { t.cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(termPtyHangup + time.Second):
			if t.cmd.Process != nil {
				t.cmd.Process.Kill()
			}
			<-done
		}
	})
	return nil
}

// openTermRelay serves one TypeTermOpen, bound to the control channel's ctx.
func (a *Agent) openTermRelay(ctx context.Context, m control.Message) {
	var ro control.TermOpen
	if err := json.Unmarshal(m.Payload, &ro); err != nil || ro.RelayID == "" {
		return
	}
	login := a.chatLogin()
	if login == "" || ro.Login != login {
		log.Printf("term relay %s: for login %q, this agent serves %q: refused", short(ro.RelayID), ro.Login, login)
		return
	}
	if !a.termRelays.take(termRelayMaxPerLogin) {
		log.Printf("term relay %s: %d terminals already open for %s: refused", short(ro.RelayID), termRelayMaxPerLogin, login)
		return
	}
	defer a.termRelays.give()

	dctx, cancel := context.WithTimeout(ctx, sshRelayDialTimeout)
	defer cancel()
	ws, err := a.dialRelayData(dctx, control.TermDataPath, ro.RelayID, ro.Secret)
	if err != nil {
		log.Printf("term relay %s: dial the hub: %v", short(ro.RelayID), err)
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(control.TermFrameMax)

	// The first frame is the hub's grant; no terminal opens before it verifies.
	var hello control.TermRelayHello
	var g *control.TermGrant
	if err = readRelayHello(ctx, ws, &hello); err == nil {
		g, err = control.VerifyTermGrant(hello.Grant, control.ChatTokenHash(a.cfg.Token), login, ro.RelayID, time.Now())
	}
	if err == nil && !a.termSpent.spend(ro.RelayID, time.Now()) {
		err = errors.New("terminal grant: already used")
	}
	if err != nil {
		log.Printf("term relay %s: %v: refused", short(ro.RelayID), err)
		ws.Close(websocket.StatusPolicyViolation, "terminal grant refused")
		return
	}
	cancel()
	// The view's id: this relay's, so two browsers never share one view.
	view := "web-" + short(ro.RelayID)
	h, err := startTermHelper(ctx, view, g.Target, 0, 0)
	if err != nil {
		log.Printf("term relay %s: %s's terminal: %v", short(ro.RelayID), login, err)
		ws.Close(websocket.StatusInternalError, "the terminal could not start for this login")
		return
	}
	log.Printf("term relay %s: %s → %s's %s", short(ro.RelayID), g.Person, login, g.Target)
	why := spliceTerm(ctx, ws, h)
	log.Printf("term relay %s: ended: %s", short(ro.RelayID), why)
}

// spliceTerm moves frames between the hub's stream and the helper until either
// ends or ctx does, then hangs the terminal up and closes the stream.
func spliceTerm(ctx context.Context, ws *websocket.Conn, h termHelper) string {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var mu sync.Mutex
	why := ""
	end := func(w string) {
		mu.Lock()
		if why == "" {
			why = w
		}
		mu.Unlock()
		cancel()
	}
	write := func(typ websocket.MessageType, b []byte) error {
		wctx, wcancel := context.WithTimeout(ctx, 30*time.Second)
		defer wcancel()
		return ws.Write(wctx, typ, b)
	}
	if b, _ := json.Marshal(control.TermControl{T: "ready"}); write(websocket.MessageText, b) != nil {
		h.Close()
		return "the hub went before the terminal was ready"
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { // terminal → hub
		defer wg.Done()
		buf := make([]byte, control.TermFrameMax)
		for {
			n, err := h.Read(buf)
			if n > 0 {
				if werr := write(websocket.MessageBinary, buf[:n]); werr != nil {
					end("the hub stopped reading")
					return
				}
			}
			if err != nil {
				end("the terminal ended")
				return
			}
		}
	}()
	go func() { // hub → terminal
		defer wg.Done()
		for {
			typ, raw, err := ws.Read(ctx)
			if err != nil {
				end("the hub closed the stream")
				return
			}
			var frame []byte
			switch typ {
			case websocket.MessageBinary:
				frame = termFrame(termFrameData, raw)
			default:
				cols, rows, perr := control.ParseTermResize(raw)
				if perr != nil {
					end("malformed control: " + perr.Error())
					return
				}
				frame = termResizeFrame(cols, rows)
			}
			if _, err := h.Write(frame); err != nil {
				end("the terminal stopped reading")
				return
			}
		}
	}()
	<-ctx.Done()
	h.Close() // hang up: the helper's read ends, so does the copy
	ws.Close(websocket.StatusNormalClosure, "")
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if why == "" {
		why = "the link dropped"
	}
	return why
}
