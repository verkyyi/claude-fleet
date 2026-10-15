// Package attachment is the bounded, transport-neutral frame layer shared by
// browser terminals and chat request adapters. It knows no PTY, socket or user.
package attachment

import (
	"context"
	"errors"

	"github.com/coder/websocket"
)

const (
	FrameMax     = 32 << 10
	BufferMax    = 256 << 10
	SignalMax    = 32 << 10
	SDPMax       = 24 << 10
	CandidateMax = 32
	ChannelLabel = "fleet.v1"
)

var ErrClosed = errors.New("attachment closed")
var ErrBackpressure = errors.New("attachment buffer full")

// Stream preserves message type, ordering and bytes, including split UTF-8.
// Callers must wait for their service's explicit ready before sending input.
type Stream interface {
	Read(context.Context) (websocket.MessageType, []byte, error)
	Write(context.Context, websocket.MessageType, []byte) error
	Close() error
}

type WebSocket struct{ Conn *websocket.Conn }

func (s WebSocket) Read(ctx context.Context) (websocket.MessageType, []byte, error) {
	return s.Conn.Read(ctx)
}
func (s WebSocket) Write(ctx context.Context, t websocket.MessageType, b []byte) error {
	if len(b) > FrameMax {
		return errors.New("attachment frame too large")
	}
	return s.Conn.Write(ctx, t, b)
}
func (s WebSocket) Close() error { return s.Conn.CloseNow() }
