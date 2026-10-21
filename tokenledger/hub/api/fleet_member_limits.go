package api

import (
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/pricing"
)

// A trial member's limits (claude-fleet T789). A person approved through
// /apply used to become a member with nothing held against them: no end, no
// spend ceiling, no session count. Approval now writes
//
//	fleet.member_limits.<principal> = "until=<RFC 3339>,usd=<dollars>,sessions=<n>,since=<RFC 3339>"
//
// from fleet.apply.trial ("days=7,usd=20,sessions=1" by default; "off" =
// approve as a full member) or the approval's own `limits`. Any part may be
// left out; "" removes the key — the person 转正, nothing held. Held:
//
//   - until: past it, every request either proxy carries for them is refused
//     with person_budget_exceeded and 「试用期已到」.
//   - usd: their pool usage since `since`, priced at API rates
//     (pricing.RatesFor; a model the table lacks at the Opus tier, so the
//     ceiling still binds), at or past it the same refusal.
//   - sessions: a hub-placed start or resume on their login refused at that
//     many running sessions.
//
// Approving again never resets a limit already written.

const (
	MemberLimitsPrefix  = "fleet.member_limits."
	ApplyTrialKey       = "fleet.apply.trial"
	applyTrialDefault   = "days=7,usd=20,sessions=1"
	memberLimitsMaxDays = 365
)

// unpricedRates is what a model with no rates is priced at: the Opus tier.
var unpricedRates = pricing.Rates{Input: 5, Output: 25, CacheWrite5m: 6.25, CacheRead: 0.5}

// MemberLimits is one person's; zero values hold nothing.
type MemberLimits struct {
	Until    time.Time
	Since    time.Time
	USD      float64
	Sessions int
}

func (l MemberLimits) empty() bool {
	return l.Until.IsZero() && l.USD <= 0 && l.Sessions <= 0
}

func (l MemberLimits) String() string {
	var p []string
	if !l.Until.IsZero() {
		p = append(p, "until="+l.Until.UTC().Format(time.RFC3339))
	}
	if l.USD > 0 {
		p = append(p, "usd="+strconv.FormatFloat(l.USD, 'f', -1, 64))
	}
	if l.Sessions > 0 {
		p = append(p, "sessions="+strconv.Itoa(l.Sessions))
	}
	if !l.Since.IsZero() && !l.empty() {
		p = append(p, "since="+l.Since.UTC().Format(time.RFC3339))
	}
	return strings.Join(p, ",")
}

// limitFields splits "a=1,b=2" (comma, space or semicolon separated).
func limitFields(v string) ([][2]string, error) {
	var out [][2]string
	for _, f := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
		k, val, ok := strings.Cut(f, "=")
		if !ok {
			return nil, fmt.Errorf("%q: want key=value", f)
		}
		out = append(out, [2]string{strings.ToLower(strings.TrimSpace(k)), strings.TrimSpace(val)})
	}
	return out, nil
}

func parseUSD(v string) (float64, error) {
	f, err := strconv.ParseFloat(strings.TrimPrefix(v, "$"), 64)
	if err != nil || f < 0 || f > 100000 {
		return 0, fmt.Errorf("usd is dollars 0..100000")
	}
	return f, nil
}

func parseSessions(v string) (int, error) {
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > 100 {
		return 0, fmt.Errorf("sessions is 0..100")
	}
	return n, nil
}

// parseMemberLimits reads a stored person's value.
func parseMemberLimits(v string) (MemberLimits, error) {
	var l MemberLimits
	fs, err := limitFields(v)
	if err != nil {
		return l, err
	}
	for _, f := range fs {
		switch f[0] {
		case "until", "since":
			t, err := time.Parse(time.RFC3339, f[1])
			if err != nil {
				return l, fmt.Errorf("%s is an RFC 3339 time", f[0])
			}
			if f[0] == "until" {
				l.Until = t
			} else {
				l.Since = t
			}
		case "usd":
			if l.USD, err = parseUSD(f[1]); err != nil {
				return l, err
			}
		case "sessions":
			if l.Sessions, err = parseSessions(f[1]); err != nil {
				return l, err
			}
		default:
			return l, fmt.Errorf("%q: the parts are until, usd, sessions, since", f[0])
		}
	}
	return l, nil
}

// trialTerms is an approval's terms: "days=7,usd=20,sessions=1", or "off".
type trialTerms struct {
	Off      bool
	Days     int
	USD      float64
	Sessions int
}

func parseTrialTerms(v string) (trialTerms, error) {
	var t trialTerms
	v = strings.TrimSpace(v)
	if strings.EqualFold(v, "off") || strings.EqualFold(v, noneValue) {
		t.Off = true
		return t, nil
	}
	fs, err := limitFields(v)
	if err != nil {
		return t, err
	}
	if len(fs) == 0 {
		return t, fmt.Errorf(`want days=<n>,usd=<dollars>,sessions=<n>, or "off"`)
	}
	for _, f := range fs {
		switch f[0] {
		case "days":
			n, err := strconv.Atoi(f[1])
			if err != nil || n < 0 || n > memberLimitsMaxDays {
				return t, fmt.Errorf("days is 0..%d", memberLimitsMaxDays)
			}
			t.Days = n
		case "usd":
			if t.USD, err = parseUSD(f[1]); err != nil {
				return t, err
			}
		case "sessions":
			if t.Sessions, err = parseSessions(f[1]); err != nil {
				return t, err
			}
		default:
			return t, fmt.Errorf("%q: the parts are days, usd, sessions", f[0])
		}
	}
	return t, nil
}

func (t trialTerms) String() string {
	if t.Off {
		return "off"
	}
	var p []string
	if t.Days > 0 {
		p = append(p, "days="+strconv.Itoa(t.Days))
	}
	if t.USD > 0 {
		p = append(p, "usd="+strconv.FormatFloat(t.USD, 'f', -1, 64))
	}
	if t.Sessions > 0 {
		p = append(p, "sessions="+strconv.Itoa(t.Sessions))
	}
	if len(p) == 0 {
		return "off"
	}
	return strings.Join(p, ",")
}

func (t trialTerms) limits(now time.Time) MemberLimits {
	if t.Off {
		return MemberLimits{}
	}
	l := MemberLimits{USD: t.USD, Sessions: t.Sessions, Since: now}
	if t.Days > 0 {
		l.Until = now.Add(time.Duration(t.Days) * 24 * time.Hour)
	}
	return l
}

func init() {
	hubSettings[ApplyTrialKey] = hubSetting{def: applyTrialDefault,
		help: "limits a person approved through /apply starts with: days=<n>,usd=<dollars of pool usage>,sessions=<n>, or off (claude-fleet T789)",
		check: func(_ *Server, v string) (string, string) {
			t, err := parseTrialTerms(v)
			if err != nil {
				return "", ApplyTrialKey + ": " + err.Error()
			}
			return t.String(), ""
		}}
}

// writeMemberLimits records an approval's limits for pid unless they have
// some already. terms "" = fleet.apply.trial.
func (s *Server) writeMemberLimits(pid, terms, by string, now time.Time) error {
	key := MemberLimitsPrefix + pid
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	if _, has := settings[key]; has {
		return nil
	}
	if strings.TrimSpace(terms) == "" {
		terms = s.setting(ApplyTrialKey)
	}
	t, err := parseTrialTerms(terms)
	if err != nil {
		return fmt.Errorf("limits: %v", err)
	}
	l := t.limits(now)
	if l.empty() {
		return nil
	}
	if err := s.Store.SetFleetSetting(key, l.String(), now); err != nil {
		return err
	}
	s.settingAudit(by, key, "", l.String(), now)
	return nil
}

// memberLimitsOf is pid's limits; ok false when none (or unreadable — logged).
func memberLimitsOf(settings map[string]string, pid string) (MemberLimits, bool) {
	v, has := settings[MemberLimitsPrefix+pid]
	if !has || strings.TrimSpace(v) == "" {
		return MemberLimits{}, false
	}
	l, err := parseMemberLimits(v)
	if err != nil {
		log.Printf("fleet: %s%s: %v", MemberLimitsPrefix, pid, err)
		return MemberLimits{}, false
	}
	return l, !l.empty()
}

// memberSpendUSD prices pid's pool usage since since at API rates.
func (s *Server) memberSpendUSD(pid string, since time.Time) (float64, error) {
	rows, err := s.Store.PersonModelUsageSince(pid, since)
	if err != nil {
		return 0, err
	}
	return priceUsage(rows), nil
}

func priceUsage(rows []store.PersonModelUsage) float64 {
	const perM = 1_000_000.0
	var usd float64
	for _, r := range rows {
		rt, ok := pricing.RatesFor(r.Model)
		if !ok {
			rt = unpricedRates
		}
		cw := rt.CacheWrite5m
		if cw == 0 {
			cw = rt.Input
		}
		usd += float64(r.In)/perM*rt.Input + float64(r.Out)/perM*rt.Output +
			float64(r.CacheWrite)/perM*cw + float64(r.CacheRead)/perM*rt.CacheRead
	}
	return usd
}

// applyMemberLimits turns st over when pid's trial has ended or its dollars
// are spent; a budget already over keeps its own message.
func (s *Server) applyMemberLimits(st *PersonBudgetState, l MemberLimits, now time.Time) {
	st.TrialUntil, st.TrialUSD = nil, 0
	if !l.Until.IsZero() {
		u := l.Until
		st.TrialUntil = &u
	}
	st.TrialUSD = l.USD
	if l.USD > 0 {
		spent, err := s.memberSpendUSD(st.Principal, l.Since)
		if err != nil {
			log.Printf("fleet: member limits of %s: %v", st.Principal, err)
		}
		st.TrialSpentUSD = spent
	}
	if st.Over {
		return
	}
	switch {
	case !l.Until.IsZero() && !now.Before(l.Until):
		st.Over, st.Window, st.Error = true, "trial", PersonBudgetExceeded
		st.Message = "试用期已于 " + l.Until.In(chinaTZ).Format("2006-01-02 15:04") +
			" 结束：请联系管理员转正后继续使用（" + PersonBudgetExceeded + "）"
	case l.USD > 0 && st.TrialSpentUSD >= l.USD:
		st.Over, st.Window, st.Error = true, "trial_usd", PersonBudgetExceeded
		st.Message = fmt.Sprintf("试用额度已用完：已用约 $%.2f / 上限 $%s，请联系管理员转正或加额度（%s）",
			st.TrialSpentUSD, strconv.FormatFloat(l.USD, 'f', -1, 64), PersonBudgetExceeded)
	}
}

var chinaTZ = time.FixedZone("CST", 8*3600)

// checkMemberSessions refuses a start or resume that would take a trial
// member past their session count on that login.
func (s *Server) checkMemberSessions(r store.FleetRow, now time.Time) error {
	pid, err := s.Store.PrincipalForLogin(r.Hostname, r.OSUser)
	if err != nil || pid == "" {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	l, ok := memberLimitsOf(settings, pid)
	if !ok || l.Sessions <= 0 {
		return nil
	}
	hb, _, _ := s.nodeStatusOf(r.EndpointID, now)
	if hb.Sessions >= l.Sessions {
		return fault("AT_CAPACITY", fmt.Sprintf("试用期内最多同时 %d 个会话，已经开着 %d 个：先关一个，或请管理员转正", l.Sessions, hb.Sessions))
	}
	return nil
}
