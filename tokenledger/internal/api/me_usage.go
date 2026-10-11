package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 我的用量 in one answer (claude-fleet#3227, EPIC #3225 C2): GET /v1/me/usage
// gives the viewer what their page draws — their own limit (never the pool's
// windows: those are an admin's, /v1/me/quota), today and this week against
// the period before, each day split Claude / Codex, the models by name, and
// where it went: by task, by repo, by batch. Every number is the viewer's
// pool_usage rows (C1) and nothing else, so a limit and the page that shows
// it cannot disagree.
//
// Where it went:
//   - a task is the (repo, issue) the row was frozen under when it was written;
//   - a row on no task whose session holds the orchestrator or the steward
//     (the worker's @fleet_role) is one row, kind "orch";
//   - every other row is the one kind "none" row, which is always there —
//     so each breakdown sums to the range's total;
//   - a batch is the task's parent issue (IssueMeta); unknown = not in one.

// meUsageRanges are the ranges ?range= takes, and how many UTC days each
// spans (today = since this UTC midnight).
var meUsageRanges = map[string]int{"today": 1, "7d": 7, "30d": 30}

// Kinds of a where-it-went row.
const (
	workIssue = "issue"
	workRepo  = "repo"
	workEpic  = "epic"
	workOrch  = "orch"
	workNone  = "none"
)

// MeUsage is GET /v1/me/usage's answer.
type MeUsage struct {
	Range     string         `json:"range"`
	Since     time.Time      `json:"since"`
	Limit     MeUsageLimit   `json:"limit"`
	Today     int64          `json:"today"`
	TodayPrev int64          `json:"today_prev"`
	Week      int64          `json:"week"`
	WeekPrev  int64          `json:"week_prev"`
	Total     int64          `json:"total"` // the range's; what each breakdown sums to
	Days      []MeUsageDay   `json:"days"`
	Models    []MeUsageModel `json:"models"`
	Work      MeUsageWork    `json:"work"`

	// BySession is what each of the viewer's sessions used today and this
	// week (claude-fleet#3377): the same rows as Today and Week, by worker_id,
	// plus the one kind "none" item for rows on no session — so each column
	// sums to Today / Week. Largest week first, "none" last.
	BySession []MeUsageSession `json:"by_session"`

	// SinceFirst is when the hub recorded its first pool row (anyone's): a
	// previous window starting before it was not fully recorded, so the page
	// says so instead of a percent off a near-empty base (claude-fleet#3230).
	// Absent = nothing recorded yet.
	SinceFirst *time.Time `json:"since_first,omitempty"`
}

// MeUsageLimit is the viewer's own limit (fleet.person_budget). Set false =
// 不限额: no limit, no remaining. A window's remaining is its limit − used,
// never below 0; the 5-hour window appears only when one is set.
type MeUsageLimit struct {
	Set           bool       `json:"set"`
	LimitWeek     *int64     `json:"limit_week,omitempty"`
	UsedWeek      int64      `json:"used_week"`
	RemainingWeek *int64     `json:"remaining_week,omitempty"`
	ResetWeek     *time.Time `json:"reset_week,omitempty"`
	Limit5h       *int64     `json:"limit_5h,omitempty"`
	Used5h        int64      `json:"used_5h"`
	Remaining5h   *int64     `json:"remaining_5h,omitempty"`
	Reset5h       *time.Time `json:"reset_5h,omitempty"`
	Over          bool       `json:"over,omitempty"`
	Window        string     `json:"window,omitempty"` // 5h | week, when over
}

// MeUsageSession is one session's pool tokens (claude-fleet#3377). Key is its
// name as the fleet says it (issue-12, scratch-7) — off its fleet's last
// heartbeat, else its row's task, else the worker_id's own key; Kind "none"
// is the rows on no session.
type MeUsageSession struct {
	Kind     string `json:"kind,omitempty"` // none, for the rows on no session
	WorkerID string `json:"worker_id,omitempty"`
	Key      string `json:"key,omitempty"`
	Repo     string `json:"repo,omitempty"`
	Issue    int    `json:"issue,omitempty"`
	Today    int64  `json:"today"`
	Week     int64  `json:"week"`
}

// MeUsageDay is one UTC day, split by provider.
type MeUsageDay struct {
	Day    string `json:"day"`
	Claude int64  `json:"claude"`
	Codex  int64  `json:"codex"`
}

// MeUsageModel is one model by its human name.
type MeUsageModel struct {
	Name     string `json:"name"`
	Provider string `json:"provider"`
	Tokens   int64  `json:"tokens"`
}

// MeUsageWork is where the range's tokens went, three ways.
type MeUsageWork struct {
	Issue []MeUsageItem `json:"issue"`
	Repo  []MeUsageItem `json:"repo"`
	Epic  []MeUsageItem `json:"epic"`
}

// MeUsageItem is one row of a breakdown. Models are [name, tokens] pairs,
// largest first, as the page's prototype holds them.
type MeUsageItem struct {
	Kind      string   `json:"kind"`
	Title     string   `json:"title"`
	Repo      string   `json:"repo,omitempty"`
	Issue     int      `json:"issue,omitempty"`
	Epic      string   `json:"epic,omitempty"` // owner/name#N of the batch
	EpicTitle string   `json:"epic_title,omitempty"`
	Tokens    int64    `json:"tokens"`
	Models    [][]any  `json:"models,omitempty"`
	Sessions  []string `json:"sessions,omitempty"`
	Node      string   `json:"node,omitempty"`  // where it ran: the service node…
	Login     string   `json:"login,omitempty"` // …and the login, for the detail only
}

func (s *Server) handleMeUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	rng := r.URL.Query().Get("range")
	if rng == "" {
		rng = "7d"
	}
	if _, ok := meUsageRanges[rng]; !ok {
		httpError(w, http.StatusBadRequest, "range is today, 7d or 30d")
		return
	}
	// Always the viewer's own: no ?principal=, whoever asks. The operator's
	// door is nobody, so it reads an empty page.
	out, err := s.meUsage(r.Context(), principalOf(r.Context()), rng, s.budgetClock())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// meUsage is principal's answer for rng at now.
func (s *Server) meUsage(ctx context.Context, principal, rng string, now time.Time) (MeUsage, error) {
	today := now.UTC().Truncate(24 * time.Hour)
	ndays := meUsageRanges[rng]
	since := today.AddDate(0, 0, 1-ndays)
	chart := since
	if ndays < 7 {
		chart = today.AddDate(0, 0, -6) // a day's bar alone says nothing: a week of them
	}
	out := MeUsage{Range: rng, Since: since, Days: []MeUsageDay{}, Models: []MeUsageModel{}, BySession: []MeUsageSession{},
		Work: MeUsageWork{Issue: []MeUsageItem{}, Repo: []MeUsageItem{}, Epic: []MeUsageItem{}}}
	var rows []store.PoolUsage
	if principal != "" {
		// Everything any number below reads: two weeks back, or the range.
		from := now.Add(-2 * budgetWindowWeek)
		for _, t := range []time.Time{since, chart, today.AddDate(0, 0, -1)} {
			if t.Before(from) {
				from = t
			}
		}
		var err error
		if rows, err = s.Store.PoolUsageFor(principal, from, time.Time{}); err != nil {
			return out, err
		}
		if out.Limit, err = s.meUsageLimit(principal, now); err != nil {
			return out, err
		}
	} else {
		out.Limit = MeUsageLimit{}
	}

	if first, ok, err := s.Store.PoolUsageFirst(); err != nil {
		return out, err
	} else if ok {
		out.SinceFirst = &first
	}

	weekCut, prevCut := now.Add(-budgetWindowWeek), now.Add(-2*budgetWindowWeek)
	for i := 0; i < int(today.Sub(chart)/(24*time.Hour))+1; i++ {
		out.Days = append(out.Days, MeUsageDay{Day: chart.AddDate(0, 0, i).Format("2006-01-02")})
	}
	var inRange []store.PoolUsage
	for _, u := range rows {
		n := u.Tokens()
		switch {
		case !u.At.Before(today):
			out.Today += n
		case !u.At.Before(today.AddDate(0, 0, -1)):
			out.TodayPrev += n
		}
		switch {
		case !u.At.Before(weekCut):
			out.Week += n
		case !u.At.Before(prevCut):
			out.WeekPrev += n
		}
		if i := int(u.At.Sub(chart) / (24 * time.Hour)); !u.At.Before(chart) && i < len(out.Days) {
			if u.Provider == "codex" {
				out.Days[i].Codex += n
			} else {
				out.Days[i].Claude += n
			}
		}
		if !u.At.Before(since) {
			inRange = append(inRange, u)
			out.Total += n
		}
	}
	out.Models = meUsageModels(inRange)
	out.Work = s.meUsageWork(ctx, inRange)
	out.BySession = s.meUsageSessions(rows, today, weekCut)
	return out, nil
}

// meUsageSessions sums rows by session: today (since this UTC midnight) and
// this week (since weekCut), as MeUsage.Today and .Week count them. A session
// with nothing in the week is left out; the "none" item is always there.
func (s *Server) meUsageSessions(rows []store.PoolUsage, today, weekCut time.Time) []MeUsageSession {
	sess := s.meSessions(rows)
	by := map[string]*MeUsageSession{}
	none := &MeUsageSession{Kind: workNone}
	for _, u := range rows {
		inToday, inWeek := !u.At.Before(today), !u.At.Before(weekCut)
		if !inToday && !inWeek {
			continue
		}
		it := none
		if u.WorkerID != "" {
			if it = by[u.WorkerID]; it == nil {
				it = &MeUsageSession{WorkerID: u.WorkerID, Key: sess[u.WorkerID].key}
				by[u.WorkerID] = it
			}
			if it.Repo == "" && u.Repo != "" && u.Issue > 0 {
				it.Repo, it.Issue = u.Repo, u.Issue
			}
		}
		n := u.Tokens()
		if inToday {
			it.Today += n
		}
		if inWeek {
			it.Week += n
		}
	}
	out := make([]MeUsageSession, 0, len(by)+1)
	for _, it := range by {
		if it.Key == "" && it.Issue > 0 {
			it.Key = fmt.Sprintf("issue-%d", it.Issue)
		}
		if it.Key == "" {
			if _, k, err := fleetid.ParseWorkerID(it.WorkerID); err == nil {
				it.Key = k
			}
		}
		out = append(out, *it)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Week != out[j].Week {
			return out[i].Week > out[j].Week
		}
		return out[i].WorkerID < out[j].WorkerID
	})
	return append(out, *none)
}

// meUsageLimit is principal's limit, from the same state the proxies are
// held to (personBudgetState), so 「剩」 is what they may still use.
func (s *Server) meUsageLimit(principal string, now time.Time) (MeUsageLimit, error) {
	st, err := s.personBudgetState(principal, now)
	if err != nil {
		return MeUsageLimit{}, err
	}
	l := MeUsageLimit{Set: st.LimitWeek > 0 || st.Limit5h > 0, UsedWeek: st.UsedWeek, Used5h: st.Used5h,
		Over: st.Over, Window: st.Window}
	if !l.Set {
		return l, nil
	}
	buckets, err := s.Store.PersonUsageSince(principal, now.Add(-budgetWindowWeek))
	if err != nil {
		return l, err
	}
	// A rolling window frees up as its oldest bucket leaves it; over, the
	// budget's own answer says when enough has.
	reset := func(win time.Duration, window string) *time.Time {
		if st.Over && st.Window == window && st.ResetAt != nil {
			t := *st.ResetAt
			return &t
		}
		cut := now.Add(-win)
		for _, b := range buckets {
			if end := store.PersonBucketStart(b.Bucket).Add(store.PersonUsageBucket); end.After(cut) && b.Tokens > 0 {
				t := end.Add(win)
				return &t
			}
		}
		return nil
	}
	left := func(limit, used int64) *int64 {
		v := limit - used
		if v < 0 {
			v = 0
		}
		return &v
	}
	if st.LimitWeek > 0 {
		v := st.LimitWeek
		l.LimitWeek, l.RemainingWeek, l.ResetWeek = &v, left(v, st.UsedWeek), reset(budgetWindowWeek, "week")
	}
	if st.Limit5h > 0 {
		v := st.Limit5h
		l.Limit5h, l.Remaining5h, l.Reset5h = &v, left(v, st.Used5h), reset(budgetWindow5h, "5h")
	}
	return l, nil
}

// meUsageModels sums rows by the model's human name, largest first.
func meUsageModels(rows []store.PoolUsage) []MeUsageModel {
	by := map[string]*MeUsageModel{}
	for _, u := range rows {
		name := modelHumanName(u.Model)
		k := u.Provider + "\x00" + name
		if by[k] == nil {
			by[k] = &MeUsageModel{Name: name, Provider: u.Provider}
		}
		by[k].Tokens += u.Tokens()
	}
	out := make([]MeUsageModel, 0, len(by))
	for _, m := range by {
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Tokens != out[j].Tokens {
			return out[i].Tokens > out[j].Tokens
		}
		return out[i].Name < out[j].Name
	})
	return out
}

var (
	claudeModelRE = regexp.MustCompile(`^claude-(?:(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?|(\d+)(?:-(\d{1,2}))?-(opus|sonnet|haiku))(?:-\d{8})?(?:\[1m\])?$`)
	gptModelRE    = regexp.MustCompile(`^gpt-(\d+(?:\.\d+)?)((?:-[a-z0-9]+)*)$`)
)

// modelHumanName is a model id as a person says it: claude-opus-5-5 → Opus
// 5.5, claude-3-5-sonnet-20241022 → Sonnet 3.5, gpt-5.4-codex → GPT-5.4
// Codex. An id it does not know stays as it is; none is "".
func modelHumanName(id string) string {
	id = strings.TrimSpace(id)
	if m := claudeModelRE.FindStringSubmatch(strings.ToLower(id)); m != nil {
		family, major, minor := m[1], m[2], m[3]
		if family == "" {
			family, major, minor = m[6], m[4], m[5]
		}
		v := major
		if minor != "" {
			v += "." + minor
		}
		return strings.ToUpper(family[:1]) + family[1:] + " " + v
	}
	if m := gptModelRE.FindStringSubmatch(strings.ToLower(id)); m != nil {
		name := "GPT-" + m[1]
		for _, w := range strings.Split(strings.TrimPrefix(m[2], "-"), "-") {
			if w != "" {
				name += " " + strings.ToUpper(w[:1]) + w[1:]
			}
		}
		return name
	}
	return id
}

// meSession is what the hub knows of a pool row's session: its key, whether
// it holds the orchestrator or the steward, and where it ran.
type meSession struct {
	key   string
	coord bool
	node  string
	login string
}

// meSessions reads each worker's session off its fleet's last heartbeat. A
// session that has closed since is unknown: its row keeps its task, and on no
// task it is the "none" row.
func (s *Server) meSessions(rows []store.PoolUsage) map[string]meSession {
	out := map[string]meSession{}
	fleets := map[string]bool{}
	for _, u := range rows {
		if u.WorkerID == "" {
			continue
		}
		fid, _, err := fleetid.ParseWorkerID(u.WorkerID)
		if err != nil || fleets[fid] {
			continue
		}
		fleets[fid] = true
		fl, err := s.Store.Fleet(fid)
		if err != nil {
			continue
		}
		var workers []map[string]any
		if json.Unmarshal([]byte(fl.WorkersJSON), &workers) != nil {
			continue
		}
		for _, wk := range workers {
			wid, _ := wk["worker_id"].(string)
			if wid == "" {
				continue
			}
			key, _ := wk["key"].(string)
			out[wid] = meSession{key: key, coord: isCoordinator(wk), node: fl.Hostname, login: fl.OSUser}
		}
	}
	return out
}

// isCoordinator is whether an inventory row is the window holding the
// orchestrator or the steward: an older node's role=orchestrator|steward, a
// newer one's coordinator flag (fleet_hub_common.py, claude-fleet#3227), or
// the orchestrator's own columns (orch_*), which only that window carries.
func isCoordinator(wk map[string]any) bool {
	if r, _ := wk["role"].(string); r == "orchestrator" || r == "steward" {
		return true
	}
	if c, _ := wk["coordinator"].(bool); c {
		return true
	}
	for k, v := range wk {
		if strings.HasPrefix(k, "orch_") && v != nil {
			return true
		}
	}
	return false
}

// meUsageWork splits rows three ways. Each breakdown's tokens sum to the
// rows' total; the "none" row is in each, even at 0.
func (s *Server) meUsageWork(ctx context.Context, rows []store.PoolUsage) MeUsageWork {
	sess := s.meSessions(rows)
	type acc struct {
		item     MeUsageItem
		models   map[string]int64
		sessions map[string]int64
		where    map[[2]string]int64
	}
	issues := map[string]*acc{}
	get := func(k string, it MeUsageItem) *acc {
		if issues[k] == nil {
			issues[k] = &acc{item: it, models: map[string]int64{}, sessions: map[string]int64{}, where: map[[2]string]int64{}}
		}
		return issues[k]
	}
	get(workNone, MeUsageItem{Kind: workNone})
	for _, u := range rows {
		n, se := u.Tokens(), sess[u.WorkerID]
		var a *acc
		switch {
		case u.Repo != "" && u.Issue > 0:
			a = get(fmt.Sprintf("%s#%d", u.Repo, u.Issue), MeUsageItem{Kind: workIssue, Repo: u.Repo, Issue: u.Issue})
			if se.key == "" {
				se.key = fmt.Sprintf("issue-%d", u.Issue)
			}
		case se.coord:
			a = get(workOrch, MeUsageItem{Kind: workOrch})
		default:
			a = get(workNone, MeUsageItem{Kind: workNone})
		}
		a.item.Tokens += n
		a.models[modelHumanName(u.Model)] += n
		if se.key != "" {
			a.sessions[se.key] += n
		}
		if se.node != "" {
			a.where[[2]string{se.node, se.login}] += n
		}
	}

	// Titles and batches: one lookup per task, bounded, never failing the page.
	tasks := map[string][2]any{}
	for k, a := range issues {
		if a.item.Kind == workIssue {
			tasks[k] = [2]any{a.item.Repo, a.item.Issue}
		}
	}
	meta := s.issueMetas(ctx, tasks)

	var out MeUsageWork
	repos, epics := map[string]*MeUsageItem{}, map[string]*MeUsageItem{}
	repoNone := &MeUsageItem{Kind: workNone}
	epicNone := &MeUsageItem{Kind: workNone}
	for k, a := range issues {
		it := a.item
		it.Models = topPairs(a.models, 0)
		for _, p := range topPairs(a.sessions, 5) {
			it.Sessions = append(it.Sessions, p[0].(string))
		}
		if w := topWhere(a.where); w[0] != "" {
			it.Node, it.Login = w[0], w[1]
		}
		if it.Kind == workIssue {
			m := meta[k]
			it.Title, it.Epic, it.EpicTitle = m.Title, m.Epic, m.EpicTitle
		}
		out.Issue = append(out.Issue, it)

		if it.Repo == "" {
			repoNone.Tokens += it.Tokens
		} else {
			if repos[it.Repo] == nil {
				repos[it.Repo] = &MeUsageItem{Kind: workRepo, Title: it.Repo, Repo: it.Repo}
			}
			repos[it.Repo].Tokens += it.Tokens
		}
		if it.Epic == "" {
			epicNone.Tokens += it.Tokens
		} else {
			if epics[it.Epic] == nil {
				epics[it.Epic] = &MeUsageItem{Kind: workEpic, Title: it.EpicTitle, Epic: it.Epic, EpicTitle: it.EpicTitle}
			}
			epics[it.Epic].Tokens += it.Tokens
		}
	}
	sortWork(out.Issue)
	for _, it := range repos {
		out.Repo = append(out.Repo, *it)
	}
	out.Repo = append(out.Repo, *repoNone)
	sortWork(out.Repo)
	for _, it := range epics {
		out.Epic = append(out.Epic, *it)
	}
	out.Epic = append(out.Epic, *epicNone)
	sortWork(out.Epic)
	return out
}

// sortWork: tasks largest first, then the orchestrator's row, then "none".
func sortWork(xs []MeUsageItem) {
	rank := func(k string) int {
		switch k {
		case workOrch:
			return 1
		case workNone:
			return 2
		}
		return 0
	}
	sort.SliceStable(xs, func(i, j int) bool {
		if ri, rj := rank(xs[i].Kind), rank(xs[j].Kind); ri != rj {
			return ri < rj
		}
		if xs[i].Tokens != xs[j].Tokens {
			return xs[i].Tokens > xs[j].Tokens
		}
		if xs[i].Repo != xs[j].Repo {
			return xs[i].Repo < xs[j].Repo
		}
		if xs[i].Issue != xs[j].Issue {
			return xs[i].Issue < xs[j].Issue
		}
		return xs[i].Epic+xs[i].Title < xs[j].Epic+xs[j].Title
	})
}

// topPairs is m as [name, tokens] pairs, largest first; max 0 = all. An empty
// name is left out.
func topPairs(m map[string]int64, max int) [][]any {
	keys := make([]string, 0, len(m))
	for k := range m {
		if k != "" {
			keys = append(keys, k)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if m[keys[i]] != m[keys[j]] {
			return m[keys[i]] > m[keys[j]]
		}
		return keys[i] < keys[j]
	})
	if max > 0 && len(keys) > max {
		keys = keys[:max]
	}
	out := make([][]any, 0, len(keys))
	for _, k := range keys {
		out = append(out, []any{k, m[k]})
	}
	return out
}

func topWhere(m map[[2]string]int64) [2]string {
	var best [2]string
	var n int64 = -1
	for k, v := range m {
		if v > n || v == n && k[0]+k[1] < best[0]+best[1] {
			best, n = k, v
		}
	}
	return best
}

// IssueMeta is what a task's row says beyond its number: its title and the
// batch it belongs to (its parent issue, owner/name#N + title). Empty fields
// = not known.
type IssueMeta struct {
	Title     string
	Epic      string
	EpicTitle string
}

// IssueMetaSource answers an issue's title and parent. It may be slow or
// fail; the page then shows the number alone and 「不在批次里」.
type IssueMetaSource interface {
	IssueMeta(ctx context.Context, repo string, issue int) (IssueMeta, error)
}

// meUsageMetaBudget bounds how long one page waits on titles; what has not
// arrived by then is left out and arrives for the next read.
const meUsageMetaBudget = 2 * time.Second

// issueMetas looks up each task's title and batch, at most meUsageMetaBudget
// for all of them together; a task not answered in time is left blank.
func (s *Server) issueMetas(ctx context.Context, tasks map[string][2]any) map[string]IssueMeta {
	out := map[string]IssueMeta{}
	if s.IssueMeta == nil || len(tasks) == 0 {
		return out
	}
	ctx, cancel := context.WithTimeout(ctx, meUsageMetaBudget)
	defer cancel()
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for k, t := range tasks {
		wg.Add(1)
		go func(k, repo string, issue int) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-sem }()
			m, err := s.IssueMeta.IssueMeta(ctx, repo, issue)
			if err != nil {
				return
			}
			mu.Lock()
			out[k] = m
			mu.Unlock()
		}(k, t[0].(string), t[1].(int))
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
	}
	mu.Lock()
	defer mu.Unlock()
	cp := make(map[string]IssueMeta, len(out))
	for k, v := range out {
		cp[k] = v
	}
	return cp
}
