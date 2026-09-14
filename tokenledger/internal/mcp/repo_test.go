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
	_, _, err := st.UpsertRepoSnapshot(model.RepoSnapshot{
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
	if seen != 3 {
		t.Errorf("found %d repo tools, want 3", seen)
	}
}

// The threshold is the repo's own p95 and there is no argument for a day
// count. With no percentiles shipped the tool must refuse rather than pick
// one: an agent cannot tell a fabricated threshold from a measured one, and
// will report it as fact either way.
func TestCall_ListRepoIssues_StaleNeedsAMeasuredScale(t *testing.T) {
	ts, st := newMCP(t)
	now := time.Now().UTC()
	if _, _, err := st.UpsertRepoSnapshot(model.RepoSnapshot{
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
	for _, name := range []string{"repo_progress", "list_repo_issues"} {
		for _, repo := range []string{"", "r", "https://github.com/o/r"} {
			out := call(t, ts, name, map[string]any{"repo": repo})
			if out["result"].(map[string]any)["isError"] != true {
				t.Errorf("%s accepted repo %q", name, repo)
			}
		}
	}
}
