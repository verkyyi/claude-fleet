package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The relay (claude-fleet#1413): the way in when a machine cannot be reached
// directly — the person's network cannot see the home LAN, the tailnet is
// down, the gateway port is closed. The hub is reachable from everywhere and
// every machine already holds a link open to it, so the hub pairs the two:
//
//	ssh -o ProxyCommand='fleet connect --proxy m4' m4
//
// opens a WebSocket here; the hub asks one of m4's agents, over its control
// channel, to dial a data stream back; the agent splices that onto m4's own
// sshd at 127.0.0.1:22; the hub copies bytes between the two. SSH runs end to
// end inside it: the hub sees ciphertext, and sshd still decides who logs in.
//
// What the hub does decide is who may ask. A relay is admitted for:
//   - the operator: the viewer token, a tailnet identity — any machine;
//   - a person: a WeCom session (cookie, or the session token as a bearer) or
//     an SSH user certificate signed by the hub's CA proven by a signature
//     over a fresh challenge — only to a machine where the hub opened them a
//     login, and only while that login is active.
//
// Each person gets at most SSHRelayMaxPerUser relays at once and SSHRelayRateBPS
// bytes a second across all of them; every relay is a row in fleet_ssh_relays.

// Relay defaults, used when the Server leaves them zero.
const (
	defaultSSHRelayMaxPerUser = 8
	// 4 MiB/s is far above any terminal and still bounds what one person's
	// scp costs in cross-border egress.
	defaultSSHRelayRateBPS = 4 << 20
	// sshRelayAttachTimeout bounds how long the client waits for the agent's
	// data stream after the hub has asked for it.
	sshRelayAttachTimeout = 15 * time.Second
	// sshRelayChunk is the largest frame the hub writes: small enough that the
	// rate limiter moves smoothly, large enough to keep the overhead low.
	sshRelayChunk = 32 << 10
)

// sshRelayIdentity is who is asking for a relay.
type sshRelayIdentity struct {
	// Operator sees every machine; Principal is empty for them.
	Operator  bool
	Principal string
	// Actor is the name in the audit: the principal, or the operator door.
	Actor string
}

// pendingSSHRelay is a relay the hub has asked an agent for and is waiting on.
type pendingSSHRelay struct {
	id, secret string
	endpointID string
	node       *nodeConn
	attach     chan *websocket.Conn
	// done is closed when the relay is over, so the data handler holding
	// the agent's half returns.
	done chan struct{}
	// cancel ends the copy (the agent's control channel dropped).
	cancel context.CancelFunc
}

// sshRelayTable holds the relays in flight.
type sshRelayTable struct {
	mu      sync.Mutex
	byID    map[string]*pendingSSHRelay
	perUser map[string]int
	limits  map[string]*byteLimiter
}

func (t *sshRelayTable) admit(actor string, max int) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.perUser == nil {
		t.perUser = map[string]int{}
	}
	if t.perUser[actor] >= max {
		return false
	}
	t.perUser[actor]++
	return true
}

func (t *sshRelayTable) release(actor string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.perUser[actor]--; t.perUser[actor] <= 0 {
		delete(t.perUser, actor)
		// The limiter goes with the last relay: an idle person costs nothing.
		delete(t.limits, actor)
	}
}

func (t *sshRelayTable) limiter(actor string, bps int64) *byteLimiter {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.limits == nil {
		t.limits = map[string]*byteLimiter{}
	}
	l := t.limits[actor]
	if l == nil {
		l = newByteLimiter(bps)
		t.limits[actor] = l
	}
	return l
}

func (t *sshRelayTable) put(p *pendingSSHRelay) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.byID == nil {
		t.byID = map[string]*pendingSSHRelay{}
	}
	t.byID[p.id] = p
}

func (t *sshRelayTable) get(id string) *pendingSSHRelay {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.byID[id]
}

func (t *sshRelayTable) drop(id string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.byID, id)
}

// closeNode ends every relay carried by nc: its control channel is gone, so
// the agent has torn its halves down too, and a client left waiting on a
// stream that will never move again is worse than a clean close.
func (t *sshRelayTable) closeNode(nc *nodeConn) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, p := range t.byID {
		if p.node == nc {
			p.cancel()
		}
	}
}

// openRelays counts relays in flight (tests and the audit page).
func (t *sshRelayTable) open() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.byID)
}

// sshRelayHTTPIdentity admits a request on what it carries over HTTP: the
// operator's doors, or a WeCom session as a cookie or a bearer. ok=false
// means it carried nothing this hub accepts — the caller may still prove a
// certificate in-band.
func (s *Server) sshRelayHTTPIdentity(r *http.Request) (sshRelayIdentity, bool) {
	if s.ViewerToken == "" {
		return sshRelayIdentity{Operator: true, Actor: "operator"}, true
	}
	if constantTimeEqual(bearer(r), s.ViewerToken) {
		return sshRelayIdentity{Operator: true, Actor: "operator"}, true
	}
	if c, err := r.Cookie("ccquota_token"); err == nil && constantTimeEqual(c.Value, s.ViewerToken) {
		return sshRelayIdentity{Operator: true, Actor: "operator"}, true
	}
	// A GitHub person (claude-fleet#1984), on the list right now.
	if sess, id, ok := s.githubSession(r); ok {
		if role, err := s.githubRole(id); err == nil && role == roleAdmin {
			// An admin sees every machine, as the operator's doors do
			// (claude-fleet#1985).
			return sshRelayIdentity{Operator: true, Actor: sess.UID}, true
		} else if err == nil && role != "" {
			return sshRelayIdentity{Principal: sess.UID, Actor: sess.UID}, true
		}
	}
	if sub, ok := s.ssoViewer(r); ok {
		return sshRelayIdentity{Principal: sub, Actor: sub}, true
	}
	// A CLI holds the session token, not a browser cookie jar.
	if s.SSO.ready() {
		if tok := bearer(r); tok != "" {
			if sess, err := authz.VerifySession(tok, s.SSO.SessionSecret, time.Now()); err == nil {
				return sshRelayIdentity{Principal: sess.Principal(), Actor: sess.Principal()}, true
			}
		}
	}
	if login, ok := s.Tailnet.Lookup(r.RemoteAddr); ok {
		return sshRelayIdentity{Operator: true, Actor: "tailnet:" + login}, true
	}
	return sshRelayIdentity{}, false
}

// sshRelayError is a refusal sent to the client before the stream starts.
type sshRelayError struct{ code, msg string }

func (e *sshRelayError) Error() string { return e.code + ": " + e.msg }

func sshRelayRefusal(code, format string, a ...any) error {
	return &sshRelayError{code, fmt.Sprintf(format, a...)}
}

// handleSSHRelayConnect serves SSHRelayPath: one client's relay to ?node=<host>.
func (s *Server) handleSSHRelayConnect(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Query().Get("node")
	if host == "" {
		httpError(w, http.StatusBadRequest, "node is required (?node=<machine>)")
		return
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	if !ok && len(s.sshRelayCAs()) == 0 {
		// No certificate is ever accepted on this hub, so there is nothing
		// to prove in-band: refuse before the upgrade.
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1 << 20)
	ctx := context.Background()

	refuse := func(err error) {
		var re *sshRelayError
		if !errors.As(err, &re) {
			re = &sshRelayError{"INTERNAL", err.Error()}
		}
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_ = wsjson.Write(wctx, conn, control.SSHRelayHello{Type: "error", Code: re.code, Message: re.msg})
		cancel()
		conn.Close(websocket.StatusPolicyViolation, re.code)
	}

	if !ok {
		if id, err = s.sshRelayCertChallenge(ctx, conn); err != nil {
			refuse(err)
			return
		}
	}
	if err := s.sshRelayAllowed(id, host); err != nil {
		refuse(err)
		return
	}
	max := s.SSHRelayMaxPerUser
	if max <= 0 {
		max = defaultSSHRelayMaxPerUser
	}
	if !s.sshRelays.admit(id.Actor, max) {
		refuse(sshRelayRefusal("TOO_MANY", "already %d relays open for %s; close one first", max, id.Actor))
		return
	}
	defer s.sshRelays.release(id.Actor)

	epID, nc, err := s.sshRelayNode(id, host)
	if err != nil {
		refuse(err)
		return
	}

	rctx, cancel := context.WithCancel(ctx)
	defer cancel()
	p := &pendingSSHRelay{id: control.NewOpID(), secret: control.NewOpID(), endpointID: epID, node: nc,
		attach: make(chan *websocket.Conn, 1), done: make(chan struct{}), cancel: cancel}
	defer close(p.done)
	s.sshRelays.put(p)
	defer s.sshRelays.drop(p.id)

	started := time.Now()
	row := store.SSHRelay{ID: p.id, Actor: id.Actor, Hostname: host, EndpointID: epID,
		OSUser: nc.user(), StartedAt: started, Outcome: "open"}
	// Recorded before the agent is asked: a relay that crashes the hub
	// still leaves its row.
	if err := s.Store.SSHRelayStarted(row); err != nil {
		refuse(fmt.Errorf("record the relay: %w", err))
		return
	}
	var up, down int64
	outcome, detail := "closed", ""
	defer func() {
		if err := s.Store.SSHRelayEnded(p.id, outcome, detail, up, down, time.Now()); err != nil {
			log.Printf("relay %s: record its end: %v", p.id, err)
		}
		log.Printf("relay %s: %s -> %s via %s: %s after %s, %d up / %d down %s",
			p.id[:8], id.Actor, host, nc.user(), outcome, time.Since(started).Round(time.Second), up, down, detail)
	}()

	open, _ := control.New(control.TypeSSHRelayOpen, control.SSHRelayOpen{RelayID: p.id, Secret: p.secret})
	wctx, wcancel := context.WithTimeout(rctx, 5*time.Second)
	err = s.SendNodeWrite(wctx, epID, open)
	wcancel()
	if err != nil {
		outcome, detail = "failed", "ask the agent: "+err.Error()
		refuse(sshRelayRefusal("NODE_OFFLINE", "%s's agent did not take the request: %v", host, err))
		return
	}
	var agentConn *websocket.Conn
	t := time.NewTimer(sshRelayAttachTimeout)
	select {
	case agentConn = <-p.attach:
		t.Stop()
	case <-t.C:
		outcome, detail = "failed", "agent never attached"
		refuse(sshRelayRefusal("NODE_TIMEOUT", "%s's agent did not open the stream within %s", host, sshRelayAttachTimeout))
		return
	case <-rctx.Done():
		outcome, detail = "failed", "agent disconnected"
		refuse(sshRelayRefusal("NODE_OFFLINE", "%s's agent disconnected", host))
		return
	}

	rd := s.SSHRelayRateBPS
	if rd == 0 {
		rd = defaultSSHRelayRateBPS
	}
	lim := s.sshRelays.limiter(id.Actor, rd)
	wctx, wcancel = context.WithTimeout(rctx, 5*time.Second)
	err = wsjson.Write(wctx, conn, control.SSHRelayHello{Type: "ready"})
	wcancel()
	if err != nil {
		outcome, detail = "failed", "client gone before the stream started"
		return
	}
	up, down, detail = pipeSSHRelay(rctx, conn, agentConn, lim)
	if rctx.Err() != nil && detail == "" {
		detail = "agent disconnected"
	}
	agentConn.Close(websocket.StatusNormalClosure, "")
	conn.Close(websocket.StatusNormalClosure, detail)
}

// handleSSHRelayData serves SSHRelayDataPath: an agent attaching the data half of
// a relay the hub asked it for.
func (s *Server) handleSSHRelayData(w http.ResponseWriter, r *http.Request) {
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}
	p := s.sshRelays.get(r.URL.Query().Get("id"))
	// The relay must be the one THIS endpoint was asked for, with the
	// secret it was given: another login on the same machine holding its
	// own token cannot step into someone else's stream.
	if p == nil || p.endpointID != ep.ID || !constantTimeEqual(r.Header.Get("X-Relay-Secret"), p.secret) {
		httpError(w, http.StatusNotFound, "no such relay for this node")
		return
	}
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1 << 20)
	select {
	case p.attach <- conn:
	default:
		// Already attached once; a second stream is not part of this relay.
		conn.Close(websocket.StatusPolicyViolation, "relay already attached")
		return
	}
	<-p.done
}

// sshRelayAllowed is the hub's half of "only your own": a person reaches only a
// machine where the hub opened them a login that is active now. sshd still
// decides which login they get in as.
func (s *Server) sshRelayAllowed(id sshRelayIdentity, host string) error {
	if id.Operator {
		return nil
	}
	accts, err := s.Store.FleetAccounts(id.Principal)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		return err
	}
	for _, a := range accts {
		if a.Hostname == host && a.State == store.AccountActive {
			return nil
		}
	}
	return sshRelayRefusal("NOT_FOUND", "no machine %q among yours", host)
}

// sshRelayNode picks the agent that carries a relay to host: a connected,
// write-compatible agent there that offered CapSSHRelay. A person's own login's
// agent first (it is theirs), then the admin agent (always running), then
// any — sshd on the machine is the same whichever login's agent dials it.
func (s *Server) sshRelayNode(id sshRelayIdentity, host string) (string, *nodeConn, error) {
	var own string
	if !id.Operator {
		if p, err := s.Store.Principal(id.Principal); err == nil {
			own = p.Login
		}
	}
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	ids := make([]string, 0, len(s.nodes.conns))
	for epID := range s.nodes.conns {
		ids = append(ids, epID)
	}
	sort.Strings(ids)
	best, rank := "", 99
	for _, epID := range ids {
		c := s.nodes.conns[epID]
		if !c.canSSHRelay || c.hostname() != host || !control.Compatible(int(c.proto.Load())) {
			continue
		}
		r := 2
		switch {
		case own != "" && c.user() == own:
			r = 0
		case c.admin:
			r = 1
		}
		if r < rank {
			best, rank = epID, r
		}
	}
	if best == "" {
		return "", nil, sshRelayRefusal("NODE_OFFLINE", "no agent on %s is connected and able to relay", host)
	}
	return best, s.nodes.conns[best], nil
}

// pipeSSHRelay copies the SSH stream both ways until either side ends or ctx
// does. up is client→machine, down machine→client; both pass the person's
// rate limiter.
func pipeSSHRelay(ctx context.Context, client, agent *websocket.Conn, lim *byteLimiter) (up, down int64, detail string) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	var mu sync.Mutex
	end := func(why string) {
		mu.Lock()
		if detail == "" {
			detail = why
		}
		mu.Unlock()
		cancel()
	}
	copyDir := func(dst, src *websocket.Conn, n *int64, from string) {
		defer wg.Done()
		buf := make([]byte, sshRelayChunk)
		for {
			typ, r, err := src.Reader(ctx)
			if err != nil {
				if websocket.CloseStatus(err) == websocket.StatusNormalClosure || ctx.Err() != nil {
					end("")
				} else {
					end(from + " closed: " + err.Error())
				}
				return
			}
			if typ != websocket.MessageBinary {
				end(from + " sent a text frame inside the stream")
				return
			}
			for {
				k, rerr := r.Read(buf)
				if k > 0 {
					if err := lim.wait(ctx, k); err != nil {
						end("")
						return
					}
					wctx, wcancel := context.WithTimeout(ctx, 30*time.Second)
					err := dst.Write(wctx, websocket.MessageBinary, buf[:k])
					wcancel()
					if err != nil {
						end("write failed: " + err.Error())
						return
					}
					mu.Lock()
					*n += int64(k)
					mu.Unlock()
				}
				if rerr == io.EOF {
					break
				}
				if rerr != nil {
					end(from + " read failed: " + rerr.Error())
					return
				}
			}
		}
	}
	wg.Add(2)
	go copyDir(agent, client, &up, "client")
	go copyDir(client, agent, &down, "agent")
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	return up, down, detail
}

// byteLimiter is a token bucket in bytes, shared by every relay of one person.
type byteLimiter struct {
	mu     sync.Mutex
	rate   float64 // bytes per second; <=0 means unlimited
	burst  float64
	tokens float64
	last   time.Time
}

func newByteLimiter(bps int64) *byteLimiter {
	b := float64(bps)
	// A one-second burst, never less than a frame, so a single chunk can
	// always pass.
	burst := b
	if burst < sshRelayChunk {
		burst = sshRelayChunk
	}
	return &byteLimiter{rate: b, burst: burst, tokens: burst, last: time.Now()}
}

// wait blocks until n bytes may pass.
func (l *byteLimiter) wait(ctx context.Context, n int) error {
	if l == nil || l.rate <= 0 {
		return nil
	}
	for {
		l.mu.Lock()
		now := time.Now()
		l.tokens += now.Sub(l.last).Seconds() * l.rate
		l.last = now
		if l.tokens > l.burst {
			l.tokens = l.burst
		}
		if l.tokens >= float64(n) {
			l.tokens -= float64(n)
			l.mu.Unlock()
			return nil
		}
		need := time.Duration((float64(n) - l.tokens) / l.rate * float64(time.Second))
		l.mu.Unlock()
		t := time.NewTimer(need)
		select {
		case <-ctx.Done():
			t.Stop()
			return ctx.Err()
		case <-t.C:
		}
	}
}

// sshRelayCertChallenge proves an SSH user certificate in-band: the hub sends a
// fresh nonce, the client answers with its certificate and an `ssh-keygen -Y
// sign` signature over the nonce made by the certificate's key. A replayed
// answer signs some other nonce; a certificate alone, without its key, signs
// nothing.
func (s *Server) sshRelayCertChallenge(ctx context.Context, conn *websocket.Conn) (sshRelayIdentity, error) {
	nonce := control.NewOpID() + control.NewOpID()
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err := wsjson.Write(wctx, conn, control.SSHRelayHello{Type: "challenge", Nonce: nonce})
	cancel()
	if err != nil {
		return sshRelayIdentity{}, err
	}
	rctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	var ans control.SSHRelayHello
	err = wsjson.Read(rctx, conn, &ans)
	cancel()
	if err != nil {
		return sshRelayIdentity{}, sshRelayRefusal("UNAUTHORIZED", "no answer to the challenge")
	}
	if ans.Type != "auth" || ans.Cert == "" || ans.Sig == "" {
		return sshRelayIdentity{}, sshRelayRefusal("UNAUTHORIZED", "a session, a viewer token or a connection certificate is required")
	}
	return s.verifySSHRelayCert(ans.Cert, ans.Sig, nonce, control.SSHRelaySigNamespace, time.Now())
}

// verifySSHRelayCert checks a certificate and its signature over nonce, made
// under namespace, and names the person it belongs to. The relay and the route
// list (claude-fleet#1414) sign under different namespaces, so a signature made
// for one is never accepted by the other.
//
// The certificate must be a user certificate signed by one of SSHRelayCA, valid
// now, whose key id is the person's WeCom userid (the principal; a
// "<scheme>:" prefix is allowed) and whose principals include the login the
// hub minted for them — so a certificate for one person can never be read as
// another's, even if its key id were spoofed by a compromised signer of a
// different scheme.
func (s *Server) verifySSHRelayCert(certLine, sigArmor, nonce, namespace string, now time.Time) (sshRelayIdentity, error) {
	bad := func(why string) (sshRelayIdentity, error) {
		return sshRelayIdentity{}, sshRelayRefusal("UNAUTHORIZED", "connection certificate refused: %s", why)
	}
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(certLine))
	if err != nil {
		return bad("unreadable")
	}
	cert, ok := pub.(*ssh.Certificate)
	if !ok {
		return bad("not a certificate")
	}
	if cert.CertType != ssh.UserCert {
		return bad("not a user certificate")
	}
	signedByCA := false
	for _, ca := range s.sshRelayCAs() {
		if bytes.Equal(ca.Marshal(), cert.SignatureKey.Marshal()) {
			signedByCA = true
			break
		}
	}
	if !signedByCA {
		return bad("not signed by this hub")
	}
	checker := ssh.CertChecker{Clock: func() time.Time { return now }}
	pid := cert.KeyId
	if i := strings.LastIndex(pid, ":"); i >= 0 {
		pid = pid[i+1:]
	}
	p, err := s.Store.Principal(pid)
	if err != nil {
		return bad("its key id names no one this hub knows")
	}
	// CheckCert verifies the CA's signature, the validity window and that
	// the person's login is among the certificate's principals.
	if err := checker.CheckCert(p.Login, cert); err != nil {
		return bad(err.Error())
	}
	if err := verifySSHSig(cert.Key, []byte(sigArmor), []byte(nonce), namespace); err != nil {
		return bad("challenge signature: " + err.Error())
	}
	// A revoked device's certificate is refused here from the moment of the
	// revocation, inside its 12 hours or not (claude-fleet#1470). sshd itself
	// cannot know, so the hub's own doors are where it bites.
	if revoked, err := s.Store.DeviceRevoked(ssh.FingerprintSHA256(cert.Key)); err != nil {
		return sshRelayIdentity{}, err
	} else if revoked {
		return bad("this device was revoked — run `fleet` and scan again")
	}
	return sshRelayIdentity{Principal: p.ID, Actor: p.ID}, nil
}

// sshRelayCAs is every CA a relay certificate may be signed by: the hub's own
// signing CA (claude-fleet#1412), when it holds one, plus SSHRelayCA — a key
// being rotated out, or a CA whose private half lives elsewhere.
func (s *Server) sshRelayCAs() []ssh.PublicKey {
	cas := append([]ssh.PublicKey(nil), s.SSHRelayCA...)
	if s.SSHCA != nil {
		if k, _, _, _, err := ssh.ParseAuthorizedKey([]byte(s.SSHCA.PublicKey())); err == nil {
			cas = append(cas, k)
		}
	}
	return cas
}

// verifySSHSig checks an OpenSSH SSHSIG signature (ssh-keygen -Y sign, see
// PROTOCOL.sshsig) over msg by key, made under namespace.
func verifySSHSig(key ssh.PublicKey, armored, msg []byte, namespace string) error {
	const begin, end = "-----BEGIN SSH SIGNATURE-----", "-----END SSH SIGNATURE-----"
	s := string(armored)
	i, j := strings.Index(s, begin), strings.Index(s, end)
	if i < 0 || j < i {
		return errors.New("not an SSH signature")
	}
	blob, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(s[i+len(begin):j]), ""))
	if err != nil {
		return errors.New("not an SSH signature")
	}
	if !bytes.HasPrefix(blob, []byte("SSHSIG")) {
		return errors.New("not an SSH signature")
	}
	var sig struct {
		Version   uint32
		PublicKey []byte
		Namespace string
		Reserved  string
		HashAlg   string
		Signature []byte
	}
	if err := ssh.Unmarshal(blob[6:], &sig); err != nil {
		return errors.New("malformed SSH signature")
	}
	if sig.Version != 1 {
		return fmt.Errorf("SSH signature version %d", sig.Version)
	}
	if sig.Namespace != namespace {
		return fmt.Errorf("signed for %q, not %q", sig.Namespace, namespace)
	}
	signer, err := ssh.ParsePublicKey(sig.PublicKey)
	if err != nil {
		return errors.New("unreadable signing key")
	}
	if c, ok := signer.(*ssh.Certificate); ok {
		signer = c.Key
	}
	if !bytes.Equal(signer.Marshal(), key.Marshal()) {
		return errors.New("signed by a different key")
	}
	var h hash.Hash
	switch sig.HashAlg {
	case "sha256":
		h = sha256.New()
	case "sha512":
		h = sha512.New()
	default:
		return fmt.Errorf("hash %q", sig.HashAlg)
	}
	h.Write(msg)
	signed := []byte("SSHSIG")
	for _, f := range [][]byte{[]byte(namespace), []byte(sig.Reserved), []byte(sig.HashAlg), h.Sum(nil)} {
		signed = binary.BigEndian.AppendUint32(signed, uint32(len(f)))
		signed = append(signed, f...)
	}
	var wire ssh.Signature
	if err := ssh.Unmarshal(sig.Signature, &wire); err != nil {
		return errors.New("malformed signature")
	}
	return key.Verify(signed, &wire)
}

// SSHRelayAudit is the body of /v1/fleet/ssh-relays.
type SSHRelayAudit struct {
	Open   int              `json:"open"`
	Relays []store.SSHRelay `json:"relays"`
}

// handleSSHRelayAudit lists the newest relays — the operator's view of who went
// through the hub to which machine, for how long, at what byte cost.
func (s *Server) handleSSHRelayAudit(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.SSHRelays(200)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, SSHRelayAudit{Open: s.sshRelays.open(), Relays: rows})
}

// ParseSSHRelayCA reads the CA public keys a relay certificate may be signed by:
// authorized_keys lines, blank lines and comments ignored.
func ParseSSHRelayCA(b []byte) ([]ssh.PublicKey, error) {
	var out []ssh.PublicKey
	for len(bytes.TrimSpace(b)) > 0 {
		k, _, _, rest, err := ssh.ParseAuthorizedKey(b)
		if err != nil {
			return nil, err
		}
		out = append(out, k)
		b = rest
	}
	return out, nil
}
