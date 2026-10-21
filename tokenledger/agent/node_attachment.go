package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/attachment"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// openAttachment uses the existing per-login callback and cap. The signaling
// websocket never becomes a generic proxy: selection commits exactly one
// service adapter. Chat adoption supplies its own admission/adapter in C6.
func (a *Agent) openAttachment(parent context.Context, m control.Message, generation string) {
	var ro control.AttachmentOpen
	if json.Unmarshal(m.Payload, &ro) != nil || ro.RelayID == "" || len(ro.RelayID) > 128 || ro.Login != a.chatLogin() {
		return
	}
	service := ro.Service
	if service == "" {
		service = "term"
	} // previous nodes' terminal open
	path := control.AttachmentDataPath
	if service == "chat" {
		if !a.cfg.FleetChat || !a.chatRelays.take() {
			return
		}
		defer a.chatRelays.give()
		path = control.ChatAttachmentDataPath
	} else if service == "term" {
		if !a.cfg.FleetTerm || !a.termRelays.take(termRelayMaxPerLogin) {
			return
		}
		defer a.termRelays.give()
	} else {
		return
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	dctx, dcancel := context.WithTimeout(ctx, sshRelayDialTimeout)
	ws, err := a.dialRelayData(dctx, path, ro.RelayID, ro.Secret)
	dcancel()
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(control.AttachmentSignalMax)
	var initial control.AttachmentSignal
	if readRelayHello(ctx, ws, &initial) != nil {
		return
	}
	key := control.ChatTokenHash(a.cfg.Token)
	g, err := control.VerifyAttachment(initial.Grant, key, ro.Login, ro.RelayID, generation, time.Now())
	if err != nil || g.Service != service || g.Epoch != 1 || !a.termSpent.spend(g.Conn, time.Now()) {
		return
	}
	finish, err := a.attachments.begin(ctx, g, cancel)
	if err != nil {
		return
	}
	defer finish()
	var peer *attachment.Peer
	defer func() {
		if peer != nil {
			peer.Close()
		}
	}()
	answer := control.AttachmentSignal{T: "answer"}
	if g.Mode == "negotiate" {
		fp, err := attachment.Fingerprint(initial.SDP)
		if err != nil || fp != g.Fingerprint {
			return
		}
		nctx, ncancel := context.WithTimeout(ctx, control.AttachmentNegotiate)
		peer, answer.SDP, err = attachment.Answer(nctx, initial.SDP, initial.STUN)
		ncancel()
		if err != nil {
			answer.SDP = ""
			answer.Error = "ice_unavailable"
		}
	} else if g.Mode != "relay" || initial.SDP != "" {
		return
	}
	if writeAttachmentSignal(ctx, ws, answer) != nil {
		return
	}
	// One reader owns the socket in every phase; even a lease message can
	// never leak into a PTY. Its bounded inbox applies backpressure to the peer.
	s := newAuthorizedStream(ctx, cancel, ws, g, key)
	defer s.Close()
	go s.read()
	go s.watchLease()
	var selection control.AttachmentGrant
	var ticket string
	select {
	case sel := <-s.selected:
		selection, ticket = sel.grant, sel.ticket
	case <-ctx.Done():
		return
	case <-time.After(control.AttachmentNegotiate):
		return
	}
	var stream attachment.Stream = s
	pair := "hub"
	if selection.Mode == "direct" {
		if peer == nil {
			return
		}
		wctx, wcancel := context.WithTimeout(ctx, control.AttachmentNegotiate)
		err = peer.Wait(wctx)
		wcancel()
		if err != nil {
			return
		}
		pair, err = peer.Pair()
		if err != nil {
			return
		}
		stream = peer
	} else if selection.Mode == "door" {
		// XX79: the payload through the nearest door; leases and the lease's
		// end stay on this hub socket (s.watchLease), which closes it
		if peer != nil {
			peer.Close()
			peer = nil
		}
		ds, err := dialDoorPipe(ctx, selection.Door, ticket)
		if err != nil {
			_ = writeAttachmentSignal(ctx, ws, control.AttachmentSignal{T: "error", Error: "door_unavailable"})
			return
		}
		defer ds.Close()
		stream, pair = ds, "door"
	} else {
		// Close waits for ICE teardown before the fallback accesses the target.
		if peer != nil {
			peer.Close()
			peer = nil
		}
	}
	if ctx.Err() != nil {
		return
	}
	var h termHelper
	if service == "term" {
		hctx := context.WithValue(ctx, termRequestKey{}, termRequest{Resume: g.TermResume, Take: g.TermTake, Renew: g.TermRenew})
		h, err = startTermHelper(hctx, "web-"+g.Conn, g.Target, 0, 0)
		if err != nil {
			code := "ended"
			for _, known := range []string{"open_elsewhere", "interrupted", "ended"} {
				if strings.Contains(err.Error(), known) {
					code = known
					break
				}
			}
			failure := control.AttachmentSignal{T: "error", Error: code}
			var admission *termAdmissionFailure
			if errors.As(err, &admission) && code == "ended" {
				failure.Term, failure.TermGen = admission.Term, admission.Gen
			}
			_ = writeAttachmentSignal(ctx, ws, failure)
			return
		}
		defer h.Close()
	}
	if writeAttachmentSignal(ctx, ws, control.AttachmentSignal{T: "selected", Mode: selection.Mode, Pair: pair}) != nil {
		return
	}
	s.mu.Lock()
	s.active = selection.Mode == "relay"
	s.mu.Unlock()
	if peer != nil {
		peer.Arm()
	}
	if service == "chat" {
		a.spliceChatStream(ctx, cancel, stream, s, g)
	} else {
		spliceTermStream(ctx, stream, h)
	}
}

func writeAttachmentSignal(ctx context.Context, ws *websocket.Conn, v control.AttachmentSignal) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return ws.Write(wctx, websocket.MessageText, b)
}

type attachmentFrame struct {
	typ websocket.MessageType
	b   []byte
}

// selection is the hub's signed select and, for a door, this half's ticket.
type selection struct {
	grant  control.AttachmentGrant
	ticket string
}

// doorDialTimeout bounds the home's dial to a door's pipe: shorter than the
// door's wait for the other half.
const doorDialTimeout = 5 * time.Second

// doorPipeClient is how the home reaches a door (nil = the default client;
// tests trust their own door's certificate through SetDoorPipeClientForTest).
var doorPipeClient *http.Client

// dialDoorPipe joins the door's pipe named in the hub's signed grant.
func dialDoorPipe(ctx context.Context, door, ticket string) (attachment.Stream, error) {
	if !control.ValidDoorPipeURL(door) || ticket == "" {
		return nil, errors.New("not a door pipe")
	}
	dctx, cancel := context.WithTimeout(ctx, doorDialTimeout)
	defer cancel()
	c, _, err := websocket.Dial(dctx, door+"?t="+url.QueryEscape(ticket), &websocket.DialOptions{HTTPClient: doorPipeClient})
	if err != nil {
		return nil, err
	}
	c.SetReadLimit(attachment.FrameMax + 1024)
	return attachment.WebSocket{Conn: c}, nil
}

type authorizedStream struct {
	ctx      context.Context
	cancel   context.CancelFunc
	ws       *websocket.Conn
	key      string
	mu       sync.Mutex
	grant    control.AttachmentGrant
	active   bool
	selected chan selection
	in       chan attachmentFrame
	recorded chan struct{}
}

func newAuthorizedStream(ctx context.Context, cancel context.CancelFunc, ws *websocket.Conn, g control.AttachmentGrant, key string) *authorizedStream {
	return &authorizedStream{ctx: ctx, cancel: cancel, ws: ws, key: key, grant: g, selected: make(chan selection, 1), in: make(chan attachmentFrame, 8), recorded: make(chan struct{}, 1)}
}

func (s *authorizedStream) read() {
	defer s.cancel()
	for {
		t, b, err := s.ws.Read(s.ctx)
		if err != nil {
			return
		}
		var signal control.AttachmentSignal
		if t == websocket.MessageText && json.Unmarshal(b, &signal) == nil && (signal.T == "select" || signal.T == "lease") {
			s.mu.Lock()
			old := s.grant
			g, err := control.VerifyAttachment(signal.Grant, s.key, old.Login, old.Conn, old.Generation, time.Now())
			valid := err == nil && control.SameAttachment(old, g) && time.Now().Before(time.Unix(old.Exp, 0))
			if signal.T == "select" {
				valid = valid && old.Epoch == 1 && g.Epoch == 2 && old.Door == "" && old.Pipe == "" &&
					(g.Mode == "direct" || g.Mode == "relay" || (g.Mode == "door" && signal.Ticket != ""))
			} else {
				valid = valid && g.Epoch == old.Epoch && g.Mode == old.Mode && g.Exp >= old.Exp
			}
			if valid {
				s.grant = g
			}
			s.mu.Unlock()
			if !valid {
				return
			}
			if signal.T == "select" {
				s.selected <- selection{grant: g, ticket: signal.Ticket}
			}
			continue
		}
		if t == websocket.MessageText && json.Unmarshal(b, &signal) == nil && signal.T == "chat_recorded" {
			if s.grant.Service != "chat" || signal.Conn != s.grant.Chat.ID {
				return
			}
			select {
			case s.recorded <- struct{}{}:
			default:
				return
			}
			continue
		}
		s.mu.Lock()
		active := s.active
		s.mu.Unlock()
		if !active || len(b) > attachment.FrameMax {
			return
		}
		select {
		case s.in <- attachmentFrame{t, b}:
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *authorizedStream) watchLease() {
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-t.C:
			s.mu.Lock()
			exp := s.grant.Exp
			s.mu.Unlock()
			if !time.Now().Before(time.Unix(exp, 0)) {
				s.cancel()
				s.ws.CloseNow()
				return
			}
		}
	}
}
func (s *authorizedStream) Read(ctx context.Context) (websocket.MessageType, []byte, error) {
	select {
	case <-s.ctx.Done():
		return 0, nil, attachment.ErrClosed
	default:
	}
	select {
	case f := <-s.in:
		return f.typ, f.b, nil
	case <-ctx.Done():
		return 0, nil, ctx.Err()
	case <-s.ctx.Done():
		return 0, nil, attachment.ErrClosed
	}
}
func (s *authorizedStream) Write(ctx context.Context, t websocket.MessageType, b []byte) error {
	if len(b) > attachment.FrameMax {
		return errors.New("frame too large")
	}
	return s.ws.Write(ctx, t, b)
}
func (s *authorizedStream) Close() error { s.cancel(); return s.ws.CloseNow() }
