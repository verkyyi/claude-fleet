package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 试用额度让人自己看得见 (claude-fleet T796): a trial member's limits
// (fleet.member_limits.<principal>, T789) were only ever held — the proxies
// refused past them and the console never said how close the person was.
// GET /v1/me/usage now carries `trial`: when it ends and the days left, the
// tokens used against the ceiling (counted as every limit counts them), the
// session count and how many run now, and one state the page colours by:
//
//	ok      — nothing near
//	soon    — a day or less left, or 80 % of the tokens used
//	expired — past the end
//	spent   — the tokens (or the old dollar ceiling) used up
//
// POST /v1/me/trial/upgrade is 申请转正: it stamps
// fleet.member_upgrade.<principal> with the time, audited, and the admin's
// 成员 list shows it beside the person's limits (fleet/person-usage's
// upgrade_asked), and every admin is told once on the notice desk — WeChat
// first, tapping through to that person's drawer (claude-fleet T805,
// notify.go's NotifyKindUpgrade). No limits = no `trial`, and the POST
// answers 409.

const (
	MemberUpgradePrefix = "fleet.member_upgrade."
	MeTrialUpgradePath  = "/v1/me/trial/upgrade"
	trialSoonPct        = 80
)

// Trial states.
const (
	trialOK      = "ok"
	trialSoon    = "soon"
	trialExpired = "expired"
	trialSpent   = "spent"
)

// MeUsageTrial is /v1/me/usage's trial: the viewer's own limits and what
// stands against them. A part not held is absent.
type MeUsageTrial struct {
	State        string     `json:"state"` // ok | soon | expired | spent
	Since        *time.Time `json:"since,omitempty"`
	Until        *time.Time `json:"until,omitempty"`
	DaysLeft     *int       `json:"days_left,omitempty"` // whole days, rounded up; 0 past the end
	Tokens       int64      `json:"tokens,omitempty"`    // the ceiling
	UsedTokens   int64      `json:"used_tokens"`
	USD          float64    `json:"usd,omitempty"` // a ceiling written before T796
	SpentUSD     float64    `json:"spent_usd,omitempty"`
	Sessions     int        `json:"sessions,omitempty"` // at most this many at once
	SessionsNow  int        `json:"sessions_now"`
	UpgradeAsked *time.Time `json:"upgrade_asked,omitempty"`
}

// meTrial is principal's trial at now off their budget state; nil = none.
func (s *Server) meTrial(st PersonBudgetState, now time.Time) *MeUsageTrial {
	if st.TrialUntil == nil && st.TrialTokens <= 0 && st.TrialUSD <= 0 && st.TrialSessions <= 0 {
		return nil
	}
	t := &MeUsageTrial{Since: st.TrialSince, Until: st.TrialUntil, Tokens: st.TrialTokens, UsedTokens: st.TrialUsedTokens,
		USD: st.TrialUSD, SpentUSD: st.TrialSpentUSD, Sessions: st.TrialSessions, UpgradeAsked: st.UpgradeAsked}
	if st.TrialUsedTokens == 0 && st.TrialTokens <= 0 {
		if n, err := s.memberTokens(st.Principal, timeOr(st.TrialSince)); err == nil {
			t.UsedTokens = n // shown even with no token ceiling
		}
	}
	t.State = trialStateOf(t, now)
	if t.Until != nil {
		d := 0
		if left := t.Until.Sub(now); left > 0 {
			d = int((left + 24*time.Hour - 1) / (24 * time.Hour))
		}
		t.DaysLeft = &d
	}
	t.SessionsNow = s.personSessionsNow(st.Principal, now)
	return t
}

func timeOr(t *time.Time) time.Time {
	if t == nil {
		return time.Time{}
	}
	return *t
}

// trialStateOf is the one rule for the trial's state.
func trialStateOf(t *MeUsageTrial, now time.Time) string {
	switch {
	case t.Until != nil && !now.Before(*t.Until):
		return trialExpired
	case t.Tokens > 0 && t.UsedTokens >= t.Tokens, t.USD > 0 && t.SpentUSD >= t.USD:
		return trialSpent
	case t.Until != nil && t.Until.Sub(now) <= 24*time.Hour,
		t.Tokens > 0 && t.UsedTokens*100 >= t.Tokens*trialSoonPct,
		t.USD > 0 && t.SpentUSD*100 >= t.USD*trialSoonPct:
		return trialSoon
	}
	return trialOK
}

// personSessionsNow is how many sessions run on principal's logins, off each
// login's last heartbeat — the count checkMemberSessions holds them to.
func (s *Server) personSessionsNow(principal string, now time.Time) int {
	pairs, err := s.loginPairsOf(principal)
	if err != nil || len(pairs) == 0 {
		return 0
	}
	mine := map[[2]string]bool{}
	for _, p := range pairs {
		mine[[2]string{p.Hostname, p.Login}] = true
	}
	fleets, err := s.Store.Fleets()
	if err != nil {
		return 0
	}
	eps := map[string]bool{}
	for _, f := range fleets {
		if f.EndpointID != "" && mine[[2]string{f.Hostname, f.OSUser}] {
			eps[f.EndpointID] = true
		}
	}
	if len(eps) == 0 {
		return 0
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		return 0
	}
	n := 0
	for _, nd := range nodes {
		if !eps[nd.EndpointID] || NodeStatus(nd.LastHeartbeat, nd.HeartbeatMS, now) == "lost" {
			continue
		}
		var hb control.Heartbeat
		if json.Unmarshal([]byte(nd.StatusJSON), &hb) == nil {
			n += hb.Sessions
		}
	}
	return n
}

// upgradeAskedOf is when pid asked to 转正; nil = never.
func upgradeAskedOf(settings map[string]string, pid string) *time.Time {
	v := strings.TrimSpace(settings[MemberUpgradePrefix+pid])
	if v == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return nil
	}
	return &t
}

// handleMeTrialUpgrade is 申请转正: the viewer's own, once per trial (asking
// again keeps the first time).
func (s *Server) handleMeTrialUpgrade(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if viewAsOf(r.Context()) != nil {
		httpError(w, http.StatusForbidden, "read-only preview")
		return
	}
	pid := principalOf(r.Context())
	if pid == "" || s.Store == nil {
		httpError(w, http.StatusConflict, "no trial")
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, ok := memberLimitsOf(settings, pid); !ok {
		httpError(w, http.StatusConflict, "no trial")
		return
	}
	now := time.Now()
	if at := upgradeAskedOf(settings, pid); at != nil {
		writeJSON(w, http.StatusOK, map[string]any{"upgrade_asked": at})
		return
	}
	key, v := MemberUpgradePrefix+pid, now.UTC().Format(time.RFC3339)
	if err := s.Store.SetFleetSetting(key, v, now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.settingAudit(actorOf(r), key, "", v, now)
	s.notifyUpgrade(pid)
	at := now.UTC().Truncate(time.Second)
	writeJSON(w, http.StatusOK, map[string]any{"upgrade_asked": at})
}
