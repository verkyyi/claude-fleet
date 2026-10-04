package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// seedQuotaWindows writes n provider quota observations two minutes apart.
func seedQuotaWindows(t *testing.T, h *harness, account string, pct float64, n int) {
	t.Helper()
	base := time.Now().UTC().Add(-time.Duration(n) * 2 * time.Minute)
	for i := 0; i < n; i++ {
		if err := h.srv.Store.InsertQuota(model.QuotaSnapshot{
			Source: "codex", AccountUUID: account, EndpointID: "ep_mac",
			ObservedAt:  base.Add(time.Duration(i) * 2 * time.Minute),
			Observation: "app_server",
			Windows: []model.QuotaWindow{
				{ID: "primary", Label: "5h", Minutes: 300, UsedPercent: pct},
				{ID: "secondary", Label: "weekly", Minutes: 10080, UsedPercent: pct / 3},
			},
		}); err != nil {
			t.Fatal(err)
		}
	}
}

// Issue #60: QuotaHistorySeries had an MCP tool (quota_history) and a place in
// the dashboard, but on HTTP it existed only as the quota_series key folded
// inside /v1/limits/history. An API caller that wanted the provider windows had
// to fetch every account's utilization series to get at them -- the one door of
// the three with no direct way to ask.
//
// This pins the new route to the folded copy rather than to expected values:
// the whole point is that the two are one computation, so a fixture with its
// own idea of the answer would not catch them diverging.
func TestQuotaHistoryRouteMatchesTheFoldedCopy(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedQuotaWindows(t, h, "acct-a", 95, 20)

	since := time.Now().UTC().Add(-3 * time.Hour).Format(time.RFC3339)
	until := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)
	q := fmt.Sprintf("account=acct-a&since=%s&until=%s", url.QueryEscape(since), url.QueryEscape(until))

	var folded struct {
		QuotaSeries []QuotaSeries `json:"quota_series"`
	}
	h.getJSON(t, "/v1/limits/history?"+q, &folded)
	if len(folded.QuotaSeries) != 2 {
		t.Fatalf("setup: want two windows in quota_series, got %d", len(folded.QuotaSeries))
	}

	var direct struct {
		AccountUUID string        `json:"account_uuid"`
		Series      []QuotaSeries `json:"series"`
	}
	h.getJSON(t, "/v1/quota/history?"+q, &direct)

	if direct.AccountUUID != "acct-a" {
		t.Errorf("account_uuid = %q", direct.AccountUUID)
	}
	want, _ := json.Marshal(folded.QuotaSeries)
	got, _ := json.Marshal(direct.Series)
	if string(want) != string(got) {
		t.Errorf("/v1/quota/history and the quota_series key inside /v1/limits/history disagree:\n"+
			"  direct: %s\n  folded: %s", got, want)
	}
}

// The route is behind the viewer gate like every other query endpoint. It
// reports the same windows /v1/limits/history already exposed, so leaving it
// open would be a quiet widening of what an unauthenticated caller can read.
func TestQuotaHistoryRouteNeedsTheViewerToken(t *testing.T) {
	h := newHarness(t)
	resp, err := http.Get(h.http.URL + "/v1/quota/history")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /v1/quota/history = %d, want 401", resp.StatusCode)
	}
}

// A malformed range is a 400 here for the same reason it is everywhere else:
// substituting a default week for a typo shows the wrong period with
// confidence.
func TestQuotaHistoryRejectsABadRange(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	if code := h.getCode(t, "/v1/quota/history?account=acct-a&since=last-tuesday"); code != http.StatusBadRequest {
		t.Fatalf("since=last-tuesday = %d, want 400", code)
	}
}
