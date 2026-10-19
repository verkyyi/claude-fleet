package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

var runT0 = time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

func runAt(s int) time.Time { return runT0.Add(time.Duration(s) * time.Second) }

func stageOf(name string, from, to int, result string) runStage {
	return runStage{Name: name, StartedAt: runAt(from), EndedAt: runAt(to), Result: result}
}

// The rule the board, `fleet release stats` and the run's summary all print
// (claude-fleet#3870 完成判据): a 360 s train whose Linux half took 240 s
// stuck in Linux; a red one says its first red test; a quick one says nothing;
// the watcher and the node image beside the release are never it.
func TestTrainBottleneck(t *testing.T) {
	slow := &trainRun{Conclusion: "success", StartedAt: runAt(0), EndedAt: runAt(360), Stages: []runStage{
		stageOf("board", 0, 10, "success"),
		stageOf("Linux", 20, 260, "success"),
		stageOf("红灯即停", 20, 300, "success"),
		stageOf("node image", 300, 900, "success"),
		stageOf("release", 280, 350, "success"),
	}}
	slow.Stages[1].QueueSecs = 35
	bn := trainBottleneck(slow)
	if bn == nil || bn.Stage != "Linux" || bn.Secs != 240 || !strings.Contains(bn.Why, "超预算 90 秒") || !strings.Contains(bn.Why, "等测试机 35 秒") {
		t.Fatalf("slow: %+v", bn)
	}
	// past 5 minutes, nothing over its budget: the longest stage, said so
	even := &trainRun{Conclusion: "superseded", StartedAt: runAt(0), EndedAt: runAt(330), Stages: []runStage{
		stageOf("Linux", 0, 140, "success"), stageOf("hub", 150, 320, "success")}}
	if bn := trainBottleneck(even); bn == nil || bn.Stage != "hub" || !strings.Contains(bn.Why, "没有一段超预算") {
		t.Fatalf("even: %+v", bn)
	}
	if bn := trainBottleneck(&trainRun{Conclusion: "success", StartedAt: runAt(0), EndedAt: runAt(200),
		Stages: []runStage{stageOf("Linux", 0, 190, "success")}}); bn != nil {
		t.Fatalf("a quick train got a line: %+v", bn)
	}
	red := &trainRun{Conclusion: "failure", StartedAt: runAt(0), EndedAt: runAt(120), FirstFail: "fleet-migrate-selftest.sh", Stages: []runStage{
		stageOf("board", 0, 10, "success"),
		stageOf("红灯即停", 10, 100, "failure"),
		stageOf("precheck", 10, 40, "cancelled"),
		stageOf("Linux", 12, 95, "failure"),
	}}
	if bn := trainBottleneck(red); bn == nil || bn.Stage != "Linux" || bn.Secs != 83 || bn.Why != "fleet-migrate-selftest.sh" {
		t.Fatalf("red: %+v", bn)
	}
	red.FirstFail = ""
	if bn := trainBottleneck(red); bn == nil || bn.Why != "Linux 红" {
		t.Fatalf("red, no test named: %+v", bn)
	}
	// a red precheck started first, but the named test is the Linux half's;
	// the verdict job is never blamed while a stage it sums is red
	red.FirstFail = "fleet-migrate-selftest.sh"
	red.Stages = append(red.Stages, stageOf("precheck", 5, 30, "failure"), stageOf("train", 1, 2, "failure"))
	if bn := trainBottleneck(red); bn == nil || bn.Stage != "Linux" {
		t.Fatalf("named test: %+v", bn)
	}
	red.FirstFail = ""
	if bn := trainBottleneck(red); bn == nil || bn.Stage != "precheck" {
		t.Fatalf("first red, not the verdict: %+v", bn)
	}
	onlyVerdict := &trainRun{Conclusion: "failure", StartedAt: runAt(0), EndedAt: runAt(60), Stages: []runStage{
		stageOf("board", 0, 10, "success"), stageOf("train", 50, 52, "failure")}}
	if bn := trainBottleneck(onlyVerdict); bn == nil || bn.Stage != "train" {
		t.Fatalf("only the verdict red: %+v", bn)
	}
	cancelled := &trainRun{Conclusion: "cancelled", StartedAt: runAt(0), EndedAt: runAt(60), Stages: []runStage{
		stageOf("board", 0, 10, "success"), stageOf("Linux", 10, 60, "cancelled")}}
	if bn := trainBottleneck(cancelled); bn == nil || bn.Stage != "Linux" || bn.Why != "Linux 被取消" {
		t.Fatalf("cancelled: %+v", bn)
	}
}

func (p *publishRig) postRun(tok string, body any) (int, string) {
	p.t().Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, p.h.http.URL+release.Path+"train", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		p.t().Fatal(err)
	}
	defer resp.Body.Close()
	var out bytes.Buffer
	_, _ = out.ReadFrom(resp.Body)
	return resp.StatusCode, out.String()
}

// The route: the train's own token writes a red run and a green one, the
// answer says the bottleneck, mac-follow hangs its stage on the train run, any
// other workflow is refused — and the stats read them all.
func TestReleaseTrainRunRoute(t *testing.T) {
	p := newPublishRig(t)
	train := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/release-train.yml@refs/heads/master"})
	mac := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/mac-follow.yml@refs/heads/master"})
	other := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/selftests.yml@refs/heads/master"})
	now := time.Now().UTC().Truncate(time.Second)
	at := func(s int) string { return now.Add(time.Duration(s) * time.Second).Format(time.RFC3339) }
	sha := strings.Repeat("ab", 20)
	merge := strings.Repeat("cd", 20)
	red := map[string]any{"run_id": "901", "sha": sha, "conclusion": "failure", "started_at": at(-900), "ended_at": at(-800),
		"first_fail": "dash-marker-selftest.sh",
		"merges":     []map[string]any{{"sha": merge, "merged_at": at(-960), "subject": "a change"}},
		"stages":     []map[string]any{{"name": "Linux", "started_at": at(-890), "ended_at": at(-810), "result": "failure"}}}
	if code, body := p.postRun(other, red); code != 401 {
		t.Fatalf("selftests.yml: %d %s", code, body)
	}
	if code, body := p.postRun("", red); code != 401 {
		t.Fatalf("no token: %d %s", code, body)
	}
	code, body := p.postRun(train, red)
	if code != 200 || !strings.Contains(body, `"recorded"`) || !strings.Contains(body, `"why":"dash-marker-selftest.sh"`) {
		t.Fatalf("red run: %d %s", code, body)
	}
	green := map[string]any{"run_id": "902", "sha": sha, "conclusion": "success", "started_at": at(-700), "ended_at": at(-340),
		"merges": []map[string]any{{"sha": merge, "merged_at": at(-960)}},
		"stages": []map[string]any{
			{"name": "board", "started_at": at(-700), "ended_at": at(-690), "result": "success"},
			{"name": "Linux", "started_at": at(-680), "ended_at": at(-440), "result": "success"},
			{"name": "release", "started_at": at(-420), "ended_at": at(-340), "result": "success"}}}
	if code, body := p.postRun(train, green); code != 200 || !strings.Contains(body, `"stage":"Linux"`) || !strings.Contains(body, `"total_secs":360`) {
		t.Fatalf("green run: %d %s", code, body)
	}
	follow := map[string]any{"run_id": "950", "train_run_id": "902", "conclusion": "success", "started_at": at(-330), "ended_at": at(-30),
		"stages": []map[string]any{{"name": stageMacFollow, "started_at": at(-330), "ended_at": at(-30), "result": "success"}}}
	if code, body := p.postRun(mac, follow); code != 200 || !strings.Contains(body, `"status":"mac"`) {
		t.Fatalf("mac follow: %d %s", code, body)
	}
	follow["train_run_id"] = "999"
	if code, body := p.postRun(mac, follow); code != 200 || !strings.Contains(body, `"no-train"`) {
		t.Fatalf("mac follow, unknown train: %d %s", code, body)
	}
	if code, body := p.postRun(train, map[string]any{"run_id": "903", "sha": sha, "conclusion": "maybe"}); code != 400 {
		t.Fatalf("bad conclusion: %d %s", code, body)
	}
	// the ledger job re-run on the same run rewrites it, keeping the Mac stage
	if code, _ := p.postRun(train, green); code != 200 {
		t.Fatal("re-post")
	}
	var st trainStats
	p.h.getJSON(t, ReleaseStatsPath+"?days=7", &st)
	if st.RunsStarted != 2 || st.RunsShipped != 1 || st.RunsSlow != 2 || st.RunsSlowSaid != 2 || len(st.Runs) != 2 {
		t.Fatalf("runs: %+v", st.runStats)
	}
	if st.MergeToStableN != 1 || secs(st.MergeToStableP50) != 620 || secs(st.MergeToStableP95) != 620 {
		t.Fatalf("merge → stable: %+v", st.runStats)
	}
	g, r := st.Runs[0], st.Runs[1]
	if g.RunID != "902" || g.Bottleneck == nil || g.Bottleneck.Stage != "Linux" || g.Mac == nil || g.Mac.AfterSecs != 310 ||
		g.RunURL != "https://github.com/o/r/actions/runs/902" || len(g.Stages) != 3 || g.Stages[1].OffsetSecs != 20 {
		t.Fatalf("green row: %+v", g)
	}
	if r.Conclusion != "failure" || r.Bottleneck == nil || r.Bottleneck.Why != "dash-marker-selftest.sh" || r.Merges[0].Subject != "a change" {
		t.Fatalf("red row: %+v", r)
	}
}

// No run posted: the stats say nothing about runs, never a 0 that means none.
func TestReleaseRunsEmpty(t *testing.T) {
	st := computeRunStats(nil, "o/r")
	if st.RunsStarted != 0 || st.MergeToStableP50 != nil || st.RunP50 != nil || st.Runs == nil || len(st.Runs) != 0 {
		t.Fatalf("empty: %+v", st)
	}
	b, _ := json.Marshal(st)
	if !strings.Contains(string(b), `"merge_to_stable_p50":null`) || !strings.Contains(string(b), `"runs":[]`) {
		t.Fatalf("json: %s", b)
	}
	// a row the hub cannot read is skipped, never a crash
	st = computeRunStats([]store.ReleaseRun{{RunID: "1", Run: "nope", StartedAt: runT0, EndedAt: runT0}}, "")
	if st.RunsStarted != 0 {
		t.Fatalf("unreadable row: %+v", st)
	}
}
