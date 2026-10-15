package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

func TestAttachmentLeaseAndEpoch(t *testing.T) {
	for _, reason := range []string{"expiry", "wrong-target", "stale-epoch", "renew"} {
		t.Run(reason, func(t *testing.T) {
			initialGrant := control.AttachmentGrant{V: 1, Person: "alice", Home: "node", Login: "alice", Node: "ep", Service: "term", Target: "personal", Conn: "conn", Generation: "gen", Mode: "relay", Epoch: 1, Iat: time.Now().Unix(), Exp: time.Now().Add(2 * time.Second).Unix()}
			done := make(chan struct{})
			selected := make(chan struct{})
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ws, err := websocket.Accept(w, r, nil)
				if err != nil {
					return
				}
				defer ws.CloseNow()
				ctx, cancel := context.WithCancel(r.Context())
				defer cancel()
				s := newAuthorizedStream(ctx, cancel, ws, initialGrant, "key")
				go s.read()
				go s.watchLease()
				select {
				case <-s.selected:
					close(selected)
				case <-ctx.Done():
				}
				<-ctx.Done()
				close(done)
			}))
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
			defer cancel()
			ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer ws.CloseNow()
			// The handler may still be starting after Dial returns. Keep its
			// initial grant separate from the client's selection and renewals.
			g := initialGrant
			if reason != "expiry" {
				g.Epoch = 2
				if err = writeAttachmentSignal(ctx, ws, control.AttachmentSignal{T: "select", Grant: control.SignAttachment(g, "key")}); err != nil {
					t.Fatal(err)
				}
				select {
				case <-selected:
				case <-ctx.Done():
					t.Fatal("not selected")
				}
				if reason == "wrong-target" {
					g.Target = "worker:other"
				}
				if reason == "stale-epoch" {
					g.Epoch = 1
				}
				if reason == "renew" {
					g.Iat = time.Now().Unix()
					g.Exp = time.Now().Add(control.AttachmentLease).Unix()
				}
				if err = writeAttachmentSignal(ctx, ws, control.AttachmentSignal{T: "lease", Grant: control.SignAttachment(g, "key")}); err != nil {
					t.Fatal(err)
				}
			}
			if reason == "renew" {
				select {
				case <-done:
					t.Fatal("valid lease closed early")
				case <-time.After(2100 * time.Millisecond):
				}
				ws.CloseNow()
			}
			select {
			case <-done:
			case <-ctx.Done():
				t.Fatal("authority remained active after " + reason)
			}
		})
	}
}

func TestAttachmentReplacementFence(t *testing.T) {
	var reg attachmentRegistry
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	g := control.AttachmentGrant{Person: "alice", Home: "node", Login: "alice", Service: "term", Target: "personal", Conn: "old", Generation: "one"}
	oldctx, oldcancel := context.WithCancel(ctx)
	finish, err := reg.begin(oldctx, g, oldcancel)
	if err != nil {
		t.Fatal(err)
	}
	defer finish()
	wrong := g
	wrong.Conn = "wrong"
	wrong.Previous = "old"
	wrong.Target = "worker:other"
	if _, err = reg.begin(ctx, wrong, func() {}); err == nil {
		t.Fatal("wrong target replaced old")
	}
	next := g
	next.Conn = "next"
	next.Previous = "old"
	started := make(chan func(), 1)
	go func() {
		f, e := reg.begin(ctx, next, func() {})
		if e == nil {
			started <- f
		}
	}()
	select {
	case <-oldctx.Done():
	case <-time.After(time.Second):
		t.Fatal("old not fenced")
	}
	select {
	case <-started:
		t.Fatal("replacement started before old cleanup")
	default:
	}
	finish()
	var nextFinish func()
	select {
	case nextFinish = <-started:
	case <-time.After(time.Second):
		t.Fatal("replacement did not start")
	}
	defer nextFinish()
	finish() // late old cleanup cannot remove the winner
	reg.mu.Lock()
	winner := reg.active["next"]
	reg.mu.Unlock()
	if winner == nil {
		t.Fatal("old cleanup removed winner")
	}
	next.Conn = "late"
	if _, err = reg.begin(ctx, next, func() {}); err == nil {
		t.Fatal("two successors won the same predecessor")
	}
}
