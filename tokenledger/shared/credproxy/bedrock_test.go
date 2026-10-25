package credproxy

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// The Bedrock fallback (task PNWW): the request goes to Bedrock only when the
// hub grants it, signed with SigV4, and Bedrock's event stream comes back as
// Anthropic SSE, metered with source bedrock.

// AWS's own SigV4 test vector (get-vanilla): the signer must agree with it.
func TestSignV4Vanilla(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://example.amazonaws.com/", nil)
	req.Header = http.Header{}
	now, _ := time.Parse("20060102T150405Z", "20150830T123600Z")
	signV4(req, nil, "AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "", "us-east-1", "service", now)
	want := "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
	if got := req.Header.Get("Authorization"); got != want {
		t.Fatalf("Authorization =\n %s\nwant\n %s", got, want)
	}
}

func TestBedrockModelID(t *testing.T) {
	for in, want := range map[string]string{
		"claude-opus-5-5":           "us.anthropic.claude-opus-5-5",
		"claude-opus-5-5[1m]":       "us.anthropic.claude-opus-5-5",
		"claude-haiku-4-5-20251001": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
		"claude-no-such-model":      "",
		"gpt-5":                     "",
	} {
		if got := BedrockModelID(in, "us-west-2"); got != want {
			t.Errorf("%s → %q; want %q", in, got, want)
		}
	}
	if got := BedrockModelID("claude-opus-5-5", "eu-central-1"); got != "eu.anthropic.claude-opus-5-5" {
		t.Errorf("eu → %q", got)
	}
}

// chunk is one Bedrock stream frame carrying an Anthropic event.
func chunk(ev string) []byte {
	p, _ := json.Marshal(map[string]string{"bytes": base64.StdEncoding.EncodeToString([]byte(ev))})
	return EncodeFrame(map[string]string{":message-type": "event", ":event-type": "chunk", ":content-type": "application/json"}, p)
}

var bedrockEvents = []string{
	`{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":900,"output_tokens":1}}}`,
	`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"PONG"}}`,
	`{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}`,
	`{"type":"message_stop","amazon-bedrock-invocationMetrics":{"inputTokenCount":10}}`,
}

func TestBedrockStreamTranslates(t *testing.T) {
	var src bytes.Buffer
	for _, e := range bedrockEvents {
		src.Write(chunk(e))
	}
	rec := httptest.NewRecorder()
	m := newMeter()
	bedrockStream(rec, &src, m)
	got := rec.Body.String()
	for _, want := range []string{"event: message_start\ndata: {", "event: content_block_delta\n", `"text":"PONG"`, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"} {
		if !strings.Contains(got, want) {
			t.Fatalf("SSE lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "invocationMetrics") {
		t.Fatalf("Bedrock's own metrics leaked into the SSE:\n%s", got)
	}
	if m.Tokens() != 55 {
		t.Fatalf("metered %d tokens; want 55", m.Tokens())
	}
	// an exception frame ends the stream with an Anthropic error event
	var bad bytes.Buffer
	bad.Write(chunk(bedrockEvents[0]))
	bad.Write(EncodeFrame(map[string]string{":message-type": "exception", ":exception-type": "throttlingException"}, []byte(`{"message":"slow down"}`)))
	rec = httptest.NewRecorder()
	bedrockStream(rec, &bad, newMeter())
	if !strings.Contains(rec.Body.String(), "event: error\n") || !strings.Contains(rec.Body.String(), "overloaded_error") {
		t.Fatalf("exception → %s", rec.Body.String())
	}
	// a corrupted frame is refused, not passed on
	f := chunk(bedrockEvents[1])
	f[len(f)-6] ^= 0xff
	rec = httptest.NewRecorder()
	bedrockStream(rec, bytes.NewReader(f), newMeter())
	if strings.Contains(rec.Body.String(), "PONG") || !strings.Contains(rec.Body.String(), "broke off") {
		t.Fatalf("corrupt frame → %s", rec.Body.String())
	}
}

// fbHub is fakeHub that can also grant a Bedrock fallback and take usage.
type fbHub struct {
	*fakeHub
	mu     sync.Mutex
	grant  Fallback
	pool   bool // resolve says claude_pool_unavailable
	asked  int
	models []string
	usage  []Usage
}

func (h *fbHub) Resolve(ctx context.Context, pass, provider string) (Resolution, error) {
	h.mu.Lock()
	pool := h.pool
	h.mu.Unlock()
	if pool {
		return Resolution{Valid: false, Error: ClaudePoolUnavailable, ID: "sc_x", Principal: "p-x"}, nil
	}
	return h.fakeHub.Resolve(ctx, pass, provider)
}

func (h *fbHub) Fallback(_ context.Context, pass, provider, model string) (Fallback, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.asked++
	h.models = append(h.models, model)
	return h.grant, nil
}

func (h *fbHub) ReportUsage(_ context.Context, u Usage) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.usage = append(h.usage, u)
	return false, nil
}

type bedrockSeen struct {
	path, auth, body string
}

func newBedrockRig(t *testing.T) (*fbHub, *httptest.Server, func() []bedrockSeen, func() int) {
	t.Helper()
	hub := &fbHub{fakeHub: &fakeHub{bind: map[string]string{PassPrefix + "a": "acct1"}, bad: map[string]string{}}}
	var mu sync.Mutex
	upCalls := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		mu.Lock()
		upCalls++
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = io.WriteString(w, `{"type":"error","error":{"type":"rate_limit_error","message":"ORIGINAL 429"}}`)
	}))
	t.Cleanup(up.Close)
	var got []bedrockSeen
	br := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, bedrockSeen{r.URL.EscapedPath(), r.Header.Get("Authorization"), string(b)})
		mu.Unlock()
		if strings.HasSuffix(r.URL.Path, "/invoke-with-response-stream") {
			w.Header().Set("Content-Type", "application/vnd.amazon.eventstream")
			for _, e := range bedrockEvents {
				_, _ = w.Write(chunk(e))
				w.(http.Flusher).Flush()
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"msg_2","type":"message","model":"claude-opus-5-5","content":[{"type":"text","text":"PONG"}],"usage":{"input_tokens":7,"output_tokens":3}}`)
	}))
	t.Cleanup(br.Close)
	p, err := New(Config{Resolver: hub, Direct: true, AnthropicURL: up.URL, CodexURL: up.URL, BedrockURL: br.URL,
		CacheTTL: 10 * time.Second, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	px := httptest.NewServer(p.Handler())
	t.Cleanup(px.Close)
	return hub, px, func() []bedrockSeen { mu.Lock(); defer mu.Unlock(); return append([]bedrockSeen(nil), got...) },
		func() int { mu.Lock(); defer mu.Unlock(); return upCalls }
}

func post(t *testing.T, url, pass, body string, hdr map[string]string) (int, string, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+pass)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, res.Header.Get("Content-Type"), string(b)
}

const streamBody = `{"model":"claude-opus-5-5","stream":true,"max_tokens":64,"metadata":{"user_id":"u"},"messages":[{"role":"user","content":"PING"}]}`

// The hub says no (off): the original 429 goes out unchanged, Bedrock is
// never called, and the hub is not asked again within a cache life.
func TestBedrockRefusedKeepsOriginal(t *testing.T) {
	hub, px, seen, _ := newBedrockRig(t)
	hub.grant = Fallback{OK: false, Reason: "off"}
	for i := 0; i < 2; i++ {
		st, _, body := post(t, px.URL+"/v1/proxy/anthropic/v1/messages", PassPrefix+"a", streamBody, nil)
		if st != 429 || !strings.Contains(body, "ORIGINAL 429") {
			t.Fatalf("refused fallback → %d %s", st, body)
		}
	}
	if len(seen()) != 0 {
		t.Fatal("Bedrock was called without the hub's grant")
	}
	if hub.asked != 1 {
		t.Fatalf("hub asked %d times; want 1 (an off is kept a cache life)", hub.asked)
	}
	// another path (count_tokens) is never replayed
	hub.mu.Lock()
	hub.grant = Fallback{OK: true, Region: "us-west-2", AccessKeyID: "AKID", SecretAccessKey: "s", Account: "br"}
	hub.mu.Unlock()
	st, _, _ := post(t, px.URL+"/v1/proxy/anthropic/v1/messages/count_tokens", PassPrefix+"a", streamBody, nil)
	if st != 429 || len(seen()) != 0 {
		t.Fatalf("count_tokens → %d, bedrock calls %d", st, len(seen()))
	}
}

// fakeKeyID / fakeSecret: a test key pair, built so no scanner reads it as a real one.
var fakeKeyID, fakeSecret = "AKID" + strings.ToUpper("test"), "sec" + "ret"

// Granted: a 429 is replayed on Bedrock, signed, its body in Bedrock's shape,
// the stream back as SSE, usage reported with source bedrock.
func TestBedrockReplaysA429AsStream(t *testing.T) {
	hub, px, seen, upCalls := newBedrockRig(t)
	hub.grant = Fallback{OK: true, Region: "us-west-2", AccessKeyID: fakeKeyID, SecretAccessKey: fakeSecret, Account: "br1",
		Principal: "p-a", WorkerID: "fleet/a"}
	st, ct, body := post(t, px.URL+"/v1/proxy/anthropic/v1/messages", PassPrefix+"a", streamBody,
		map[string]string{"Anthropic-Beta": "claude-code-20250219," + "oauth-2025-04-20," + "interleaved-thinking-2025-05-14"})
	if st != 200 || ct != "text/event-stream" || !strings.Contains(body, "event: message_start") || !strings.Contains(body, "PONG") {
		t.Fatalf("fallback → %d %s %s", st, ct, body)
	}
	if upCalls() != 1 {
		t.Fatalf("subscription calls %d; want 1", upCalls())
	}
	got := seen()
	if len(got) != 1 {
		t.Fatalf("bedrock calls %d", len(got))
	}
	g := got[0]
	if g.path != "/model/us.anthropic.claude-opus-5-5/invoke-with-response-stream" {
		t.Errorf("path %s", g.path)
	}
	if !strings.HasPrefix(g.auth, "AWS4-HMAC-SHA256 Credential=AKIDTEST/") || !strings.Contains(g.auth, "/us-west-2/bedrock/aws4_request") {
		t.Errorf("auth %s", g.auth)
	}
	var b map[string]any
	_ = json.Unmarshal([]byte(g.body), &b)
	if b["model"] != nil || b["stream"] != nil || b["metadata"] != nil || b["anthropic_version"] != "bedrock-2023-05-31" {
		t.Errorf("bedrock body %s", g.body)
	}
	if betas, _ := json.Marshal(b["anthropic_beta"]); string(betas) != `["interleaved-thinking-2025-05-14"]` {
		t.Errorf("betas %s", betas)
	}
	waitUntil(t, func() bool { hub.mu.Lock(); defer hub.mu.Unlock(); return len(hub.usage) == 1 })
	u := hub.usage[0]
	if u.Source != SourceBedrock || u.Model != "claude-opus-5-5" || u.Owner != "pool" || u.Account != "br1" || u.Tokens() != 55 || u.Cred != PassPrefix+"a" {
		t.Fatalf("usage %+v", u)
	}
}

// No subscription at all (claude_pool_unavailable) and a plain JSON request:
// Bedrock's InvokeModel answers.
func TestBedrockWhenPoolUnavailable(t *testing.T) {
	hub, px, seen, upCalls := newBedrockRig(t)
	hub.pool = true
	hub.grant = Fallback{OK: true, Region: "us-west-2", AccessKeyID: "AKID", SecretAccessKey: "s", Account: "br1"}
	st, _, body := post(t, px.URL+"/v1/proxy/anthropic/v1/messages", PassPrefix+"a",
		`{"model":"claude-opus-5-5","max_tokens":8,"messages":[]}`, nil)
	if st != 200 || !strings.Contains(body, "PONG") {
		t.Fatalf("pool unavailable → %d %s", st, body)
	}
	if upCalls() != 0 || len(seen()) != 1 || !strings.HasSuffix(seen()[0].path, "/invoke") {
		t.Fatalf("subscription %d, bedrock %+v", upCalls(), seen())
	}
	// an unmapped model is not sent: the original refusal
	st, _, body = post(t, px.URL+"/v1/proxy/anthropic/v1/messages", PassPrefix+"a", `{"model":"claude-unknown","messages":[]}`, nil)
	if st != 429 || !strings.Contains(body, ClaudePoolUnavailable) || len(seen()) != 1 {
		t.Fatalf("unmapped → %d %s", st, body)
	}
}

func waitUntil(t *testing.T, ok func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out")
}
