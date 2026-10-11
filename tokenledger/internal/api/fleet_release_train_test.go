package api

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// trainRoster is three managed machines heard, one 维护中, one lost, and a
// laptop with no machine link: a train waits for the three only.
func trainRoster(time.Time) (NodesSnapshot, error) {
	return NodesSnapshot{Nodes: []NodeView{
		{Hostname: "m1", MachineLink: true, Status: "online"},
		{Hostname: "M2.local", MachineLink: true, Status: "online"},
		{Hostname: "m3", MachineLink: true, Status: "online"},
		{Hostname: "m3", OSUser: "alice", Status: "online"},
		{Hostname: "m4", MachineLink: true, Status: "maintenance"},
		{Hostname: "m5", MachineLink: true, Status: "lost"},
		{Hostname: "laptop", OSUser: "bob", Status: "online"},
	}}, nil
}

func trainJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func secs(p *float64) float64 {
	if p == nil {
		return -1
	}
	return *p
}

// A train published, three machines reporting in one after another: the
// stats read the merge → all-machines time off the last of them, a machine
// 维护中 at publish never holds it up, and an old publish (no train) is in
// none of it.
func TestReleaseTrainLedger(t *testing.T) {
	p := newPublishRig(t)
	p.h.srv.releaseRoster = trainRoster
	tok := p.oidc.token(nil)
	a := p.repo.commit("A", nil)
	if code, body := p.publish(tok, a, "", nil, nil); code != 200 || strings.Contains(body, "train") {
		t.Fatalf("old publish: %d %s", code, body)
	}
	b := p.repo.commit("B", nil)
	now := time.Now().UTC().Truncate(time.Second)
	other := strings.Repeat("ab", 20)
	train := trainJSON(t, map[string]any{
		"run_id":   "777",
		"prev_sha": a,
		"merges": []map[string]any{
			{"sha": b, "merged_at": now.Add(-30 * time.Minute)},
			{"sha": other, "merged_at": now.Add(-60 * time.Minute)},
		},
		"stages": []map[string]any{
			{"name": "linux tests", "started_at": now.Add(-25 * time.Minute), "ended_at": now.Add(-20 * time.Minute)},
			{"name": "publish", "started_at": now.Add(-2 * time.Minute), "ended_at": now.Add(-1 * time.Minute)},
		},
		"macos_queue_secs": []float64{600, 60, 120},
	})
	code, body := p.publishParts(tok, b, a, nil, nil, map[string]string{"train": train})
	if code != 200 || !strings.Contains(body, `"train":"recorded"`) || !strings.Contains(body, `"published"`) {
		t.Fatalf("train publish: %d %s", code, body)
	}
	// a re-run keeps the first row
	if code, body := p.publishParts(tok, b, a, nil, nil, map[string]string{"train": train}); code != 200 || !strings.Contains(body, `"train":"kept"`) {
		t.Fatalf("re-run: %d %s", code, body)
	}
	srv := p.h.srv
	var st trainStats
	srv.noteReleaseReach("m1", b, now.Add(5*time.Minute))
	srv.noteReleaseReach("M2.local", b, now.Add(10*time.Minute))
	srv.noteReleaseReach("m1", b, now.Add(40*time.Minute)) // the first beat stands
	srv.noteReleaseReach("m1", a, now)                     // not a train: nothing
	p.h.getJSON(t, ReleaseStatsPath+"?days=7", &st)
	if st.Trains != 1 || st.TrainsReached != 0 || st.MergesPending != 2 || st.MergeToAll.N != 0 || st.MergeToAll.MedianSecs != nil {
		t.Fatalf("two of three on it: %+v", st)
	}
	if len(st.Recent) != 1 || st.Recent[0].Machines != 3 || st.Recent[0].Reached != 2 || strings.Join(st.Recent[0].Missing, ",") != "m3" {
		t.Fatalf("recent: %+v", st.Recent)
	}
	srv.noteReleaseReach("m3", b, now.Add(20*time.Minute))
	p.h.getJSON(t, ReleaseStatsPath, &st)
	// 50 and 80 minutes; m4 (维护中) and m5 (lost) never asked for
	if st.TrainsReached != 1 || st.MergesPending != 0 || st.MergeToAll.N != 2 ||
		secs(st.MergeToAll.MedianSecs) != 3000 || secs(st.MergeToAll.P90Secs) != 4800 {
		t.Fatalf("merge → all: %+v", st)
	}
	if st.MacOSQueue.N != 3 || secs(st.MacOSQueue.MedianSecs) != 120 || secs(st.MacOSQueue.P90Secs) != 600 {
		t.Fatalf("macOS queue: %+v", st.MacOSQueue)
	}
	if len(st.Stages) != 2 || st.Stages[0].Name != "linux tests" || secs(st.Stages[0].MedianSecs) != 300 || secs(st.Stages[1].P90Secs) != 60 {
		t.Fatalf("stages: %+v", st.Stages)
	}
	if st.PerHour.Releases != 1 || st.PerHour.ActiveHours < 1 || st.PerHour.Rate == nil {
		t.Fatalf("per hour: %+v", st.PerHour)
	}
	// the rows themselves
	trains, err := srv.Store.ReleaseTrainsSince(time.Time{})
	if err != nil || len(trains) != 1 || trains[0].SHA != b || trains[0].PrevSHA != a || trains[0].RunID != "777" ||
		trains[0].Machines != `["m1","m2.local","m3"]` {
		t.Fatalf("trains: %+v %v", trains, err)
	}
	reach, err := srv.Store.ReleaseReachFor([]string{a, b})
	if err != nil || len(reach) != 3 {
		t.Fatalf("reach: %+v %v", reach, err)
	}
	for _, r := range reach {
		if r.Machine == "m1" && !r.ReachedAt.Equal(now.Add(5*time.Minute)) {
			t.Fatalf("m1 reached at %v, want its first beat", r.ReachedAt)
		}
	}
	// a malformed train never holds the release back
	c := p.repo.commit("C", nil)
	code, body = p.publishParts(tok, c, b, nil, nil, map[string]string{"train": `{"merges":[{"sha":"nope"}]}`})
	if code != 200 || !strings.Contains(body, `"published"`) || !strings.Contains(body, `"train":"refused: merges[0].sha`) {
		t.Fatalf("bad train: %d %s", code, body)
	}
	if trains, _ := srv.Store.ReleaseTrainsSince(time.Time{}); len(trains) != 1 {
		t.Fatalf("a refused train was written: %+v", trains)
	}
	// the route is the operator's, and days is bounded
	if resp, _ := getBody(t, p.h.http.URL+ReleaseStatsPath); resp.StatusCode != 401 && resp.StatusCode != 403 {
		t.Fatalf("anonymous stats: %d", resp.StatusCode)
	}
}

// No train part: the publish answers exactly as before and the ledger stays empty.
func TestReleaseTrainOffAddsNothing(t *testing.T) {
	p := newPublishRig(t)
	p.h.srv.releaseRoster = trainRoster
	tok := p.oidc.token(nil)
	a := p.repo.commit("A", nil)
	code, body := p.publish(tok, a, "", nil, nil)
	if code != 200 {
		t.Fatalf("publish: %d %s", code, body)
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 4 || out["status"] != "published" || out["sha"] != a {
		t.Fatalf("answer = %v, want status/sha/prev/seq only", out)
	}
	p.h.srv.noteReleaseReach("m1", a, time.Now())
	if trains, err := p.h.srv.Store.ReleaseTrainsSince(time.Time{}); err != nil || len(trains) != 0 {
		t.Fatalf("trains: %+v %v", trains, err)
	}
	if reach, err := p.h.srv.Store.ReleaseReachFor([]string{a}); err != nil || len(reach) != 0 {
		t.Fatalf("reach: %+v %v", reach, err)
	}
	var st trainStats
	p.h.getJSON(t, ReleaseStatsPath, &st)
	if st.Trains != 0 || st.MergeToAll.N != 0 || st.MergeToAll.MedianSecs != nil || st.PerHour.Rate != nil || st.MacOSQueue.P90Secs != nil {
		t.Fatalf("empty ledger: %+v", st)
	}
}

// The fold on fixed clocks: a machine that skipped a train has its merges
// once it is on a later one; a train still missing a machine is pending;
// the hours master moved in are the merges' hours and the next.
func TestComputeTrainStats(t *testing.T) {
	day := time.Date(2026, 10, 11, 0, 0, 0, 0, time.UTC)
	at := func(h, m int) time.Time { return day.Add(time.Duration(h)*time.Hour + time.Duration(m)*time.Minute) }
	sha := func(c string) string { return strings.Repeat(c, 40) }
	mk := func(s string, pub time.Time, machines []string, merges ...time.Time) store.ReleaseTrain {
		var ms []map[string]any
		for i, m := range merges {
			ms = append(ms, map[string]any{"sha": sha(string(rune('a' + i))), "merged_at": m})
		}
		return store.ReleaseTrain{SHA: s, PublishedAt: pub, Train: trainJSON(t, map[string]any{"merges": ms}), Machines: trainJSON(t, machines)}
	}
	t1, t2, t3 := sha("1"), sha("2"), sha("3")
	trains := []store.ReleaseTrain{
		mk(t3, at(12, 0), []string{"a", "c"}, at(11, 50)),
		mk(t1, at(10, 0), []string{"a", "b"}, at(9, 10), at(9, 40)),
		mk(t2, at(11, 0), []string{"a", "b"}, at(10, 30)),
	}
	reach := []store.ReleaseReach{
		{SHA: t1, Machine: "a", ReachedAt: at(10, 5)},
		{SHA: t2, Machine: "a", ReachedAt: at(11, 5)},
		{SHA: t2, Machine: "b", ReachedAt: at(11, 20)}, // b skipped t1
		{SHA: t3, Machine: "a", ReachedAt: at(12, 3)},
	}
	st := computeTrainStats(trains, reach, 1, day, at(12, 30))
	// t1: 11:20 − 09:10, 11:20 − 09:40; t2: 11:20 − 10:30 → 3000 6000 7800
	if st.Trains != 3 || st.TrainsReached != 2 || st.MergesPending != 1 || st.MergeToAll.N != 3 ||
		secs(st.MergeToAll.MedianSecs) != 6000 || secs(st.MergeToAll.P90Secs) != 7800 {
		t.Fatalf("stats: %+v", st)
	}
	// hours 09 10 11 12 (13 is past now)
	if st.PerHour.Releases != 3 || st.PerHour.ActiveHours != 4 || secs(st.PerHour.Rate) != 0.75 {
		t.Fatalf("per hour: %+v", st.PerHour)
	}
	if len(st.Recent) != 3 || st.Recent[0].SHA != t3 || st.Recent[0].AllAt != nil || strings.Join(st.Recent[0].Missing, ",") != "c" ||
		st.Recent[2].SHA != t1 || st.Recent[2].AllAt == nil || !st.Recent[2].AllAt.Equal(at(11, 20)) {
		t.Fatalf("recent: %+v", st.Recent)
	}
	// a machine-less train (no managed machine heard) is neither reached nor pending
	st = computeTrainStats([]store.ReleaseTrain{mk(t1, at(10, 0), []string{}, at(9, 0))}, nil, 1, day, at(12, 0))
	if st.TrainsReached != 0 || st.MergesPending != 0 || st.MergeToAll.N != 0 {
		t.Fatalf("no machines: %+v", st)
	}
}

func TestParseTrainRefuses(t *testing.T) {
	ok := `{"merges":[{"sha":"` + strings.Repeat("a", 40) + `","merged_at":"2026-10-11T05:27:00Z"}]}`
	if _, err := parseTrain([]byte(ok)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		`nope`,
		`{"prev_sha":"x"}`,
		`{"merges":[{"sha":"` + strings.Repeat("a", 40) + `"}]}`,
		`{"stages":[{"name":"x","started_at":"2026-10-11T06:00:00Z","ended_at":"2026-10-11T05:00:00Z"}]}`,
		`{"stages":[{"name":"","started_at":"2026-10-11T05:00:00Z","ended_at":"2026-10-11T06:00:00Z"}]}`,
		`{"macos_queue_secs":[-1]}`,
	} {
		if _, err := parseTrain([]byte(bad)); err == nil {
			t.Errorf("%s: accepted", bad)
		}
	}
}
