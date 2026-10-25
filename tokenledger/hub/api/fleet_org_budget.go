package api

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// An organization's budget (task PNWW): fleet.org_budget.<org_id> =
// "5h=<tokens>,week=<tokens>,month=<tokens>" (any part may be left out; ""
// removes it). It sums the organization's pool_usage rows — org_id is stamped
// on each row when it is written, so a row from before the column, or from
// before a person moved, counts where it was filed — and is checked beside
// the person's own budget: a member's next request is refused when either is
// over, the organization's with its own code, org_budget_exceeded. month is
// the last 30 days. No budget set ⇒ nothing is refused.

const (
	// OrgBudgetPrefix is the setting an organization's budget lives in.
	OrgBudgetPrefix = "fleet.org_budget."
	// OrgBudgetExceeded is the refusal code for a member of an organization
	// over its budget.
	OrgBudgetExceeded = "org_budget_exceeded"
	budgetWindowMonth = 30 * 24 * time.Hour
)

// orgIDRE is an organization id.
var orgIDRE = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// OrgBudget is one organization's limits, in tokens; 0 = no limit there.
type OrgBudget struct {
	H5    int64 `json:"5h,omitempty"`
	Week  int64 `json:"week,omitempty"`
	Month int64 `json:"month,omitempty"`
}

func parseOrgBudget(v string) (OrgBudget, error) {
	var b OrgBudget
	fields := strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == ';' })
	if len(fields) == 0 {
		return b, fmt.Errorf("an organization's budget is 5h=<tokens>,week=<tokens>,month=<tokens> (any part may be left out)")
	}
	for _, f := range fields {
		k, n, ok := strings.Cut(f, "=")
		if !ok {
			return b, fmt.Errorf("%q: want 5h=, week= or month=<tokens>", f)
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
		case "month", "30d", "m":
			b.Month = t
		default:
			return b, fmt.Errorf("%q: the windows are 5h, week and month", f)
		}
	}
	return b, nil
}

func (b OrgBudget) String() string {
	var p []string
	for _, x := range []struct {
		k string
		n int64
	}{{"5h", b.H5}, {"week", b.Week}, {"month", b.Month}} {
		if x.n > 0 {
			p = append(p, x.k+"="+strconv.FormatInt(x.n, 10))
		}
	}
	return strings.Join(p, ",")
}

// OrgBudgetState is an organization's standing.
type OrgBudgetState struct {
	OrgID      string     `json:"org_id"`
	Budget     string     `json:"budget,omitempty"`
	Limit5h    int64      `json:"limit_5h"`
	LimitWeek  int64      `json:"limit_week"`
	LimitMonth int64      `json:"limit_month"`
	Used5h     int64      `json:"used_5h"`
	UsedWeek   int64      `json:"used_week"`
	UsedMonth  int64      `json:"used_month"`
	Over       bool       `json:"over"`
	Window     string     `json:"window,omitempty"` // 5h | week | month, when over
	ResetAt    *time.Time `json:"reset_at,omitempty"`
	Error      string     `json:"error,omitempty"`
	Message    string     `json:"message,omitempty"`
}

// orgBudgetState is org's standing now; a budget that does not parse is no
// budget (the settings PUT refuses one).
func (s *Server) orgBudgetState(org string, now time.Time) (OrgBudgetState, error) {
	st := OrgBudgetState{OrgID: org}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return st, err
	}
	b, _ := parseOrgBudget(settings[OrgBudgetPrefix+org])
	st.Budget, st.Limit5h, st.LimitWeek, st.LimitMonth = b.String(), b.H5, b.Week, b.Month
	rows, err := s.Store.OrgUsageSince(org, now.Add(-budgetWindowMonth))
	if err != nil {
		return st, err
	}
	in := func(win time.Duration) []store.OrgUsageRow {
		cut := now.Add(-win)
		var out []store.OrgUsageRow
		for _, r := range rows {
			if !r.At.Before(cut) {
				out = append(out, r)
			}
		}
		return out
	}
	sum := func(rs []store.OrgUsageRow) (n int64) {
		for _, r := range rs {
			n += r.Tokens
		}
		return n
	}
	r5, rw := in(budgetWindow5h), in(budgetWindowWeek)
	st.Used5h, st.UsedWeek, st.UsedMonth = sum(r5), sum(rw), sum(rows)
	over := func(window string, used, limit int64, win time.Duration, rs []store.OrgUsageRow) bool {
		if limit <= 0 || used < limit {
			return false
		}
		left := used
		var at time.Time
		for _, r := range rs {
			left -= r.Tokens
			if left < limit {
				at = r.At.Add(win)
				break
			}
		}
		st.Over, st.Window, st.Error = true, window, OrgBudgetExceeded
		if !at.IsZero() {
			st.ResetAt = &at
		}
		name := map[string]string{"5h": "近 5 小时", "week": "近 7 天", "month": "近 30 天"}[window]
		st.Message = fmt.Sprintf("已达组织额度（%s）：%s已用 %s / 上限 %s token", org, name, humanTokens(used), humanTokens(limit))
		if !at.IsZero() {
			d := at.Sub(now).Round(time.Minute)
			if d < time.Minute {
				d = time.Minute
			}
			st.Message += "，约 " + humanDur(d) + "后恢复"
		}
		st.Message += "（" + OrgBudgetExceeded + "；额度由管理员或组织管理员设置）"
		return true
	}
	if !over("5h", st.Used5h, b.H5, budgetWindow5h, r5) && !over("week", st.UsedWeek, b.Week, budgetWindowWeek, rw) {
		over("month", st.UsedMonth, b.Month, budgetWindowMonth, rows)
	}
	return st, nil
}

// applyOrgBudget holds st (a person not over their own budget) to their
// organization's: over it, st reads over with org_budget_exceeded.
func (s *Server) applyOrgBudget(st *PersonBudgetState, now time.Time) error {
	if st.Over || st.Principal == "" || isSvcPrincipal(st.Principal) {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	org, _, err := s.Store.PersonOrg(st.Principal)
	if err != nil || org == "" {
		return err
	}
	if strings.TrimSpace(settings[OrgBudgetPrefix+org]) == "" {
		return nil // no budget: no query
	}
	os, err := s.orgBudgetState(org, now)
	if err != nil {
		return err
	}
	if os.Over {
		st.Over, st.Window, st.Error, st.Message, st.ResetAt = true, "org_"+os.Window, OrgBudgetExceeded, os.Message, os.ResetAt
	}
	return nil
}
