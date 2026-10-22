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
	if strings.HasPrefix(strings.ToLower(contentType), "text/event-stream") {
		return &codexAffinityReader{source: bufio.NewReader(source), record: record}, nil
	}
	raw, err := io.ReadAll(io.LimitReader(source, maxWhole+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxWhole {
		return nil, errors.New("affinity_response_too_large")
	}
	var v map[string]any
	if !uniqueCodexJSON(raw) || json.Unmarshal(raw, &v) != nil || v == nil {
		return nil, errors.New("affinity_response_invalid")
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
