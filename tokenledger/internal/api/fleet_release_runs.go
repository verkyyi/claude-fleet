package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Every run of the release train, whatever it came to (claude-fleet#3870,
// EPIC #3863 C7 — 共同约定 7: the ledger is the one source of stage times).
// The ledger part of a publish (fleet_release_train.go) is written only when a
// train ships; a red, cancelled or superseded train left nothing. Now the
// train's last job, `ledger` (if: always()), posts its run:
//
//	POST /v1/fleet/release/train   the release CI's OIDC, as the publish
//	{"run_id": "…", "sha": "<40 hex>", "prev_sha": "…",
//	 "conclusion": "success|failure|cancelled|superseded",
//	 "started_at": "…", "ended_at": "…",
//	 "merges": [{"sha": "…", "merged_at": "…", "subject": "…"}],
//	 "stages": [{"name": "Linux", "started_at": "…", "ended_at": "…",
//	             "result": "success|failure|cancelled", "queue_secs": 12}],
//	 "first_fail": "<the first FAIL / TIMEOUT test>"}
//
// and mac-follow.yml, once its macOS half is done, adds the Mac stage to the
// train run that started it: {"train_run_id": "…", "run_id": "…",
// "conclusion": "…", "stages": [{"name": "mac follow", …}]}.
//
// The answer carries the run's bottleneck — the hub's one rule
// (trainBottleneck) — so the run's summary page says the same 「卡在 X 段」 line
// the /trains page does. Bookkeeping only: nothing gates on it.

const (
	trainRunMaxBytes   = 256 << 10
	trainRunsShown     = 100
	trainSlowSecs      = 300 // 5 minutes: a train past it says where it stuck
	stageMacFollow     = "mac follow"
	trainBudgetDefault = 120
)

// The page (web/dist/admin/trains.js): an admin's, mounted like every admin page.
const (
	trainsPagePath = "/trains"
	trainsPageID   = "trains"
)

// trainWorkflows may post a run: the publishing ones and mac-follow.
var trainWorkflows = []string{"release-train.yml", "mac-follow.yml", "stable-publish.yml"}

// stageBudget is how long each stage of a train may take (seconds) before it
// is what made a slow train slow — the EPIC's own arithmetic (#3863: board 15 s
// · runner wait 20 s · tests 90 s · sign and move 45 s), with room.
var stageBudget = map[string]float64{
	"board": 30, "quarantine": 60, "plan": 60, "Linux": 150, "隔离": 60,
	"precheck": 120, "train": 30, "hub plan": 60, "hub": 180, "release": 90,
	// built beside the tests (#3867): on the path only when the tests end first
	"hub build": 300, "发布包": 120,
}

// stageOffPath never makes a train slow: a watcher spanning the run, the
// ledger itself, the node image built beside the release, and the Mac half
// that follows it.
var stageOffPath = map[string]bool{
	"红灯即停": true, "ledger": true, "node tools": true, "node image": true, stageMacFollow: true,
}

// stageTests run the selftests (a red test is theirs); stageVerdict only sums
// the others up (its red is theirs).
var (
	stageTests   = map[string]bool{"Linux": true, "macOS": true}
	stageVerdict = map[string]bool{"train": true}
)

type trainRun struct {
	RunID      string     `json:"run_id"`
	TrainRunID string     `json:"train_run_id,omitempty"`
	SHA        string     `json:"sha"`
	PrevSHA    string     `json:"prev_sha,omitempty"`
	Conclusion string     `json:"conclusion"`
	StartedAt  time.Time  `json:"started_at"`
	EndedAt    time.Time  `json:"ended_at"`
	Merges     []runMerge `json:"merges"`
	Stages     []runStage `json:"stages"`
	FirstFail  string     `json:"first_fail,omitempty"`
}

type runMerge struct {
	SHA      string    `json:"sha"`
	MergedAt time.Time `json:"merged_at"`
	Subject  string    `json:"subject,omitempty"`
}

type runStage struct {
	Name      string    `json:"name"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at"`
	Result    string    `json:"result,omitempty"`
	QueueSecs float64   `json:"queue_secs,omitempty"`
}

// bottleneck is the one line a slow or red train gets: where it stuck, how
// long that stage took, why.
type bottleneck struct {
	Stage string  `json:"stage"`
	Secs  float64 `json:"secs"`
	Why   string  `json:"why"`
}

var runConclusions = map[string]bool{"success": true, "failure": true, "cancelled": true, "superseded": true}

func runLine(s string, n int) string {
	s = strings.TrimSpace(firstLine(s))
	if len([]rune(s)) > n {
		s = string([]rune(s)[:n])
	}
	return s
}

// parseTrainRun reads and checks a run.
func parseTrainRun(b []byte) (*trainRun, error) {
	if len(b) > trainRunMaxBytes {
		return nil, fmt.Errorf("%d bytes, at most %d", len(b), trainRunMaxBytes)
	}
	var r trainRun
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("not JSON: %v", err)
	}
	r.RunID, r.TrainRunID = runLine(r.RunID, 40), runLine(r.TrainRunID, 40)
	if r.RunID == "" {
		return nil, errors.New("run_id: missing")
	}
	if !runConclusions[r.Conclusion] {
		return nil, fmt.Errorf("conclusion: want success|failure|cancelled|superseded, got %q", runLine(r.Conclusion, 40))
	}
	if r.TrainRunID == "" && !release.ValidSHA(r.SHA) {
		return nil, fmt.Errorf("sha: want 40 hex, got %q", runLine(r.SHA, 50))
	}
	if r.PrevSHA != "" && !release.ValidSHA(r.PrevSHA) {
		return nil, fmt.Errorf("prev_sha: want 40 hex, got %q", runLine(r.PrevSHA, 50))
	}
	switch {
	case len(r.Merges) > trainMaxMerges:
		return nil, fmt.Errorf("%d merges, at most %d", len(r.Merges), trainMaxMerges)
	case len(r.Stages) > trainMaxStages:
		return nil, fmt.Errorf("%d stages, at most %d", len(r.Stages), trainMaxStages)
	}
	for i, m := range r.Merges {
		if !release.ValidSHA(m.SHA) || m.MergedAt.IsZero() {
			return nil, fmt.Errorf("merges[%d]: want a 40-hex sha and merged_at", i)
		}
		r.Merges[i].Subject = runLine(m.Subject, 200)
	}
	for i, st := range r.Stages {
		name := strings.TrimSpace(st.Name)
		if name == "" || len(name) > 64 || strings.ContainsAny(name, "\r\n") {
			return nil, fmt.Errorf("stages[%d].name: want one short line, got %q", i, firstLine(st.Name))
		}
		r.Stages[i].Name = name
		if st.StartedAt.IsZero() || st.EndedAt.IsZero() || st.EndedAt.Before(st.StartedAt) {
			return nil, fmt.Errorf("stages[%d] (%s): want started_at ≤ ended_at", i, name)
		}
		if math.IsNaN(st.QueueSecs) || math.IsInf(st.QueueSecs, 0) || st.QueueSecs < 0 {
			return nil, fmt.Errorf("stages[%d] (%s): queue_secs: want a non-negative number", i, name)
		}
		r.Stages[i].Result = runLine(st.Result, 20)
	}
	if r.StartedAt.IsZero() || r.EndedAt.IsZero() || r.EndedAt.Before(r.StartedAt) {
		// a run is its stages' span when it does not say
		for _, st := range r.Stages {
			if r.StartedAt.IsZero() || st.StartedAt.Before(r.StartedAt) {
				r.StartedAt = st.StartedAt
			}
			if st.EndedAt.After(r.EndedAt) {
				r.EndedAt = st.EndedAt
			}
		}
		if r.StartedAt.IsZero() || r.EndedAt.Before(r.StartedAt) {
			return nil, errors.New("started_at / ended_at: missing, and no stage to read them off")
		}
	}
	r.FirstFail = runLine(r.FirstFail, 120)
	sort.SliceStable(r.Stages, func(i, j int) bool { return r.Stages[i].StartedAt.Before(r.Stages[j].StartedAt) })
	return &r, nil
}

func budgetOf(stage string) float64 {
	if b, ok := stageBudget[stage]; ok {
		return b
	}
	return trainBudgetDefault
}

func runShipped(c string) bool { return c == "success" || c == "superseded" }

// trainBottleneck is the hub's one rule for where a train stuck (nil = it did
// not): a red train ⇒ its first red stage, why = the first red test when the
// shards named one; a train past 5 minutes ⇒ the longest stage over its
// budget (none over ⇒ the longest), why = how far over, and the runner wait in
// it. The Mac half, the node image and the watchers are never it.
func trainBottleneck(r *trainRun) *bottleneck {
	dur := func(st runStage) float64 { return st.EndedAt.Sub(st.StartedAt).Seconds() }
	if !runShipped(r.Conclusion) {
		// the first red stage by start — the stage of the named red test when
		// there is one, the verdict job only when nothing else is red
		var pick *runStage
		find := func(want string, ok func(*runStage) bool) {
			if pick != nil {
				return
			}
			var found *runStage
			defer func() { pick = found }()
			for i := range r.Stages {
				if st := &r.Stages[i]; !stageOffPath[st.Name] && st.Result == want && ok(st) &&
					(found == nil || st.StartedAt.Before(found.StartedAt)) {
					found = st
				}
			}
		}
		if r.FirstFail != "" {
			find("failure", func(st *runStage) bool { return stageTests[st.Name] })
		}
		find("failure", func(st *runStage) bool { return !stageVerdict[st.Name] })
		find("failure", func(*runStage) bool { return true })
		find("cancelled", func(st *runStage) bool { return !stageVerdict[st.Name] })
		b := &bottleneck{Why: "没发出"}
		if pick != nil {
			b.Stage, b.Secs = pick.Name, math.Round(dur(*pick))
			b.Why = pick.Name + " 红"
			if pick.Result == "cancelled" {
				b.Why = pick.Name + " 被取消"
			}
		}
		if r.FirstFail != "" {
			b.Why = r.FirstFail
		}
		return b
	}
	total := r.EndedAt.Sub(r.StartedAt).Seconds()
	if total <= trainSlowSecs {
		return nil
	}
	var over, longest *runStage
	for i := range r.Stages {
		st := &r.Stages[i]
		if stageOffPath[st.Name] {
			continue
		}
		if longest == nil || dur(*st) > dur(*longest) {
			longest = st
		}
		if dur(*st) > budgetOf(st.Name) && (over == nil || dur(*st) > dur(*over)) {
			over = st
		}
	}
	if longest == nil {
		return &bottleneck{Secs: math.Round(total), Why: fmt.Sprintf("共 %d 秒，没有分段可看", int(math.Round(total)))}
	}
	pick, why := longest, fmt.Sprintf("共 %d 秒；没有一段超预算，这段最长", int(math.Round(total)))
	if over != nil {
		pick = over
		why = fmt.Sprintf("超预算 %d 秒（预算 %d 秒）", int(math.Round(dur(*over)-budgetOf(over.Name))), int(budgetOf(over.Name)))
	}
	if pick.QueueSecs >= 1 {
		why += fmt.Sprintf("，其中等测试机 %d 秒", int(math.Round(pick.QueueSecs)))
	}
	return &bottleneck{Stage: pick.Name, Secs: math.Round(dur(*pick)), Why: why}
}

// macFollow is the Mac stage a train run carries once mac-follow reported.
type macFollow struct {
	RunID      string    `json:"run_id"`
	Conclusion string    `json:"conclusion"`
	StartedAt  time.Time `json:"started_at"`
	EndedAt    time.Time `json:"ended_at"`
}

// handleReleaseTrain serves POST /v1/fleet/release/train.
func (s *Server) handleReleaseTrain(w http.ResponseWriter, r *http.Request) {
	rs := s.Releases
	if rs == nil || rs.Publish == nil || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	who, err := rs.Publish.CheckFor(r.Context(), r, rs.Repo, trainWorkflows)
	if err != nil {
		log.Printf("fleet: release train run: %v", err)
		httpError(w, http.StatusUnauthorized, err.Error())
		return
	}
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, trainRunMaxBytes+1))
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	run, err := parseTrainRun(b)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	out := map[string]any{"run_id": run.RunID}
	if run.TrainRunID != "" {
		// mac-follow's word on the train run that started it
		m := macFollow{RunID: run.RunID, Conclusion: run.Conclusion, StartedAt: run.StartedAt, EndedAt: run.EndedAt}
		mb, _ := json.Marshal(m)
		ok, err := s.Store.RecordReleaseRunMac(run.TrainRunID, string(mb))
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out["status"] = "mac"
		if !ok {
			out["status"] = "no-train" // that train never wrote its run
		}
		log.Printf("fleet: release train run %s: mac follow %s (%s) by %s", run.TrainRunID, run.Conclusion, out["status"], who)
		writeJSON(w, http.StatusOK, out)
		return
	}
	rb, _ := json.Marshal(run)
	if err := s.Store.RecordReleaseRun(store.ReleaseRun{RunID: run.RunID, SHA: run.SHA, Conclusion: run.Conclusion,
		StartedAt: run.StartedAt, EndedAt: run.EndedAt, Run: string(rb)}); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out["status"] = "recorded"
	out["conclusion"] = run.Conclusion
	out["total_secs"] = math.Round(run.EndedAt.Sub(run.StartedAt).Seconds())
	if bn := trainBottleneck(run); bn != nil {
		out["bottleneck"] = bn
	}
	log.Printf("fleet: release train run %s %s: %s by %s", run.RunID, short(run.SHA), run.Conclusion, who)
	writeJSON(w, http.StatusOK, out)
}

// runRow is one run on the /trains page and in `fleet release stats`.
type runRow struct {
	RunID      string      `json:"run_id"`
	RunURL     string      `json:"run_url,omitempty"`
	SHA        string      `json:"sha"`
	Conclusion string      `json:"conclusion"`
	StartedAt  time.Time   `json:"started_at"`
	EndedAt    time.Time   `json:"ended_at"`
	TotalSecs  float64     `json:"total_secs"`
	Merges     []runMerge  `json:"merges"`
	Stages     []stageRow  `json:"stages"`
	Bottleneck *bottleneck `json:"bottleneck"`
	Mac        *macRow     `json:"mac,omitempty"`
}

type stageRow struct {
	Name       string  `json:"name"`
	OffsetSecs float64 `json:"offset_secs"`
	Secs       float64 `json:"secs"`
	BudgetSecs float64 `json:"budget_secs"`
	QueueSecs  float64 `json:"queue_secs,omitempty"`
	Result     string  `json:"result,omitempty"`
	OffPath    bool    `json:"off_path,omitempty"`
}

type macRow struct {
	Conclusion string  `json:"conclusion"`
	Secs       float64 `json:"secs"`
	// AfterSecs: the train's end → the Mac half's end (Mac 晚多久).
	AfterSecs float64 `json:"after_secs"`
}

// runStats is what the runs add to GET …/release/stats.
type runStats struct {
	MergeToStableN   int      `json:"merge_to_stable_n"`
	MergeToStableP50 *float64 `json:"merge_to_stable_p50"`
	MergeToStableP95 *float64 `json:"merge_to_stable_p95"`
	RunsStarted      int      `json:"runs_started"`
	RunsShipped      int      `json:"runs_shipped"`
	RunP50           *float64 `json:"run_p50_secs"`
	RunsSlow         int      `json:"runs_slow"`
	RunsSlowSaid     int      `json:"runs_slow_said"`
	Lanes            runLanes `json:"lanes"`
	Runs             []runRow `json:"runs"`
}

type runLanes struct {
	Stable      string `json:"stable,omitempty"`
	StableMacOS string `json:"stable_macos,omitempty"`
}

// computeRunStats folds the runs: merge → stable (each merge's commit time →
// the end of the first shipped run carrying it), how many shipped, and each
// run's row, newest first.
func computeRunStats(runs []store.ReleaseRun, repo string) runStats {
	out := runStats{Runs: []runRow{}}
	sort.SliceStable(runs, func(i, j int) bool { return runs[i].StartedAt.Before(runs[j].StartedAt) })
	toStable := map[string]float64{}
	var totals []float64
	rows := make([]runRow, 0, len(runs))
	for _, sr := range runs {
		var r trainRun
		if json.Unmarshal([]byte(sr.Run), &r) != nil {
			continue
		}
		r.Conclusion, r.StartedAt, r.EndedAt = sr.Conclusion, sr.StartedAt, sr.EndedAt
		total := r.EndedAt.Sub(r.StartedAt).Seconds()
		out.RunsStarted++
		row := runRow{RunID: sr.RunID, SHA: sr.SHA, Conclusion: r.Conclusion, StartedAt: r.StartedAt, EndedAt: r.EndedAt,
			TotalSecs: math.Round(total), Merges: r.Merges, Stages: []stageRow{}, Bottleneck: trainBottleneck(&r)}
		if row.Merges == nil {
			row.Merges = []runMerge{}
		}
		if repo != "" {
			row.RunURL = "https://github.com/" + repo + "/actions/runs/" + sr.RunID
		}
		for _, st := range r.Stages {
			row.Stages = append(row.Stages, stageRow{Name: st.Name, OffsetSecs: math.Round(st.StartedAt.Sub(r.StartedAt).Seconds()),
				Secs: math.Round(st.EndedAt.Sub(st.StartedAt).Seconds()), BudgetSecs: budgetOf(st.Name), QueueSecs: st.QueueSecs,
				Result: st.Result, OffPath: stageOffPath[st.Name]})
		}
		if sr.Mac != "" {
			var m macFollow
			if json.Unmarshal([]byte(sr.Mac), &m) == nil {
				row.Mac = &macRow{Conclusion: m.Conclusion, Secs: math.Round(m.EndedAt.Sub(m.StartedAt).Seconds()),
					AfterSecs: math.Round(m.EndedAt.Sub(r.EndedAt).Seconds())}
			}
		}
		if runShipped(r.Conclusion) {
			out.RunsShipped++
			totals = append(totals, total)
			if r.Conclusion == "success" {
				for _, m := range r.Merges {
					if _, ok := toStable[m.SHA]; !ok {
						toStable[m.SHA] = math.Max(0, r.EndedAt.Sub(m.MergedAt).Seconds())
					}
				}
			}
		}
		if total > trainSlowSecs || !runShipped(r.Conclusion) {
			out.RunsSlow++
			if row.Bottleneck != nil && row.Bottleneck.Stage != "" {
				out.RunsSlowSaid++
			}
		}
		rows = append(rows, row)
	}
	lat := make([]float64, 0, len(toStable))
	for _, v := range toStable {
		lat = append(lat, v)
	}
	out.MergeToStableN = len(lat)
	out.MergeToStableP50 = percentile(lat, 0.5)
	out.MergeToStableP95 = percentile(lat, 0.95)
	out.RunP50 = percentile(totals, 0.5)
	for i := len(rows) - 1; i >= 0 && len(out.Runs) < trainRunsShown; i-- {
		out.Runs = append(out.Runs, rows[i])
	}
	return out
}
