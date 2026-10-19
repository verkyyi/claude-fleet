package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/pion/webrtc/v4"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/attachment"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestAttachmentControllerCapability(t *testing.T) {
	r := newTermRig(t, true)
	r.nc.canTermController = false
	c, status := dialAttachment(t, r, "service=term&target=personal&controller=1", r.alice)
	if c != nil || status != http.StatusConflict || len(r.starts()) != 0 {
		t.Fatalf("old node admitted recovery: socket=%v status=%d starts=%v", c, status, r.starts())
	}
}

// Renewal uses the existing authenticated attachment admission in both modes.
// An old node must refuse the mutation, not silently treat it as reconnect.
func TestAttachmentRenewAdmission(t *testing.T) {
	r := newTermRig(t, true)
	for _, query := range []string{
		"service=term&worker=" + r.wid + "&renew=1&term_resume=terminal:1",
		"service=term&target=personal&renew=1",
		"service=term&target=personal&renew=1&term_resume=terminal:1&take=1",
	} {
		c, status := dialAttachment(t, r, query, r.alice)
		if c != nil || status != 400 {
			t.Fatalf("invalid renew: %s socket=%v status=%d", query, c, status)
		}
	}
	query := "service=term&target=personal&renew=1&term_resume=terminal:1"
	c, status := dialAttachment(t, r, query, nil)
	if c != nil || status != 401 {
		t.Fatalf("unauthenticated renew: %v %d", c, status)
	}
	r.nc.canTermRenew = false
	c, status = dialAttachment(t, r, query, r.alice)
	if c != nil || status != 409 || len(r.starts()) != 0 {
		t.Fatalf("old node renew: %v %d %v", c, status, r.starts())
	}
}

func dialAttachment(t *testing.T, r *termRig, query string, cookie *http.Cookie) (*websocket.Conn, int) {
	t.Helper()
	h := http.Header{"Origin": []string{r.origin}}
	if cookie != nil {
		h.Set("Cookie", cookie.String())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(r.origin, "http")+AttachmentPath+"?"+query, &websocket.DialOptions{HTTPHeader: h})
	if err != nil {
		if resp != nil {
			return nil, resp.StatusCode
		}
		t.Fatal(err)
	}
	return c, 101
}

type attachmentClient struct {
	ws              *websocket.Conn
	pc              *webrtc.PeerConnection
	dc              *webrtc.DataChannel
	data            chan attachmentFrame
	signals         <-chan attachmentFrame
	gen, conn, pair string
	mode            string
}

func receiveAttachment(t *testing.T, ch <-chan attachmentFrame) attachmentFrame {
	t.Helper()
	select {
	case f := <-ch:
		if f.err != nil {
			t.Fatal(f.err)
		}
		return f
	case <-time.After(15 * time.Second):
		t.Fatal("attachment receive timeout")
	}
	return attachmentFrame{}
}

// A real Pion client connects to the real node adapter, which opens the isolated
// PTY command from C1's rig. No live tmux server or AI process is involved.
func connectAttachmentTest(t *testing.T, r *termRig, direct bool) *attachmentClient {
	t.Helper()
	c, st := dialAttachment(t, r, "service=term&worker="+r.wid, r.alice)
	if c == nil {
		t.Fatalf("attach status %d", st)
	}
	return connectAttachmentSocket(t, c, direct)
}

func connectAttachmentSocket(t *testing.T, c *websocket.Conn, direct bool) *attachmentClient {
	ctx, cancel := context.WithCancel(context.Background())
	a := &attachmentClient{ws: c, signals: readAttachmentFrames(ctx, c), data: make(chan attachmentFrame, 32), mode: "relay"}
	t.Cleanup(func() {
		cancel()
		if a.pc != nil {
			a.pc.Close()
		}
		c.CloseNow()
	})
	var config control.AttachmentSignal
	f := receiveAttachment(t, a.signals)
	if json.Unmarshal(f.b, &config) != nil || config.T != "config" {
		t.Fatalf("config %s", f.b)
	}
	a.gen = config.Generation
	if direct {
		a.mode = "direct"
		var err error
		a.pc, err = webrtc.NewPeerConnection(webrtc.Configuration{})
		if err != nil {
			t.Fatal(err)
		}
		proto := attachment.ChannelLabel
		a.dc, err = a.pc.CreateDataChannel(proto, &webrtc.DataChannelInit{Protocol: &proto})
		if err != nil {
			t.Fatal(err)
		}
		a.dc.OnMessage(func(m webrtc.DataChannelMessage) {
			typ := websocket.MessageBinary
			if m.IsString {
				typ = websocket.MessageText
			}
			select {
			case a.data <- attachmentFrame{typ: typ, b: m.Data}:
			case <-ctx.Done():
			}
		})
		a.dc.OnOpen(func() { sendAttachmentSignal(ctx, c, control.AttachmentSignal{T: "select", Mode: "direct"}) })
		offer, err := a.pc.CreateOffer(nil)
		if err != nil {
			t.Fatal(err)
		}
		gather := webrtc.GatheringCompletePromise(a.pc)
		if err = a.pc.SetLocalDescription(offer); err != nil {
			t.Fatal(err)
		}
		select {
		case <-gather:
		case <-time.After(5 * time.Second):
			t.Fatal("ICE gathering timeout")
		}
		if err = sendAttachmentSignal(ctx, c, control.AttachmentSignal{T: "offer", SDP: a.pc.LocalDescription().SDP}); err != nil {
			t.Fatal(err)
		}
	} else {
		sendAttachmentSignal(ctx, c, control.AttachmentSignal{T: "relay"})
		sendAttachmentSignal(ctx, c, control.AttachmentSignal{T: "select", Mode: "relay"})
	}
	for {
		f := receiveAttachment(t, a.signals)
		var sig control.AttachmentSignal
		if json.Unmarshal(f.b, &sig) != nil {
			t.Fatalf("unexpected signal %s", f.b)
		}
		switch sig.T {
		case "hello":
			a.conn = sig.Conn
		case "answer":
			if direct {
				if sig.Error != "" {
					t.Fatal(sig.Error)
				}
				if err := a.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: sig.SDP}); err != nil {
					t.Fatal(err)
				}
			}
		case "selected":
			a.pair = sig.Pair
			if sig.Mode != a.mode {
				t.Fatalf("mode %s want %s", sig.Mode, a.mode)
			}
			if direct {
				f := receiveAttachment(t, a.data)
				if !strings.Contains(string(f.b), `"ready"`) {
					t.Fatalf("not ready: %s", f.b)
				}
				return a
			}
		case "ready":
			return a
		case "error":
			t.Fatal(sig.Error)
		}
	}
}

func (a *attachmentClient) send(t *testing.T, b []byte) {
	t.Helper()
	var err error
	if a.dc != nil {
		err = a.dc.Send(b)
	} else {
		err = a.ws.Write(context.Background(), websocket.MessageBinary, b)
	}
	if err != nil {
		t.Fatal(err)
	}
}
func (a *attachmentClient) output(t *testing.T, want string) {
	t.Helper()
	ch := a.signals
	if a.dc != nil {
		ch = a.data
	}
	var out strings.Builder
	for !strings.Contains(out.String(), want) {
		f := receiveAttachment(t, ch)
		if f.typ == websocket.MessageBinary {
			out.Write(f.b)
		}
	}
}

func TestAttachmentDirectOrderedBytes(t *testing.T) {
	r := newTermRig(t, true)
	a := connectAttachmentTest(t, r, true)
	if a.pair == "" || strings.Contains(a.pair, "relay") || a.pair == "hub" {
		t.Fatalf("not direct: %s", a.pair)
	}
	// Split a UTF-8 scalar over separate ordered frames, then two commands.
	b := []byte("中文\n")
	a.send(t, b[:1])
	a.send(t, b[1:4])
	a.send(t, b[4:])
	a.output(t, "got:中文")
	a.send(t, []byte("second\n"))
	a.output(t, "got:second")
	a.pc.Close()
	a.ws.CloseNow()
	waitFor(t, 30*time.Second, "direct resources cleaned", func() bool { return r.procs() == 0 && r.h.srv.termRelays.open() == 0 })
	rows, err := r.h.srv.Store.FleetTermSessions(pAlice, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Mode != "direct" || rows[0].BytesUp != 0 || rows[0].BytesDown != 0 {
		t.Fatalf("hub payload counters: %+v", rows)
	}
	t.Logf("direct pair=%s target=%s generation=%s hub_payload=0/0 processes=0", a.pair, r.wid, a.gen)
}

func TestAttachmentRelayAndLateSelection(t *testing.T) {
	r := newTermRig(t, true)
	a := connectAttachmentTest(t, r, false)
	// An expired direct attempt can neither switch nor close the relay winner.
	sendAttachmentSignal(context.Background(), a.ws, control.AttachmentSignal{T: "select", Mode: "direct"})
	a.send(t, []byte("one-command\n"))
	a.output(t, "got:one-command")
	a.ws.CloseNow()
	waitFor(t, 30*time.Second, "relay resources cleaned", func() bool { return r.procs() == 0 && r.h.srv.termRelays.open() == 0 })
	rows, _ := r.h.srv.Store.FleetTermSessions(pAlice, 5)
	if len(rows) != 1 || rows[0].Mode != "relay" || rows[0].BytesUp == 0 || rows[0].BytesDown == 0 {
		t.Fatalf("relay counters %+v", rows)
	}
}

func TestAttachmentRejectsBeforeTarget(t *testing.T) {
	r := newTermRig(t, true)
	for _, tc := range []struct {
		name, query string
		cookie      *http.Cookie
		status      int
	}{
		{"other person", "service=term&worker=" + r.wid, personCookie(pCarol, "carol"), 409},
		{"admin", "service=term&worker=" + r.wid, r.bobAd, 409},
		{"other service", "service=chat&target=personal", r.alice, 400},
		{"replacement pod", "service=term&target=personal&generation=old-pod", r.alice, 409},
		{"arbitrary target", "service=term&target=/bin/sh", r.alice, 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, st := dialAttachment(t, r, tc.query, tc.cookie)
			if c != nil {
				c.CloseNow()
				t.Fatal("unauthorized attachment")
			}
			if st != tc.status {
				t.Fatalf("status %d want %d", st, tc.status)
			}
		})
	}
	if r.procs() != 0 || len(r.starts()) != 0 {
		t.Fatal("unauthorized target accessed")
	}
	// Data while signaling cannot be turned into later input.
	c, st := dialAttachment(t, r, "service=term&target=personal", r.alice)
	if c == nil {
		t.Fatal(st)
	}
	send(t, c, websocket.MessageBinary, []byte("must-not-run\n"))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, _, err := c.Read(ctx)
		if err != nil {
			break
		}
	}
	c.CloseNow()
	if r.procs() != 0 || len(r.starts()) != 0 {
		t.Fatal("signaling data reached target")
	}
}

func TestAttachmentLogoutRevokesDirect(t *testing.T) {
	r := newTermRig(t, true)
	a := connectAttachmentTest(t, r, true)
	// Keep reading signaling so hub pings prove this is revocation, not a dead
	// browser. Logout on another HTTP request invalidates the existing authority.
	resp := r.h.postForm(t, "/logout", map[string]string{"Cookie": r.alice.String(), "Origin": r.origin})
	resp.Body.Close()
	waitFor(t, 12*time.Second, "logout closed direct target", func() bool { return r.procs() == 0 && r.h.srv.termRelays.open() == 0 })
	c, st := dialAttachment(t, r, "service=term&target=personal", r.alice)
	if c != nil {
		c.CloseNow()
		t.Fatal("saved cookie reattached after logout")
	}
	if st != 401 {
		t.Fatalf("status %d", st)
	}
	a.ws.CloseNow()
}

func TestAttachmentGrantReplayAndWrongService(t *testing.T) {
	r := newTermRig(t, true)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	id := control.NewOpID()
	good := control.AttachmentGrant{V: 1, Person: pAlice, Home: r.host, Login: r.login, Node: "ep_" + r.label, Service: "term", Target: "personal", Conn: id, Generation: r.nc.attachmentGeneration, Mode: "relay", Epoch: 1, Iat: time.Now().Unix(), Exp: time.Now().Add(control.AttachmentLease).Unix()}
	attempt := func(g control.AttachmentGrant, wantAnswer bool) {
		p := &pendingSSHRelay{id: g.Conn, secret: control.NewOpID(), endpointID: "ep_" + r.label, node: r.nc, attach: make(chan *websocket.Conn, 1), done: make(chan struct{}), cancel: func() {}}
		r.h.srv.termRelays.put(p)
		defer r.h.srv.termRelays.drop(p.id)
		defer close(p.done)
		m, _ := control.New(control.TypeAttachmentOpen, control.AttachmentOpen{RelayID: p.id, Secret: p.secret, Login: r.login})
		if err := r.h.srv.SendNodeWrite(ctx, p.endpointID, m); err != nil {
			t.Fatal(err)
		}
		var ws *websocket.Conn
		select {
		case ws = <-p.attach:
		case <-time.After(5 * time.Second):
			t.Fatal("no node callback")
		}
		defer ws.CloseNow()
		sendAttachmentSignal(ctx, ws, control.AttachmentSignal{T: "open", Grant: control.SignAttachment(g, r.nc.tokHash)})
		rctx, rcancel := context.WithTimeout(ctx, 5*time.Second)
		defer rcancel()
		_, b, err := ws.Read(rctx)
		if wantAnswer {
			if err != nil || !strings.Contains(string(b), `"answer"`) {
				t.Fatalf("first use: %s %v", b, err)
			}
		} else if err == nil {
			t.Fatalf("invalid/replayed grant accepted: %s", b)
		}
	}
	wrong := good
	wrong.Service = "chat"
	wrong.Target = "conversation"
	attempt(wrong, false)
	old := good
	old.Generation = "old-pod"
	attempt(old, false)
	attempt(good, true)
	attempt(good, false)
	if r.procs() != 0 || len(r.starts()) != 0 {
		t.Fatal("grant rejection/negotiation touched target")
	}
}
