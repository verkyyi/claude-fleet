package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// seedReviewHarness pushes two sessions through the real ingest path.
func seedReviewHarness(t *testing.T, h *harness) {
	t.Helper()
	tok := h.enroll(t, "mac")
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	mk := func(uuid, session, cwd string, min int, out int64, priced bool) model.UsageEvent {
		// Pricing is stamped server-side on ingest (see handleIngest ->
		// Pricing.Apply), which overwrites whatever CostUSD a fixture sets
		// here for a model the table knows. "priced" therefore has to pick
		// the MODEL, not just fill in a cost: an unpriced event needs a model
		// absent from pricing.Default() or the hub prices it anyway.
		m := "claude-opus-5"
		if !priced {
			m = "claude-unpriced-test-model"
		}
		e := model.UsageEvent{AccountUUID: "acct-a", EndpointID: "ep_mac", SessionID: session, MessageUUID: uuid,
			TS: base.Add(time.Duration(min) * time.Minute), Model: m, OutputTokens: out, CacheRead: 900,
			CWD: cwd, OSUser: "verkyyi"}
		return e
	}
	batch := model.Batch{Identity: model.Identity{
		AccountUUID: "acct-a", Email: "acct-a@example.com", Hostname: "mac",
		OS: "darwin", Arch: "arm64", SubscriptionType: "max", OSUser: "verkyyi",
	}, AccountOrigin: model.OriginLogin, Events: []model.UsageEvent{
		mk("1", "s-big", "/p/alpha", 0, 100, true), mk("2", "s-big", "/p/alpha", 30, 100, true),
		mk("3", "s-small", "/p/beta", 130, 20, false)}}
	if res := h.push(t, tok, batch); res.StatusCode != http.StatusOK {
		t.Fatalf("push: %d", res.StatusCode)
	}
}

func TestSummaryEndpoint(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	var got struct {
		Events, Sessions int64
		Prev             *struct{ Events int64 } `json:"prev"`
	}
	h.getJSON(t, "/v1/summary?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z&compare=1", &got)
	if got.Events != 3 || got.Sessions != 2 || got.Prev == nil || got.Prev.Events != 0 {
		t.Fatalf("%+v", got)
	}
}

func TestSessionsEndpoints(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	var rows []struct {
		SessionID string `json:"session_id"`
		Turns     int64  `json:"turns"`
		Endpoint  string `json:"endpoint"`
	}
	h.getJSON(t, "/v1/sessions?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z&project=%2Fp%2Falpha", &rows)
	if len(rows) != 1 || rows[0].SessionID != "s-big" || rows[0].Turns != 2 || rows[0].Endpoint != "mac" {
		t.Fatalf("%+v", rows)
	}
	var one struct {
		Session struct{ Turns int64 }    `json:"session"`
		Turns   []struct{ Model string } `json:"turns"`
		Pruned  bool                     `json:"pruned"`
	}
	h.getJSON(t, "/v1/sessions/s-big?account=all", &one)
	if one.Session.Turns != 2 || len(one.Turns) != 2 || one.Pruned {
		t.Fatalf("%+v", one)
	}
	if code := h.getCode(t, "/v1/sessions/nope?account=all"); code != http.StatusNotFound {
		t.Fatalf("unknown session: %d", code)
	}
}

func TestLimitsHistoryEndpoint(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	at := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	for i, pct := range []float64{10, 95, 95, 20} {
		snap := &model.LimitsSnapshot{AccountUUID: "acct-a", EndpointID: "ep_mac", ObservedAt: at.Add(time.Duration(i) * time.Minute)}
		snap.FiveHour.Utilization = pct
		if err := h.srv.Store.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
	}
	var got struct {
		Accounts []struct {
			Points           []json.RawMessage `json:"points"`
			CriticalSeconds  int64             `json:"critical_seconds"`
			CriticalEpisodes int               `json:"critical_episodes"`
		} `json:"accounts"`
	}
	h.getJSON(t, "/v1/limits/history?account=all&since=2026-09-01T09:00:00Z&until=2026-09-01T11:00:00Z", &got)
	if len(got.Accounts) != 1 || len(got.Accounts[0].Points) != 4 || got.Accounts[0].CriticalSeconds != 120 || got.Accounts[0].CriticalEpisodes != 1 {
		t.Fatalf("%+v", got)
	}
}

// Issue #101 turned the wall-history card into a table of counts and
// durations, and cut what the dashboard asks for from points=400 to points=1.
// That is only safe because LimitsHistoryView and QuotaHistorySeries both run
// criticalTime() over the FULL scan and downsample only afterwards -- so the
// two figures the card now shows cannot be a function of `points`.
//
// Swap those two steps (downsample first, count second) and the table quietly
// starts reporting fewer, longer episodes: the answer stays plausible, which
// is exactly why it needs pinning rather than eyeballing. The assertion is
// "every value of points agrees", not a fixture's idea of the right number.
func TestEpisodeFiguresDoNotMoveWithPoints(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)

	// Enough snapshots that points=1 downsamples hard, and a shape that enters
	// the critical band more than once so the episode COUNT is load-bearing.
	at := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 600; i++ {
		pct := 10.0
		if (i/20)%3 == 0 {
			pct = 95
		}
		obs := at.Add(time.Duration(i) * 2 * time.Minute)
		snap := &model.LimitsSnapshot{AccountUUID: "acct-a", EndpointID: "ep_mac", ObservedAt: obs}
		snap.FiveHour.Utilization = pct
		if err := h.srv.Store.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.InsertQuota(model.QuotaSnapshot{
			Source: "codex", AccountUUID: "acct-a", EndpointID: "ep_mac",
			ObservedAt: obs, Observation: "app_server",
			Windows: []model.QuotaWindow{{ID: "primary", Label: "5h", Minutes: 300, UsedPercent: pct}},
		}); err != nil {
			t.Fatal(err)
		}
	}

	type series struct {
		Label            string            `json:"label"`
		Points           []json.RawMessage `json:"points"`
		CriticalSeconds  int64             `json:"critical_seconds"`
		CriticalEpisodes int               `json:"critical_episodes"`
	}
	type view struct {
		Accounts    []series `json:"accounts"`
		QuotaSeries []series `json:"quota_series"`
	}
	// The figures, without the points -- what must be identical.
	figures := func(v view) string {
		var b strings.Builder
		for _, s := range append(append([]series{}, v.Accounts...), v.QuotaSeries...) {
			fmt.Fprintf(&b, "%s=%d/%ds ", s.Label, s.CriticalEpisodes, s.CriticalSeconds)
		}
		return b.String()
	}

	const window = "account=all&since=2026-09-01T00:00:00Z&until=2026-09-02T00:00:00Z"
	var base view
	h.getJSON(t, "/v1/limits/history?"+window+"&points=400", &base)
	if len(base.Accounts) != 1 || len(base.QuotaSeries) != 1 {
		t.Fatalf("setup: want one account series and one quota series, got %d/%d",
			len(base.Accounts), len(base.QuotaSeries))
	}
	if base.Accounts[0].CriticalEpisodes < 2 {
		t.Fatalf("setup: want a shape that enters critical more than once, got %d episodes",
			base.Accounts[0].CriticalEpisodes)
	}
	want := figures(base)

	for _, pts := range []int{200, 50, 10, 1} {
		var got view
		h.getJSON(t, fmt.Sprintf("/v1/limits/history?%s&points=%d", window, pts), &got)
		if g := figures(got); g != want {
			t.Errorf("points=%d changed the episode figures:\n  points=400: %s\n  points=%d: %s",
				pts, want, pts, g)
		}
		// ...and it really did downsample, so the comparison above is not
		// vacuously true because every request returned the same full series.
		if n := len(got.Accounts[0].Points); n > pts {
			t.Errorf("points=%d returned %d points", pts, n)
		}
	}
}
