package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Service usage, by tenant, with a ceiling (claude-fleet#4006, the SPACE EPIC
// C4).
//
// A run's model calls ride a pass minted for its run (svc_runner.go
// svcRunSpec): principal svc:<name>, and — signed into it — svc, tenant, run.
// The cluster credential proxy reports each call with that pass, and the hub
// files the row under the principal AND the tenant (pool_usage.tenant), so one
// tenant's spend never lands on another's, nor on a person's.
//
// Two ceilings, both fleet settings, both in tokens (input + cache writes +
// output, the person budget's count), over a rolling 24 hours and 7 days:
//
//	fleet.svc_budget.<name>        = "day=<tokens>,week=<tokens>"  the whole service
//	fleet.svc_tenant_budget.<name> = "day=<tokens>,week=<tokens>"  each tenant
//
// Over the service's: every new run is refused quota_exceeded; over one
// tenant's: that tenant's runs are refused tenant_limit and nobody else's. A
// refusal comes at submit (429, nothing queued), at dispatch (a queued run
// ends failed with the code, no retry) and mid-run (the proxy's resolve
// answers person_budget_exceeded, the refusal it already never retries; the
// run's failure then ends with the budget's code instead of a retry). People
// are never held to a service's ceiling.
//
// When the pool is tight the service yields (fleet_credproxy.go sessionBind):
// a run's session is never first bound to an account whose latest reading is
// at or past fleet.svc.<name>.yield_pct (default 80) of its five-hour or
// seven-day window — that headroom is left to people.
//
//	GET /v1/svc/usage?tenant=&since=&until=&tz=   runs:read
//
// answers per tenant what its ended runs' callbacks carried (usage: the sum of
// each run's own usage) beside what the proxy metered (metered), and where the
// service and each tenant stand against their ceilings — the reconciliation
// SPACE runs each day (the EPIC's contract 12).

const (
	SvcUsagePath = "/v1/svc/usage"

	// SvcBudgetPrefix + <name> is a service's whole budget.
	SvcBudgetPrefix = "fleet.svc_budget."
	// SvcTenantBudgetPrefix + <name> is each of its tenants' budget.
	SvcTenantBudgetPrefix = "fleet.svc_tenant_budget."

	// The refusals of the EPIC's contract 6.
	SvcErrQuotaExceeded = "quota_exceeded"
	SvcErrTenantLimit   = "tenant_limit"

	svcWindowDay       = 24 * time.Hour
	svcWindowWeek      = 7 * 24 * time.Hour
	svcYieldPctDefault = 80
	svcUsageTZ         = "Asia/Shanghai"
)

// SvcYieldKey is the fleet setting a service's yield threshold lives in.
func SvcYieldKey(principal string) string {
	return "fleet.svc." + strings.TrimPrefix(principal, "svc:") + ".yield_pct"
}

func svcName(principal string) string { return strings.TrimPrefix(principal, "svc:") }

func isSvcPrincipal(principal string) bool {
	return strings.HasPrefix(principal, "svc:") && len(principal) > len("svc:")
}

// SvcBudget is a ceiling in tokens per window; 0 = none on that window.
type SvcBudget struct {
	Day  int64 `json:"day,omitempty"`
	Week int64 `json:"week,omitempty"`
}

// ParseSvcBudget reads "day=2M,week=10M" (either half may be left out; k / m
// suffixes as a person's budget).
func ParseSvcBudget(v string) (SvcBudget, error) {
	var b SvcBudget
	fields := strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == ';' })
	if len(fields) == 0 {
		return b, fmt.Errorf("a service budget is day=<tokens>,week=<tokens> (either half may be left out)")
	}
	for _, f := range fields {
		k, n, ok := strings.Cut(f, "=")
		if !ok {
			return b, fmt.Errorf("%q: want day=<tokens> or week=<tokens>", f)
		}
		t, err := parseTokens(n)
		if err != nil {
			return b, fmt.Errorf("%q: %v", f, err)
		}
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "day", "24h", "1d", "d":
			b.Day = t
		case "week", "7d", "w":
			b.Week = t
		default:
			return b, fmt.Errorf("%q: the windows are day and week", f)
		}
	}
	return b, nil
}

func (b SvcBudget) String() string {
	var p []string
	if b.Day > 0 {
		p = append(p, "day="+strconv.FormatInt(b.Day, 10))
	}
	if b.Week > 0 {
		p = append(p, "week="+strconv.FormatInt(b.Week, 10))
	}
	return strings.Join(p, ",")
}

func (b SvcBudget) set() bool { return b.Day > 0 || b.Week > 0 }

// SvcBudgetState is where the service, or one tenant, stands.
type SvcBudgetState struct {
	Budget    string     `json:"budget,omitempty"`
	LimitDay  int64      `json:"limit_day"`
	LimitWeek int64      `json:"limit_week"`
	UsedDay   int64      `json:"used_day"`
	UsedWeek  int64      `json:"used_week"`
	Over      bool       `json:"over"`
	Window    string     `json:"window,omitempty"` // day | week, when over
	ResetAt   *time.Time `json:"reset_at,omitempty"`
	ErrorCode string     `json:"error_code,omitempty"` // quota_exceeded | tenant_limit, when over
	Message   string     `json:"-"`                    // the hub's own line, never SPACE's
}

// svcBudgetState sums rows (oldest first; any tenants) into both windows.
func svcBudgetState(who string, b SvcBudget, rows []store.SvcUsageRow, code string, now time.Time) SvcBudgetState {
	st := SvcBudgetState{Budget: b.String(), LimitDay: b.Day, LimitWeek: b.Week}
	cutDay, cutWeek := now.Add(-svcWindowDay), now.Add(-svcWindowWeek)
	var inDay, inWeek []store.SvcUsageRow
	for _, r := range rows {
		end := store.PersonBucketStart(r.Bucket).Add(store.PersonUsageBucket)
		if end.Before(cutWeek) {
			continue
		}
		st.UsedWeek += r.Tokens()
		inWeek = append(inWeek, r)
		if !end.Before(cutDay) {
			st.UsedDay += r.Tokens()
			inDay = append(inDay, r)
		}
	}
	over := func(window string, used, limit int64, win time.Duration, rs []store.SvcUsageRow) bool {
		if limit <= 0 || used < limit {
			return false
		}
		left := used
		var at time.Time
		for _, r := range rs {
			left -= r.Tokens()
			if left < limit {
				at = store.PersonBucketStart(r.Bucket).Add(store.PersonUsageBucket + win)
				break
			}
		}
		st.Over, st.Window, st.ErrorCode = true, window, code
		if !at.IsZero() {
			st.ResetAt = &at
		}
		st.Message = fmt.Sprintf("%s over its %s budget: %s / %s tokens (%s)", who,
			map[string]string{"day": "24-hour", "week": "7-day"}[window], humanTokens(used), humanTokens(limit), code)
		if !at.IsZero() {
			st.Message += ", frees up at " + at.UTC().Format(time.RFC3339)
		}
		return true
	}
	if !over("day", st.UsedDay, b.Day, svcWindowDay, inDay) {
		over("week", st.UsedWeek, b.Week, svcWindowWeek, inWeek)
	}
	return st
}

// svcBudgets is principal's two ceilings, as set (a value that does not parse
// is no ceiling — the settings write refuses one).
func svcBudgets(settings map[string]string, principal string) (whole, tenant SvcBudget) {
	whole, _ = ParseSvcBudget(settings[SvcBudgetPrefix+svcName(principal)])
	tenant, _ = ParseSvcBudget(settings[SvcTenantBudgetPrefix+svcName(principal)])
	return whole, tenant
}

// svcUsageRows is principal's metered buckets of the last week, every tenant.
func (s *Server) svcUsageRows(principal string, now time.Time) ([]store.SvcUsageRow, error) {
	since := store.PersonBucketStart(now.Add(-svcWindowWeek).Unix() / int64(store.PersonUsageBucket/time.Second))
	return s.Store.SvcUsageSince(principal, "", since, time.Time{})
}

func svcRowsOf(rows []store.SvcUsageRow, tenant string) []store.SvcUsageRow {
	var out []store.SvcUsageRow
	for _, r := range rows {
		if r.Tenant == tenant {
			out = append(out, r)
		}
	}
	return out
}

// svcBudgetCheck is whether a run of principal for tenant may use the pool
// now: the zero state when it may, else the refusal — the whole service's
// first (quota_exceeded), then the tenant's (tenant_limit). No ceiling set ⇒
// nothing is read and nothing refused.
func (s *Server) svcBudgetCheck(principal, tenant string, now time.Time) (SvcBudgetState, error) {
	if !isSvcPrincipal(principal) {
		return SvcBudgetState{}, nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return SvcBudgetState{}, err
	}
	whole, per := svcBudgets(settings, principal)
	if !whole.set() && !per.set() {
		return SvcBudgetState{}, nil
	}
	rows, err := s.svcUsageRows(principal, now)
	if err != nil {
		return SvcBudgetState{}, err
	}
	if st := svcBudgetState(principal, whole, rows, SvcErrQuotaExceeded, now); st.Over {
		return st, nil
	}
	if per.set() {
		if st := svcBudgetState(principal+" tenant "+tenant, per, svcRowsOf(rows, tenant), SvcErrTenantLimit, now); st.Over {
			return st, nil
		}
	}
	return SvcBudgetState{}, nil
}

// svcBudgetRefusal is svcBudgetCheck's code, or "" — a read that fails
// refuses nothing (it is logged): a ceiling is a guard, not a dependency.
func (s *Server) svcBudgetRefusal(principal, tenant string, now time.Time) (SvcBudgetState, bool) {
	st, err := s.svcBudgetCheck(principal, tenant, now)
	if err != nil {
		log.Printf("svc budget %s: %v", principal, err)
		return st, false
	}
	return st, st.Over
}

// svcPassTenant is the tenant a service pass's usage is filed under: the one
// signed into it, else (a pass minted before claude-fleet#4006) the run its
// worker id names; "" for a person's pass.
func (s *Server) svcPassTenant(c *sessionCredClaims) string {
	if c == nil || !isSvcPrincipal(c.Principal) {
		return ""
	}
	if c.Tenant != "" {
		return c.Tenant
	}
	ref, _, _ := strings.Cut(strings.TrimPrefix(c.WorkerID, "svc/"), "/")
	if id := store.ParseSvcRunRef(ref); id > 0 && s.Store != nil {
		if run, err := s.Store.SvcRun(id); err == nil && run.Principal == c.Principal {
			return run.Tenant
		}
	}
	return ""
}

// svcYieldPct is principal's yield threshold, in percent of a window.
func svcYieldPct(settings map[string]string, principal string) float64 {
	if n, err := strconv.Atoi(strings.TrimSpace(settings[SvcYieldKey(principal)])); err == nil && n > 0 && n <= 100 {
		return float64(n)
	}
	return svcYieldPctDefault
}

// svcYield is choices less every account a service should leave to people:
// at its limit, or with a latest reading at or past the yield threshold.
func (s *Server) svcYield(principal string, choices []store.Credential, now time.Time) []store.Credential {
	settings, _ := s.Store.FleetSettings()
	pct := svcYieldPct(settings, principal)
	var out []store.Credential
	for _, c := range choices {
		if s.credAtLimit(c, now) != "" || s.credPeak(c, now) >= pct {
			continue
		}
		out = append(out, c)
	}
	return out
}

// SvcUsageSums is usage as a callback carries it (the runner's own count).
type SvcUsageSums struct {
	InputTokens  int64   `json:"input_tokens"`
	OutputTokens int64   `json:"output_tokens"`
	WallS        float64 `json:"wall_s"`
}

// SvcMetered is what the credential proxy metered.
type SvcMetered struct {
	InputTokens      int64 `json:"input_tokens"`
	CacheWriteTokens int64 `json:"cache_write_tokens"`
	CacheReadTokens  int64 `json:"cache_read_tokens"`
	OutputTokens     int64 `json:"output_tokens"`
	Tokens           int64 `json:"tokens"` // what a budget counts
	Requests         int64 `json:"requests"`
}

// SvcTenantUsage is one tenant's line.
type SvcTenantUsage struct {
	Tenant    string          `json:"tenant"`
	Runs      int             `json:"runs"`
	Succeeded int             `json:"succeeded"`
	Usage     SvcUsageSums    `json:"usage"`
	Metered   SvcMetered      `json:"metered"`
	Budget    *SvcBudgetState `json:"budget,omitempty"`
}

// svcRunUsage reads one run's usage JSON (a callback's): unknown or missing
// keys count 0.
func svcRunUsage(v string) SvcUsageSums {
	var u struct {
		InputTokens  json.Number `json:"input_tokens"`
		OutputTokens json.Number `json:"output_tokens"`
		WallS        json.Number `json:"wall_s"`
	}
	d := json.NewDecoder(strings.NewReader(v))
	d.UseNumber()
	if v == "" || d.Decode(&u) != nil {
		return SvcUsageSums{}
	}
	in, _ := u.InputTokens.Int64()
	out, _ := u.OutputTokens.Int64()
	wall, _ := u.WallS.Float64()
	return SvcUsageSums{InputTokens: in, OutputTokens: out, WallS: wall}
}

// svcUsageLoc is the zone a day is cut in (SPACE's: Beijing).
func svcUsageLoc(name string) (*time.Location, error) {
	if name == "" {
		name = svcUsageTZ
	}
	if loc, err := time.LoadLocation(name); err == nil {
		return loc, nil
	}
	if name == svcUsageTZ { // an image without tzdata
		return time.FixedZone("CST", 8*3600), nil
	}
	return nil, fmt.Errorf("tz %q is not a time zone", name)
}

// svcUsageTime reads since / until: today, a YYYY-MM-DD (that day's start in
// loc), or an RFC 3339 time.
func svcUsageTime(v string, loc *time.Location, now time.Time) (time.Time, error) {
	switch {
	case v == "today":
		y, m, d := now.In(loc).Date()
		return time.Date(y, m, d, 0, 0, 0, 0, loc), nil
	case len(v) == len("2006-01-02"):
		return time.ParseInLocation("2006-01-02", v, loc)
	}
	return time.Parse(time.RFC3339, v)
}

// handleSvcUsage is GET /v1/svc/usage: the caller's own usage, by tenant.
func (s *Server) handleSvcUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	p, _, _ := SvcCallerOf(r.Context())
	q := r.URL.Query()
	now := s.budgetClock()
	loc, err := svcUsageLoc(q.Get("tz"))
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	sinceV := q.Get("since")
	if sinceV == "" {
		sinceV = "today"
	}
	since, err := svcUsageTime(sinceV, loc, now)
	if err != nil {
		httpError(w, http.StatusBadRequest, "since is today, a YYYY-MM-DD or an RFC 3339 time")
		return
	}
	var until time.Time
	if v := q.Get("until"); v != "" {
		if until, err = svcUsageTime(v, loc, now); err != nil || !until.After(since) {
			httpError(w, http.StatusBadRequest, "until is a YYYY-MM-DD or an RFC 3339 time after since")
			return
		}
	}
	tenant := q.Get("tenant")
	if tenant != "" && !svcWord(tenant, 200) {
		httpError(w, http.StatusBadRequest, "tenant is one word of at most 200 bytes")
		return
	}
	runs, err := s.Store.SvcRunsEnded(p.ID, tenant, since, until)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	metered, err := s.Store.SvcUsageSince(p.ID, tenant, since, until)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	window, err := s.svcUsageRows(p.ID, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	whole, per := svcBudgets(settings, p.ID)

	by := map[string]*SvcTenantUsage{}
	line := func(t string) *SvcTenantUsage {
		if by[t] == nil {
			by[t] = &SvcTenantUsage{Tenant: t}
		}
		return by[t]
	}
	var total SvcTenantUsage
	for _, run := range runs {
		u := svcRunUsage(run.UsageJSON)
		for _, l := range []*SvcTenantUsage{line(run.Tenant), &total} {
			l.Runs++
			if run.State == store.SvcRunSucceeded {
				l.Succeeded++
			}
			l.Usage.InputTokens += u.InputTokens
			l.Usage.OutputTokens += u.OutputTokens
			l.Usage.WallS += u.WallS
		}
	}
	for _, m := range metered {
		for _, l := range []*SvcTenantUsage{line(m.Tenant), &total} {
			l.Metered.InputTokens += m.In
			l.Metered.CacheWriteTokens += m.CacheWrite
			l.Metered.CacheReadTokens += m.CacheRead
			l.Metered.OutputTokens += m.Out
			l.Metered.Tokens += m.Tokens()
			l.Metered.Requests += m.Requests
		}
	}
	if tenant != "" {
		line(tenant)
	}
	out := make([]SvcTenantUsage, 0, len(by))
	for _, l := range by {
		if per.set() {
			st := svcBudgetState(p.ID+" tenant "+l.Tenant, per, svcRowsOf(window, l.Tenant), SvcErrTenantLimit, now)
			l.Budget = &st
		}
		out = append(out, *l)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Tenant < out[j].Tenant })
	body := map[string]any{"principal": p.ID, "since": since.Format(time.RFC3339), "tz": loc.String(),
		"tenants": out, "total": map[string]any{"runs": total.Runs, "succeeded": total.Succeeded,
			"usage": total.Usage, "metered": total.Metered}}
	if !until.IsZero() {
		body["until"] = until.Format(time.RFC3339)
	}
	st := svcBudgetState(p.ID, whole, window, SvcErrQuotaExceeded, now)
	body["budget"] = st
	if per.set() {
		body["tenant_budget"] = per.String()
	}
	writeJSON(w, http.StatusOK, body)
}

// svcBudgetEnd ends a run the budget now refuses, with the budget's code: a
// queued run at dispatch, a failed one instead of its retry. ok false = the
// budget does not refuse it.
func (s *Server) svcBudgetEnd(run store.SvcRun, now time.Time) (store.SvcRun, bool) {
	st, over := s.svcBudgetRefusal(run.Principal, run.Tenant, now)
	if !over {
		return run, false
	}
	ended, changed, err := s.Store.FinishSvcRun(run.ID, store.SvcRunEnd{State: store.SvcRunFailed, ErrorCode: st.ErrorCode}, now)
	if err != nil {
		log.Printf("svc run %s: %v", run.Ref(), err)
		return run, true
	}
	if changed {
		s.svcAudit(run.Principal, "svc.run.end", run.Ref(), ended.State, st.ErrorCode+": "+st.Message, now)
	}
	return ended, true
}

// errSvcNoRun is svcSubmitRefusal's "no such key": the budget is asked.
var errSvcNoRun = sql.ErrNoRows

// svcSubmitRefusal is the budget's word on a new run: a key already used is
// its run's replay and never refused here.
func (s *Server) svcSubmitRefusal(principal, tenant, key string, now time.Time) (SvcBudgetState, bool) {
	if _, err := s.Store.SvcRunByKey(principal, key); !errors.Is(err, errSvcNoRun) {
		return SvcBudgetState{}, false
	}
	return s.svcBudgetRefusal(principal, tenant, now)
}
