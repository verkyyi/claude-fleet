package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

// costResponse is /v1/repo/cost as a caller sees it.
type costResponse struct {
	Repo   string `json:"repo"`
	Issues []struct {
		Number     int64            `json:"number"`
		Known      bool             `json:"known"`
		Title      string           `json:"title"`
		State      string           `json:"state"`
		AgeSeconds *float64         `json:"age_seconds"`
		Stale      *bool            `json:"stale"`
		Window     store.SpendTotal `json:"window"`
		Lifetime   store.SpendTotal `json:"lifetime"`
	} `json:"issues"`
	Distinct     int              `json:"distinct_issues"`
	Attributed   store.SpendTotal `json:"attributed"`
	Unattributed struct {
		store.SpendTotal
		Branches []store.UnattributedBranch `json:"branches"`
	} `json:"unattributed"`
	Total store.SpendTotal `json:"total"`
	Scale *store.RepoScale `json:"scale"`
}

// spendOnBranch pushes usage recorded on one branch, through the real ingest
// path: the house rule is that a test exercises the endpoint, not the store.
func spendOnBranch(t *testing.T, h *harness, endpoint, branch string, uuids ...string) {
	t.Helper()
	tok := h.tokens[endpoint]
	if tok == "" {
		tok = h.enroll(t, endpoint)
	}
	b := batchFor("acct-a", endpoint, uuids, "/w")
	for i := range b.Events {
		b.Events[i].GitBranch = branch
		b.Events[i].SessionID = uuids[i]
	}
	resp := h.push(t, tok, b)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("push on %s: HTTP %d", branch, resp.StatusCode)
	}
}

// oneRepo seeds the single repository the §5 binding requires.
func oneRepo(t *testing.T, h *harness, repo string, scale bool, issues ...model.RepoIssue) {
	t.Helper()
	snap := model.RepoSnapshot{Repo: repo, ObservedAt: time.Now().UTC(), Issues: issues}
	day := model.RepoDay{Day: time.Now().UTC().Format(model.RepoDayLayout), Opened: 1, Closed: 1, OpenAtEnd: 2}
	if scale {
		// p95 of one day: anything older than a day is past it.
		day.CloseP95Seconds = fptr(86400)
		day.ClosedSample = func() *int { n := 30; return &n }()
	}
	snap.Days = []model.RepoDay{day}
	seedRepo(t, h, snap)
}

// The headline: money on the issue axis, with progress beside it.
func TestRepoCost_PutsMoneyAndProgressOnOneAxis(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true,
		repoIssue(57, 9, model.RepoStateOpen),
		repoIssue(58, 0, model.RepoStateOpen))
	spendOnBranch(t, h, "web-01", "issue-57", "a1", "a2")
	spendOnBranch(t, h, "web-01", "issue-58", "b1")

	var got costResponse
	h.getJSON(t, "/v1/repo/cost?repo=o/r", &got)

	if len(got.Issues) != 2 {
		t.Fatalf("issues = %+v, want two", got.Issues)
	}
	top := got.Issues[0]
	if top.Number != 57 {
		t.Errorf("top spender = #%d, want #57 (two turns against one)", top.Number)
	}
	if !top.Known || top.Title == "" || top.State != model.RepoStateOpen {
		t.Errorf("#57 carries no progress: %+v", top)
	}
	if top.Window.Events != 2 {
		t.Errorf("#57 window events = %d, want 2", top.Window.Events)
	}
	if top.Lifetime.Events != 2 {
		t.Errorf("#57 lifetime events = %d, want 2", top.Lifetime.Events)
	}
	// Nine days open against a one-day p95.
	if top.Stale == nil || !*top.Stale {
		t.Errorf("#57 stale = %v, want true against this repo's own p95", top.Stale)
	}
	if got.Issues[1].Stale == nil || *got.Issues[1].Stale {
		t.Errorf("#58 stale = %v, want false: opened today against a one-day p95", got.Issues[1].Stale)
	}
}

// The bucket that must never vanish, and the sum a reader is allowed to check.
func TestRepoCost_UnattributedIsVisibleAndTheSumHolds(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true, repoIssue(57, 2, model.RepoStateOpen))
	spendOnBranch(t, h, "web-01", "issue-57", "a1")
	spendOnBranch(t, h, "web-01", "scratch-94", "s1")
	spendOnBranch(t, h, "web-01", "HEAD", "h1")

	var got costResponse
	h.getJSON(t, "/v1/repo/cost?repo=o/r", &got)

	if got.Unattributed.Events != 2 {
		t.Fatalf("unattributed events = %d, want 2 (scratch-94 and HEAD)", got.Unattributed.Events)
	}
	if got.Attributed.Events+got.Unattributed.Events != got.Total.Events {
		t.Errorf("%d attributed + %d unattributed != %d total",
			got.Attributed.Events, got.Unattributed.Events, got.Total.Events)
	}
	if got.Attributed.Tokens+got.Unattributed.Tokens != got.Total.Tokens {
		t.Errorf("token parts do not sum to the total")
	}
	names := map[string]bool{}
	for _, b := range got.Unattributed.Branches {
		names[b.Branch] = true
	}
	if !names["scratch-94"] || !names["HEAD"] {
		t.Errorf("branches = %+v, want the bucket explained by branch", got.Unattributed.Branches)
	}
}

// A repo that has shipped no percentiles gets "the scale is unknown", not a
// substituted threshold and not a confident false.
func TestRepoCost_NoScaleMeansStaleIsUnknownNotFalse(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", false, repoIssue(57, 400, model.RepoStateOpen))
	spendOnBranch(t, h, "web-01", "issue-57", "a1")

	var got costResponse
	h.getJSON(t, "/v1/repo/cost?repo=o/r", &got)

	if got.Scale != nil && got.Scale.P95Seconds != nil {
		t.Fatalf("scale = %+v, want none shipped", got.Scale)
	}
	if len(got.Issues) != 1 {
		t.Fatalf("issues = %+v", got.Issues)
	}
	if got.Issues[0].Stale != nil {
		t.Errorf("stale = %v for a 400-day-old issue with no scale; want null, never a guess", *got.Issues[0].Stale)
	}
}

// Spend outlives the issue rows, so a number with no backlog row keeps its
// money and says it is unknown. Dropping it would break the sum above.
func TestRepoCost_SpendOnAnIssueTheHubNoLongerHoldsStaysVisible(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true, repoIssue(57, 2, model.RepoStateOpen))
	spendOnBranch(t, h, "web-01", "issue-57", "a1")
	spendOnBranch(t, h, "web-01", "issue-4059", "b1")

	var got costResponse
	h.getJSON(t, "/v1/repo/cost?repo=o/r", &got)

	var found bool
	for _, i := range got.Issues {
		if i.Number != 4059 {
			continue
		}
		found = true
		if i.Known {
			t.Error("#4059 claims to be known; the hub holds no row for it")
		}
		if i.Window.Events != 1 {
			t.Errorf("#4059 window events = %d, want its money kept", i.Window.Events)
		}
		if i.Stale != nil {
			t.Error("#4059 has a staleness verdict without an age to judge")
		}
	}
	if !found {
		t.Error("#4059 is missing entirely; its spend would vanish from the total")
	}
	if got.Attributed.Events != 2 {
		t.Errorf("attributed events = %d, want 2", got.Attributed.Events)
	}
}

// The §5 gate. A number means two different things once a second repository
// enrols, and nothing on the spend row can separate them, so the read refuses.
func TestRepoCost_RefusesOnceTheHubHoldsTwoRepos(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true, repoIssue(57, 2, model.RepoStateOpen))
	spendOnBranch(t, h, "web-01", "issue-57", "a1")

	if code := h.getCode(t, "/v1/repo/cost?repo=o/r"); code != http.StatusOK {
		t.Fatalf("one repo: HTTP %d, want 200", code)
	}

	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/second", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(57, 2, model.RepoStateOpen)},
	})

	resp, body := h.get(t, "/v1/repo/cost?repo=o/r")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("two repos: HTTP %d, want 409", resp.StatusCode)
	}
	if !strings.Contains(string(body), "o/second") {
		t.Errorf("the refusal does not name what the hub holds: %s", body)
	}
}

// Asking about a repository the hub does not hold is the same failure wearing
// a different hat: there is no backlog to bind the numbers to.
func TestRepoCost_RefusesARepoTheHubDoesNotHold(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true, repoIssue(57, 2, model.RepoStateOpen))

	if code := h.getCode(t, "/v1/repo/cost?repo=o/other"); code != http.StatusConflict {
		t.Errorf("HTTP %d for an unheld repo, want 409", code)
	}
	// And a hub with no progress at all.
	empty := newHarness(t)
	if code := empty.getCode(t, "/v1/repo/cost?repo=o/r"); code != http.StatusConflict {
		t.Errorf("HTTP %d on a hub with no repos, want 409", code)
	}
}

// repo stays required, exactly as it is on every other repo endpoint.
func TestRepoCost_RequiresARepo(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true)
	if code := h.getCode(t, "/v1/repo/cost"); code != http.StatusBadRequest {
		t.Errorf("HTTP %d without repo=, want 400", code)
	}
	if code := h.getCode(t, "/v1/repo/cost?repo=o/r&limit=0"); code != http.StatusBadRequest {
		t.Errorf("HTTP %d for limit=0, want 400", code)
	}
}

// cost=1 puts the burn beside a stalled issue, and leaves the endpoint exactly
// as it was for every caller that did not ask.
func TestRepoIssues_CostIsOptInAndGated(t *testing.T) {
	h := newHarness(t)
	oneRepo(t, h, "o/r", true, repoIssue(57, 9, model.RepoStateOpen))
	spendOnBranch(t, h, "web-01", "issue-57", "a1", "a2")

	var plain struct {
		Issues []map[string]json.RawMessage `json:"issues"`
	}
	h.getJSON(t, "/v1/repo/issues?repo=o/r&stale=1", &plain)
	if len(plain.Issues) != 1 {
		t.Fatalf("stale issues = %d, want 1", len(plain.Issues))
	}
	if _, ok := plain.Issues[0]["lifetime"]; ok {
		t.Error("lifetime appeared without cost=1; the field must be opt-in")
	}

	var priced struct {
		Issues []struct {
			Number   int              `json:"number"`
			Lifetime store.SpendTotal `json:"lifetime"`
		} `json:"issues"`
	}
	h.getJSON(t, "/v1/repo/issues?repo=o/r&stale=1&cost=1", &priced)
	if len(priced.Issues) != 1 || priced.Issues[0].Number != 57 {
		t.Fatalf("priced = %+v", priced.Issues)
	}
	if priced.Issues[0].Lifetime.Events != 2 {
		t.Errorf("#57 lifetime events = %d, want 2", priced.Issues[0].Lifetime.Events)
	}

	// The gate applies to the flag, not to the endpoint: a second repo must
	// not start refusing callers who never asked for money.
	seedRepo(t, h, model.RepoSnapshot{Repo: "o/second", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(57, 2, model.RepoStateOpen)}})
	if code := h.getCode(t, "/v1/repo/issues?repo=o/r&stale=1"); code != http.StatusOK {
		t.Errorf("HTTP %d without cost=1 on a two-repo hub, want 200", code)
	}
	// cost=1 degrades instead of refusing: the backlog is correct either way,
	// and the reason travels with it rather than the field simply vanishing.
	var degraded struct {
		Issues []struct {
			Number   int               `json:"number"`
			Lifetime *store.SpendTotal `json:"lifetime"`
		} `json:"issues"`
		CostUnavailable string `json:"cost_unavailable"`
	}
	h.getJSON(t, "/v1/repo/issues?repo=o/r&stale=1&cost=1", &degraded)
	if len(degraded.Issues) != 1 {
		t.Fatalf("the backlog went missing with the money: %+v", degraded)
	}
	if degraded.Issues[0].Lifetime != nil {
		t.Error("a lifetime figure was served on a hub where the numbers cannot be bound")
	}
	if !strings.Contains(degraded.CostUnavailable, "o/second") {
		t.Errorf("cost_unavailable = %q; want the reason, naming what the hub holds", degraded.CostUnavailable)
	}
}
