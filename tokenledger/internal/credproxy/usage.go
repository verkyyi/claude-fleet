package credproxy

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Per-person usage (claude-fleet#1977): the proxy counts what each response's
// own `usage` says and reports it to the hub under the session's person; the
// hub answers a person over budget with a resolve refusal of its own code.

// PersonBudgetExceeded is the hub's refusal code for a person over budget.
const PersonBudgetExceeded = "person_budget_exceeded"

// UsagePath is the hub route the proxy reports to (api.CredProxyUsagePath).
const UsagePath = "/v1/fleet/credproxy/usage"

// Usage is one forwarded request's report (claude-fleet#3226): the pass it
// rode on — the hub files the row under that pass's person, never under the
// principal named here, which it only checks — and the response's own usage,
// by kind. In excludes the cached part an OpenAI-shaped input counts.
type Usage struct {
	Cred       string `json:"cred"`
	Principal  string `json:"principal,omitempty"`
	WorkerID   string `json:"worker_id,omitempty"`
	Provider   string `json:"provider"`
	Owner      string `json:"owner,omitempty"`
	Account    string `json:"account,omitempty"`
	Model      string `json:"model,omitempty"`
	In         int64  `json:"in"`
	CacheWrite int64  `json:"cache_write"`
	CacheRead  int64  `json:"cache_read"`
	Out        int64  `json:"out"`
}

// Tokens is what a budget counts: input + cache writes + output.
func (u Usage) Tokens() int64 { return u.In + u.CacheWrite + u.Out }

// UsageReporter is a Resolver that also takes usage reports. over = the
// person is now over budget (the proxy drops their cached answers).
type UsageReporter interface {
	ReportUsage(ctx context.Context, u Usage) (over bool, err error)
}

// ReportUsage posts one request's usage to the hub.
func (h *HubResolver) ReportUsage(ctx context.Context, u Usage) (bool, error) {
	c := h.Client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	body, _ := json.Marshal(u)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(h.URL, "/")+UsagePath, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+h.Token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.Do(req)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if res.StatusCode != http.StatusOK {
		return false, fmt.Errorf("usage report: %d %s", res.StatusCode, firstLine(raw))
	}
	var st struct {
		Over bool `json:"over"`
	}
	_ = json.Unmarshal(raw, &st)
	return st.Over, nil
}

// meter reads a response as it streams past and keeps the largest value each
// usage field reached: a Claude stream names input in message_start and the
// running output in message_delta; a Codex stream names it all in
// response.completed; a plain JSON answer names it once.
type meter struct {
	line  []byte
	whole []byte // a non-SSE body, up to maxWhole
	sse   bool
	f     map[string]int64
	model string // the first model the answer names
}

const maxWhole = 8 << 20

func newMeter() *meter { return &meter{f: map[string]int64{}} }

func (m *meter) Write(p []byte) (int, error) {
	if !m.sse && len(m.whole) < maxWhole {
		m.whole = append(m.whole, p...)
	}
	for _, c := range p {
		if c == '\n' {
			m.onLine(m.line)
			m.line = m.line[:0]
			continue
		}
		if len(m.line) < 1<<20 {
			m.line = append(m.line, c)
		}
	}
	return len(p), nil
}

func (m *meter) onLine(l []byte) {
	l = bytes.TrimSpace(l)
	if !bytes.HasPrefix(l, []byte("data:")) {
		if bytes.HasPrefix(l, []byte("event:")) {
			m.sse, m.whole = true, nil
		}
		return
	}
	m.sse, m.whole = true, nil
	var v map[string]any
	if json.Unmarshal(bytes.TrimSpace(l[5:]), &v) == nil {
		m.take(v)
	}
}

func (m *meter) take(v map[string]any) {
	if m.model == "" {
		for _, x := range []any{v["model"], dig(v, "message", "model"), dig(v, "response", "model")} {
			if s, ok := x.(string); ok && s != "" {
				m.model = s
				break
			}
		}
	}
	for _, u := range []any{v["usage"], dig(v, "message", "usage"), dig(v, "response", "usage")} {
		um, ok := u.(map[string]any)
		if !ok {
			continue
		}
		for k, x := range um {
			if n, ok := x.(float64); ok && n > float64(m.f[k]) {
				m.f[k] = int64(n)
			}
		}
		if n, ok := dig(um, "input_tokens_details", "cached_tokens").(float64); ok && int64(n) > m.f["cached_tokens"] {
			m.f["cached_tokens"] = int64(n)
		}
	}
}

func dig(v map[string]any, keys ...string) any {
	var cur any = v
	for _, k := range keys {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[k]
	}
	return cur
}

// meterCodings are the content codings the meter can open (claude-fleet#3407).
var meterCodings = map[string]bool{"gzip": true, "x-gzip": true, "deflate": true, "identity": true}

// meterAccept is the Accept-Encoding a metered request goes out with: the
// client's own list less what the meter cannot open (br, zstd, *), else identity.
func meterAccept(vs []string) string {
	var keep []string
	for _, v := range vs {
		for _, part := range strings.Split(v, ",") {
			c := strings.ToLower(strings.TrimSpace(strings.SplitN(part, ";", 2)[0]))
			if meterCodings[c] {
				keep = append(keep, strings.TrimSpace(part))
			}
		}
	}
	if len(keep) == 0 {
		return "identity"
	}
	return strings.Join(keep, ", ")
}

// decoder is where the meter's copy of an answer goes: as is, or opened
// (gzip / deflate) on a goroutine of its own — the client always gets the
// upstream's bytes as they came. Write never fails (it must not fail the
// client's read); Close waits until everything written was read.
func (m *meter) decoder(enc string) io.WriteCloser {
	var open func(io.Reader) (io.Reader, error)
	switch strings.ToLower(strings.TrimSpace(enc)) {
	case "", "identity":
		return nopCloser{m}
	case "gzip", "x-gzip":
		open = func(r io.Reader) (io.Reader, error) { return gzip.NewReader(r) }
	case "deflate":
		open = func(r io.Reader) (io.Reader, error) { return zlib.NewReader(r) }
	default:
		return nopCloser{io.Discard}
	}
	pr, pw := io.Pipe()
	d := &decodeW{pw: pw, done: make(chan struct{})}
	go func() {
		defer close(d.done)
		if zr, err := open(pr); err == nil {
			_, _ = io.Copy(m, zr)
		}
		_, _ = io.Copy(io.Discard, pr)
	}()
	return d
}

type nopCloser struct{ io.Writer }

func (nopCloser) Close() error { return nil }

type decodeW struct {
	pw   *io.PipeWriter
	done chan struct{}
}

func (d *decodeW) Write(p []byte) (int, error) {
	_, _ = d.pw.Write(p)
	return len(p), nil
}

func (d *decodeW) Close() error {
	_ = d.pw.Close()
	<-d.done
	return nil
}

// usage is what the answer said it used, by kind. An OpenAI-shaped input
// counts its cached part, which moves from In to CacheRead.
func (m *meter) usage() Usage {
	if !m.sse && len(m.whole) > 0 {
		var v map[string]any
		if json.Unmarshal(m.whole, &v) == nil {
			m.take(v)
		}
		m.whole = nil
	}
	in := m.f["input_tokens"] - m.f["cached_tokens"]
	if in < 0 {
		in = 0
	}
	return Usage{Model: m.model, In: in + m.f["prompt_tokens"], CacheWrite: m.f["cache_creation_input_tokens"],
		CacheRead: m.f["cache_read_input_tokens"] + m.f["cached_tokens"], Out: m.f["output_tokens"] + m.f["completion_tokens"]}
}

// Tokens is input + cache writes + output; cache reads are left out (an
// OpenAI-shaped input counts its cached part, which is subtracted).
func (m *meter) Tokens() int64 { return m.usage().Tokens() }

// report sends a request's usage without holding up the client, and drops
// the person's cached answers once the hub says they are over. A report the
// hub refuses is audited and dropped: the hub files usage only under a pass.
func (p *Proxy) report(u Usage) {
	ur, ok := p.cfg.Resolver.(UsageReporter)
	if !ok || u.Cred == "" || u.Tokens() <= 0 {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		over, err := ur.ReportUsage(ctx, u)
		if err != nil {
			p.cfg.Audit(fmt.Sprintf(`{"ev":"credproxy_usage","principal":%q,"worker_id":%q,"err":%q}`, u.Principal, u.WorkerID, errClass(err)))
			return
		}
		if over {
			p.forget(u.Principal)
		}
	}()
}

// forget drops every cached answer for a person, so their next request asks
// the hub (and meets the budget) instead of riding a 30 s answer.
func (p *Proxy) forget(principal string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for k, e := range p.cache {
		if e.mu.TryLock() {
			if e.ok && e.res.Principal == principal {
				delete(p.cache, k)
			}
			e.mu.Unlock()
		}
	}
}
