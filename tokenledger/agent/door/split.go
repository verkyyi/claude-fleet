package door

import (
	"bufio"
	"net"
	"sync"
	"time"
)

// SplitTLS shares one port between the browser listener (TLS) and the homes'
// relay dial-back (plain ws): a connection whose first byte is a TLS handshake
// record (0x16) goes to the first listener, any other to the second (XX79 — a
// door whose firewall opens only the relay's port carries both on it). A
// connection that says nothing within the handshake timeout is closed.
func SplitTLS(ln net.Listener, timeout time.Duration) (tlsLn, plainLn net.Listener) {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	s := &splitter{ln: ln, timeout: timeout, done: make(chan struct{})}
	s.tls = &splitLn{s: s, ch: make(chan net.Conn)}
	s.plain = &splitLn{s: s, ch: make(chan net.Conn)}
	go s.run()
	return s.tls, s.plain
}

type splitter struct {
	ln         net.Listener
	timeout    time.Duration
	tls, plain *splitLn
	once       sync.Once
	done       chan struct{}
	err        error
}

func (s *splitter) run() {
	for {
		c, err := s.ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			s.close(err)
			return
		}
		go s.route(c)
	}
}

func (s *splitter) route(c net.Conn) {
	_ = c.SetReadDeadline(time.Now().Add(s.timeout))
	br := bufio.NewReader(c)
	b, err := br.Peek(1)
	_ = c.SetReadDeadline(time.Time{})
	if err != nil {
		c.Close()
		return
	}
	to := s.plain
	if b[0] == 0x16 {
		to = s.tls
	}
	select {
	case to.ch <- &peekedConn{Conn: c, r: br}:
	case <-s.done:
		c.Close()
	}
}

func (s *splitter) close(err error) {
	s.once.Do(func() {
		s.err = err
		close(s.done)
		s.ln.Close()
	})
}

type splitLn struct {
	s  *splitter
	ch chan net.Conn
}

func (l *splitLn) Accept() (net.Conn, error) {
	select {
	case c := <-l.ch:
		return c, nil
	case <-l.s.done:
		if l.s.err != nil {
			return nil, l.s.err
		}
		return nil, net.ErrClosed
	}
}

// Close closes the shared port: both halves end together.
func (l *splitLn) Close() error   { l.s.close(net.ErrClosed); return nil }
func (l *splitLn) Addr() net.Addr { return l.s.ln.Addr() }

// peekedConn reads what was peeked first, then the connection.
type peekedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *peekedConn) Read(p []byte) (int, error) { return c.r.Read(p) }
