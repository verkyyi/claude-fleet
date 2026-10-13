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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
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
		if !c.canChat {
			seen = true
			continue
		}
		return epID, c, nil
	}
	if seen {
		return "", nil, sshRelayRefusal("NO_CHAT", "%s on %s runs an agent without the chat relay; update it", login, host)
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
	key := chatRelayKey(host, login)
	max := s.ChatRelayMaxPerLogin
	if max <= 0 {
		max = defaultChatRelayMaxPerLogin
	}
	if !s.chatRelays.admit(key, max) {
		return nil, sshRelayRefusal("TOO_MANY", "already %d chat relays open for %s", max, key)
	}
	rctx, cancel := context.WithCancel(context.Background())
	p := &pendingSSHRelay{id: control.NewOpID(), secret: control.NewOpID(), endpointID: epID, node: nc,
		attach: make(chan *websocket.Conn, 1), done: make(chan struct{}), cancel: cancel}
	s.chatRelays.put(p)
	started := time.Now()
	var once sync.Once
	end := func(why string) {
		once.Do(func() {
			cancel()
			close(p.done)
			s.chatRelays.drop(p.id)
			s.chatRelays.release(key)
			log.Printf("chat relay %s: %s -> %s: %s after %s", p.id[:8], person, key, why, time.Since(started).Round(time.Second))
		})
	}

	open, _ := control.New(control.TypeChatRelayOpen, control.ChatRelayOpen{RelayID: p.id, Secret: p.secret, Login: login})
	wctx, wcancel := context.WithTimeout(ctx, 5*time.Second)
	err = s.SendNodeWrite(wctx, epID, open)
	wcancel()
	if err != nil {
		end("ask the agent: " + err.Error())
		return nil, sshRelayRefusal("NODE_OFFLINE", "%s's agent did not take the request: %v", key, err)
	}
	var agentConn *websocket.Conn
	t := time.NewTimer(sshRelayAttachTimeout)
	defer t.Stop()
	select {
	case agentConn = <-p.attach:
	case <-t.C:
		end("agent never attached")
		return nil, sshRelayRefusal("NODE_TIMEOUT", "%s's agent did not open the stream within %s", key, sshRelayAttachTimeout)
	case <-ctx.Done():
		end("caller gone")
		return nil, ctx.Err()
	case <-rctx.Done():
		end("agent disconnected")
		return nil, sshRelayRefusal("NODE_OFFLINE", "%s's agent disconnected", key)
	}

	tokHash := nc.tokHash
	if tokHash == "" {
		if tokHash, err = s.Store.EndpointTokenHash(epID); err != nil || tokHash == "" {
			end("no token hash to sign with")
			return nil, sshRelayRefusal("INTERNAL", "cannot sign for %s", key)
		}
	}
	now := time.Now()
	hello, _ := json.Marshal(control.ChatRelayHello{Person: control.SignChatPerson(control.ChatPerson{
		V: 1, Person: person, Login: login, Relay: p.id, Iat: now.Unix(), Exp: now.Add(chatPersonTTL).Unix(),
	}, tokHash)})
	wctx, wcancel = context.WithTimeout(ctx, 5*time.Second)
	err = agentConn.Write(wctx, websocket.MessageText, hello)
	wcancel()
	if err != nil {
		end("agent gone before the stream started")
		return nil, sshRelayRefusal("NODE_OFFLINE", "%s's agent closed the stream: %v", key, err)
	}
	rd := s.ChatRelayRateBPS
	if rd == 0 {
		rd = defaultChatRelayRateBPS
	}
	return &chatRelayConn{
		Conn: websocket.NetConn(rctx, agentConn, websocket.MessageBinary),
		ctx:  rctx, lim: s.chatRelays.limiter(key, rd), end: end,
	}, nil
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
