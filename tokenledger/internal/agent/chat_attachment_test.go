package agent

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/attachment"
)

type chatTestStream struct{ frames []attachmentFrame }

func (s *chatTestStream) Read(context.Context) (websocket.MessageType, []byte, error) {
	if len(s.frames) == 0 {
		return 0, nil, attachment.ErrClosed
	}
	f := s.frames[0]
	s.frames = s.frames[1:]
	return f.typ, f.b, nil
}
func (*chatTestStream) Write(context.Context, websocket.MessageType, []byte) error { return nil }
func (*chatTestStream) Close() error                                               { return nil }

func TestChatAttachmentBoundedBody(t *testing.T) {
	for _, test := range []struct {
		end  string
		size int
		ok   bool
	}{
		{`{"t":"request_end"}`, 2, true}, {`{"t":"request_end"}`, 1, false},
		{`{"t":"request_end"}`, 3, false}, {`{"t":"resize"}`, 2, false},
		{`{"t":"chat_result","refund":true}`, 2, false},
	} {
		s := &chatTestStream{frames: []attachmentFrame{{websocket.MessageBinary, []byte(`{}`)}, {websocket.MessageText, []byte(test.end)}}}
		paced := 0
		b, err := readChatRequest(context.Background(), s, test.size, func(n int) error { paced += n; return nil })
		if (err == nil) != test.ok {
			t.Fatalf("%+v: %q %v", test, b, err)
		}
		if test.ok && paced != 2 {
			t.Fatal("upload bypassed rate budget")
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	var rate chatRate
	if err := rate.wait(ctx, 1024, 1); err == nil {
		t.Fatal("unbounded rate wait ignored cancellation")
	}
}
