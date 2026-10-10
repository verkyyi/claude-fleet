package agent

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/user"
	"runtime"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// One node program per machine (claude-fleet#2333, EPIC #2329 C5).
//
// `ccquota agent --machine` runs as root, holds ONE control connection opened
// with the machine's own node token, and serves every login of the machine as
// a tenant: a full Agent per login (its usage scan, its fleet heartbeat, its
// reads, writes, relays and account ops), whose control channel is that
// login's lane on the shared link instead of a websocket of its own. Each
// tenant says its own hello on the lane, proving its login with its own node
// token, and every command it runs drops to its login (runas.go).
//
// The machine link refuses, on the node side too, any message for a login it
// does not carry — the hub's WRONG_LOGIN has a twin here, so an op never runs
// as the wrong login even if the hub misrouted it.

// nodeLink is one login's control channel: a websocket of its own, or its
// lane on the machine link.
type nodeLink interface {
	write(ctx context.Context, m control.Message) error
	read(ctx context.Context) (control.Message, error)
	ping(ctx context.Context) error
	// close is a clean goodbye; closeNow drops whatever is left.
	close(reason string)
	closeNow()
}

// wsLink is a plain agent's own websocket.
type wsLink struct{ c *websocket.Conn }

func (l wsLink) write(ctx context.Context, m control.Message) error { return wsjson.Write(ctx, l.c, m) }
func (l wsLink) read(ctx context.Context) (control.Message, error) {
	var m control.Message
	err := wsjson.Read(ctx, l.c, &m)
	return m, err
}
func (l wsLink) ping(ctx context.Context) error { return l.c.Ping(ctx) }
func (l wsLink) close(reason string)            { l.c.Close(websocket.StatusGoingAway, reason) }
func (l wsLink) closeNow()                      { l.c.CloseNow() }

// errLaneClosed ends a lane: the hub closed this login's session, or the
// machine link itself dropped. The tenant says its hello again after a backoff.
var errLaneClosed = errors.New("machine link: this login's lane closed")

// MachineConfig is `ccquota agent --machine`.
type MachineConfig struct {
	HubURL  string
	Token   string // the machine's own node token
	Version string
	// LiveInterval is the machine link's own heartbeat.
	LiveInterval time.Duration
	// ServicesFile is the machine daemon's state.json, whose services[] the
	// link's beat carries (claude-fleet#2526); "" = none.
	ServicesFile string
	// ServiceCtl is the daemon's script every tenant runs for the hub's
	// service_control (claude-fleet#2527): fleet-node-supervisor.py beside
	// the ccquota binary in the root runtime; "" = no service control.
	ServiceCtl string
	// Updater is the machine's updater (fleet-node-update.py beside the
	// ccquota binary), asked `versions --json` every versionsEvery for the
	// beat's 版本与更新 (claude-fleet#2798); "" = no versions reported.
	Updater string
	// Tenants is one Config per login served: its own Token (that login's
	// node token), Home, StateDir and RunAs. Fleet is forced on.
	Tenants []Config
}

// machineLink is the machine's one connection to the hub.
type machineLink struct {
	cfg MachineConfig

	mu    sync.Mutex
	conn  *websocket.Conn // nil while down
	up    chan struct{}   // closed while conn is up
	lanes map[string]*lane
	// refused is login → the hub's WRONG_LOGIN for its last hello
	// (claude-fleet#2501), carried on the link's own heartbeat.
	refused map[string]string
	// vers is the machine's last 版本与更新 reading (claude-fleet#2798),
	// refreshed off the beat — a slow updater never holds the beat up.
	vers asyncReading[control.Versions]
}

// setRefused records (why != "") or clears a login's refused hello.
func (ml *machineLink) setRefused(login, why string) {
	ml.mu.Lock()
	defer ml.mu.Unlock()
	if why == "" {
		delete(ml.refused, login)
		return
	}
	if ml.refused == nil {
		ml.refused = map[string]string{}
	}
	ml.refused[login] = why
}

// refusedNow is a copy of refused; nil when no lane is refused.
func (ml *machineLink) refusedNow() map[string]string {
	ml.mu.Lock()
	defer ml.mu.Unlock()
	if len(ml.refused) == 0 {
		return nil
	}
	out := make(map[string]string, len(ml.refused))
	for k, v := range ml.refused {
		out[k] = v
	}
	return out
}

// lane is one login on the machine link.
type lane struct {
	ml    *machineLink
	login string
	conn  *websocket.Conn
	in    chan control.Message
	done  chan struct{}
	once  sync.Once
}

func newMachineLink(cfg MachineConfig) *machineLink {
	return &machineLink{cfg: cfg, up: make(chan struct{}), lanes: map[string]*lane{}}
}

// lane opens login's lane, waiting for the link to be up.
func (ml *machineLink) lane(ctx context.Context, login string) (*lane, error) {
	for {
		ml.mu.Lock()
		up, conn := ml.up, ml.conn
		if conn != nil {
			if old := ml.lanes[login]; old != nil {
				old.shut()
			}
			l := &lane{ml: ml, login: login, conn: conn, in: make(chan control.Message, 256), done: make(chan struct{})}
			ml.lanes[login] = l
			ml.mu.Unlock()
			return l, nil
		}
		ml.mu.Unlock()
		select {
		case <-up:
		case <-ctx.Done():
			return nil, fmt.Errorf("machine link not up: %w", ctx.Err())
		}
	}
}

func (l *lane) shut() { l.once.Do(func() { close(l.done) }) }

func (l *lane) write(ctx context.Context, m control.Message) error {
	select {
	case <-l.done:
		return errLaneClosed
	default:
	}
	m.Login = l.login
	return wsjson.Write(ctx, l.conn, m)
}

func (l *lane) read(ctx context.Context) (control.Message, error) {
	select {
	case m := <-l.in:
		return m, nil
	case <-l.done:
		return control.Message{}, errLaneClosed
	case <-ctx.Done():
		return control.Message{}, ctx.Err()
	}
}

func (l *lane) ping(ctx context.Context) error {
	select {
	case <-l.done:
		return errLaneClosed
	default:
	}
	return l.conn.Ping(ctx)
}

// close leaves the lane; the link and the other logins stay up.
func (l *lane) close(string) { l.drop() }
func (l *lane) closeNow()    { l.drop() }

func (l *lane) drop() {
	l.shut()
	l.ml.mu.Lock()
	if l.ml.lanes[l.login] == l {
		delete(l.ml.lanes, l.login)
	}
	l.ml.mu.Unlock()
}

// run keeps the machine link up until ctx ends.
func (ml *machineLink) run(ctx context.Context) {
	var bo nodeBackoff
	var lastErr string
	for {
		established, err := ml.session(ctx)
		if ctx.Err() != nil {
			return
		}
		if established {
			bo.reset()
		}
		msg := "machine link closed"
		if err != nil {
			msg = "machine link: " + err.Error()
		}
		if msg != lastErr {
			log.Print(msg + "; reconnecting")
			lastErr = msg
		}
		t := time.NewTimer(bo.next())
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

func (ml *machineLink) session(ctx context.Context) (bool, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	dctx, dcancel := context.WithTimeout(ctx, nodeDialTimeout)
	defer dcancel()
	conn, _, err := websocket.Dial(dctx, nodeURL(ml.cfg.HubURL), &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + ml.cfg.Token}},
	})
	if err != nil {
		return false, err
	}
	defer conn.CloseNow()
	conn.SetReadLimit(4 << 20)

	off := false
	hello, err := control.New(control.TypeHello, control.Hello{
		HeartbeatMS:  int(ml.cfg.LiveInterval / time.Millisecond),
		AgentVersion: ml.cfg.Version,
		Capabilities: []string{control.CapMachine},
		Compute:      &off,
	})
	if err != nil {
		return false, err
	}
	if err := wsjson.Write(dctx, conn, hello); err != nil {
		return false, err
	}
	var reply control.Message
	if err := wsjson.Read(dctx, conn, &reply); err != nil {
		return false, err
	}
	if reply.Type != control.TypeWelcome {
		if reply.Error != nil {
			return false, fmt.Errorf("hub refused the machine hello: %s: %s", reply.Error.Code, reply.Error.Message)
		}
		return false, fmt.Errorf("hub answered the machine hello with %q", reply.Type)
	}
	dcancel()

	ml.mu.Lock()
	ml.conn = conn
	close(ml.up)
	ml.mu.Unlock()
	defer func() {
		ml.mu.Lock()
		ml.conn = nil
		ml.up = make(chan struct{})
		for k, l := range ml.lanes {
			l.shut()
			delete(ml.lanes, k)
		}
		ml.mu.Unlock()
	}()

	readErr := make(chan error, 1)
	go func() {
		for {
			var m control.Message
			if err := wsjson.Read(ctx, conn, &m); err != nil {
				readErr <- err
				return
			}
			ml.demux(ctx, conn, m)
		}
	}()

	beat := func() error {
		hb := machineHeartbeat(ml.cfg.Version, ml.refusedNow(), ml.cfg.ServicesFile)
		ml.fillVersions(ctx, &hb)
		m, err := control.New(control.TypeHeartbeat, hb)
		if err != nil {
			return err
		}
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		if err := wsjson.Write(wctx, conn, m); err != nil {
			return err
		}
		return conn.Ping(wctx)
	}
	if err := beat(); err != nil {
		return true, err
	}
	every := ml.cfg.LiveInterval
	if every <= 0 {
		every = DefaultLiveInterval
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			conn.Close(websocket.StatusGoingAway, "agent stopping")
			return true, nil
		case err := <-readErr:
			return true, err
		case <-t.C:
			if err := beat(); err != nil {
				return true, err
			}
		}
	}
}

// demux hands one message from the hub to its login's lane.
func (ml *machineLink) demux(ctx context.Context, conn *websocket.Conn, m control.Message) {
	if m.Login == "" {
		// The machine's own half: nothing is ever asked of it.
		if m.Type == control.TypeError && m.Error != nil {
			log.Printf("machine link: hub reported %s: %s", m.Error.Code, m.Error.Message)
		}
		return
	}
	ml.mu.Lock()
	l := ml.lanes[m.Login]
	ml.mu.Unlock()
	if l == nil {
		// Not a login this program serves: refuse, never run it as anyone.
		if m.Type != control.TypeError && m.Type != control.TypeAck {
			out := control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto, Login: m.Login,
				Error: &control.Error{Code: control.CodeWrongLogin, Message: "this machine's node program does not serve login " + m.Login}}
			wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
			_ = wsjson.Write(wctx, conn, out)
			cancel()
		}
		return
	}
	if m.Type == control.TypeError && m.Error != nil &&
		(m.Error.Code == control.CodeLinkClosed || (m.Error.Code == control.CodeWrongLogin && m.OpID == "")) {
		l.shut()
		return
	}
	select {
	case l.in <- m:
	case <-l.done:
	case <-ctx.Done():
	}
}

// machineHeartbeat is the machine link's own beat: liveness and the machine's
// load (the sampler's, with its time — claude-fleet#2798), never sessions — its logins report those on their own lanes — the
// logins whose hello the hub refused (claude-fleet#2501) and the machine
// daemon's register of login services (claude-fleet#2526).
func machineHeartbeat(version string, refused map[string]string, servicesFile string) control.Heartbeat {
	off := false
	hb := control.Heartbeat{OS: runtime.GOOS, Arch: runtime.GOARCH, NCPU: runtime.NumCPU(),
		AgentVersion: version, ObservedAt: time.Now().UTC(), Compute: &off, LoginsRefused: refused,
		Services: readServices(servicesFile)}
	hb.Hostname, _ = os.Hostname()
	if u, err := user.Current(); err == nil {
		hb.OSUser = u.Username
	}
	fillSys(&hb, processSys)
	return hb
}

// fillVersions puts the machine's last 版本与更新 into its beat
// (claude-fleet#2798), starting a fresh read when the last is versionsEvery
// old. It never waits: the first beats go out without versions.
func (ml *machineLink) fillVersions(ctx context.Context, hb *control.Heartbeat) {
	if ml.cfg.Updater == "" {
		return
	}
	updater := ml.cfg.Updater
	v, at, ok := ml.vers.get(ctx, versionsEvery, 0, false, func(ctx context.Context) (control.Versions, bool) {
		return readVersions(ctx, updater)
	})
	if ok {
		hb.Versions, hb.VersionsAt = &v, &at
	}
}

// loginToken is what a tenant's hello proves its login with; empty for a
// plain agent, whose bearer token already did.
func (a *Agent) loginToken() string {
	if a.machine == nil {
		return ""
	}
	return a.cfg.Token
}

// RunMachine is `ccquota agent --machine`: the machine link and one tenant
// per login, until ctx ends.
func RunMachine(ctx context.Context, mc MachineConfig) error {
	if mc.HubURL == "" || mc.Token == "" {
		return errors.New("machine agent: a hub URL and the machine's node token are required")
	}
	if len(mc.Tenants) == 0 {
		return errors.New("machine agent: no logins to serve")
	}
	seen := map[string]bool{}
	var agents []*Agent
	for _, tc := range mc.Tenants {
		if tc.RunAs == nil || tc.RunAs.Login == "" {
			return errors.New("machine agent: every login needs who to run as")
		}
		if seen[tc.RunAs.Login] {
			return fmt.Errorf("machine agent: login %s listed twice", tc.RunAs.Login)
		}
		seen[tc.RunAs.Login] = true
		if tc.Token == "" {
			return fmt.Errorf("machine agent: login %s has no node token", tc.RunAs.Login)
		}
		tc.HubURL, tc.Version, tc.Fleet, tc.Once = mc.HubURL, mc.Version, true, false
		tc.ServiceCtl = mc.ServiceCtl
		if tc.FleetCreds && tc.FleetCredStore == "" {
			// Root would otherwise write the login's credential files: in
			// machine mode they go to the shared proxy or nowhere.
			log.Printf("machine agent: %s: credential lease off (no credential store); set CCQUOTA_FLEET_CRED_STORE", tc.RunAs.Login)
			tc.FleetCreds = false
		}
		a, err := New(tc)
		if err != nil {
			return fmt.Errorf("machine agent: login %s: %w", tc.RunAs.Login, err)
		}
		agents = append(agents, a)
	}
	machineStrict.Add(1)
	defer machineStrict.Add(-1)
	ml := newMachineLink(mc)
	for _, a := range agents {
		registerTenant(a.cfg.RunAs)
		defer unregisterTenant(a.cfg.RunAs)
		a.machine = ml
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); ml.run(ctx) }()
	for _, a := range agents {
		wg.Add(1)
		go func(a *Agent) {
			defer wg.Done()
			if err := a.Run(ctx); err != nil && ctx.Err() == nil {
				log.Printf("machine agent: %s: %v", a.cfg.RunAs.Login, err)
			}
		}(a)
	}
	log.Printf("ccquota agent --machine %s -> %s (%d logins)", mc.Version, mc.HubURL, len(agents))
	wg.Wait()
	return nil
}
