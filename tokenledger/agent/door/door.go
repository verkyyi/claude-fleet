// Package door is the cluster door's own SSH server (A5SQ, design v2: one
// address for everyone, routed by username — docs/dev/DOOR-SIMPLIFY.md §5).
//
// A person points their SSH app at the door's one address with their own
// login as the username and their own key. The door is the SSH server for
// that connection — the username travels only inside the encryption, so
// routing by it means terminating it:
//
//  1. the book (GET EntryRoutesNodePath?home=1, the door's own token, pulled
//     every Pull) names each person whose home is a machine: their login and
//     their keys. A key that is not the username's owner's is refused before
//     any signature is asked for;
//  2. once the person's publickey signature verified, the door hands it to
//     the hub (DoorSessionPath) with a one-off key of its own; the hub checks
//     the signature itself and signs a two-minute certificate for that key —
//     one principal, the home login, loopback only;
//  3. the door opens the hub's stream to that home's entry port
//     (DoorHomePath) and logs in there with the certificate, checking the
//     home's host key against the one the hub gave — never trusting on first
//     use;
//  4. every channel and request the person opens is carried to the home and
//     back, byte for byte.
//
// The door also carries the pods' jump (claude-fleet#4193, design #4181 A2) on
// the same port: the account JumpUser, no session, and each person's key may
// open ONE kind of tunnel — direct-tcpip to their own pod's sshd
// (<svc>.<namespace>.svc.cluster.local:22) — where the pod's sshd does the
// login with that same key. bin/fleet-door-keys.py's rule, on OpenSSH's door.
//
// The door holds no key into any home: without a fresh signature of the
// person's there is no certificate. Its own host key is the door's (every
// replica the same one) — what a phone trusts once and never again.
package door

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	ssh "github.com/verkyyi/claude-fleet/tokenledger/agent/internal/xssh"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// HostKey is the door's host key (outside this module the xssh copy is
// internal: these are the only ways to make one).
type HostKey = ssh.Signer

// NewHostKey wraps a private key (ed25519, ecdsa or rsa).
func NewHostKey(k crypto.Signer) (HostKey, error) { return ssh.NewSignerFromSigner(k) }

// ParseHostKey reads an OpenSSH / PEM private key file's bytes.
func ParseHostKey(pemBytes []byte) (HostKey, error) { return ssh.ParsePrivateKey(pemBytes) }

// PublicKeyLine is a host key's public half in authorized_keys form.
func PublicKeyLine(k HostKey) string {
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k.PublicKey())))
}

// Config is one door.
type Config struct {
	Hub     string  // the hub's base URL (https://…)
	Token   string  // the door's machine token (machine.env), never an argv
	HostKey HostKey // the door's host key
	// Pull is how often the book is read (default 15 s).
	Pull time.Duration
	// HandshakeTimeout bounds a connection's handshake and login (default 20 s).
	HandshakeTimeout time.Duration
	// MaxPending is how many connections may be in their handshake at once (default 64).
	MaxPending int
	// Audit gets one JSON line per login attempt that reached a decision (nil = the log).
	Audit io.Writer
	HTTP  *http.Client
	// Namespace is the pods' namespace (default fleet-workers): a jump's
	// tunnel goes to <svc>.<Namespace>.svc.cluster.local:22.
	Namespace string
	// JumpUser is the jump account's name (default fleet-jump).
	JumpUser string
	// JumpTargets (tests only) maps a pod's Service to the address its
	// tunnel dials instead; the tunnel's NAME is still the in-cluster one.
	JumpTargets map[string]string
}

// Server is a running door.
type Server struct {
	cfg     Config
	mu      sync.RWMutex
	book    map[string]home     // login → the person whose home login it is
	jump    map[string][]string // a key's fingerprint → the pod sshds it may tunnel to
	version int
	pulled  time.Time
	pending chan struct{}
	auditMu sync.Mutex
}

type home struct {
	principal string
	keys      map[string]bool // SHA256 fingerprints
}

// New is a door ready to Serve; nothing is read until then.
func New(cfg Config) (*Server, error) {
	if cfg.Hub == "" || cfg.Token == "" || cfg.HostKey == nil {
		return nil, errors.New("door: a hub, a token and a host key are required")
	}
	if cfg.Pull <= 0 {
		cfg.Pull = 15 * time.Second
	}
	if cfg.HandshakeTimeout <= 0 {
		cfg.HandshakeTimeout = 20 * time.Second
	}
	if cfg.MaxPending <= 0 {
		cfg.MaxPending = 64
	}
	if cfg.HTTP == nil {
		cfg.HTTP = &http.Client{Timeout: 15 * time.Second}
	}
	if cfg.Namespace == "" {
		cfg.Namespace = "fleet-workers"
	}
	if !nsRE.MatchString(cfg.Namespace) {
		return nil, fmt.Errorf("door: %q is not a namespace name", cfg.Namespace)
	}
	if cfg.JumpUser == "" {
		cfg.JumpUser = "fleet-jump"
	}
	cfg.Hub = strings.TrimRight(cfg.Hub, "/")
	return &Server{cfg: cfg, book: map[string]home{}, jump: map[string][]string{}, pending: make(chan struct{}, cfg.MaxPending)}, nil
}

// Pull reads the book once.
func (s *Server) Pull(ctx context.Context) error {
	// jump=1&ns=: this door carries the pods' jump (the hub offers it only
	// while a door says so); home=1: and people's homes
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		s.cfg.Hub+control.EntryRoutesNodePath+"?jump=1&ns="+url.QueryEscape(s.cfg.Namespace)+"&home=1", nil)
	req.Header.Set("Authorization", "Bearer "+s.cfg.Token)
	req.Header.Set("Accept", "application/json")
	resp, err := s.cfg.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the hub: HTTP %d %s", resp.StatusCode, bytes.TrimSpace(body))
	}
	var lst control.EntryRouteList
	if err := json.Unmarshal(body, &lst); err != nil {
		return fmt.Errorf("the hub's list: %w", err)
	}
	book := map[string]home{}
	for _, h := range lst.Homes {
		if !control.ValidExistingLogin(h.Login) || h.Principal == "" {
			continue
		}
		if _, dup := book[h.Login]; dup {
			// the hub drops a login two homes share; a list that still has
			// one takes neither
			book[h.Login] = home{}
			continue
		}
		hm := home{principal: h.Principal, keys: map[string]bool{}}
		for _, k := range h.Keys {
			hm.keys[k.FP] = true
		}
		book[h.Login] = hm
	}
	// the pods' jump: every routed login's keys, each to its own pod; a login
	// two routes name tunnels to neither
	seen := map[string]int{}
	for _, r := range lst.Routes {
		seen[r.Login]++
	}
	jump := map[string][]string{}
	for _, r := range lst.Routes {
		if seen[r.Login] != 1 || !serviceRE.MatchString(r.Service) || r.Login == "root" {
			continue
		}
		tgt := r.Service + "." + s.cfg.Namespace + ".svc.cluster.local:22"
		for _, k := range lst.Logins[r.Login].Keys {
			if !containsString(jump[k.FP], tgt) {
				jump[k.FP] = append(jump[k.FP], tgt)
			}
		}
	}
	s.mu.Lock()
	s.book, s.jump, s.version, s.pulled = book, jump, lst.Version, time.Now()
	s.mu.Unlock()
	return nil
}

var (
	nsRE      = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	serviceRE = regexp.MustCompile(`^u-[a-z0-9]{4,20}$`)
)

func containsString(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// jumpTargets is the pods a key may tunnel to through the jump account.
func (s *Server) jumpTargets(fp string) []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]string(nil), s.jump[fp]...)
}

// Homes is how many people the book takes home (status, tests).
func (s *Server) Homes() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.book)
}

// JumpKeys is how many keys the jump lets through (status, tests).
func (s *Server) JumpKeys() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.jump)
}

func (s *Server) lookup(login, fp string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	h, ok := s.book[login]
	if !ok || h.principal == "" || !h.keys[fp] {
		return "", false
	}
	return h.principal, true
}

// Serve accepts on ln until ctx ends, pulling the book every Pull.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	if err := s.Pull(ctx); err != nil {
		log.Printf("door: the first pull: %v — nobody is taken home until one succeeds", err)
	}
	go func() {
		t := time.NewTicker(s.cfg.Pull)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if err := s.Pull(ctx); err != nil {
					log.Printf("door: pull: %v — the last book stands", err)
				}
			}
		}
	}()
	go func() { <-ctx.Done(); ln.Close() }()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		select {
		case s.pending <- struct{}{}:
			go s.serve(ctx, c)
		default:
			// too many handshakes at once: refuse this one outright
			c.Close()
		}
	}
}

const (
	extPrincipal = "fleet-door-principal"
	extSig       = "fleet-door-sig"
	extAlgo      = "fleet-door-algo"
	extKey       = "fleet-door-key"
	extJump      = "fleet-door-jump"
)

func (s *Server) serverConfig() *ssh.ServerConfig {
	cfg := &ssh.ServerConfig{
		MaxAuthTries: 3,
		// a key that is not the username's owner's is refused before any
		// signature is asked for
		PublicKeyCallback: func(c ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if _, cert := key.(*ssh.Certificate); cert {
				return nil, errors.New("certificates are not taken here")
			}
			if c.User() == s.cfg.JumpUser {
				tg := s.jumpTargets(ssh.FingerprintSHA256(key))
				if len(tg) == 0 {
					return nil, errors.New("not a key the jump lets through")
				}
				return &ssh.Permissions{Extensions: map[string]string{extJump: strings.Join(tg, ",")}}, nil
			}
			p, ok := s.lookup(c.User(), ssh.FingerprintSHA256(key))
			if !ok {
				return nil, errors.New("not a key of this login's owner")
			}
			return &ssh.Permissions{Extensions: map[string]string{extPrincipal: p}}, nil
		},
		SignedPublicKeyCallback: func(c ssh.ConnMetadata, key ssh.PublicKey, perms *ssh.Permissions, algo string, sig *ssh.Signature) (*ssh.Permissions, error) {
			out := &ssh.Permissions{Extensions: map[string]string{}}
			if perms != nil {
				for k, v := range perms.Extensions {
					out.Extensions[k] = v
				}
			}
			out.Extensions[extSig] = base64.StdEncoding.EncodeToString(ssh.Marshal(sig))
			out.Extensions[extAlgo] = algo
			out.Extensions[extKey] = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))
			return out, nil
		},
		ServerVersion: "SSH-2.0-fleet-door",
	}
	cfg.AddHostKey(s.cfg.HostKey)
	return cfg
}

// auditLine is one login's record: never a key's body or a signature.
type auditLine struct {
	At        string `json:"at"`
	From      string `json:"from"`
	User      string `json:"user"`
	Principal string `json:"principal,omitempty"`
	FP        string `json:"fp,omitempty"`
	Session   string `json:"session,omitempty"`
	Home      string `json:"home,omitempty"`
	Result    string `json:"result"`
	Why       string `json:"why,omitempty"`
}

func (s *Server) audit(l auditLine) {
	l.At = time.Now().UTC().Format(time.RFC3339)
	b, _ := json.Marshal(l)
	if s.cfg.Audit == nil {
		log.Printf("door: %s", b)
		return
	}
	s.auditMu.Lock()
	defer s.auditMu.Unlock()
	_, _ = s.cfg.Audit.Write(append(b, '\n'))
}

func (s *Server) serve(ctx context.Context, nc net.Conn) {
	released := false
	release := func() {
		if !released {
			released = true
			<-s.pending
		}
	}
	defer release()
	defer nc.Close()
	_ = nc.SetDeadline(time.Now().Add(s.cfg.HandshakeTimeout))
	sconn, chans, reqs, err := ssh.NewServerConn(nc, s.serverConfig())
	if err != nil {
		return // the client could not log in: sshd says nothing more either
	}
	defer sconn.Close()
	ext := sconn.Permissions.Extensions
	line := auditLine{From: nc.RemoteAddr().String(), User: sconn.User(), Principal: ext[extPrincipal]}
	if pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(ext[extKey])); err == nil {
		line.FP = ssh.FingerprintSHA256(pk)
	}
	sum := sconn.SessionID()
	if len(sum) >= 8 {
		line.Session = base64.RawURLEncoding.EncodeToString(sum[:8])
	}
	if tg := ext[extJump]; tg != "" && line.FP != "" {
		_ = nc.SetDeadline(time.Time{})
		release()
		line.Result, line.Home = "jump", tg
		s.audit(line)
		s.serveJump(sconn, chans, reqs, strings.Split(tg, ","), line)
		return
	}
	homeConn, cert, err := s.goHome(ctx, sconn)
	_ = nc.SetDeadline(time.Time{})
	release() // past the handshake: it no longer counts against MaxPending
	if err != nil {
		line.Result, line.Why = "refused", err.Error()
		s.audit(line)
		tellAndClose(chans, reqs, "fleet 门：接不到你的家："+err.Error())
		return
	}
	defer homeConn.Close()
	line.Result, line.Home = "home", cert.Login+"@"+cert.Machine
	s.audit(line)
	proxy(sconn, chans, reqs, homeConn)
}

// goHome gets the hop's certificate and logs in to the person's home with it.
func (s *Server) goHome(ctx context.Context, sconn *ssh.ServerConn) (*ssh.Client, control.DoorSessionCert, error) {
	ext := sconn.Permissions.Extensions
	_, dpriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, control.DoorSessionCert{}, err
	}
	dsigner, err := ssh.NewSignerFromKey(dpriv)
	if err != nil {
		return nil, control.DoorSessionCert{}, err
	}
	req := control.DoorSessionRequest{Key: ext[extKey], User: sconn.User(),
		SessionID: base64.StdEncoding.EncodeToString(sconn.SessionID()), Algo: ext[extAlgo], Sig: ext[extSig],
		DoorKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(dsigner.PublicKey())))}
	cert, err := s.session(ctx, req)
	if err != nil {
		return nil, cert, err
	}
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(cert.Cert))
	if err != nil {
		return nil, cert, fmt.Errorf("the hub's certificate: %w", err)
	}
	c, ok := pk.(*ssh.Certificate)
	if !ok {
		return nil, cert, errors.New("the hub's certificate is not a certificate")
	}
	signer, err := ssh.NewCertSigner(c, dsigner)
	if err != nil {
		return nil, cert, err
	}
	var known []ssh.PublicKey
	for _, hk := range cert.HostKeys {
		if k, _, _, _, err := ssh.ParseAuthorizedKey([]byte(hk)); err == nil {
			known = append(known, k)
		}
	}
	if len(known) == 0 {
		return nil, cert, errors.New("入口还不知道你家的主机钥匙（家还没报过）")
	}
	stream, err := s.stream(ctx, cert.Principal)
	if err != nil {
		return nil, cert, err
	}
	hc, hchans, hreqs, err := ssh.NewClientConn(stream, cert.Machine, &ssh.ClientConfig{
		User: cert.Login, Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			for _, k := range known {
				if bytes.Equal(k.Marshal(), key.Marshal()) {
					return nil
				}
			}
			return errors.New("your home answered with a host key the hub does not know")
		},
		Timeout: s.cfg.HandshakeTimeout,
	})
	if err != nil {
		stream.Close()
		return nil, cert, fmt.Errorf("log in at your home: %w", err)
	}
	return ssh.NewClient(hc, hchans, hreqs), cert, nil
}

// session asks the hub for the hop's certificate.
func (s *Server) session(ctx context.Context, req control.DoorSessionRequest) (control.DoorSessionCert, error) {
	var out control.DoorSessionCert
	b, _ := json.Marshal(req)
	hr, _ := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.Hub+control.DoorSessionPath, bytes.NewReader(b))
	hr.Header.Set("Authorization", "Bearer "+s.cfg.Token)
	hr.Header.Set("Content-Type", "application/json")
	resp, err := s.cfg.HTTP.Do(hr)
	if err != nil {
		return out, fmt.Errorf("入口连不上：%w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(body, &e)
		if e.Error == "" {
			e.Error = strings.TrimSpace(string(body))
		}
		return out, fmt.Errorf("入口不签（HTTP %d）：%s", resp.StatusCode, e.Error)
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return out, fmt.Errorf("the hub's answer: %w", err)
	}
	return out, nil
}

// stream opens DoorHomePath for person: a net.Conn onto their home's entry port.
func (s *Server) stream(ctx context.Context, person string) (net.Conn, error) {
	u := s.cfg.Hub + control.DoorHomePath + "?principal=" + url.QueryEscape(person)
	u = "ws" + strings.TrimPrefix(u, "http")
	dctx, cancel := context.WithTimeout(ctx, s.cfg.HandshakeTimeout)
	defer cancel()
	c, resp, err := websocket.Dial(dctx, u, &websocket.DialOptions{HTTPClient: s.cfg.HTTP,
		HTTPHeader: http.Header{"Authorization": {"Bearer " + s.cfg.Token}}})
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("入口不接（HTTP %d）", resp.StatusCode)
		}
		return nil, fmt.Errorf("入口连不上：%w", err)
	}
	c.SetReadLimit(1 << 20)
	var hello control.SSHRelayHello
	if err := wsjson.Read(dctx, c, &hello); err != nil {
		c.CloseNow()
		return nil, fmt.Errorf("入口没回话：%w", err)
	}
	if hello.Type != "ready" {
		c.CloseNow()
		if hello.Message != "" {
			return nil, errors.New(hello.Message)
		}
		return nil, fmt.Errorf("入口说 %s %s", hello.Type, hello.Code)
	}
	return websocket.NetConn(context.Background(), c, websocket.MessageBinary), nil
}

// tellAndClose answers the person's first session with why, then ends it all.
func tellAndClose(chans <-chan ssh.NewChannel, reqs <-chan *ssh.Request, why string) {
	go ssh.DiscardRequests(reqs)
	t := time.NewTimer(10 * time.Second)
	defer t.Stop()
	select {
	case nch, ok := <-chans:
		if !ok {
			return
		}
		if nch.ChannelType() != "session" {
			nch.Reject(ssh.Prohibited, why)
			return
		}
		ch, creqs, err := nch.Accept()
		if err != nil {
			return
		}
		go func() {
			for r := range creqs {
				if r.WantReply {
					r.Reply(r.Type == "pty-req" || r.Type == "shell" || r.Type == "exec" || r.Type == "env", nil)
				}
			}
		}()
		fmt.Fprintf(ch.Stderr(), "%s\r\n", why)
		ch.SendRequest("exit-status", false, ssh.Marshal(struct{ S uint32 }{1}))
		ch.Close()
	case <-t.C:
	}
}

// proxy carries every channel and request between the person (sconn) and
// their home (home) until either side ends.
func proxy(sconn *ssh.ServerConn, chans <-chan ssh.NewChannel, reqs <-chan *ssh.Request, home *ssh.Client) {
	done := make(chan struct{})
	go func() {
		_ = home.Wait()
		sconn.Close()
		close(done)
	}()
	go func() {
		for r := range reqs {
			ok, payload, err := home.SendRequest(r.Type, r.WantReply, r.Payload)
			if err != nil {
				ok = false
			}
			if r.WantReply {
				r.Reply(ok, payload)
			}
		}
	}()
	for nch := range chans {
		go carry(nch, home)
	}
	home.Close()
	<-done
}

// carry opens nch's twin at home and copies both ways: data, stderr, requests.
func carry(nch ssh.NewChannel, home *ssh.Client) {
	hch, hreqs, err := home.OpenChannel(nch.ChannelType(), nch.ExtraData())
	if err != nil {
		var oce *ssh.OpenChannelError
		if errors.As(err, &oce) {
			nch.Reject(oce.Reason, oce.Message)
		} else {
			nch.Reject(ssh.ConnectionFailed, err.Error())
		}
		return
	}
	ch, creqs, err := nch.Accept()
	if err != nil {
		hch.Close()
		return
	}
	go func() {
		for r := range creqs {
			ok, err := hch.SendRequest(r.Type, r.WantReply, r.Payload)
			if r.WantReply {
				r.Reply(ok && err == nil, nil)
			}
		}
		hch.Close()
	}()
	var wg sync.WaitGroup
	wg.Add(3)
	go func() { defer wg.Done(); _, _ = io.Copy(hch, ch); _ = hch.CloseWrite() }()
	go func() { defer wg.Done(); _, _ = io.Copy(hch.Stderr(), ch.Stderr()) }()
	go func() { defer wg.Done(); _, _ = io.Copy(ch.Stderr(), hch.Stderr()) }()
	// the home's requests (keepalives, exit-status, exit-signal) are read as
	// they come — an unread one would stall the whole connection — and the
	// channel closes only once both the data and they are through
	reqDone := make(chan struct{})
	go func() {
		defer close(reqDone)
		for r := range hreqs {
			ok, err := ch.SendRequest(r.Type, r.WantReply, r.Payload)
			if r.WantReply {
				r.Reply(ok && err == nil, nil)
			}
		}
	}()
	_, _ = io.Copy(ch, hch)
	_ = ch.CloseWrite()
	<-reqDone
	ch.Close()
	hch.Close()
	go wg.Wait()
}

// serveJump is the jump account's connection: no session, no global
// request, and direct-tcpip only to one of allowed (its owner's pod sshds).
func (s *Server) serveJump(sconn *ssh.ServerConn, chans <-chan ssh.NewChannel, reqs <-chan *ssh.Request, allowed []string, line auditLine) {
	go func() {
		for r := range reqs {
			if r.WantReply {
				r.Reply(false, nil)
			}
		}
	}()
	for nch := range chans {
		if nch.ChannelType() != "direct-tcpip" {
			nch.Reject(ssh.Prohibited, "the jump opens a tunnel to your own pod, nothing else")
			continue
		}
		var d struct {
			Host  string
			Port  uint32
			OHost string
			OPort uint32
		}
		if err := ssh.Unmarshal(nch.ExtraData(), &d); err != nil {
			nch.Reject(ssh.ConnectionFailed, "bad direct-tcpip request")
			continue
		}
		tgt := net.JoinHostPort(d.Host, fmt.Sprint(d.Port))
		// against the book as it is NOW: a key the hub took away opens no
		// new tunnel on a connection it already holds
		if !containsString(allowed, tgt) || !containsString(s.jumpTargets(line.FP), tgt) {
			l := line
			l.Result, l.Home, l.Why = "tunnel-refused", tgt, "not this key's own pod"
			s.audit(l)
			nch.Reject(ssh.Prohibited, "not your own pod")
			continue
		}
		go s.tunnel(nch, tgt)
	}
}

// tunnel splices one direct-tcpip channel onto tgt (in the cluster).
func (s *Server) tunnel(nch ssh.NewChannel, tgt string) {
	dial := tgt
	if svc, _, ok := strings.Cut(tgt, "."); ok && s.cfg.JumpTargets[svc] != "" {
		dial = s.cfg.JumpTargets[svc]
	}
	c, err := net.DialTimeout("tcp", dial, s.cfg.HandshakeTimeout)
	if err != nil {
		nch.Reject(ssh.ConnectionFailed, "your pod does not answer")
		return
	}
	ch, creqs, err := nch.Accept()
	if err != nil {
		c.Close()
		return
	}
	go ssh.DiscardRequests(creqs)
	go func() {
		_, _ = io.Copy(c, ch)
		if cw, ok := c.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
	}()
	_, _ = io.Copy(ch, c)
	ch.Close()
	c.Close()
}
