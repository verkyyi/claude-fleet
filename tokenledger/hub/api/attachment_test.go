package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/pion/webrtc/v4"
)

type attachmentClient struct {
	ws              *websocket.Conn
	pc              *webrtc.PeerConnection
	dc              *webrtc.DataChannel
	data            chan attachmentFrame
	signals         <-chan attachmentFrame
	gen, conn, pair string
	mode            string
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
