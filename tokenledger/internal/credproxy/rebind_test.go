package credproxy

import (
	"net/http"
	"testing"
)

// Only a quota 429 moves a session (claude-fleet#2115): the account's
// five-hour / weekly window or Codex's usage limit, never a request rate.
func TestQuotaLimited(t *testing.T) {
	hdr := func(kv ...string) http.Header {
		h := http.Header{}
		for i := 0; i+1 < len(kv); i += 2 {
			h.Set(kv[i], kv[i+1])
		}
		return h
	}
	for _, c := range []struct {
		name, provider string
		h              http.Header
		body           string
		want           bool
		reset          int64
	}{
		{"claude weekly message", Claude, hdr(), `{"type":"error","error":{"type":"rate_limit_error","message":"You've hit your weekly limit"}}`, true, 0},
		{"claude unified rejected", Claude, hdr("anthropic-ratelimit-unified-status", "rejected", "anthropic-ratelimit-unified-reset", "1900000000"), `{}`, true, 1900000000},
		{"claude 7d at 100%", Claude, hdr("anthropic-ratelimit-unified-7d-utilization", "1.0", "anthropic-ratelimit-unified-7d-reset", "1900000001"), `{}`, true, 1900000001},
		{"claude request rate", Claude, hdr("anthropic-ratelimit-unified-7d-utilization", "0.4", "retry-after", "3"),
			`{"type":"error","error":{"type":"rate_limit_error","message":"Number of requests has exceeded your per-minute rate limit"}}`, false, 0},
		{"codex usage limit", Codex, hdr(), `{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","resets_at":1900000002}}`, true, 1900000002},
		{"codex secondary at 100%", Codex, hdr("x-codex-secondary-used-percent", "100", "x-codex-secondary-reset-at", "1900000003"), `{}`, true, 1900000003},
		{"codex request rate", Codex, hdr("x-codex-primary-used-percent", "12"), `{"error":{"type":"rate_limit_exceeded"}}`, false, 0},
	} {
		got, reset := quotaLimited(c.provider, c.h, []byte(c.body))
		if got != c.want || reset != c.reset {
			t.Errorf("%s: quotaLimited = %v, %d; want %v, %d", c.name, got, reset, c.want, c.reset)
		}
	}
}
