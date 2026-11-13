package store

// The 2026-11-13 outage as a test (task N9GH): a systemd-networkd restart on
// the box left every OPEN Postgres connection silently dropped — no reply, no
// error, no RST — while new connections worked. The hub's requests, /readyz
// included, then hung ~15 minutes on the kernel's retransmission timer.
//
// blackholeProxy sits between the store and Postgres and can do exactly that
// to the connections it carries: freeze() keeps each one open and swallows
// whatever either side sends; a connection made afterwards is forwarded as
// usual. The test runs on the Postgres leg only (CI's tokenledger job). The
// kernel options (pgnet: keepalive, TCP_USER_TIMEOUT) cannot be shown through
// a userspace proxy — its own kernel acknowledges everything — so this pins
// the hub's half: /readyz answers inside its budget and comes back on a fresh
// connection, a statement with no deadline of its own ends at the default
// one, and the dead connection is never handed out again. pgnet's own test
// pins the socket options; deploy/aws/k3s-box/db-blackhole-drill.sh does the
// real thing with iptables on the box.

import (
	"context"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type blackholeProxy struct {
	ln       net.Listener
	upstream string

	mu     sync.Mutex
	gen    int // connections accepted before freeze()'s generation are frozen
	frozen int
	conns  []net.Conn
}

func newBlackholeProxy(t *testing.T, upstream string) *blackholeProxy {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &blackholeProxy{ln: ln, upstream: upstream, gen: 1}
	t.Cleanup(p.close)
	go p.serve()
	return p
}

func (p *blackholeProxy) serve() {
	for {
		c, err := p.ln.Accept()
		if err != nil {
			return
		}
		u, err := net.Dial("tcp", p.upstream)
		if err != nil {
			c.Close()
			continue
		}
		p.mu.Lock()
		gen := p.gen
		p.conns = append(p.conns, c, u)
		p.mu.Unlock()
		go p.pipe(c, u, gen)
		go p.pipe(u, c, gen)
	}
}

// pipe copies src to dst until the connection's generation is frozen; from
// then on it reads and drops everything — the peer sees silence, never an
// error.
func (p *blackholeProxy) pipe(src, dst net.Conn, gen int) {
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			p.mu.Lock()
			dead := gen <= p.frozen
			p.mu.Unlock()
			if !dead {
				if _, werr := dst.Write(buf[:n]); werr != nil {
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}

// freeze blackholes every connection made so far.
func (p *blackholeProxy) freeze() {
	p.mu.Lock()
	p.frozen = p.gen
	p.gen++
	p.mu.Unlock()
}

func (p *blackholeProxy) close() {
	p.ln.Close()
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range p.conns {
		c.Close()
	}
}

func TestBlackholedConnectionsRecover(t *testing.T) {
	if os.Getenv(envDBURL) == "" {
		t.Skip("the Postgres leg only (CCQUOTA_DB_URL)")
	}
	t.Setenv(envStatementTimeout, "3s")
	u, err := url.Parse(dbURL(filepath.Join(t.TempDir(), "blackhole.db")))
	if err != nil {
		t.Fatal(err)
	}
	upstream := u.Host
	if u.Port() == "" {
		upstream = net.JoinHostPort(u.Hostname(), "5432")
	}
	px := newBlackholeProxy(t, upstream)
	u.Host = px.ln.Addr().String()
	s, err := openStore(postgresDialect, u.String(), "postgres via the blackhole proxy")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	s.read.SetMaxOpenConns(2)
	ctx := context.Background()

	write := func(c context.Context) error {
		return s.TouchDeployProbe(c, time.Now(), "blackhole")
	}
	read := func(c context.Context) error {
		var n int
		return s.read.QueryRowContext(c, `SELECT COUNT(*) FROM rollup_meta`).Scan(&n)
	}
	// warm every pool: the writer, the readers and the readiness probe each
	// hold an open connection the freeze will catch
	if err := write(ctx); err != nil {
		t.Fatal(err)
	}
	if err := read(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.Ready(ctx); err != nil {
		t.Fatal(err)
	}

	px.freeze()
	t0 := time.Now()

	// /readyz answers inside its budget even though its connection is dead
	r0 := time.Now()
	err = s.Ready(ctx)
	if took := time.Since(r0); took > readyBudget+time.Second {
		t.Fatalf("Ready on a blackholed connection took %v (budget %v)", took, readyBudget)
	}
	t.Logf("first Ready after the freeze: %v", err)

	// ...and reads ready again on a fresh connection well inside a minute
	for {
		rctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err := s.Ready(rctx)
		cancel()
		if err == nil {
			break
		}
		if time.Since(t0) > 60*time.Second {
			t.Fatalf("not ready 60 s after the freeze: %v", err)
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Logf("ready again after %v", time.Since(t0).Round(time.Millisecond))

	// a write with no deadline of its own comes back inside the default one
	// instead of hanging on the dead writer connection: database/sql's
	// pre-statement ping fails at the deadline, the connection is thrown away
	// and the write runs on a fresh one (or fails — never hangs)
	w0 := time.Now()
	werr := write(context.Background())
	if took := time.Since(w0); took > 6*time.Second {
		t.Fatalf("a write on the blackholed writer took %v (statement deadline 3s)", took)
	}
	t.Logf("first write after the freeze: %v in %v", werr, time.Since(w0).Round(time.Millisecond))
	// the dead connections are evicted: the pools serve again on new ones
	for {
		werr := write(context.Background())
		rerr := read(context.Background())
		if werr == nil && rerr == nil {
			break
		}
		if time.Since(t0) > 60*time.Second {
			t.Fatalf("still failing 60 s after the freeze: write %v, read %v", werr, rerr)
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Logf("serving again after %v", time.Since(t0).Round(time.Millisecond))
}
