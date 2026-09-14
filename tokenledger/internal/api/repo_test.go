package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func (h *harness) pushRepo(t *testing.T, token string, snap model.RepoSnapshot) *http.Response {
	t.Helper()
	body, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest/repo", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func repoIssue(n int, ageDays int, state string) model.RepoIssue {
	created := time.Now().UTC().AddDate(0, 0, -ageDays)
	i := model.RepoIssue{Number: n, Title: "issue", State: state, CreatedAt: created}
	if state == model.RepoStateClosed {
		c := created.Add(time.Hour)
		i.ClosedAt = &c
	}
	return i
}

func fptr(f float64) *float64 { return &f }

// seedRepo ships one snapshot through the real ingest path — the house rule:
// tests exercise the endpoint, not the store behind it.
func seedRepo(t *testing.T, h *harness, snap model.RepoSnapshot) {
	t.Helper()
	tok := h.tokens["shipper"]
	if tok == "" {
		tok = h.enroll(t, "shipper")
	}
	resp := h.pushRepo(t, tok, snap)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		buf.ReadFrom(resp.Body)
		t.Fatalf("seed snapshot: %d %s", resp.StatusCode, buf.String())
	}
}

func TestRepoIngest_StoresAndServesBack(t *testing.T) {
	h := newHarness(t)
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "verkyyi/tokenledger", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(32, 13, model.RepoStateOpen)},
		Days: []model.RepoDay{{
			Day:    time.Now().UTC().Format(model.RepoDayLayout),
			Opened: 4, Closed: 6, OpenAtEnd: 431,
			CloseP50Seconds: fptr(11232), CloseP95Seconds: fptr(941760),
		}},
	})

	var repos []store.Repo
	h.getJSON(t, "/v1/repos", &repos)
	if len(repos) != 1 || repos[0].Repo != "verkyyi/tokenledger" || repos[0].Open != 1 {
		t.Fatalf("repos = %+v", repos)
	}

	var flow struct {
		Repo  string           `json:"repo"`
		Days  []model.RepoDay  `json:"days"`
		Scale *store.RepoScale `json:"scale"`
	}
	h.getJSON(t, "/v1/repo/flow?repo=verkyyi/tokenledger", &flow)
	if len(flow.Days) != 1 || flow.Days[0].OpenAtEnd != 431 {
		t.Fatalf("flow days = %+v", flow.Days)
	}
	// The scale travels with the flow: every age number in the response is
	// meaningless without the distribution it is measured against.
	if flow.Scale == nil || flow.Scale.P95Seconds == nil || *flow.Scale.P95Seconds != 941760 {
		t.Fatalf("scale = %+v", flow.Scale)
	}
}

// The repo shipper is not an endpoint agent and carries no identity, but it
// does carry the same kind of credential. An unauthenticated push must be
// refused exactly as /v1/ingest refuses one.
func TestRepoIngest_RequiresAnEnrollmentToken(t *testing.T) {
	h := newHarness(t)
	snap := model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(1, 1, model.RepoStateOpen)},
	}
	for name, tok := range map[string]string{"none": "", "garbage": "ccq_not-a-token"} {
		resp := h.pushRepo(t, tok, snap)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s token: %d, want 401", name, resp.StatusCode)
		}
	}
	// The viewer token opens the dashboard; it must not open a write path.
	resp := h.pushRepo(t, viewerToken, snap)
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("viewer token was accepted for ingest: %d", resp.StatusCode)
	}
}

// A shipper bug is a 400 the shipper can act on, not a 500 that sends whoever
// wrote it reading hub logs.
func TestRepoIngest_RejectsWhatItCannotStoreHonestly(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shipper")
	bad := map[string]model.RepoSnapshot{
		"no repo": {ObservedAt: time.Now().UTC(),
			Issues: []model.RepoIssue{repoIssue(1, 1, model.RepoStateOpen)}},
		"repo is not owner/name": {Repo: "tokenledger", ObservedAt: time.Now().UTC(),
			Issues: []model.RepoIssue{repoIssue(1, 1, model.RepoStateOpen)}},
		"no observed_at": {Repo: "o/r",
			Issues: []model.RepoIssue{repoIssue(1, 1, model.RepoStateOpen)}},
		"empty": {Repo: "o/r", ObservedAt: time.Now().UTC()},
	}
	for name, snap := range bad {
		resp := h.pushRepo(t, tok, snap)
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, resp.StatusCode)
		}
	}
}

// Staleness is only ever measured against the repo's own p95. There is no way
// to pass a day count, because a query parameter would reintroduce the
// hardcoded threshold this feature exists to remove, one URL at a time.
func TestRepoIssues_StaleScalesToTheRepoAndRefusesWithoutOne(t *testing.T) {
	h := newHarness(t)
	today := time.Now().UTC().Format(model.RepoDayLayout)
	// Percentiles absent: the hub must refuse rather than pick a threshold.
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/fast", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(1, 40, model.RepoStateOpen)},
		Days:   []model.RepoDay{{Day: today, Opened: 1, Closed: 0, OpenAtEnd: 1}},
	})
	if code := h.getCode(t, "/v1/repo/issues?repo=o/fast&stale=1"); code != http.StatusConflict {
		t.Errorf("stale with no percentiles: %d, want 409", code)
	}

	// p95 = 3 days. A 40-day-old issue is stale here and a 1-day-old one is
	// not — on a repo whose p95 were 90 days, neither would be.
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/fast", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(2, 1, model.RepoStateOpen)},
		Days: []model.RepoDay{{Day: today, Opened: 2, Closed: 0, OpenAtEnd: 2,
			CloseP95Seconds: fptr(3 * 24 * 3600)}},
	})
	var out struct {
		Stale  bool                 `json:"stale"`
		Issues []store.RepoIssueRow `json:"issues"`
		Scale  *store.RepoScale     `json:"scale"`
	}
	h.getJSON(t, "/v1/repo/issues?repo=o/fast&stale=1&state=open", &out)
	if !out.Stale || len(out.Issues) != 1 || out.Issues[0].Number != 1 {
		t.Fatalf("stale list = %+v", out.Issues)
	}
	if out.Scale == nil || out.Scale.P95Seconds == nil {
		t.Fatalf("stale list must carry the scale it used: %+v", out.Scale)
	}
}

// A typo in the range must not be answered with a confidently wrong window,
// and an unnamed repo must not be answered with a blend of all of them.
func TestRepoEndpoints_RefuseAnAmbiguousScope(t *testing.T) {
	h := newHarness(t)
	for _, path := range []string{
		"/v1/repo/flow",
		"/v1/repo/flow?repo=tokenledger",
		"/v1/repo/flow?repo=o/r&since=last-tuesday",
		"/v1/repo/flow?repo=o/r&since=1d&until=7d",
		"/v1/repo/issues?repo=o/r&state=merged",
		"/v1/repo/issues?repo=o/r&limit=0",
		"/v1/repo/issues?repo=o/r&limit=99999",
	} {
		if code := h.getCode(t, path); code != http.StatusBadRequest {
			t.Errorf("GET %s: %d, want 400", path, code)
		}
	}
}

// Repo progress is read through the same viewer gate as everything else.
func TestRepoEndpoints_AreViewerOnly(t *testing.T) {
	h := newHarness(t)
	for _, path := range []string{"/v1/repos", "/v1/repo/flow?repo=o/r", "/v1/repo/issues?repo=o/r"} {
		req, _ := http.NewRequest("GET", h.http.URL+path, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("GET %s unauthenticated: %d, want 401", path, resp.StatusCode)
		}
	}
}

// Repo rows are hub-wide and deliberately carry no account_uuid: a repository
// is not owned by a subscription. Guard the shape so nobody later "fixes" it
// by stamping whichever account happened to be nearby.
func TestRepoRows_CarryNoAccountAttribution(t *testing.T) {
	h := newHarness(t)
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(1, 2, model.RepoStateOpen)},
	})
	_, body := h.get(t, "/v1/repo/issues?repo=o/r")
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	issues := raw["issues"].([]any)
	row := issues[0].(map[string]any)
	for _, k := range []string{"account_uuid", "account", "endpoint_id"} {
		if _, ok := row[k]; ok {
			t.Errorf("repo issue row carries %q; a repo is not owned by a subscription", k)
		}
	}
}

// Enrolling a repo shipper must not buy a permanent false alarm. Every fleet
// surface reads "enrolled but silent" as a collection failure, and a shipper
// is silent BY DESIGN — it never reports usage. Its health shows up where it
// means something: the repositories list's observed_at.
func TestRepoIngest_ShipperLeavesTheFleetRosterAlone(t *testing.T) {
	h := newHarness(t)
	agent := h.enroll(t, "laptop")
	h.push(t, agent, batchFor("acct-a", "laptop", []string{"u1"}, "/p")).Body.Close()

	var before []store.Endpoint
	h.getJSON(t, "/v1/endpoints", &before)

	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(1, 2, model.RepoStateOpen)},
	})

	var after []store.Endpoint
	h.getJSON(t, "/v1/endpoints", &after)
	if len(after) != len(before) {
		t.Fatalf("the shipper joined the fleet roster: %d endpoints before, %d after", len(before), len(after))
	}
	for _, e := range after {
		if e.Label == "shipper" {
			t.Errorf("repo shipper %q is listed as a collecting endpoint", e.Label)
		}
	}
	// It must still be able to push: excluding it from the roster must not
	// touch the token lookup that authenticates it.
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{repoIssue(2, 1, model.RepoStateOpen)},
	})
}
