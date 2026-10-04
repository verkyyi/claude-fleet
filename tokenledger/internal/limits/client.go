// Package limits reads an account's true, account-wide quota state.
//
// This is the only exact number in ccquota. Anthropic already aggregates
// across every device on the account, so one HTTP call answers "am I about to
// hit the wall" for the whole fleet — no agent coordination required.
// Everything the transcript scanner produces is an estimate by comparison.
//
// The endpoint is UNDOCUMENTED. It will change or disappear. Every failure
// path here therefore returns ErrUnavailable rather than a zero-valued
// snapshot, so the dashboard can drop its gauges and say so instead of
// rendering a confident, wrong percentage.
package limits

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// Endpoint is Claude Code's own usage endpoint.
const Endpoint = "https://api.anthropic.com/api/oauth/usage"

// oauthBeta is the header Claude Code sends alongside a bearer OAuth token.
const oauthBeta = "oauth-2025-04-20"

// ErrUnavailable means the true limits could not be read. Callers must treat
// this as "unknown", never as "zero".
var ErrUnavailable = errors.New("limits unavailable")

// maxBody caps the response read. A wildly oversized body means we are talking
// to something that is not this endpoint.
const maxBody = 1 << 20

// Client fetches limit snapshots.
type Client struct {
	HTTP     *http.Client
	Endpoint string
}

// New returns a Client with sane timeouts.
func New() *Client {
	return &Client{
		HTTP:     &http.Client{Timeout: 15 * time.Second},
		Endpoint: Endpoint,
	}
}

// rawWindow is one bucket in the payload. Every numeric field is a pointer so
// an absent field is distinguishable from a real zero — the difference between
// "no data" and "you have used none of your quota".
type rawWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type rawLimit struct {
	Kind     string   `json:"kind"`
	Group    string   `json:"group"`
	Percent  *float64 `json:"percent"`
	Severity string   `json:"severity"`
	ResetsAt *string  `json:"resets_at"`
	IsActive bool     `json:"is_active"`
	Scope    *struct {
		Model *struct {
			ID          *string `json:"id"`
			DisplayName *string `json:"display_name"`
		} `json:"model"`
		Surface *string `json:"surface"`
	} `json:"scope"`
}

type rawUsage struct {
	FiveHour *rawWindow `json:"five_hour"`
	SevenDay *rawWindow `json:"seven_day"`
	Limits   []rawLimit `json:"limits"`

	ExtraUsage json.RawMessage `json:"extra_usage"`
	Spend      json.RawMessage `json:"spend"`
}

// Fetch reads the current snapshot for whichever account the token belongs to.
func (c *Client) Fetch(ctx context.Context, token string) (*model.LimitsSnapshot, error) {
	if token == "" {
		return nil, fmt.Errorf("%w: no token", ErrUnavailable)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", oauthBeta)
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBody))
	if err != nil {
		return nil, fmt.Errorf("%w: read body: %v", ErrUnavailable, err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: HTTP %d", ErrUnavailable, resp.StatusCode)
	}

	snap, err := Parse(body)
	if err != nil {
		return nil, err
	}
	return snap, nil
}

// Parse converts a payload into a snapshot.
//
// Exported so the contract test can pin it to a recorded response: when
// Anthropic changes the shape, that test fails loudly instead of the field
// quietly becoming zero.
func Parse(body []byte) (*model.LimitsSnapshot, error) {
	var raw rawUsage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("%w: parse: %v", ErrUnavailable, err)
	}

	// The two headline windows are the whole point of the call. If neither
	// carries a utilization, we are looking at something that is no longer
	// this endpoint, and reporting 0%% would be a lie.
	if !hasUtilization(raw.FiveHour) && !hasUtilization(raw.SevenDay) {
		return nil, fmt.Errorf("%w: payload has no five_hour or seven_day utilization", ErrUnavailable)
	}

	snap := &model.LimitsSnapshot{
		ObservedAt: time.Now().UTC(),
		FiveHour:   toWindow(raw.FiveHour),
		SevenDay:   toWindow(raw.SevenDay),
		RawJSON:    string(body),
	}
	if len(raw.ExtraUsage) > 0 {
		snap.ExtraUsageJSON = string(raw.ExtraUsage)
	}
	if len(raw.Spend) > 0 {
		snap.SpendJSON = string(raw.Spend)
	}

	for _, l := range raw.Limits {
		// The headline windows already cover session and weekly_all; keeping
		// them here too would double them in the UI.
		if l.Kind != "weekly_scoped" {
			continue
		}
		sw := model.ScopedWindow{Kind: l.Kind, IsActive: l.IsActive}
		if l.Percent != nil {
			sw.Utilization = *l.Percent
		}
		sw.ResetsAt = parseTime(l.ResetsAt)
		if l.Scope != nil {
			if l.Scope.Model != nil && l.Scope.Model.DisplayName != nil {
				sw.Model = *l.Scope.Model.DisplayName
			}
			if l.Scope.Surface != nil {
				sw.Surface = *l.Scope.Surface
			}
		}
		snap.Scoped = append(snap.Scoped, sw)
	}

	return snap, nil
}

func hasUtilization(w *rawWindow) bool { return w != nil && w.Utilization != nil }

func toWindow(w *rawWindow) model.Window {
	if w == nil {
		return model.Window{}
	}
	out := model.Window{ResetsAt: parseTime(w.ResetsAt)}
	if w.Utilization != nil {
		out.Utilization = *w.Utilization
	}
	return out
}

// parseTime tolerates an absent or unparseable timestamp by returning nil. A
// missing reset time degrades the countdown, which the UI can render as
// "unknown"; inventing one would produce a countdown that is simply wrong.
func parseTime(s *string) *time.Time {
	if s == nil || *s == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, *s)
	if err != nil {
		return nil
	}
	t = t.UTC()
	return &t
}
