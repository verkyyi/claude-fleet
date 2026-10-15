package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/attachment"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The shared per-login direct budget bounds all simultaneous chat channels.
// Relay traffic is additionally held to the hub's existing login budget.
type chatRate struct {
	mu   sync.Mutex
	next time.Time
}

func (r *chatRate) wait(ctx context.Context, n int, bps int64) error {
	if bps <= 0 {
		return nil
	}
	r.mu.Lock()
	now := time.Now()
	if r.next.Before(now) {
		r.next = now
	}
	r.next = r.next.Add(time.Duration(int64(n) * int64(time.Second) / bps))
	d := time.Until(r.next)
	r.mu.Unlock()
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (a *Agent) spliceChatStream(ctx context.Context, cancel context.CancelFunc, stream attachment.Stream, auth *authorizedStream, g control.AttachmentGrant) {
	// Only trusted node results go on the signaling lane. A browser can never
	// turn a data frame into a refund or change the grant's service/route.
	result := func(refund bool) {
		if ctx.Err() != nil {
			return
		}
		if writeAttachmentSignal(ctx, auth.ws, control.AttachmentSignal{T: "chat_result", Conn: g.Chat.ID, Refund: refund}) != nil {
			return
		}
		select {
		case <-auth.recorded:
		case <-ctx.Done():
		case <-time.After(5 * time.Second):
		}
	}
	write := func(t websocket.MessageType, b []byte) error {
		if err := a.chatDirectRate.wait(ctx, len(b), g.Chat.Rate); err != nil {
			return err
		}
		wctx, stop := context.WithTimeout(ctx, 5*time.Second)
		defer stop()
		// Backpressure is bounded: wait only for a frame the peer refused before
		// enqueuing it, never resend a frame that may have been delivered.
		for {
			err := stream.Write(wctx, t, b)
			if !errors.Is(err, attachment.ErrBackpressure) {
				return err
			}
			select {
			case <-wctx.Done():
				return wctx.Err()
			case <-time.After(5 * time.Millisecond):
			}
		}
	}
	send := func(v control.ChatAttachmentFrame) error {
		b, _ := json.Marshal(v)
		return write(websocket.MessageText, b)
	}
	if send(control.ChatAttachmentFrame{T: "ready"}) != nil {
		return
	}
	// Do not connect to chat.sock until a complete, bounded request arrived.
	rctx, stop := context.WithTimeout(ctx, 15*time.Second)
	body, err := readChatRequest(rctx, stream, g.Chat.Bytes, func(n int) error {
		if err := a.chatDirectRate.wait(rctx, n, g.Chat.Rate); err != nil {
			return err
		}
		return send(control.ChatAttachmentFrame{T: "continue"})
	})
	stop()
	if err != nil {
		result(true)
		return
	}
	if writeAttachmentSignal(ctx, auth.ws, control.AttachmentSignal{T: "chat_accepted", Conn: g.Chat.ID}) != nil {
		return
	}
	ack := make(chan struct{}, 1)
	go func() {
		t, b, err := stream.Read(ctx)
		var f control.ChatAttachmentFrame
		if err == nil && t == websocket.MessageText && json.Unmarshal(b, &f) == nil && f.T == "received" {
			ack <- struct{}{}
			return
		}
		// cancel, unexpected input, or disconnection closes only this request.
		cancel()
	}()
	dctx, dcancel := context.WithTimeout(ctx, sshRelayDialTimeout)
	sock, err := a.chatSockOrEnsure(ctx, dctx, g.Login, g.Conn, dialChatSock)
	dcancel()
	if err != nil {
		result(true)
		send(control.ChatAttachmentFrame{T: "failed", Error: "home_down"})
		return
	}
	defer sock.Close()
	headerDeadline := time.AfterFunc(30*time.Second, func() { sock.Close() })
	defer headerDeadline.Stop()
	stopSocket := context.AfterFunc(ctx, func() { sock.Close() })
	defer stopSocket()
	method := http.MethodPost
	if g.Target == "conversation" {
		method = http.MethodGet
	}
	req, _ := http.NewRequestWithContext(ctx, method, "http://webchat/api/"+g.Target, bytes.NewReader(body))
	req.Close = true
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Fleet-Webchat", "1")
	req.Header.Set(control.ChatPersonHeader, g.Person)
	if g.Chat.Client != "" {
		req.Header.Set(control.ChatClientHeader, g.Chat.Client)
	}
	if err := req.Write(sock); err != nil {
		result(true)
		return
	}
	// Bounded response headers; the body stays streaming and may outlive a tab.
	reader := bufio.NewReaderSize(sock, attachment.FrameMax)
	var header []byte
	for {
		line, err := reader.ReadSlice('\n')
		if err != nil || len(header)+len(line) > attachment.FrameMax {
			result(true)
			return
		}
		header = append(header, line...)
		if bytes.Equal(line, []byte("\r\n")) {
			break
		}
	}
	resp, err := http.ReadResponse(bufio.NewReader(io.MultiReader(bytes.NewReader(header), reader)), req)
	if err != nil {
		result(true)
		return
	}
	defer resp.Body.Close()
	headerDeadline.Stop()
	if send(control.ChatAttachmentFrame{T: "headers", Status: resp.StatusCode, ContentType: resp.Header.Get("Content-Type")}) != nil {
		return
	}
	var outcome control.ChatOutcome
	buf := make([]byte, 16<<10)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			outcome.Feed(buf[:n])
			if write(websocket.MessageBinary, buf[:n]) != nil {
				return
			}
		}
		if err != nil {
			result(resp.StatusCode != http.StatusOK || outcome.Refund())
			if err != io.EOF {
				send(control.ChatAttachmentFrame{T: "failed", Error: "response_interrupted"})
				return
			}
			if send(control.ChatAttachmentFrame{T: "end"}) != nil {
				return
			}
			select {
			case <-ack:
			case <-ctx.Done():
			case <-time.After(5 * time.Second):
			}
			return
		}
	}
}

func readChatRequest(ctx context.Context, stream attachment.Stream, size int, pace func(int) error) ([]byte, error) {
	if size < 0 || size > control.ChatBodyMax {
		return nil, errors.New("invalid body size")
	}
	body := make([]byte, 0, size)
	for {
		t, b, err := stream.Read(ctx)
		if err != nil {
			return nil, err
		}
		if len(b) > attachment.FrameMax {
			return nil, errors.New("frame too large")
		}
		if t == websocket.MessageBinary {
			if len(body)+len(b) > size {
				return nil, errors.New("body exceeds grant")
			}
			if err := pace(len(b)); err != nil {
				return nil, err
			}
			body = append(body, b...)
			continue
		}
		var f control.ChatAttachmentFrame
		if t != websocket.MessageText || json.Unmarshal(b, &f) != nil || f.T != "request_end" || len(body) != size {
			return nil, errors.New("invalid request frame")
		}
		return body, nil
	}
}
