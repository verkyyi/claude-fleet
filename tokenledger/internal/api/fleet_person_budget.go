package api

import (
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Per-person budgets (claude-fleet#1977, EPIC #1967 R2).
//
// Both credential proxies — a login's local one (bin/fleet-cred-proxy.py) and
// the cluster's (internal/credproxy) — count the tokens each response's own
// `usage` names and report them here under the person: the local proxy with
// its node token (POST /v1/node/usage — the person is the login's, never the
// node's say-so), the cluster proxy with its own token (POST
// /v1/fleet/credproxy/usage — the person rides the session pass). The
// operator sets a person's budget as fleet.person_budget.<principal> =
// "5h=<tokens>,week=<tokens>" (either half may be left out; "" removes it).
// Over either window, the person's next request is refused with
// person_budget_exceeded — a status neither client retries — and a message
// saying which window and when it frees up; everybody else is untouched.
//
// Tokens counted: input + cache writes + output. Cache reads are left out —
// they are most of a long session's input and the subscription itself weighs
// them lightly. No budget set ⇒ nothing is ever refused; no proxy (the
// FLEET_CRED_PROXY=0 default) ⇒ nothing is reported at all.

// PersonBudgetPrefix is the setting a person's budget lives in.
const PersonBudgetPrefix = "fleet.person_budget."

// PersonBudgetExceeded is the refusal code both proxies answer with.
const PersonBudgetExceeded = "person_budget_exceeded"

// CredProxyUsagePath is where the cluster proxy reports what a person used.
const CredProxyUsagePath = "/v1/fleet/credproxy/usage"

const (
	budgetWindow5h   = 5 * time.Hour
	budgetWindowWeek = 7 * 24 * time.Hour
)

// principalKeyRE is a principal as a setting key's tail: gh:<id>, a drill
// person, a legacy login.
var principalKeyRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9:._@-]{0,127}$`)

// PersonBudget is one person's limits, in tokens; 0 = no limit on that window.
type PersonBudget struct {
	H5   int64 `json:"5h,omitempty"`
	Week int64 `json:"week,omitempty"`
}

// parsePersonBudget reads "5h=200k,week=2M" (comma or space separated; k / m
// suffixes; a bare number is tokens).
func parsePersonBudget(v string) (PersonBudget, error) {
	var b PersonBudget
	fields := strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == ';' })
	if len(fields) == 0 {
		return b, fmt.Errorf("a person's budget is 5h=<tokens>,week=<tokens> (either half may be left out)")
	}
	for _, f := range fields {
		k, n, ok := strings.Cut(f, "=")
		if !ok {
			return b, fmt.Errorf("%q: want 5h=<tokens> or week=<tokens>", f)
		}
		t, err := parseTokens(n)
		if err != nil {
			return b, fmt.Errorf("%q: %v", f, err)
		}
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "5h":
			b.H5 = t
		case "week", "7d", "w":
			b.Week = t
		default:
			return b, fmt.Errorf("%q: the windows are 5h and week", f)
		}
	}
	return b, nil
}

func parseTokens(s string) (int64, error) {
	s = strings.TrimSpace(s)
	mul := int64(1)
	switch {
	case strings.HasSuffix(s, "k") || strings.HasSuffix(s, "K"):
		mul, s = 1_000, s[:len(s)-1]
	case strings.HasSuffix(s, "m") || strings.HasSuffix(s, "M"):
		mul, s = 1_000_000, s[:len(s)-1]
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || f < 0 || f > 1e12 {
		return 0, fmt.Errorf("a token count (e.g. 200000, 200k, 2M)")
	}
	return int64(f * float64(mul)), nil
}

func (b PersonBudget) String() string {
	var p []string
	if b.H5 > 0 {
		p = append(p, "5h="+strconv.FormatInt(b.H5, 10))
	}
	if b.Week > 0 {
		p = append(p, "week="+strconv.FormatInt(b.Week, 10))
	}
	return strings.Join(p, ",")
}

// PersonBudgetState is a person's standing: what they used, what they may,
// and — when over — why and until when.
type PersonBudgetState struct {
	Principal   string     `json:"principal"`
	DisplayName string     `json:"display_name,omitempty"`
	Budget      string     `json:"budget,omitempty"`
	Limit5h     int64      `json:"limit_5h"`
	LimitWeek   int64      `json:"limit_week"`
	Used5h      int64      `json:"used_5h"`
	UsedWeek    int64      `json:"used_week"`
	Requests5h  int64      `json:"requests_5h"`
	Over        bool       `json:"over"`
	Window      string     `json:"window,omitempty"` // 5h | week, when over
	ResetAt     *time.Time `json:"reset_at,omitempty"`
	Error       string     `json:"error,omitempty"`   // person_budget_exceeded, when over
	Message     string     `json:"message,omitempty"` // the line the session shows
}

func (s *Server) budgetClock() time.Time {
	if s.budgetNow != nil {
		return s.budgetNow()
	}
	return time.Now()
}

// personBudgets reads every fleet.person_budget.* setting.
func personBudgets(settings map[string]string) map[string]PersonBudget {
	out := map[string]PersonBudget{}
	for k, v := range settings {
		if !strings.HasPrefix(k, PersonBudgetPrefix) {
			continue
		}
		if b, err := parsePersonBudget(v); err == nil {
			out[k[len(PersonBudgetPrefix):]] = b
		}
	}
	return out
}

// personBudgetStates answers for one person, or everyone with a budget or
// any usage this week when principal is "".
func (s *Server) personBudgetStates(principal string, now time.Time) ([]PersonBudgetState, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	budgets := personBudgets(settings)
	rows, err := s.Store.PersonUsageSince(principal, now.Add(-budgetWindowWeek))
	if err != nil {
		return nil, err
	}
	by := map[string][]store.PersonUsageRow{}
	for _, r := range rows {
		by[r.Principal] = append(by[r.Principal], r)
	}
	var ids []string
	if principal != "" {
		ids = []string{principal}
	} else {
		seen := map[string]bool{}
		for id := range budgets {
			seen[id] = true
		}
		for id := range by {
			seen[id] = true
		}
		for id := range seen {
			ids = append(ids, id)
		}
		sort.Strings(ids)
	}
	out := make([]PersonBudgetState, 0, len(ids))
	for _, id := range ids {
		out = append(out, budgetState(id, budgets[id], by[id], now))
	}
	return out, nil
}

// personBudgetState is one person's.
func (s *Server) personBudgetState(principal string, now time.Time) (PersonBudgetState, error) {
	st, err := s.personBudgetStates(principal, now)
	if err != nil || len(st) == 0 {
		return PersonBudgetState{Principal: principal}, err
	}
	return st[0], nil
}

// budgetState sums one person's buckets (oldest first) into both windows.
func budgetState(id string, b PersonBudget, rows []store.PersonUsageRow, now time.Time) PersonBudgetState {
	st := PersonBudgetState{Principal: id, Budget: b.String(), Limit5h: b.H5, LimitWeek: b.Week}
	cut5h := now.Add(-budgetWindow5h)
	var in5h []store.PersonUsageRow
	for _, r := range rows {
		st.UsedWeek += r.Tokens
		if !store.PersonBucketStart(r.Bucket).Add(store.PersonUsageBucket).Before(cut5h) {
			st.Used5h += r.Tokens
			st.Requests5h += r.Requests
			in5h = append(in5h, r)
		}
	}
	over := func(window string, used, limit int64, win time.Duration, rs []store.PersonUsageRow) bool {
		if limit <= 0 || used < limit {
			return false
		}
		// frees up when enough of the oldest buckets leave the window
		left := used
		var at time.Time
		for _, r := range rs {
			left -= r.Tokens
			if left < limit {
				at = store.PersonBucketStart(r.Bucket).Add(store.PersonUsageBucket + win)
				break
			}
		}
		st.Over, st.Window, st.Error = true, window, PersonBudgetExceeded
		if !at.IsZero() {
			st.ResetAt = &at
		}
		st.Message = budgetMessage(window, used, limit, at, now)
		return true
	}
	if !over("5h", st.Used5h, b.H5, budgetWindow5h, in5h) {
		over("week", st.UsedWeek, b.Week, budgetWindowWeek, rows)
	}
	return st
}

func budgetMessage(window string, used, limit int64, at, now time.Time) string {
	name := map[string]string{"5h": "近 5 小时", "week": "近 7 天"}[window]
	msg := fmt.Sprintf("已达个人额度：%s已用 %s / 上限 %s token", name, humanTokens(used), humanTokens(limit))
	if !at.IsZero() {
		d := at.Sub(now).Round(time.Minute)
		if d < time.Minute {
			d = time.Minute
		}
		msg += "，约 " + humanDur(d) + "后恢复"
	}
	return msg + "（" + PersonBudgetExceeded + "；额度由管理员设置：fleet config budget）"
}

func humanTokens(n int64) string {
	switch {
	case n >= 1_000_000:
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + "M"
	case n >= 10_000:
		return strconv.FormatInt(n/1000, 10) + "k"
	}
	return strconv.FormatInt(n, 10)
}

func humanDur(d time.Duration) string {
	h, m := int(d.Hours()), int(d.Minutes())%60
	switch {
	case h >= 24:
		return fmt.Sprintf("%d 天 %d 小时", h/24, h%24)
	case h > 0 && m > 0:
		return fmt.Sprintf("%d 小时 %d 分钟", h, m)
	case h > 0:
		return fmt.Sprintf("%d 小时", h)
	}
	return fmt.Sprintf("%d 分钟", m)
}

// usageReport is what a proxy sends: tokens per provider since its last report.
type usageReport struct {
	Principal string `json:"principal,omitempty"` // the cluster proxy only
	Usage     []struct {
		Provider string `json:"provider"`
		Tokens   int64  `json:"tokens"`
		Requests int64  `json:"requests"`
	} `json:"usage"`
}

func (s *Server) recordUsage(principal string, rep usageReport, now time.Time) error {
	for _, u := range rep.Usage {
		if !hasString(sessionCredProviders, u.Provider) || u.Tokens < 0 || u.Tokens > 1e10 || u.Requests < 0 || u.Requests > 1e6 {
			continue
		}
		if err := s.Store.AddPersonUsage(principal, u.Provider, u.Tokens, u.Requests, now); err != nil {
			return err
		}
	}
	return nil
}

// handleNodeUsage is a login's local proxy: GET = the login's person's
// standing, POST {usage:[…]} = add, then the standing.
func (s *Server) handleNodeUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "GET or POST {usage:[{provider, tokens, requests}]}")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	now := s.budgetClock()
	host, user := s.nodeIdentity(ep)
	principal, err := s.Store.PrincipalForLogin(host, user)
	if err != nil {
		// no person for this login: nothing to count against, nothing refused
		writeJSON(w, http.StatusOK, PersonBudgetState{Message: "no person is mapped to " + user + "@" + host})
		return
	}
	if r.Method == http.MethodPost {
		var rep usageReport
		if err := readOptionalJSON(r, &rep); err != nil {
			httpError(w, http.StatusBadRequest, "body must be {usage:[{provider, tokens, requests}]}")
			return
		}
		if err := s.recordUsage(principal, rep, now); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	st, err := s.personBudgetState(principal, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// handleCredProxyUsage is the cluster proxy: POST {principal, usage:[…]}.
func (s *Server) handleCredProxyUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST {principal, usage:[…]}")
		return
	}
	if s.CredProxyToken == "" {
		sessionCredRefuse(w, http.StatusServiceUnavailable, CredProxyOff,
			"the cluster credential proxy is off on this hub (no CCQUOTA_FLEET_CREDPROXY_TOKEN)")
		return
	}
	if !constantTimeEqual(bearer(r), s.CredProxyToken) {
		sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated", "the credential proxy's token is required")
		return
	}
	var rep usageReport
	if err := readOptionalJSON(r, &rep); err != nil || !principalKeyRE.MatchString(rep.Principal) {
		httpError(w, http.StatusBadRequest, "body must be {principal, usage:[{provider, tokens, requests}]}")
		return
	}
	now := s.budgetClock()
	if err := s.recordUsage(rep.Principal, rep, now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	st, err := s.personBudgetState(rep.Principal, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// handleFleetPersonUsage is GET /v1/fleet/person-usage, cut by role (我的用量,
// claude-fleet#2519): the operator's door and an admin read everyone with a
// budget or usage this week (?principal= narrows it); a user reads only their
// own, whatever ?principal= says, and an admin their own with ?mine=1. One
// person's answer also carries `days`, their tokens per UTC day this week —
// the curve the page draws under the budget.
func (s *Server) handleFleetPersonUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	now := s.budgetClock()
	pid := principalOf(r.Context())
	mine := roleOf(r.Context()) == roleUser || r.URL.Query().Get("mine") != ""
	if mine && pid == "" {
		// The operator's door asking for its own: it is nobody.
		writeJSON(w, http.StatusOK, map[string]any{"people": []PersonBudgetState{}, "days": []PersonUsageDay{}})
		return
	}
	who := strings.TrimSpace(r.URL.Query().Get("principal"))
	if mine {
		who = pid
	}
	st, err := s.personBudgetStates(who, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for i := range st {
		if p, err := s.Store.Principal(st[i].Principal); err == nil {
			st[i].DisplayName = p.DisplayName
		}
	}
	out := map[string]any{"people": st}
	if who != "" {
		days, err := s.personUsageDays(who, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out["days"] = days
	}
	writeJSON(w, http.StatusOK, out)
}

// PersonUsageDay is one UTC day of one person's counted tokens.
type PersonUsageDay struct {
	Day    string `json:"day"` // YYYY-MM-DD, UTC
	Tokens int64  `json:"tokens"`
}

// personUsageDays is principal's tokens for each of the 7 UTC days ending
// today, oldest first; a day with nothing is 0.
func (s *Server) personUsageDays(principal string, now time.Time) ([]PersonUsageDay, error) {
	today := now.UTC().Truncate(24 * time.Hour)
	first := today.AddDate(0, 0, -6)
	rows, err := s.Store.PersonUsageSince(principal, first)
	if err != nil {
		return nil, err
	}
	out := make([]PersonUsageDay, 7)
	for i := range out {
		out[i].Day = first.AddDate(0, 0, i).Format("2006-01-02")
	}
	for _, r := range rows {
		if i := int(store.PersonBucketStart(r.Bucket).Sub(first) / (24 * time.Hour)); i >= 0 && i < len(out) {
			out[i].Tokens += r.Tokens
		}
	}
	return out, nil
}
