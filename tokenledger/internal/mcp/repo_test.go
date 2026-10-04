package mcp

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func secs(f float64) *float64 { return &f }

// seedRepo ships one repository: two issues, one of them far older than the
// repo's own p95, and a day row carrying that p95.
func seedRepo(t *testing.T, st *store.Store) {
	t.Helper()
	now := time.Now().UTC()
	_, err := st.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		Issues: []model.RepoIssue{
			{Number: 1, Title: "old", State: model.RepoStateOpen, CreatedAt: now.AddDate(0, 0, -40)},
			{Number: 2, Title: "fresh", State: model.RepoStateOpen, CreatedAt: now.Add(-time.Hour)},
		},
		Days: []model.RepoDay{{
			Day: now.Format(model.RepoDayLayout), Opened: 2, Closed: 0, OpenAtEnd: 2,
			CloseP50Seconds: secs(11232), CloseP95Seconds: secs(3 * 24 * 3600),
			ClosedSample: func() *int { n := 2257; return &n }(),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestCall_RepoProgress(t *testing.T) {
	ts, st := newMCP(t)
	seedRepo(t, st)

	sc := structured(t, call(t, ts, "repo_progress", map[string]any{"repo": "o/r"}))
	days := sc["days"].([]any)
	if len(days) != 1 || days[0].(map[string]any)["open_at_end"].(float64) != 2 {
		t.Fatalf("days = %v", days)
	}
	scale, ok := sc["scale"].(map[string]any)
	if !ok || scale["p95_seconds"].(float64) != 3*24*3600 {
		t.Fatalf("scale = %v", sc["scale"])
	}
}

// An agent reading these rows can get exactly two things wrong: that the hub
// collected them, and that an age means anything without the repo's own
// distribution. Both have to be in the text it sees.
func TestToolsList_RepoToolsSayWhereTheRowsCameFromAndHowToScaleThem(t *testing.T) {
	ts, _ := newMCP(t)
	out := rpc(t, ts, "tools/list", nil)
	tools := out["result"].(map[string]any)["tools"].([]any)

	seen := 0
	for _, raw := range tools {
		tool := raw.(map[string]any)
		name := tool["name"].(string)
		if !strings.HasPrefix(name, "repo_") && !strings.HasPrefix(name, "list_repo") {
			continue
		}
		seen++
		desc := tool["description"].(string)
		if !strings.Contains(desc, "SHIPPED") {
			t.Errorf("%s does not say the rows were shipped, not collected", name)
		}
		if !strings.Contains(desc, "percentile") {
			t.Errorf("%s does not tell the reader to scale ages to the repo's percentiles", name)
		}
	}
	if seen != 4 {
		t.Errorf("found %d repo tools, want 4", seen)
	}
}

// The threshold is the repo's own p95 and there is no argument for a day
// count. With no percentiles shipped the tool must refuse rather than pick
// one: an agent cannot tell a fabricated threshold from a measured one, and
// will report it as fact either way.
func TestCall_ListRepoIssues_StaleNeedsAMeasuredScale(t *testing.T) {
	ts, st := newMCP(t)
	now := time.Now().UTC()
	if _, err := st.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/noscale", ObservedAt: now,
		Issues: []model.RepoIssue{{Number: 1, State: model.RepoStateOpen, CreatedAt: now.AddDate(0, 0, -400)}},
	}); err != nil {
		t.Fatal(err)
	}
	out := call(t, ts, "list_repo_issues", map[string]any{"repo": "o/noscale", "stale": true})
	res := out["result"].(map[string]any)
	if res["isError"] != true {
		t.Fatalf("stale with no percentiles was answered rather than refused: %v", res)
	}

	seedRepo(t, st)
	sc := structured(t, call(t, ts, "list_repo_issues", map[string]any{"repo": "o/r", "stale": true}))
	issues := sc["issues"].([]any)
	if len(issues) != 1 || issues[0].(map[string]any)["number"].(float64) != 1 {
		t.Fatalf("stale list = %v; want only the 40-day issue on a repo whose p95 is 3 days", issues)
	}
	if sc["scale"] == nil {
		t.Error("the stale list does not carry the scale it was computed from")
	}
}

// A repo name that is not owner/name would become a second tenant nothing ever
// reconciles, so the tools refuse it rather than normalise it.
func TestCall_RepoTools_RejectAnAmbiguousRepoName(t *testing.T) {
	ts, st := newMCP(t)
	seedRepo(t, st)
	for _, name := range []string{"repo_progress", "list_repo_issues", "repo_issue_cost"} {
		for _, repo := range []string{"", "r", "https://github.com/o/r"} {
			out := call(t, ts, name, map[string]any{"repo": repo})
			if out["result"].(map[string]any)["isError"] != true {
				t.Errorf("%s accepted repo %q", name, repo)
			}
		}
	}
}

// The issue axis over MCP. What an agent must not be able to do is report the
// attributed share as the whole bill, so the unattributed bucket and the
// totals that let it be checked have to arrive in the same payload.
func TestCall_RepoIssueCost_CarriesTheUnattributedBucket(t *testing.T) {
	ts, st := newMCP(t)
	seedRepo(t, st)
	seed(t, st, "acct-a", "ep-1", "/a", "warm")

	now := time.Now().UTC().Add(-time.Minute)
	cost := 1.0
	ev := func(uuid, branch string, out int64) model.UsageEvent {
		return model.UsageEvent{
			AccountUUID: "acct-a", EndpointID: "ep-1", MessageUUID: uuid,
			SessionID: uuid, TS: now, Model: "claude-sonnet-5", CWD: "/a",
			GitBranch: branch, OutputTokens: out, CostUSD: &cost,
		}
	}
	if _, _, err := st.InsertEvents([]model.UsageEvent{
		ev("c-1", "issue-1", 900),
		ev("c-2", "scratch-94", 100),
	}); err != nil {
		t.Fatal(err)
	}

	sc := structured(t, call(t, ts, "repo_issue_cost", map[string]any{"repo": "o/r"}))

	issues := sc["issues"].([]any)
	if len(issues) != 1 || issues[0].(map[string]any)["number"].(float64) != 1 {
		t.Fatalf("issues = %v; want issue #1 alone", issues)
	}
	if title := issues[0].(map[string]any)["title"]; title != "old" {
		t.Errorf("issue #1 title = %v; the progress row did not travel with the money", title)
	}
	// #1 has been open 40 days against a 3-day p95.
	if stale := issues[0].(map[string]any)["stale"]; stale != true {
		t.Errorf("stale = %v, want true against this repo's own p95", stale)
	}

	// Two events the rule declines: scratch-94, and the warm-up event whose
	// branch was never recorded at all. Both belong in the bucket.
	un := sc["unattributed"].(map[string]any)
	if un["events"].(float64) != 2 {
		t.Fatalf("unattributed = %v; scratch-94 and the branchless event must both have a place", un)
	}
	branches := map[string]bool{}
	for _, raw := range un["branches"].([]any) {
		branches[raw.(map[string]any)["branch"].(string)] = true
	}
	if !branches["scratch-94"] || !branches[""] {
		t.Errorf("branches = %v; the bucket has to be explicable, not just disclosed", branches)
	}
	att := sc["attributed"].(map[string]any)
	total := sc["total"].(map[string]any)
	if att["events"].(float64)+un["events"].(float64) != total["events"].(float64) {
		t.Errorf("attributed %v + unattributed %v != total %v",
			att["events"], un["events"], total["events"])
	}
}

// The §5 refusal reaches an agent too. A tool that answered where the browser
// gets a 409 would hand back a blend across repositories as a measurement.
func TestCall_RepoIssueCost_RefusesWhenTheNumberCannotBeBound(t *testing.T) {
	ts, st := newMCP(t)
	seedRepo(t, st)
	if _, err := st.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/second", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{{Number: 1, State: model.RepoStateOpen, CreatedAt: time.Now().UTC()}},
	}); err != nil {
		t.Fatal(err)
	}

	res := call(t, ts, "repo_issue_cost", map[string]any{"repo": "o/r"})["result"].(map[string]any)
	if res["isError"] != true {
		t.Fatalf("two repositories were answered rather than refused: %v", res)
	}
}

// §6: the refusal above lifts for an agent the moment the endpoints declare a
// repository, and what lifts it also has to be legible to the agent — `binding`
// says which reading it got, and `declaration` says what the scope left out.
func TestCall_RepoIssueCost_BindsByTheDeclaredRepo(t *testing.T) {
	ts, st := newMCP(t)
	seedRepo(t, st)
	seed(t, st, "acct-a", "ep-1", "/a", "warm")
	if _, err := st.UpsertRepoSnapshot(model.RepoSnapshot{
		Repo: "o/second", ObservedAt: time.Now().UTC(),
		Issues: []model.RepoIssue{{Number: 1, State: model.RepoStateOpen, CreatedAt: time.Now().UTC()}},
	}); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Add(-time.Minute)
	cost := 1.0
	ev := func(uuid, branch, repo string, out int64) model.UsageEvent {
		return model.UsageEvent{
			AccountUUID: "acct-a", EndpointID: "ep-1", MessageUUID: uuid,
			SessionID: uuid, TS: now, Model: "claude-sonnet-5", CWD: "/a/" + repo,
			GitBranch: branch, GitRepo: repo, OutputTokens: out, CostUSD: &cost,
		}
	}
	if _, _, err := st.InsertEvents([]model.UsageEvent{
		ev("d-1", "issue-1", "o/r", 900),
		ev("d-2", "issue-1", "o/second", 400),
		ev("d-3", "issue-1", "", 100), // an endpoint that has not upgraded
	}); err != nil {
		t.Fatal(err)
	}

	sc := structured(t, call(t, ts, "repo_issue_cost", map[string]any{"repo": "o/r"}))
	if sc["binding"] != "declared" {
		t.Fatalf("binding = %v; two repositories must now be answerable, not refused", sc["binding"])
	}
	issues := sc["issues"].([]any)
	if len(issues) != 1 || issues[0].(map[string]any)["window"].(map[string]any)["events"].(float64) != 1 {
		t.Fatalf("issues = %v; want only o/r's own turn on #1", issues)
	}
	d, ok := sc["declaration"].(map[string]any)
	if !ok {
		t.Fatal("no declaration block: the agent cannot see what the scope dropped")
	}
	if d["other_repos"].(map[string]any)["events"].(float64) != 1 {
		t.Errorf("other_repos = %v; want o/second's turn", d["other_repos"])
	}
	// The warm-up event has no repo either, so undeclared is that plus d-3.
	if d["undeclared"].(map[string]any)["events"].(float64) != 2 {
		t.Errorf("undeclared = %v; want the two turns that named no repository", d["undeclared"])
	}
}
