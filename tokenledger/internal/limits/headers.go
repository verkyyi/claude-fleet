package limits

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// A second way to read a subscription's meter: the rate-limit headers Anthropic
// attaches to ordinary inference responses.
//
// This exists because /api/oauth/usage requires the `user:profile` scope, and a
// token minted by `claude setup-token` — the kind an operator keeps for
// automation — does not carry it. Measured: that endpoint returns
//
//	403 "OAuth token does not meet scope requirement user:profile"
//
// while the same token gets full rate-limit headers from /v1/messages. The scope
// gate is on the endpoint, not on the numbers.
//
// The headers are ACCOUNT-scoped, not per-connection. Verified by reading one
// account two ways at the same moment, through two different credentials: the
// endpoint reported 18.0% / 4.0% and the headers 0.17 / 0.04 for the same reset
// instants. A per-session counter on a fresh connection would have read zero.
var messagesEndpoint = "https://api.anthropic.com/v1/messages"

// SetMessagesEndpointForTest points the probe at a stub. Tests only.
func SetMessagesEndpointForTest(u string) {
	if u == "" {
		messagesEndpoint = "https://api.anthropic.com/v1/messages"
		return
	}
	messagesEndpoint = u
}

// probeModel and probeTokens keep the cost of a reading near zero.
//
// The reading is not free: it is an inference call, so measuring the meter moves
// it. One turn of the cheapest model capped at a single token is the smallest
// request that still comes back with headers.
const (
	probeModel  = "claude-haiku-4-5-20251001"
	probeTokens = 1
)

// utilizationScale converts the header's fraction to the percentage the rest of
// ccquota speaks.
//
// The two sources disagree by a factor of a hundred and nothing says so: the
// endpoint's `utilization` is 0-100, the header's is 0-1. Measured side by side
// on one account — endpoint 18.0 and 4.0, headers 0.17 and 0.04. Storing the
// header value raw would have shown 0.17% for a subscription at 17%, and every
// gauge would have read "healthy" until the moment work started being refused.
const utilizationScale = 100

// FetchViaInference reads a subscription's meter from the rate-limit headers of
// a minimal inference call.
//
// Returns ErrUnavailable when the response carries no rate-limit headers, which
// is what an API-key (non-plan) token looks like: it has invoices, not windows.
func (c *Client) FetchViaInference(ctx context.Context, token string) (*model.LimitsSnapshot, error) {
	body := strings.NewReader(fmt.Sprintf(
		`{"model":%q,"max_tokens":%d,"messages":[{"role":"user","content":"."}]}`,
		probeModel, probeTokens))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, messagesEndpoint, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", oauthBeta)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("content-type", "application/json")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer resp.Body.Close()
	// The body is irrelevant — only the headers are wanted — but it must be
	// drained for the connection to be reused.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxBody))

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: HTTP %d from the messages endpoint", ErrUnavailable, resp.StatusCode)
	}
	snap := SnapshotFromHeaders(resp.Header)
	if snap == nil {
		return nil, fmt.Errorf("%w: the response carried no rate-limit headers", ErrUnavailable)
	}
	return snap, nil
}

// SnapshotFromHeaders builds a snapshot from unified rate-limit headers.
//
// Returns nil when neither window is present, so an API-key token reads as
// "unknown" rather than as a plan sitting at zero.
func SnapshotFromHeaders(h http.Header) *model.LimitsSnapshot {
	five, okFive := windowFromHeaders(h, "5h")
	seven, okSeven := windowFromHeaders(h, "7d")
	if !okFive && !okSeven {
		return nil
	}
	return &model.LimitsSnapshot{
		ObservedAt: time.Now().UTC(),
		FiveHour:   five,
		SevenDay:   seven,
	}
}

func windowFromHeaders(h http.Header, window string) (model.Window, bool) {
	var w model.Window
	raw := h.Get("anthropic-ratelimit-unified-" + window + "-utilization")
	if raw == "" {
		return w, false
	}
	frac, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return w, false
	}
	w.Utilization = frac * utilizationScale

	if ts := h.Get("anthropic-ratelimit-unified-" + window + "-reset"); ts != "" {
		if sec, err := strconv.ParseInt(ts, 10, 64); err == nil && sec > 0 {
			t := time.Unix(sec, 0).UTC()
			w.ResetsAt = &t
		}
	}
	return w, true
}
