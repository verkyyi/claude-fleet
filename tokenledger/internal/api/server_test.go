package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

const viewerToken = "viewer-secret"

type harness struct {
	srv    *Server
	http   *httptest.Server
	tokens map[string]string // endpoint label -> enrollment token
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	return &harness{srv: srv, http: ts, tokens: map[string]string{}}
}

func (h *harness) enroll(t *testing.T, label string) string {
	t.Helper()
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	id := "ep_" + label
	if err := h.srv.Store.Enroll(id, label, HashToken(tok)); err != nil {
		t.Fatal(err)
	}
	h.tokens[label] = tok
	return tok
}

func (h *harness) push(t *testing.T, token string, batch model.Batch) *http.Response {
	t.Helper()
	body, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func (h *harness) get(t *testing.T, path string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	buf.ReadFrom(resp.Body)
	return resp, buf.Bytes()
}

func batchFor(account, host string, uuids []string, cwd string) model.Batch {
	evs := make([]model.UsageEvent, len(uuids))
	for i, u := range uuids {
		evs[i] = model.UsageEvent{
			MessageUUID: u, SessionID: "sess-" + host, TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 1000, CWD: cwd,
		}
	}
	return model.Batch{
		AgentVersion: "test",
		Identity: model.Identity{
			AccountUUID: account, Email: account + "@example.com",
			Hostname: host, OS: "linux", Arch: "amd64",
			SubscriptionType: "max",
		},
		Events: evs,
	}
}

// The end-to-end shape: two subscriptions, two endpoints, and no leakage
// between them through any query path.
func TestEndToEnd_TwoSubscriptionsStayIsolated(t *testing.T) {
	h := newHarness(t)
	tokA := h.enroll(t, "web-01")
	tokB := h.enroll(t, "other-co")

	if resp := h.push(t, tokA, batchFor("acct-a", "web-01", []string{"a1", "a2"}, "/srv/alpha")); resp.StatusCode != 200 {
		t.Fatalf("push A: HTTP %d", resp.StatusCode)
	}
	if resp := h.push(t, tokB, batchFor("acct-b", "other-co", []string{"b1"}, "/srv/confidential")); resp.StatusCode != 200 {
		t.Fatalf("push B: HTTP %d", resp.StatusCode)
	}

	// Both subscriptions are visible to the hub operator.
	_, body := h.get(t, "/v1/accounts")
	var accts []store.Account
	if err := json.Unmarshal(body, &accts); err != nil {
		t.Fatal(err)
	}
	if len(accts) != 2 {
		t.Fatalf("accounts = %d, want 2", len(accts))
	}

	// But acct-a's breakdown must not mention acct-b's work.
	_, body = h.get(t, "/v1/usage?account=acct-a&by=project&since=1d")
	if s := string(body); strings.Contains(s, "confidential") {
		t.Fatalf("acct-a's project breakdown leaked acct-b's directory: %s", s)
	}

	_, body = h.get(t, "/v1/usage?account=acct-a&by=endpoint&since=1d")
	if s := string(body); strings.Contains(s, "other-co") {
		t.Fatalf("acct-a's endpoint breakdown leaked acct-b's endpoint: %s", s)
	}
}

// With more than one subscription the hub must refuse to guess which one is
// meant, rather than silently answering for the wrong account.
func TestQuery_AmbiguousAccountIsRefused(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "a"), batchFor("acct-a", "a", []string{"a1"}, "/a"))
	h.push(t, h.enroll(t, "b"), batchFor("acct-b", "b", []string{"b1"}, "/b"))

	resp, body := h.get(t, "/v1/usage?by=endpoint")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("HTTP %d, want 400 when the account is ambiguous", resp.StatusCode)
	}
	if !strings.Contains(string(body), "account") {
		t.Errorf("the error should tell the caller to pass ?account=: %s", body)
	}
}

// One subscription is the common case and should need no ceremony.
func TestQuery_SingleAccountIsInferred(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "a"), batchFor("acct-a", "a", []string{"a1"}, "/a"))

	resp, _ := h.get(t, "/v1/usage?by=endpoint")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("HTTP %d, want 200 when there is only one subscription", resp.StatusCode)
	}
}

// The endpoint id must come from the token, never from the body — otherwise
// any enrolled agent could write rows attributed to another machine.
func TestIngest_EndpointIdentityComesFromTheToken(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "web-01")

	batch := batchFor("acct-a", "web-01", []string{"x1"}, "/srv/alpha")
	batch.Events[0].EndpointID = "ep_someone-else"
	batch.Events[0].AccountUUID = "acct-impersonated"

	if resp := h.push(t, tok, batch); resp.StatusCode != 200 {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}

	var endpointID, account string
	err := h.srv.Store.DB().QueryRow(
		`SELECT endpoint_id, account_uuid FROM usage_events WHERE message_uuid='x1'`).
		Scan(&endpointID, &account)
	if err != nil {
		t.Fatal(err)
	}
	if endpointID != "ep_web-01" {
		t.Errorf("endpoint_id = %q; the body overrode the authenticated identity", endpointID)
	}
	if account != "acct-a" {
		t.Errorf("account_uuid = %q, want the identity the agent reported", account)
	}
}

func TestIngest_RejectsBadToken(t *testing.T) {
	h := newHarness(t)
	h.enroll(t, "web-01")

	resp := h.push(t, "ccq_not-a-real-token", batchFor("acct-a", "web-01", []string{"x"}, "/a"))
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("HTTP %d, want 401", resp.StatusCode)
	}
}

func TestIngest_ReplayIsDeduped(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "web-01")
	batch := batchFor("acct-a", "web-01", []string{"r1", "r2"}, "/a")

	for i, want := range []struct{ accepted, deduped int }{{2, 0}, {0, 2}} {
		resp := h.push(t, tok, batch)
		defer resp.Body.Close()
		var out model.IngestResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		if out.Accepted != want.accepted || out.Deduped != want.deduped {
			t.Fatalf("push %d: %d accepted / %d deduped, want %d/%d",
				i+1, out.Accepted, out.Deduped, want.accepted, want.deduped)
		}
	}
}

// The seam that cannot be repaired must at least be recorded.
func TestIngest_RecordsAccountSwitch(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shared-laptop")

	h.push(t, tok, batchFor("acct-a", "shared-laptop", []string{"s1"}, "/a"))
	h.push(t, tok, batchFor("acct-b", "shared-laptop", []string{"s2"}, "/b"))

	switches, err := h.srv.Store.AccountSwitches(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(switches) != 1 {
		t.Fatalf("switches = %d, want 1", len(switches))
	}
	if switches[0].FromAccount != "acct-a" || switches[0].ToAccount != "acct-b" {
		t.Errorf("switch = %+v", switches[0])
	}
}

// No snapshot must present as unavailable-with-a-reason, never as 0%.
func TestLimits_UnavailableIsExplicitNotZero(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "a"), batchFor("acct-a", "a", []string{"a1"}, "/a"))

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if view.Available {
		t.Fatal("available = true with no snapshot on record")
	}
	if view.Reason == "" {
		t.Error("an unavailable reading must carry a reason")
	}
	if view.FiveHour != nil {
		t.Errorf("five_hour = %+v; an unavailable reading must render NO gauge", view.FiveHour)
	}
}

func TestLimits_PresentWithShares(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "web-01")

	reset := time.Now().UTC().Add(2 * time.Hour)
	batch := batchFor("acct-a", "web-01", []string{"l1"}, "/a")
	batch.Limits = &model.LimitsSnapshot{
		ObservedAt: time.Now().UTC(),
		FiveHour:   model.Window{Utilization: 40, ResetsAt: &reset},
		SevenDay:   model.Window{Utilization: 12},
	}
	if resp := h.push(t, tok, batch); resp.StatusCode != 200 {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if !view.Available || view.FiveHour == nil {
		t.Fatalf("view = %+v, want an available reading", view)
	}
	if view.FiveHour.Utilization != 40 {
		t.Errorf("utilization = %v, want the exact 40 from Anthropic", view.FiveHour.Utilization)
	}
	if len(view.EndpointShares) != 1 {
		t.Fatalf("shares = %d, want 1", len(view.EndpointShares))
	}
	// One endpoint spent everything, so it owns the whole exact figure.
	if got := view.EndpointShares[0].EstimatedUtilization; got != 40 {
		t.Errorf("sole endpoint's share = %v, want 40", got)
	}
	if !strings.Contains(view.Disclaimer, "estimate") && !strings.Contains(view.Disclaimer, "ESTIMATE") {
		t.Errorf("the view must carry the estimate caveat, got %q", view.Disclaimer)
	}
}

// Everything except ingest and health is behind the viewer token.
func TestAuth_ViewerTokenRequired(t *testing.T) {
	h := newHarness(t)
	for _, path := range []string{"/v1/accounts", "/v1/limits", "/v1/endpoints", "/v1/usage", "/v1/history", "/"} {
		resp, err := h.http.Client().Get(h.http.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d without a token, want 401", path, resp.StatusCode)
		}
	}
}

func TestAuth_HealthAndIngestAreNotViewerGated(t *testing.T) {
	h := newHarness(t)
	resp, err := h.http.Client().Get(h.http.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/healthz: HTTP %d, want 200 so a load balancer can probe it", resp.StatusCode)
	}
}

// A token in the query string ends up in browser history and referrers; it is
// exchanged for a cookie on first use.
func TestAuth_QueryTokenIsExchangedForACookie(t *testing.T) {
	h := newHarness(t)
	client := h.http.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

	resp, err := client.Get(h.http.URL + "/?token=" + viewerToken)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusFound {
		t.Fatalf("HTTP %d, want a redirect that strips the token", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); strings.Contains(loc, "token=") {
		t.Errorf("redirect still carries the token: %s", loc)
	}
	var found bool
	for _, c := range resp.Cookies() {
		if c.Name == "ccquota_token" {
			found = true
			if !c.HttpOnly {
				t.Error("the session cookie must be HttpOnly")
			}
		}
	}
	if !found {
		t.Error("no ccquota_token cookie was set")
	}
}

func TestTokens_HashIsNotThePlaintext(t *testing.T) {
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	h := HashToken(tok)
	if strings.Contains(h, tok) || h == tok {
		t.Fatal("the stored hash must not contain the plaintext token")
	}
	if HashToken(tok) != h {
		t.Fatal("hashing must be deterministic")
	}
	if !strings.HasPrefix(tok, "ccq_") {
		t.Errorf("token = %q, want a recognisable prefix", tok)
	}
}

func TestMintToken_IsUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		tok, err := MintToken()
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatal("MintToken returned a duplicate")
		}
		seen[tok] = true
	}
}

func TestTimeRange_RelativeAndAbsolute(t *testing.T) {
	now := time.Now().UTC()
	start, end := timeRange("2d", "")
	if d := end.Sub(start); d < 47*time.Hour || d > 49*time.Hour {
		t.Errorf("range for since=2d is %v, want ~48h", d)
	}
	if end.Sub(now) > time.Minute {
		t.Errorf("end = %v, want ~now", end)
	}

	abs := now.Add(-30 * time.Hour).Format(time.RFC3339)
	start, _ = timeRange(abs, "")
	if start.Sub(now.Add(-30*time.Hour)).Abs() > time.Second {
		t.Errorf("absolute since not honored: %v", start)
	}
}

// A nonsense range must not silently invert into a query that returns
// everything or nothing.
func TestTimeRange_RejectsInvertedRange(t *testing.T) {
	now := time.Now().UTC()
	start, end := timeRange(now.Format(time.RFC3339), now.Add(-time.Hour).Format(time.RFC3339))
	if !start.Before(end) {
		t.Fatalf("range %v..%v is still inverted", start, end)
	}
}

func TestUsage_UnknownDimensionIsRejected(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "a"), batchFor("acct-a", "a", []string{"a1"}, "/a"))

	resp, _ := h.get(t, "/v1/usage?account=acct-a&by="+fmt.Sprint("nonsense"))
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("HTTP %d, want 400 for an unknown dimension", resp.StatusCode)
	}
}
