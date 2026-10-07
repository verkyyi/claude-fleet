package credproxy

import (
	"strings"
	"testing"
)

// The meter reads what each provider's answer says it used (claude-fleet#1977):
// input + cache writes + output, never cache reads.
func TestMeter(t *testing.T) {
	for name, c := range map[string]struct {
		body  string
		chunk int
		want  int64
	}{
		"claude json": {`{"content":[],"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":9000,"output_tokens":7}}`, 3, 22},
		"claude stream": {"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":5,\"cache_read_input_tokens\":900,\"output_tokens\":1}}}\n\n" +
			"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n\n" +
			"event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":40}}\n\n", 7, 55},
		"codex stream": {"event: response.created\ndata: {\"type\":\"response.created\",\"response\":{}}\n\n" +
			"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":80},\"output_tokens\":30,\"total_tokens\":130}}}\n\n", 11, 50},
		"no usage": {`{"ok":true}`, 4, 0},
		"not json": {"PONG", 1, 0},
	} {
		m := newMeter()
		for i := 0; i < len(c.body); i += c.chunk {
			end := i + c.chunk
			if end > len(c.body) {
				end = len(c.body)
			}
			_, _ = m.Write([]byte(c.body[i:end]))
		}
		if got := m.Tokens(); got != c.want {
			t.Errorf("%s: %d tokens; want %d", name, got, c.want)
		}
	}
}

// A person over budget is refused under the hub's own code, in each
// provider's shape, and nothing reaches the upstream.
func TestBudgetRefusal(t *testing.T) {
	h := newHarness(t, true, nil)
	h.hub.set(func() {
		h.hub.over = map[string]string{PassPrefix + "over": "已达个人额度：近 5 小时已用 300 / 上限 300 token"}
	})
	st, body := h.do(t, "/v1/proxy/anthropic/v1/messages", PassPrefix+"over", "{}", nil)
	if st != 403 || !strings.Contains(body, `"code":"`+PersonBudgetExceeded+`"`) || !strings.Contains(body, "已达个人额度") {
		t.Fatalf("claude over budget → %d %s", st, body)
	}
	st, body = h.do(t, "/v1/proxy/codex/responses", PassPrefix+"over", "{}", nil)
	if st != 403 || !strings.Contains(body, `"code":"`+PersonBudgetExceeded+`"`) {
		t.Fatalf("codex over budget → %d %s", st, body)
	}
	if h.upstreamCount() != 0 {
		t.Fatal("an over-budget request reached the upstream")
	}
}
