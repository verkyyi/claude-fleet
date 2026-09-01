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

	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken,
		LiveStore: NewLive()}
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
			SubscriptionType: "max", OSUser: "ci",
		},
		Events: evs,
		// The machine's own login, which is what most fixtures mean. Batches
		// for a subscription merely seen running on the box use
		// sessionBatchFor.
		AccountOrigin: model.OriginLogin,
	}
}

// sessionBatchFor is a batch for a subscription observed in a session on the
// machine, rather than the account the machine is logged into. A scan emits
// several of these alongside the login batch, one per subscription in play.
func sessionBatchFor(account, host string, uuids []string, cwd string) model.Batch {
	b := batchFor(account, host, uuids, cwd)
	b.AccountOrigin = model.OriginSession
	return b
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

// With several subscriptions and no choice made, the honest answer is
// everything, labelled as everything. Refusing used to be the safe option; it
// turned the subscription into a mode the whole page was stuck in, and left no
// way to ask "how much across all of them".
func TestQuery_NoAccountSpansEverythingAndSaysSo(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "a"), batchFor("acct-a", "a", []string{"a1"}, "/a"))
	h.push(t, h.enroll(t, "b"), batchFor("acct-b", "b", []string{"b1"}, "/b"))

	resp, body := h.get(t, "/v1/usage?by=endpoint&since=1d")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("HTTP %d, want 200", resp.StatusCode)
	}
	var out struct {
		AllAccounts bool           `json:"all_accounts"`
		ScopeNote   string         `json:"scope_note"`
		Buckets     []store.Bucket `json:"buckets"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if !out.AllAccounts {
		t.Error("a cross-subscription answer must be flagged as such")
	}
	if out.ScopeNote == "" {
		t.Error("a cross-subscription total must state what it spans")
	}
	if len(out.Buckets) != 2 {
		t.Fatalf("buckets = %d, want both machines", len(out.Buckets))
	}
}

// Account is now an ordinary axis: "which subscription" is the same shape of
// question as "which machine".
func TestQuery_ByAccountDimension(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "a"), batchFor("acct-a", "a", []string{"a1"}, "/a"))
	h.push(t, h.enroll(t, "b"), batchFor("acct-b", "b", []string{"b1"}, "/b"))

	resp, body := h.get(t, "/v1/usage?account=all&by=account&since=1d")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("HTTP %d: %s", resp.StatusCode, body)
	}
	var out struct {
		Buckets []store.Bucket `json:"buckets"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Buckets) != 2 {
		t.Fatalf("buckets = %d, want one per subscription", len(out.Buckets))
	}
}

// THE constraint. Two pools at 4% and 19% are not 23% of anything; the
// cross-subscription shape is a list with no aggregate field to misread.
func TestLimits_AcrossAccountsIsNeverSummed(t *testing.T) {
	h := newHarness(t)
	tokA, tokB := h.enroll(t, "a"), h.enroll(t, "b")

	mk := func(acct, host, uuid string, util float64) model.Batch {
		b := batchFor(acct, host, []string{uuid}, "/"+host)
		reset := time.Now().UTC().Add(time.Hour)
		b.Limits = &model.LimitsSnapshot{
			ObservedAt: time.Now().UTC(),
			FiveHour:   model.Window{Utilization: util, ResetsAt: &reset},
			SevenDay:   model.Window{Utilization: util / 2},
		}
		return b
	}
	h.push(t, tokA, mk("acct-a", "a", "a1", 4))
	h.push(t, tokB, mk("acct-b", "b", "b1", 19))

	_, body := h.get(t, "/v1/limits?account=all")

	// The shape itself must offer nowhere to put a total. Substring-matching
	// for "23" was the first attempt and it is worthless — timestamps contain
	// it. Asserting the key set is exact means an aggregate field cannot be
	// added later without this failing.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{"per_account": true, "worst": true, "note": true}
	for k := range raw {
		if !allowed[k] {
			t.Errorf("unexpected top-level key %q in a cross-subscription reading; "+
				"utilization must have nowhere to be totalled", k)
		}
	}

	var across LimitsAcross
	if err := json.Unmarshal(body, &across); err != nil {
		t.Fatal(err)
	}
	if len(across.PerAccount) != 2 {
		t.Fatalf("per_account = %d, want one entry per subscription", len(across.PerAccount))
	}
	for _, e := range across.PerAccount {
		if e.Limits == nil || !e.Limits.Available {
			t.Fatalf("%s has no reading", e.Label)
		}
	}
	if across.Worst == nil {
		t.Fatal("no worst subscription identified")
	}
	if across.Worst.Limits.FiveHour.Utilization != 19 {
		t.Errorf("worst = %v%%, want the 19%% pool", across.Worst.Limits.FiveHour.Utilization)
	}
	if across.Note == "" {
		t.Error("the response must say why there is no total")
	}
}

// An unavailable reading is unknown, not zero, and must not be crowned "worst"
// nor suppress a real one.
func TestLimits_AcrossIgnoresUnavailableWhenPickingWorst(t *testing.T) {
	h := newHarness(t)
	tokA, tokB := h.enroll(t, "a"), h.enroll(t, "b")

	known := batchFor("acct-a", "a", []string{"a1"}, "/a")
	reset := time.Now().UTC().Add(time.Hour)
	known.Limits = &model.LimitsSnapshot{ObservedAt: time.Now().UTC(),
		FiveHour: model.Window{Utilization: 7, ResetsAt: &reset}}
	h.push(t, tokA, known)

	blind := batchFor("acct-b", "b", []string{"b1"}, "/b")
	blind.LimitsUnavailable = "token expired"
	h.push(t, tokB, blind)

	_, body := h.get(t, "/v1/limits?account=all")
	var across LimitsAcross
	if err := json.Unmarshal(body, &across); err != nil {
		t.Fatal(err)
	}
	if across.Worst == nil || across.Worst.AccountUUID != "acct-a" {
		t.Fatalf("worst = %+v, want the only subscription with a real reading", across.Worst)
	}
	if len(across.PerAccount) != 2 {
		t.Error("a subscription with no reading must still appear, so its gap is visible")
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

// Real-machine finding: an endpoint knows exactly why it could not read the
// limits ("the local OAuth token has expired"), and that was thrown away, so
// the UI could only say "nobody managed to read them" — useless for working out
// WHICH machine to go fix.
func TestLimits_UnavailableCarriesTheEndpointsOwnReason(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "macmini")

	batch := batchFor("acct-a", "macmini", []string{"r1"}, "/a")
	batch.LimitsUnavailable = "the local OAuth token has expired; it refreshes when Claude Code next runs"
	if resp := h.push(t, tok, batch); resp.StatusCode != 200 {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if view.Available {
		t.Fatal("available = true with no snapshot")
	}
	if !strings.Contains(view.Reason, "macmini") {
		t.Errorf("reason %q does not name the endpoint to go fix", view.Reason)
	}
	if !strings.Contains(view.Reason, "expired") {
		t.Errorf("reason %q dropped the endpoint's own explanation", view.Reason)
	}
}

// Control: with nothing reported, the generic message stands — otherwise the
// assertion above could pass on a build that always echoes a canned string.
func TestLimits_NoReasonReportedFallsBackToTheGenericMessage(t *testing.T) {
	h := newHarness(t)
	h.push(t, h.enroll(t, "quiet"), batchFor("acct-a", "quiet", []string{"q1"}, "/a"))

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(view.Reason, "reports:") {
		t.Errorf("reason %q claims an endpoint said something when none did", view.Reason)
	}
	if view.Reason == "" {
		t.Error("an unavailable reading must still carry some reason")
	}
}

// Regression from a live two-machine hub: a scan is split across many batches
// and the limits verdict rides on the first one. Recording unconditionally let
// every later batch overwrite the real reason with an empty string, so the UI
// fell back to "nobody managed to read them" — the exact message the reason
// plumbing exists to replace.
func TestIngest_LaterBatchesDoNotEraseTheLimitsReason(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "macmini")

	first := batchFor("acct-a", "macmini", []string{"c1"}, "/a")
	first.LimitsUnavailable = "the local OAuth token has expired"
	if resp := h.push(t, tok, first); resp.StatusCode != 200 {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}

	// The rest of the same scan: no limits verdict, just more events.
	for i := 2; i <= 4; i++ {
		rest := batchFor("acct-a", "macmini", []string{fmt.Sprintf("c%d", i)}, "/a")
		if resp := h.push(t, tok, rest); resp.StatusCode != 200 {
			t.Fatalf("chunk %d: HTTP %d", i, resp.StatusCode)
		}
	}

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(view.Reason, "expired") {
		t.Fatalf("reason = %q; the later chunks erased what the first one reported", view.Reason)
	}
	if !strings.Contains(view.Reason, "macmini") {
		t.Errorf("reason = %q; it no longer names the machine to go fix", view.Reason)
	}
}

// Control: a successful reading must CLEAR a previously recorded failure,
// otherwise a stale complaint would outlive the problem.
func TestIngest_SuccessfulReadingClearsAnOldReason(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "flaky")

	bad := batchFor("acct-a", "flaky", []string{"f1"}, "/a")
	bad.LimitsUnavailable = "temporary network failure"
	h.push(t, tok, bad)

	reset := time.Now().UTC().Add(time.Hour)
	good := batchFor("acct-a", "flaky", []string{"f2"}, "/a")
	good.Limits = &model.LimitsSnapshot{
		ObservedAt: time.Now().UTC(),
		FiveHour:   model.Window{Utilization: 11, ResetsAt: &reset},
	}
	h.push(t, tok, good)

	_, reason, err := h.srv.Store.LimitsReason("acct-a")
	if err != nil {
		t.Fatal(err)
	}
	if reason != "" {
		t.Errorf("stale reason %q survived a successful reading", reason)
	}
}

// The bug this replaced, in its measured shape.
//
// A laptop was running two subscriptions at once, so every scan emitted a login
// batch for one and a session batch for the other. The hub wrote both to the
// endpoint's single account column and logged a switch on each change: 83
// "switches" in four hours, in exactly balanced A->B/B->A pairs as little as
// 0.003s apart, none of which happened.
//
// The control for this assertion is TestIngest_RecordsAccountSwitch above — it
// proves a genuine login change is still recorded, so a zero here means
// concurrency was distinguished, not that the feature was turned off.
func TestIngest_ConcurrentSubscriptionsAreNotSwitches(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")

	for i := 0; i < 5; i++ {
		h.push(t, tok, batchFor("acct-a", "laptop", []string{fmt.Sprintf("a%d", i)}, "/a"))
		h.push(t, tok, sessionBatchFor("acct-b", "laptop", []string{fmt.Sprintf("b%d", i)}, "/b"))
	}

	switches, err := h.srv.Store.AccountSwitches(100)
	if err != nil {
		t.Fatal(err)
	}
	if len(switches) != 0 {
		t.Fatalf("switches = %d, want 0: two subscriptions running side by side is "+
			"not a machine changing account (%+v)", len(switches), switches)
	}

	// Both must still be visible — the fix is to record concurrency, not to
	// drop the second subscription on the floor.
	eas, err := h.srv.Store.EndpointAccounts(100)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]string{}
	for _, ea := range eas {
		seen[ea.AccountUUID] = ea.Origin
	}
	if seen["acct-a"] != "login" {
		t.Errorf("acct-a origin = %q, want login", seen["acct-a"])
	}
	if seen["acct-b"] != "session" {
		t.Errorf("acct-b origin = %q, want session", seen["acct-b"])
	}
}

// A subscription merely seen running on a machine must not become the machine's
// login. If it does, the endpoint's account flips on every scan and every
// account-scoped query follows it.
func TestIngest_SessionBatchDoesNotMoveTheEndpointLogin(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")

	h.push(t, tok, batchFor("acct-a", "laptop", []string{"a1"}, "/a"))
	h.push(t, tok, sessionBatchFor("acct-b", "laptop", []string{"b1"}, "/b"))

	eps, err := h.srv.Store.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if len(eps) != 1 {
		t.Fatalf("endpoints = %d, want 1", len(eps))
	}
	if eps[0].AccountUUID != "acct-a" {
		t.Errorf("endpoint login = %q, want acct-a — a guest subscription took the slot",
			eps[0].AccountUUID)
	}
}

// An endpoint that has never reported takes whatever arrives first, even from
// an agent too old to declare an origin. Leaving it NULL would make the
// endpoint invisible to every account-scoped query, limits included.
func TestIngest_FirstReportEstablishesTheLoginEvenWithoutAnOrigin(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "old-agent")

	b := batchFor("acct-a", "old-agent", []string{"x1"}, "/a")
	b.AccountOrigin = "" // an agent from before the field existed
	h.push(t, tok, b)

	eps, err := h.srv.Store.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if eps[0].AccountUUID != "acct-a" {
		t.Fatalf("endpoint login = %q, want acct-a", eps[0].AccountUUID)
	}
	// ...and correcting that provisional guess later is not a "switch".
	h.push(t, tok, batchFor("acct-b", "old-agent", []string{"x2"}, "/a"))
	switches, err := h.srv.Store.AccountSwitches(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(switches) != 0 {
		t.Errorf("switches = %d, want 0: the first value was a guess, not a login", len(switches))
	}
}

// Spend must be attributable to the OS login it ran under. On a shared machine
// this is the axis an operator asks about, and no other column carries it.
func TestUsageByUser(t *testing.T) {
	h := newHarness(t)

	alice := h.enroll(t, "buildbox-alice")
	a := batchFor("acct-a", "buildbox", []string{"u1", "u2"}, "/proj")
	a.Identity.OSUser = "alice"
	h.push(t, alice, a)

	bob := h.enroll(t, "buildbox-bob")
	b := batchFor("acct-a", "buildbox", []string{"u3"}, "/proj")
	b.Identity.OSUser = "bob"
	h.push(t, bob, b)

	_, body := h.get(t, "/v1/usage?account=acct-a&by=user&since=-24h")
	var out struct {
		By      string `json:"by"`
		Buckets []struct {
			Key    string `json:"key"`
			Events int64  `json:"events"`
			Tokens int64  `json:"tokens"`
		} `json:"buckets"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	for _, b := range out.Buckets {
		got[b.Key] = b.Events
	}
	if got["alice"] != 2 || got["bob"] != 1 {
		t.Fatalf("by-user events = %v, want alice:2 bob:1 — the two logins on one "+
			"machine were not separated", got)
	}
}

// End to end: a reading that contradicts the previous one must not be stored,
// and the endpoint must say why. Measured on this hub — the seven-day window
// reported 41% at 17:57 and 0% at 18:00 with an unchanged reset time, and
// ccquota served the 0% as truth. `ccquota budget` reads exactly this, so the
// stale-but-real 41% becoming a fresh-looking 0% is headroom that does not
// exist.
func TestIngest_RefusesALimitsReadingThatContradictsTheLast(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")

	sevenReset := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	fiveReset := time.Date(2026, 9, 1, 18, 40, 0, 0, time.UTC)

	good := batchFor("acct-a", "laptop", []string{"g1"}, "/a")
	good.Limits = &model.LimitsSnapshot{
		AccountUUID: "acct-a",
		ObservedAt:  time.Now().UTC().Add(-3 * time.Minute),
		FiveHour:    model.Window{Utilization: 32, ResetsAt: &fiveReset},
		SevenDay:    model.Window{Utilization: 41, ResetsAt: &sevenReset},
	}
	h.push(t, tok, good)

	bad := batchFor("acct-a", "laptop", []string{"g2"}, "/a")
	bad.Limits = &model.LimitsSnapshot{
		AccountUUID: "acct-a",
		ObservedAt:  time.Now().UTC(),
		FiveHour:    model.Window{Utilization: 0, ResetsAt: &fiveReset},
		SevenDay:    model.Window{Utilization: 0, ResetsAt: &sevenReset},
	}
	h.push(t, tok, bad)

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if view.SevenDay != nil && view.SevenDay.Utilization == 0 {
		t.Fatal("the contradicting reading was stored: the seven-day window now reads 0%, " +
			"which a scheduler would see as a full week of headroom")
	}
	if view.SevenDay == nil || view.SevenDay.Utilization != 41 {
		t.Fatalf("seven-day = %+v, want the last trustworthy reading (41%%)", view.SevenDay)
	}

	// The refusal must be visible, not silent — otherwise the number simply
	// stops moving and nobody knows why.
	eps, err := h.srv.Store.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(eps[0].LimitsUnavailable, "seven-day") {
		t.Errorf("endpoint reason = %q; it should say which window contradicted",
			eps[0].LimitsUnavailable)
	}
}

// Control: an ordinary rollover must still be accepted, or the guard would
// freeze every account's limits five hours after the hub started.
func TestIngest_AcceptsAWindowRollover(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")

	sevenReset := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	before := time.Date(2026, 9, 1, 18, 40, 0, 0, time.UTC)
	after := time.Date(2026, 9, 1, 23, 40, 0, 0, time.UTC)

	first := batchFor("acct-a", "laptop", []string{"r1"}, "/a")
	first.Limits = &model.LimitsSnapshot{AccountUUID: "acct-a", ObservedAt: time.Now().UTC().Add(-time.Minute),
		FiveHour: model.Window{Utilization: 96, ResetsAt: &before},
		SevenDay: model.Window{Utilization: 41, ResetsAt: &sevenReset}}
	h.push(t, tok, first)

	rolled := batchFor("acct-a", "laptop", []string{"r2"}, "/a")
	rolled.Limits = &model.LimitsSnapshot{AccountUUID: "acct-a", ObservedAt: time.Now().UTC(),
		FiveHour: model.Window{Utilization: 2, ResetsAt: &after},
		SevenDay: model.Window{Utilization: 41, ResetsAt: &sevenReset}}
	h.push(t, tok, rolled)

	_, body := h.get(t, "/v1/limits?account=acct-a")
	var view LimitsView
	if err := json.Unmarshal(body, &view); err != nil {
		t.Fatal(err)
	}
	if view.FiveHour == nil || view.FiveHour.Utilization != 2 {
		t.Fatalf("five-hour = %+v, want the rolled-over 2%% — the guard must not "+
			"reject an ordinary reset", view.FiveHour)
	}
}

// An endpoint has one login at a time and any number of concurrent guests. The
// 'login' marking is sticky so a session sighting cannot demote a real login —
// but nothing un-stuck it after a genuine logout/login, so the dashboard showed
// one machine claiming two "own logins" at once, contradicting the very model
// the junction table exists to express.
func TestIngest_ASwitchDemotesThePreviousLogin(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")

	h.push(t, tok, batchFor("acct-old", "laptop", []string{"o1"}, "/a"))
	h.push(t, tok, batchFor("acct-new", "laptop", []string{"n1"}, "/a"))

	eas, err := h.srv.Store.EndpointAccounts(100)
	if err != nil {
		t.Fatal(err)
	}
	origin := map[string]string{}
	for _, ea := range eas {
		origin[ea.AccountUUID] = ea.Origin
	}
	if origin["acct-new"] != "login" {
		t.Errorf("the account just logged into is %q, want login", origin["acct-new"])
	}
	if origin["acct-old"] != "session" {
		t.Errorf("the previous login is still %q; one machine cannot have two own logins",
			origin["acct-old"])
	}
	// It must not vanish — sessions started under it keep running and reporting.
	if _, present := origin["acct-old"]; !present {
		t.Error("the previous account was dropped rather than demoted")
	}
}

// Control: a guest sighting must NOT demote the real login.
func TestIngest_AGuestDoesNotDemoteTheLogin(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")

	h.push(t, tok, batchFor("acct-login", "laptop", []string{"l1"}, "/a"))
	h.push(t, tok, sessionBatchFor("acct-guest", "laptop", []string{"g1"}, "/b"))

	eas, err := h.srv.Store.EndpointAccounts(100)
	if err != nil {
		t.Fatal(err)
	}
	for _, ea := range eas {
		if ea.AccountUUID == "acct-login" && ea.Origin != "login" {
			t.Errorf("a guest sighting demoted the real login to %q", ea.Origin)
		}
		if ea.AccountUUID == "acct-guest" && ea.Origin != "session" {
			t.Errorf("a guest was promoted to %q", ea.Origin)
		}
	}
}
