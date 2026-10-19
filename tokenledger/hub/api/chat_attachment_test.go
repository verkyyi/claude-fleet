package api

import (
	"context"
	"testing"

	"github.com/coder/websocket"
)

func (a *attachmentClient) text(t *testing.T, value string) {
	t.Helper()
	var err error
	if a.dc != nil {
		err = a.dc.SendText(value)
	} else {
		err = a.ws.Write(context.Background(), websocket.MessageText, []byte(value))
	}
	if err != nil {
		t.Fatal(err)
	}
}
