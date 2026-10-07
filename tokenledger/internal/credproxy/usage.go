package credproxy

import (
	"bytes"
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

// UsageReporter is a Resolver that also takes usage reports. over = the
// person is now over budget (the proxy drops their cached answers).
type UsageReporter interface {
	ReportUsage(ctx context.Context, principal, provider string, tokens int64) (over bool, err error)
}

// ReportUsage posts one response's tokens to the hub.
func (h *HubResolver) ReportUsage(ctx context.Context, principal, provider string, tokens int64) (bool, error) {
	c := h.Client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	body, _ := json.Marshal(map[string]any{"principal": principal,
		"usage": []map[string]any{{"provider": provider, "tokens": tokens, "requests": 1}}})
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

// Tokens is input + cache writes + output; cache reads are left out (an
// OpenAI-shaped input counts its cached part, which is subtracted).
func (m *meter) Tokens() int64 {
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
	return in + m.f["cache_creation_input_tokens"] + m.f["output_tokens"] + m.f["prompt_tokens"] + m.f["completion_tokens"]
}

// report sends a response's tokens without holding up the client, and drops
// the person's cached answers once the hub says they are over.
func (p *Proxy) report(principal, provider string, tokens int64) {
	ur, ok := p.cfg.Resolver.(UsageReporter)
	if !ok || principal == "" || tokens <= 0 {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		over, err := ur.ReportUsage(ctx, principal, provider, tokens)
		if err != nil {
			p.cfg.Audit(fmt.Sprintf(`{"ev":"credproxy_usage","principal":%q,"err":%q}`, principal, errClass(err)))
			return
		}
		if over {
			p.forget(principal)
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
