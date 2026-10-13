package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The agent half of the chat relay (claude-fleet#3644, EPIC #3642 C2) — the SSH
// relay's shape (node_ssh_relay.go) with two differences: the stream is admitted
// only after the hub's X-Fleet-Person statement verifies with THIS login's token
// hash, and the one place it reaches is the login's conversation socket,
// $FLEET_CONF_DIR/webchat/chat.sock (bin/fleet-webchat.sh serve), reached AS the
// login. Nothing in the hub's request names a target.

// ChatPipeCmd is the subcommand `ccquota chat-pipe` (cmd/ccquota): run as the
// login, it connects to that login's socket and copies stdio both ways.
const ChatPipeCmd = "chat-pipe"

const (
	// chatRelayMaxPerLogin bounds one login's relays at once on this agent —
	// the hub's per-login cap (Server.ChatRelayMaxPerLogin) is the first one,
	// this the backstop should a hub ask for more.
	chatRelayMaxPerLogin = 8
	// chatRelayHelloTimeout bounds the wait for the hub's first frame.
	chatRelayHelloTimeout = 10 * time.Second
	// chatPipeReady is the one byte the helper writes once it is connected,
	// so a socket nobody listens on is told apart from a stream that ended.
	chatPipeReady = 0x01
)

// chatSockPath is the login's conversation socket under its conf dir.
func chatSockPath(confDir string) string {
	return filepath.Join(confDir, "webchat", "chat.sock")
}

// ownConfDir is this process's $FLEET_CONF_DIR, else ~/.config/claude-fleet.
func ownConfDir() string {
	if d := os.Getenv("FLEET_CONF_DIR"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "claude-fleet")
}

// chatLogin is the login this agent serves: its tenant's, else its own user.
func (a *Agent) chatLogin() string {
	if a.cfg.RunAs != nil {
		return a.cfg.RunAs.Login
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return ""
}

// chatSlots counts this agent's relays in flight.
type chatSlots struct {
	mu sync.Mutex
	n  int
}

func (c *chatSlots) take() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.n >= chatRelayMaxPerLogin {
		return false
	}
	c.n++
	return true
}

func (c *chatSlots) give() {
	c.mu.Lock()
	c.n--
	c.mu.Unlock()
}

// chatRelayDataURL is the data stream's ws(s) URL for relay id.
func chatRelayDataURL(hub, id string) string {
	u := nodeURL(hub)
	return strings.TrimSuffix(u, control.Path) + control.ChatRelayDataPath + "?id=" + url.QueryEscape(id)
}

// openChatRelay serves one TypeChatRelayOpen, bound to the control channel's ctx.
func (a *Agent) openChatRelay(ctx context.Context, m control.Message) {
	var ro control.ChatRelayOpen
	if err := json.Unmarshal(m.Payload, &ro); err != nil || ro.RelayID == "" {
		return
	}
	login := a.chatLogin()
	if login == "" || ro.Login != login {
		// Not this login's: never dial, never touch a socket.
		log.Printf("chat relay %s: for login %q, this agent serves %q: refused", short(ro.RelayID), ro.Login, login)
		return
	}
	if !a.chatRelays.take() {
		log.Printf("chat relay %s: %d relays already open for %s: refused", short(ro.RelayID), chatRelayMaxPerLogin, login)
		return
	}
	defer a.chatRelays.give()

	dctx, cancel := context.WithTimeout(ctx, sshRelayDialTimeout)
	defer cancel()
	u := chatRelayDataURL(a.cfg.HubURL, ro.RelayID)
	ws, _, err := websocket.Dial(dctx, u, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization":  []string{a.authValue(http.MethodGet, u)},
			"X-Relay-Secret": []string{ro.Secret},
		},
	})
	if err != nil {
		log.Printf("chat relay %s: dial the hub: %v", short(ro.RelayID), err)
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(1 << 20)

	// The first frame is the hub's statement of who this is for; nothing
	// reaches the socket before it verifies.
	hctx, hcancel := context.WithTimeout(ctx, chatRelayHelloTimeout)
	typ, raw, err := ws.Read(hctx)
	hcancel()
	var hello control.ChatRelayHello
	if err == nil && (typ != websocket.MessageText || json.Unmarshal(raw, &hello) != nil) {
		err = errors.New("first frame is not the X-Fleet-Person hello")
	}
	var who *control.ChatPerson
	if err == nil {
		who, err = control.VerifyChatPerson(hello.Person, control.ChatTokenHash(a.cfg.Token), login, ro.RelayID, time.Now())
	}
	if err != nil {
		log.Printf("chat relay %s: %v: refused", short(ro.RelayID), err)
		ws.Close(websocket.StatusPolicyViolation, "X-Fleet-Person refused")
		return
	}

	sock, err := dialChatSock(dctx)
	if err != nil {
		log.Printf("chat relay %s: %s's conversation socket: %v", short(ro.RelayID), login, err)
		ws.Close(websocket.StatusInternalError, "the conversation service is not running for this login")
		return
	}
	cancel()
	log.Printf("chat relay %s: %s → %s's conversation", short(ro.RelayID), who.Person, login)
	splice(ctx, ws, sock)
}

// dialChatSock reaches ctx's login's socket. A plain agent IS the login and
// dials it; a machine tenant runs `ccquota chat-pipe` as the login (prepCmd: the
// kernel, not this process, decides it may connect — a seat could not anyway).
func dialChatSock(ctx context.Context) (io.ReadWriteCloser, error) {
	if runAsOf(ctx) == nil {
		if machineStrict.Load() > 0 && os.Geteuid() == 0 {
			return nil, errNoLogin
		}
		var d net.Dialer
		return d.DialContext(ctx, "unix", chatSockPath(ownConfDir()))
	}
	return startChatPipe(ctx)
}

// chatPipe is the helper process as one stream: reads are its stdout, writes its
// stdin; Close ends it.
type chatPipe struct {
	cmd  *exec.Cmd
	in   io.WriteCloser
	out  *bufio.Reader
	once sync.Once
}

func (p *chatPipe) Read(b []byte) (int, error)  { return p.out.Read(b) }
func (p *chatPipe) Write(b []byte) (int, error) { return p.in.Write(b) }
func (p *chatPipe) Close() error {
	p.once.Do(func() {
		p.in.Close()
		if p.cmd.Process != nil {
			p.cmd.Process.Kill()
		}
		p.cmd.Wait()
	})
	return nil
}

func startChatPipe(ctx context.Context) (io.ReadWriteCloser, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	// No argument but the subcommand: the helper derives the one path itself.
	cmd := exec.Command(self, ChatPipeCmd)
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
	ready := make(chan error, 1)
	go func() {
		b, err := p.out.ReadByte()
		if err == nil && b != chatPipeReady {
			err = fmt.Errorf("unexpected first byte %#x", b)
		}
		ready <- err
	}()
	select {
	case err = <-ready:
	case <-ctx.Done():
		err = ctx.Err()
	}
	if err != nil {
		p.Close()
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return nil, errors.New(msg)
		}
		return nil, err
	}
	return p, nil
}

// limitedWriter keeps the first n bytes written to it.
type limitedWriter struct {
	w io.Writer
	n int
}

func (l *limitedWriter) Write(b []byte) (int, error) {
	if l.n > 0 {
		k := len(b)
		if k > l.n {
			k = l.n
		}
		l.w.Write(b[:k])
		l.n -= k
	}
	return len(b), nil
}

// RunChatPipe is `ccquota chat-pipe`: connect to this login's conversation
// socket, say ready, then copy stdin → socket and socket → stdout until either
// ends. It takes no argument — the path is the login's own, never a caller's.
func RunChatPipe(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) != 0 {
		return errors.New("chat-pipe takes no arguments")
	}
	conf := ownConfDir()
	if conf == "" {
		return errors.New("no home to find the conversation socket under")
	}
	c, err := net.DialTimeout("unix", chatSockPath(conf), sshRelayDialTimeout)
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err := stdout.Write([]byte{chatPipeReady}); err != nil {
		return err
	}
	// stdin's end half-closes the socket; the answer still drains to stdout,
	// and stdout is written by this goroutine alone.
	go func() {
		io.Copy(c, stdin)
		if uc, ok := c.(*net.UnixConn); ok {
			uc.CloseWrite()
		} else {
			c.Close()
		}
	}()
	io.Copy(stdout, c)
	return nil
}
