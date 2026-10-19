package credproxy

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"io"
	"net/http"
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

// A compressed answer is metered too (claude-fleet#3407): Claude Code asks for
// gzip, and Anthropic gzips its event stream — the meter read the compressed
// bytes and counted nothing for every Claude session.
func TestMeterCompressed(t *testing.T) {
	stream := "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-x\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":5,\"output_tokens\":1}}}\n\n" +
		"event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":40}}\n\n"
	var gz, zl bytes.Buffer
	g := gzip.NewWriter(&gz)
	_, _ = g.Write([]byte(stream))
	_ = g.Close()
	z := zlib.NewWriter(&zl)
	_, _ = z.Write([]byte(stream))
	_ = z.Close()
	for name, c := range map[string]struct {
		enc  string
		body []byte
		want int64
	}{
		"gzip":     {"gzip", gz.Bytes(), 55},
		"deflate":  {"deflate", zl.Bytes(), 55},
		"identity": {"", []byte(stream), 55},
		"br":       {"br", gz.Bytes(), 0},
		"bad gzip": {"gzip", []byte(stream), 0},
	} {
		m := newMeter()
		w := m.decoder(c.enc)
		for i := 0; i < len(c.body); i += 5 {
			end := i + 5
			if end > len(c.body) {
				end = len(c.body)
			}
			if n, err := w.Write(c.body[i:end]); err != nil || n != end-i {
				t.Fatalf("%s: the meter's write failed the stream: %d %v", name, n, err)
			}
		}
		_ = w.Close()
		if got := m.Tokens(); got != c.want {
			t.Errorf("%s: %d tokens; want %d", name, got, c.want)
		}
	}
}

func TestMeterAccept(t *testing.T) {
	for in, want := range map[string]string{
		"gzip, deflate, br, zstd": "gzip, deflate",
		"br;q=1.0, gzip;q=0.8":    "gzip;q=0.8",
		"br, zstd":                "identity",
		"":                        "identity",
		"*":                       "identity",
	} {
		var vs []string
		if in != "" {
			vs = []string{in}
		}
		if got := meterAccept(vs); got != want {
			t.Errorf("meterAccept(%q) = %q; want %q", in, got, want)
		}
	}
}

// The upstream is asked only for codings the meter can open, and the client
// still gets the upstream's compressed bytes untouched.
func TestCompressedPassThrough(t *testing.T) {
	var gz bytes.Buffer
	g := gzip.NewWriter(&gz)
	_, _ = g.Write([]byte("event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":3}}}\n\n"))
	_ = g.Close()
	var sawAE string
	h := newHarness(t, true, func(w http.ResponseWriter, r *http.Request) {
		sawAE = r.Header.Get("Accept-Encoding")
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Content-Encoding", "gzip")
		_, _ = w.Write(gz.Bytes())
	})
	h.hub.set(func() { h.hub.bind[PassPrefix+"a"] = "acct" })
	req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+"/v1/proxy/anthropic/v1/messages", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer "+PassPrefix+"a")
	req.Header.Set("Accept-Encoding", "gzip, deflate, br, zstd")
	res, err := (&http.Client{Transport: &http.Transport{DisableCompression: true}}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	if sawAE != "gzip, deflate" {
		t.Errorf("upstream asked for %q; want gzip, deflate", sawAE)
	}
	if res.Header.Get("Content-Encoding") != "gzip" || !bytes.Equal(b, gz.Bytes()) {
		t.Errorf("client got %q / %d bytes; want the upstream's gzip bytes as they came", res.Header.Get("Content-Encoding"), len(b))
	}
}
