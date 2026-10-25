package credproxy

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

// Source metadata must commit BEFORE the client sees a reference. Otherwise a
// reused reference or a concurrent request can race a stale account mapping.
// SSE frames are bounded and retain their exact bytes; plain JSON is bounded
// and buffered. The upstream is asked for identity encoding on this path.
type codexAffinityReader struct {
	source  *bufio.Reader
	pending *bytes.Reader
	record  func(map[string]any) error
	ended   bool
	failed  bool
}

func codexResponseReader(source io.Reader, contentType string, record func(map[string]any) error) (io.Reader, error) {
	br := bufio.NewReader(source)
	// The stream is recognised by its bytes as well as its Content-Type: through
	// the relay a streamed Codex reply has arrived without text/event-stream
	// (prod 2026-10-25, svc:xiaoerge), and parsing it as one JSON document failed
	// every call with affinity_response_invalid. An SSE body starts with a field
	// name (`event:` / `data:` / `id:` / `retry:`) or a comment (`:`); a JSON body
	// starts with `{`. Anything else still takes the JSON path and fails closed.
	if strings.HasPrefix(strings.ToLower(contentType), "text/event-stream") || looksLikeSSE(br) {
		return &codexAffinityReader{source: br, record: record}, nil
	}
	source = br
	raw, err := io.ReadAll(io.LimitReader(source, maxWhole+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxWhole {
		return nil, errors.New("affinity_response_too_large")
	}
	var v map[string]any
	if !uniqueCodexJSON(raw) || json.Unmarshal(raw, &v) != nil || v == nil {
		return nil, errors.New("affinity_response_invalid (content-type " + strconvQuote(contentType) + ")")
	}
	if err := record(v); err != nil {
		return nil, err
	}
	return bytes.NewReader(raw), nil
}

func (r *codexAffinityReader) Read(p []byte) (n int, err error) {
	defer func() {
		if err != nil && err != io.EOF {
			r.failed = true
		}
	}()
	for r.pending == nil || r.pending.Len() == 0 {
		if r.ended {
			return 0, io.EOF
		}
		var frame, data []byte
		for {
			var line []byte
			for {
				chunk, err := r.source.ReadSlice('\n')
				line = append(line, chunk...)
				if len(frame)+len(line) > maxWhole {
					return 0, errors.New("affinity_event_too_large")
				}
				if err == bufio.ErrBufferFull {
					continue
				}
				if err != nil && err != io.EOF {
					return 0, err
				}
				if err == io.EOF {
					r.ended = true
				}
				break
			}
			frame = append(frame, line...)
			bare := bytes.TrimSuffix(bytes.TrimSuffix(line, []byte("\n")), []byte("\r"))
			if bytes.HasPrefix(bare, []byte("data:")) {
				part := bytes.TrimPrefix(bare[5:], []byte(" "))
				data = append(data, part...)
				data = append(data, '\n')
			}
			if len(bare) == 0 || r.ended {
				break
			}
		}
		data = bytes.TrimSpace(data)
		if len(data) > 0 && !bytes.Equal(data, []byte("[DONE]")) {
			var v map[string]any
			if !uniqueCodexJSON(data) || json.Unmarshal(data, &v) != nil {
				return 0, errors.New("affinity_event_invalid")
			}
			if err := r.record(v); err != nil {
				return 0, err
			}
		}
		r.pending = bytes.NewReader(frame)
	}
	return r.pending.Read(p)
}

// looksLikeSSE peeks (without consuming) past leading whitespace and reports
// whether the body opens like an event stream.
func looksLikeSSE(br *bufio.Reader) bool {
	head, _ := br.Peek(64)
	head = bytes.TrimLeft(head, " \t\r\n\ufeff")
	for _, p := range []string{"event:", "data:", "id:", "retry:", ":"} {
		if bytes.HasPrefix(head, []byte(p)) {
			return true
		}
	}
	return false
}

func strconvQuote(s string) string {
	if s == "" {
		return "none"
	}
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}
