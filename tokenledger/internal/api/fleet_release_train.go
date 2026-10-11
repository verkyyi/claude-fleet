package api

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The release ledger (claude-fleet#3140, EPIC #3139 C1): every release train
// writes down what it carried, how long each stage took and when each machine
// ran it — so 「合并后到所有机器都用上」, 「每小时发出的版本」 and 「macOS 测试排队」
// are read off one route instead of pieced together from run logs.
//
// The CI's publish (fleet_publish.go) may carry one more multipart part,
// `train`, a JSON object:
//
//	{"run_id": "…", "prev_sha": "<40 hex>",
//	 "merges": [{"sha": "<40 hex>", "merged_at": "<RFC 3339>"}],
//	 "stages": [{"name": "…", "started_at": "…", "ended_at": "…"}],
//	 "macos_queue_secs": [12.5, …]}
//
// Once the publish succeeds the hub writes it to fleet_release_trains with the
// machines the train must reach: every managed machine (one with a machine
// link) heard and not 维护中 at that moment — a lost or flagged one is not
// waited for. A machine link's beat whose Versions.Runtime first names a
// train's sha writes fleet_release_reach. A train is the bookkeeping, never a
// gate: a malformed one is answered `"train": "refused: …"` and the publish
// stands. No `train` part ⇒ no row, no response field — byte for byte as before.
//
//	GET /v1/fleet/release/stats?days=7   the operator's numbers (fleet release stats)
//
// A machine that skips a train (it went straight to a later one) has its
// merges all the same: a train counts as reached on a machine at the first
// beat on it or on any train published after it.

// ReleaseStatsPath is the ledger's read route.
const ReleaseStatsPath = release.Path + "stats"

const (
	trainMaxBytes     = 256 << 10
	trainMaxMerges    = 2000
	trainMaxStages    = 64
	trainMaxQueue     = 256
	trainStatsMaxDays = 90
	trainRecent       = 10
	// trainBookDays is how far back the reach hook remembers trains: a
	// machine still on an older one reaches nothing worth counting.
	trainBookDays = 30
)

// releaseTrain is the `train` part.
type releaseTrain struct {
	RunID          string       `json:"run_id"`
	PrevSHA        string       `json:"prev_sha"`
	Merges         []trainMerge `json:"merges"`
	Stages         []trainStage `json:"stages"`
	MacOSQueueSecs []float64    `json:"macos_queue_secs"`
}

type trainMerge struct {
	SHA      string    `json:"sha"`
	MergedAt time.Time `json:"merged_at"`
}

type trainStage struct {
	Name      string    `json:"name"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at"`
}

// parseTrain reads and checks a `train` part.
func parseTrain(b []byte) (*releaseTrain, error) {
	if len(b) > trainMaxBytes {
		return nil, fmt.Errorf("%d bytes, at most %d", len(b), trainMaxBytes)
	}
	var t releaseTrain
	if err := json.Unmarshal(b, &t); err != nil {
		return nil, fmt.Errorf("not JSON: %v", err)
	}
	t.RunID = firstLine(strings.TrimSpace(t.RunID))
	if len(t.RunID) > 200 {
		t.RunID = t.RunID[:200]
	}
	if t.PrevSHA != "" && !release.ValidSHA(t.PrevSHA) {
		return nil, fmt.Errorf("prev_sha: want 40 hex, got %q", firstLine(t.PrevSHA))
	}
	switch {
	case len(t.Merges) > trainMaxMerges:
		return nil, fmt.Errorf("%d merges, at most %d", len(t.Merges), trainMaxMerges)
	case len(t.Stages) > trainMaxStages:
		return nil, fmt.Errorf("%d stages, at most %d", len(t.Stages), trainMaxStages)
	case len(t.MacOSQueueSecs) > trainMaxQueue:
		return nil, fmt.Errorf("%d macOS queue readings, at most %d", len(t.MacOSQueueSecs), trainMaxQueue)
	}
	for i, m := range t.Merges {
		if !release.ValidSHA(m.SHA) {
			return nil, fmt.Errorf("merges[%d].sha: want 40 hex, got %q", i, firstLine(m.SHA))
		}
		if m.MergedAt.IsZero() {
			return nil, fmt.Errorf("merges[%d].merged_at: missing", i)
		}
	}
	for i, st := range t.Stages {
		name := strings.TrimSpace(st.Name)
		if name == "" || len(name) > 64 || strings.ContainsAny(name, "\r\n") {
			return nil, fmt.Errorf("stages[%d].name: want one short line, got %q", i, firstLine(st.Name))
		}
		t.Stages[i].Name = name
		if st.StartedAt.IsZero() || st.EndedAt.IsZero() || st.EndedAt.Before(st.StartedAt) {
			return nil, fmt.Errorf("stages[%d] (%s): want started_at ≤ ended_at", i, name)
		}
	}
	for i, q := range t.MacOSQueueSecs {
		if math.IsNaN(q) || math.IsInf(q, 0) || q < 0 {
			return nil, fmt.Errorf("macos_queue_secs[%d]: want a non-negative number", i)
		}
	}
	return &t, nil
}

// recordTrain writes a published sha's train and says how it went, for the
// publish's answer: recorded · kept (a re-run: the first row stands) ·
// refused: <why>. Never fails the publish.
func (s *Server) recordTrain(sha, prev string, raw []byte, now time.Time) string {
	t, err := parseTrain(raw)
	if err == nil && s.Store == nil {
		err = fmt.Errorf("no store")
	}
	if err != nil {
		log.Printf("fleet: release %s: train refused: %v", short(sha), err)
		return "refused: " + err.Error()
	}
	if t.PrevSHA == "" {
		t.PrevSHA = prev
	}
	tb, _ := json.Marshal(t)
	mb, _ := json.Marshal(s.trainMachines(now))
	wrote, err := s.Store.RecordReleaseTrain(store.ReleaseTrain{SHA: sha, PrevSHA: t.PrevSHA, RunID: t.RunID,
		PublishedAt: now, Train: string(tb), Machines: string(mb)})
	if err != nil {
		log.Printf("fleet: release %s: train: %v", short(sha), err)
		return "refused: " + err.Error()
	}
	s.trains.add(sha)
	if !wrote {
		return "kept"
	}
	return "recorded"
}

// trainMachines is the machines a train published now must reach.
func (s *Server) trainMachines(now time.Time) []string {
	roster := s.releaseRoster
	if roster == nil {
		roster = s.Nodes
	}
	snap, err := roster(now)
	if err != nil {
		log.Printf("fleet: release train: roster: %v", err)
		return []string{}
	}
	return trainMachinesOf(snap)
}

// trainMachinesOf: every machine whose machine link is heard and not 维护中
// (a lost link is not waited for, a flagged machine's row reads maintenance).
func trainMachinesOf(snap NodesSnapshot) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, n := range snap.Nodes {
		if !n.MachineLink || n.Status != "online" {
			continue
		}
		if h := trainHost(n.Hostname); h != "" && !seen[h] {
			seen[h] = true
			out = append(out, h)
		}
	}
	sort.Strings(out)
	return out
}

func trainHost(h string) string { return strings.ToLower(strings.TrimSpace(h)) }

// trainBook is what the reach hook remembers, so a beat costs a map lookup:
// the trains' shas and which (sha, machine) already has its row.
type trainBook struct {
	mu      sync.Mutex
	loaded  bool
	shas    map[string]bool
	reached map[string]bool // sha + " " + machine
}

func (b *trainBook) add(sha string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.loaded { // else the load reads it from the table
		b.shas[sha] = true
	}
}

func (b *trainBook) load(st *store.Store, now time.Time) error {
	trains, err := st.ReleaseTrainsSince(now.Add(-trainBookDays * 24 * time.Hour))
	if err != nil {
		return err
	}
	shas := make([]string, 0, len(trains))
	for _, t := range trains {
		shas = append(shas, t.SHA)
	}
	reach, err := st.ReleaseReachFor(shas)
	if err != nil {
		return err
	}
	b.shas, b.reached = map[string]bool{}, map[string]bool{}
	for _, sha := range shas {
		b.shas[sha] = true
	}
	for _, r := range reach {
		b.reached[r.SHA+" "+r.Machine] = true
	}
	b.loaded = true
	return nil
}

// noteReleaseReach is a machine link's beat: its runtime names sha. The first
// beat on a train's sha writes the machine's reach; every other is a lookup.
func (s *Server) noteReleaseReach(host, sha string, at time.Time) {
	host = trainHost(host)
	if s.Store == nil || host == "" || !release.ValidSHA(sha) {
		return
	}
	b := &s.trains
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.loaded {
		if err := b.load(s.Store, at); err != nil {
			log.Printf("fleet: release ledger: load: %v", err)
			return
		}
	}
	key := sha + " " + host
	if !b.shas[sha] || b.reached[key] {
		return
	}
	if err := s.Store.RecordReleaseReach(sha, host, at); err != nil {
		log.Printf("fleet: release %s: reach %s: %v", short(sha), host, err)
		return
	}
	b.reached[key] = true
}

// trainStats is GET …/release/stats's answer. A number with nothing behind it
// is null, never 0.
type trainStats struct {
	Days          int       `json:"days"`
	Since         time.Time `json:"since"`
	Trains        int       `json:"trains"`
	TrainsReached int       `json:"trains_reached"`
	// MergeToAll: each merge a train carried → the last of its machines on it.
	MergeToAll    durStats     `json:"merge_to_all"`
	MergesPending int          `json:"merges_pending"`
	PerHour       perHour      `json:"releases_per_hour"`
	MacOSQueue    durStats     `json:"macos_queue"`
	Stages        []stageStats `json:"stages"`
	Recent        []trainRow   `json:"recent"`
}

type durStats struct {
	N          int      `json:"n"`
	MedianSecs *float64 `json:"median_secs"`
	P90Secs    *float64 `json:"p90_secs"`
}

// perHour: trains published ÷ the hours master moved in (a merge that hour or
// the one before).
type perHour struct {
	Releases    int      `json:"releases"`
	ActiveHours int      `json:"active_hours"`
	Rate        *float64 `json:"rate"`
}

type stageStats struct {
	Name string `json:"name"`
	durStats
}

type trainRow struct {
	SHA         string     `json:"sha"`
	PublishedAt time.Time  `json:"published_at"`
	Merges      int        `json:"merges"`
	Machines    int        `json:"machines"`
	Reached     int        `json:"reached"`
	Missing     []string   `json:"missing,omitempty"`
	AllAt       *time.Time `json:"all_at,omitempty"`
}

// percentile is the nearest-rank p-th of xs (sorted in place); nil for none.
func percentile(xs []float64, p float64) *float64 {
	if len(xs) == 0 {
		return nil
	}
	sort.Float64s(xs)
	i := int(math.Ceil(p*float64(len(xs)))) - 1
	if i < 0 {
		i = 0
	}
	if i >= len(xs) {
		i = len(xs) - 1
	}
	v := xs[i]
	return &v
}

func durOf(xs []float64) durStats {
	return durStats{N: len(xs), MedianSecs: percentile(xs, 0.5), P90Secs: percentile(xs, 0.9)}
}

// computeTrainStats folds the trains published in [since, now] and their reach.
func computeTrainStats(trains []store.ReleaseTrain, reach []store.ReleaseReach, days int, since, now time.Time) trainStats {
	out := trainStats{Days: days, Since: since, Trains: len(trains), Stages: []stageStats{}, Recent: []trainRow{}}
	sort.SliceStable(trains, func(i, j int) bool { return trains[i].PublishedAt.Before(trains[j].PublishedAt) })
	at := map[string]map[string]time.Time{}
	for _, r := range reach {
		if at[r.SHA] == nil {
			at[r.SHA] = map[string]time.Time{}
		}
		at[r.SHA][r.Machine] = r.ReachedAt
	}
	parsed := make([]releaseTrain, len(trains))
	machines := make([][]string, len(trains))
	for i, t := range trains {
		_ = json.Unmarshal([]byte(t.Train), &parsed[i])
		_ = json.Unmarshal([]byte(t.Machines), &machines[i])
	}
	// a train is on a machine once it or any later train is: walk newest
	// first, keeping each machine's earliest reach so far
	eff := make([]map[string]time.Time, len(trains))
	run := map[string]time.Time{}
	for i := len(trains) - 1; i >= 0; i-- {
		for m, t := range at[trains[i].SHA] {
			if old, ok := run[m]; !ok || t.Before(old) {
				run[m] = t
			}
		}
		eff[i] = make(map[string]time.Time, len(run))
		for m, t := range run {
			eff[i][m] = t
		}
	}
	var lat, queue []float64
	stageDur := map[string][]float64{}
	stageOrder := []string{}
	hours := map[int64]bool{}
	firstHour, lastHour := since.Truncate(time.Hour), now.Truncate(time.Hour)
	for i, t := range trains {
		row := trainRow{SHA: t.SHA, PublishedAt: t.PublishedAt, Merges: len(parsed[i].Merges), Machines: len(machines[i])}
		var all time.Time
		for _, m := range machines[i] {
			r, ok := eff[i][m]
			if !ok {
				row.Missing = append(row.Missing, m)
				continue
			}
			row.Reached++
			if r.After(all) {
				all = r
			}
		}
		done := len(machines[i]) > 0 && len(row.Missing) == 0
		if done {
			a := all
			row.AllAt = &a
			out.TrainsReached++
		}
		for _, m := range parsed[i].Merges {
			switch {
			case done:
				lat = append(lat, math.Max(0, all.Sub(m.MergedAt).Seconds()))
			case len(machines[i]) > 0:
				out.MergesPending++
			}
			for _, h := range []time.Time{m.MergedAt.Truncate(time.Hour), m.MergedAt.Truncate(time.Hour).Add(time.Hour)} {
				if !h.Before(firstHour) && !h.After(lastHour) {
					hours[h.Unix()] = true
				}
			}
		}
		for _, st := range parsed[i].Stages {
			if _, ok := stageDur[st.Name]; !ok {
				stageOrder = append(stageOrder, st.Name)
			}
			stageDur[st.Name] = append(stageDur[st.Name], st.EndedAt.Sub(st.StartedAt).Seconds())
		}
		queue = append(queue, parsed[i].MacOSQueueSecs...)
		out.Recent = append(out.Recent, row)
	}
	out.MergeToAll = durOf(lat)
	out.MacOSQueue = durOf(queue)
	for _, n := range stageOrder {
		out.Stages = append(out.Stages, stageStats{Name: n, durStats: durOf(stageDur[n])})
	}
	out.PerHour = perHour{Releases: len(trains), ActiveHours: len(hours)}
	if len(hours) > 0 {
		r := float64(len(trains)) / float64(len(hours))
		out.PerHour.Rate = &r
	}
	// newest first, the last few
	for i, j := 0, len(out.Recent)-1; i < j; i, j = i+1, j-1 {
		out.Recent[i], out.Recent[j] = out.Recent[j], out.Recent[i]
	}
	if len(out.Recent) > trainRecent {
		out.Recent = out.Recent[:trainRecent]
	}
	return out
}

// handleReleaseStats serves GET /v1/fleet/release/stats?days=N.
func (s *Server) handleReleaseStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	days := 7
	if v := r.URL.Query().Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > trainStatsMaxDays {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("days: want 1..%d, got %q", trainStatsMaxDays, firstLine(v)))
			return
		}
		days = n
	}
	if s.Store == nil {
		http.NotFound(w, r)
		return
	}
	now := time.Now().UTC()
	since := now.Add(-time.Duration(days) * 24 * time.Hour)
	trains, err := s.Store.ReleaseTrainsSince(since)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	shas := make([]string, 0, len(trains))
	for _, t := range trains {
		shas = append(shas, t.SHA)
	}
	reach, err := s.Store.ReleaseReachFor(shas)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, computeTrainStats(trains, reach, days, since, now))
}
