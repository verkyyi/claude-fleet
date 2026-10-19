package api

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The hub half of the chat relay (claude-fleet#3644, EPIC #3642 C2). The entry's
// /v1/chat/* (C3) has already decided WHO is asking and found their home login;
// dialChatRelay opens one stream to that login's conversation service:
//
//	hub ──TypeChatRelayOpen {id, secret, login}──▶ that login's agent (CapChat only)
//	agent ──wss ChatRelayDataPath?id=…──▶ hub (attachRelayData, the SSH relay's door)
//	hub ──first frame {"person": X-Fleet-Person}──▶ agent, which verifies it, then
//	agent ──as the login──▶ $FLEET_CONF_DIR/webchat/chat.sock
//
// The statement is signed with the token hash that login's link proved itself
// with (the worker assertion's keying, #1810): only the hub, or that login's own
// node, can make one — never another login on the same machine. Each login gets
// at most ChatRelayMaxPerLogin relays at once and ChatRelayRateBPS bytes a
// second across all of them, the SSH relay's two bounds keyed by login.

const (
	defaultChatRelayMaxPerLogin = 8
	// 1 MiB/s: a conversation is text; this still bounds a runaway page.
	defaultChatRelayRateBPS = 1 << 20
	// chatPersonTTL is how long a statement holds: it is read once, the
	// moment the agent attaches.
	chatPersonTTL = 2 * time.Minute
)

// chatRelayKey is what the per-login bounds count by.
func chatRelayKey(host, login string) string { return host + "/" + login }

// chatRelayNode picks the link that carries a chat relay to login on host: that
// login's own agent (or its lane on the machine link), connected, write-
// compatible and offering CapChat. Another login's agent is never used — the
// socket is reachable only as the login.
func (s *Server) chatRelayNode(host, login string) (string, *nodeConn, error) {
	return s.loginRelayNode(host, login, func(c *nodeConn) bool { return c.canChat },
		"NO_CHAT", "the chat relay")
}

// loginRelayNode picks login's own link on host that offers a relay kind (has):
// the chat relay's and the terminal's (claude-fleet#3838) one picker. A link
// of that login without it answers missing; none at all, NODE_OFFLINE.
func (s *Server) loginRelayNode(host, login string, has func(*nodeConn) bool, missing, what string) (string, *nodeConn, error) {
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	ids := make([]string, 0, len(s.nodes.conns))
	for epID := range s.nodes.conns {
		ids = append(ids, epID)
	}
	sort.Strings(ids)
	seen := false
	for _, epID := range ids {
		c := s.nodes.conns[epID]
		if c.hostname() != host || c.user() != login || !control.Compatible(int(c.proto.Load())) {
			continue
		}
		if !has(c) {
			seen = true
			continue
		}
		return epID, c, nil
	}
	if seen {
		return "", nil, sshRelayRefusal(missing, "%s on %s runs an agent without %s; update it", login, host, what)
	}
	return "", nil, sshRelayRefusal("NODE_OFFLINE", "%s on %s is not connected", login, host)
}

// dialChatRelay opens one chat relay for person to login on host and returns it
// as a stream: what is written reaches the conversation socket, what it answers
// is read back. Close ends the relay. ctx bounds only the opening.
func (s *Server) dialChatRelay(ctx context.Context, person, host, login string) (net.Conn, error) {
	if person == "" || host == "" || login == "" {
		return nil, sshRelayRefusal("BAD_REQUEST", "a chat relay needs a person, a machine and a login")
	}
	epID, nc, err := s.chatRelayNode(host, login)
	if err != nil {
		return nil, err
	}
	max := s.ChatRelayMaxPerLogin
	if max <= 0 {
		max = defaultChatRelayMaxPerLogin
	}
	or, err := s.openLoginRelay(ctx, loginRelaySpec{
		kind: "chat relay", table: &s.chatRelays, epID: epID, node: nc,
		key: chatRelayKey(host, login), max: max, person: person,
		open: func(id, secret string) (control.Message, error) {
			return control.New(control.TypeChatRelayOpen, control.ChatRelayOpen{RelayID: id, Secret: secret, Login: login})
		},
		hello: func(id, tokHash string, now time.Time) []byte {
			b, _ := json.Marshal(control.ChatRelayHello{Person: control.SignChatPerson(control.ChatPerson{
				V: 1, Person: person, Login: login, Relay: id, Iat: now.Unix(), Exp: now.Add(chatPersonTTL).Unix(),
			}, tokHash)})
			return b
		},
	})
	if err != nil {
		return nil, err
	}
	rd := s.ChatRelayRateBPS
	if rd == 0 {
		rd = defaultChatRelayRateBPS
	}
	return &chatRelayConn{
		Conn: websocket.NetConn(or.ctx, or.ws, websocket.MessageBinary),
		ctx:  or.ctx, lim: s.chatRelays.limiter(or.key, rd), end: or.end,
	}, nil
}

// loginRelaySpec is one relay to ask a login's agent for: which table admits
// and holds it, the open request and the first frame (the statement) to send.
type loginRelaySpec struct {
	kind   string // "chat relay", "term relay": the log's word
	table  *sshRelayTable
	epID   string
	node   *nodeConn
	key    string // what the table's bound counts by
	max    int
	person string
	open   func(id, secret string) (control.Message, error)
	hello  func(id, tokHash string, now time.Time) []byte
}

// openedRelay is a relay whose agent attached and took the first frame.
type openedRelay struct {
	id, key string
	ws      *websocket.Conn
	// ctx ends when the relay does (Close, or the agent's link dropped).
	ctx context.Context
	end func(why string)
}

// openLoginRelay is the chat relay's and the terminal's (claude-fleet#3838) one
// opening: admit the relay against its table's per-key bound, ask the agent on
// its control channel, wait for its data stream (sshRelayAttachTimeout), sign
// and send the first frame with the token hash that link proved its login
// with. Every failure ends the relay and frees its slot; end is idempotent.
func (s *Server) openLoginRelay(ctx context.Context, sp loginRelaySpec) (*openedRelay, error) {
	if !sp.table.admit(sp.key, sp.max) {
		return nil, sshRelayRefusal("TOO_MANY", "already %d %ss open for %s", sp.max, sp.kind, sp.key)
	}
	rctx, cancel := context.WithCancel(context.Background())
	p := &pendingSSHRelay{id: control.NewOpID(), secret: control.NewOpID(), endpointID: sp.epID, node: sp.node,
		attach: make(chan *websocket.Conn, 1), done: make(chan struct{}), cancel: cancel}
	sp.table.put(p)
	started := time.Now()
	var once sync.Once
	end := func(why string) {
		once.Do(func() {
			cancel()
			close(p.done)
			sp.table.drop(p.id)
			sp.table.release(sp.key)
			log.Printf("%s %s: %s -> %s: %s after %s", sp.kind, p.id[:8], sp.person, sp.key, why, time.Since(started).Round(time.Second))
		})
	}

	open, err := sp.open(p.id, p.secret)
	if err != nil {
		end("build the request: " + err.Error())
		return nil, sshRelayRefusal("INTERNAL", "cannot build the request")
	}
	wctx, wcancel := context.WithTimeout(ctx, 5*time.Second)
	err = s.SendNodeWrite(wctx, sp.epID, open)
	wcancel()
	if err != nil {
		end("ask the agent: " + err.Error())
		return nil, sshRelayRefusal("NODE_OFFLINE", "%s's agent did not take the request: %v", sp.key, err)
	}
	var agentConn *websocket.Conn
	t := time.NewTimer(sshRelayAttachTimeout)
	defer t.Stop()
	select {
	case agentConn = <-p.attach:
	case <-t.C:
		end("agent never attached")
		return nil, sshRelayRefusal("NODE_TIMEOUT", "%s's agent did not open the stream within %s", sp.key, sshRelayAttachTimeout)
	case <-ctx.Done():
		end("caller gone")
		return nil, ctx.Err()
	case <-rctx.Done():
		end("agent disconnected")
		return nil, sshRelayRefusal("NODE_OFFLINE", "%s's agent disconnected", sp.key)
	}

	tokHash := sp.node.tokHash
	if tokHash == "" {
		if tokHash, err = s.Store.EndpointTokenHash(sp.epID); err != nil || tokHash == "" {
			end("no token hash to sign with")
			return nil, sshRelayRefusal("INTERNAL", "cannot sign for %s", sp.key)
		}
	}
	wctx, wcancel = context.WithTimeout(ctx, 5*time.Second)
	err = agentConn.Write(wctx, websocket.MessageText, sp.hello(p.id, tokHash, time.Now()))
	wcancel()
	if err != nil {
		end("agent gone before the stream started")
		return nil, sshRelayRefusal("NODE_OFFLINE", "%s's agent closed the stream: %v", sp.key, err)
	}
	return &openedRelay{id: p.id, key: sp.key, ws: agentConn, ctx: rctx, end: end}, nil
}

// handleChatRelayData serves ChatRelayDataPath: an agent attaching the data half
// of a chat relay the hub asked it for — the SSH relay's door, its own table.
func (s *Server) handleChatRelayData(w http.ResponseWriter, r *http.Request) {
	s.attachRelayData(w, r, &s.chatRelays)
}

// chatRelayConn is one chat relay as a net.Conn, paced by its login's limiter.
type chatRelayConn struct {
	net.Conn
	ctx context.Context
	lim *byteLimiter
	end func(string)
}

func (c *chatRelayConn) Read(b []byte) (int, error) {
	if len(b) > sshRelayChunk {
		b = b[:sshRelayChunk]
	}
	n, err := c.Conn.Read(b)
	if n > 0 {
		if werr := c.lim.wait(c.ctx, n); werr != nil && err == nil {
			err = werr
		}
	}
	return n, err
}

func (c *chatRelayConn) Write(b []byte) (int, error) {
	total := 0
	for len(b) > 0 {
		k := len(b)
		if k > sshRelayChunk {
			k = sshRelayChunk
		}
		if err := c.lim.wait(c.ctx, k); err != nil {
			return total, err
		}
		n, err := c.Conn.Write(b[:k])
		total += n
		if err != nil {
			return total, err
		}
		b = b[k:]
	}
	return total, nil
}

func (c *chatRelayConn) Close() error {
	err := c.Conn.Close()
	c.end("closed")
	return err
}

// chatRelayPeer is the other replica to hand a person's whole /v1/chat request
// to (claude-fleet#3847, the SSH relay's #2151 half the chat routes lacked):
// only when this one holds no link to login on host able to carry a chat relay
// and another replica holds one that offered CapChat. That replica serves it as
// its own — it signs the person in again, opens the relay and audits it — and a
// request already handed over (the replicas' token) is never handed on again.
// Off — a single hub — it is never asked.
func (s *Server) chatRelayPeer(r *http.Request, host, login string) (store.NodeConn, bool) {
	if s.Replica == nil || s.relayHopped(r) {
		return store.NodeConn{}, false
	}
	if _, _, err := s.chatRelayNode(host, login); err == nil {
		return store.NodeConn{}, false
	}
	return s.peerLoginLink(host, login, control.CapChat)
}

// peerLoginLink is the other replica's link to login on host offering cap, the
// lowest endpoint id first; false when none does.
func (s *Server) peerLoginLink(host, login, cap string) (store.NodeConn, bool) {
	peers := s.peerConns()
	if len(peers) == 0 {
		return store.NodeConn{}, false
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		log.Printf("fleet: read nodes for a login relay: %v", err)
		return store.NodeConn{}, false
	}
	var l []store.NodeConn
	for _, n := range nodes {
		pc, ok := peers[n.EndpointID]
		if !ok || n.Hostname != host || n.OSUser != login || !pc.HasCap(cap) || !control.Compatible(n.Proto) {
			continue
		}
		l = append(l, pc)
	}
	if len(l) == 0 {
		return store.NodeConn{}, false
	}
	sort.Slice(l, func(i, j int) bool { return l[i].EndpointID < l[j].EndpointID })
	return l[0], true
}
