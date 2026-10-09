package api

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 我的额度 (claude-fleet#2517, EPIC #2512 C5): the subscriptions a person's
// own logins run on — the 5-hour and 7-day windows, when the binding one
// resets, and whether it is used up or paused. Before it the quota lived only
// on the admin's Subscriptions page, so a user who hit a weekly limit saw a
// stuck session and no reason.
//
// Which subscriptions are "theirs" is fleetSummary's cut (fleet_summary.go):
// the accounts reported by an endpoint on one of their (machine, login)
// pairs. An admin gets the same cut — this is the "mine" page, the whole pool
// stays on Subscriptions. The operator's token (no principal) reads every
// subscription, as it reads everything else.
//
// Nothing that names an account leaves: no account uuid, no e-mail, no
// endpoint shares — a subscription is called by its pool credential's label,
// else the name an admin gave it by hand, else its plan.

// MyQuota is one row of /v1/me/quota. A percentage is null when there is no
// reading of that window.
type MyQuota struct {
	Subscription string     `json:"subscription"`
	Provider     string     `json:"provider"`
	Used5hPct    *float64   `json:"used_5h_pct"`
	Used7dPct    *float64   `json:"used_7d_pct"`
	ResetsAt     *time.Time `json:"resets_at"`
	State        string     `json:"state"`
}

// The states a row can be in.
const (
	QuotaOK      = "ok"      // room left
	QuotaLimited = "limited" // a window is used up (or the provider says blocked)
	QuotaPaused  = "paused"  // an admin paused it in the pool
	QuotaUnknown = "unknown" // no reading yet
)

func (s *Server) handleMeQuota(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	out, err := s.myQuota(principalOf(r.Context()), time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// serveQuotaPage serves 我的额度's page.
func (s *Server) serveQuotaPage(w http.ResponseWriter, r *http.Request) {
	s.serveStandalonePage(w, r, "quota.html")
}

// myQuota is pid's rows; pid "" is the operator's door, every subscription.
func (s *Server) myQuota(pid string, now time.Time) ([]MyQuota, error) {
	var mine map[string]bool
	if pid != "" {
		visible, err := s.ownScope(pid)
		if err != nil {
			return nil, err
		}
		eps, err := s.Store.ListEndpoints("")
		if err != nil {
			return nil, err
		}
		mine = map[string]bool{}
		for _, e := range eps {
			if visible(e.Hostname, e.OSUser) {
				mine[e.AccountUUID] = true
			}
		}
	}
	out := []MyQuota{}
	if mine != nil && len(mine) == 0 {
		return out, nil
	}
	accts, err := s.Store.ListAccounts()
	if err != nil {
		return nil, err
	}
	names, paused, err := s.poolNames()
	if err != nil {
		return nil, err
	}
	seen := map[string]int{}
	for _, a := range accts {
		if mine != nil && !mine[a.AccountUUID] {
			continue
		}
		v, err := s.LimitsFor(a.AccountUUID)
		if err != nil {
			return nil, err
		}
		q := MyQuota{Provider: providerOf(a, v), State: QuotaUnknown}
		cred := names.match(a)
		switch {
		case cred != "":
			q.Subscription = cred
		case a.LabelLocked && a.Email != "":
			q.Subscription = a.Email // a hand label (SetAccountLabel)
		default:
			q.Subscription = planName(a, q.Provider)
		}
		if n := seen[q.Subscription]; n > 0 {
			seen[q.Subscription] = n + 1
			q.Subscription = fmt.Sprintf("%s · %d", q.Subscription, n+1)
		} else {
			seen[q.Subscription] = 1
		}
		fillQuota(&q, v)
		if cred != "" && paused[cred] {
			q.State = QuotaPaused
		}
		out = append(out, q)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Subscription < out[j].Subscription })
	return out, nil
}

// fillQuota reads the two windows off v — Claude's five_hour / seven_day, or
// a Codex reading's windows by their length — and the state they add up to.
func fillQuota(q *MyQuota, v *LimitsView) {
	if v == nil {
		return
	}
	var h5, h7 *WindowView
	h5, h7 = v.FiveHour, v.SevenDay
	for i := range v.Windows {
		w := &v.Windows[i]
		switch {
		case w.Minutes > 0 && w.Minutes <= 5*60 && h5 == nil:
			h5 = &w.WindowView
		case w.Minutes >= 7*24*60 && h7 == nil:
			h7 = &w.WindowView
		}
	}
	pct := func(w *WindowView) *float64 {
		if w == nil {
			return nil
		}
		p := w.Utilization
		return &p
	}
	q.Used5hPct, q.Used7dPct = pct(h5), pct(h7)
	if !v.Available && h5 == nil && h7 == nil && !v.Blocked {
		return
	}
	// The reset that matters: a full window's (the later, when both are),
	// else the soonest — when there is next more room.
	var full, soon *time.Time
	for _, w := range []*WindowView{h5, h7} {
		if w == nil || w.ResetsAt == nil {
			continue
		}
		if w.Utilization >= 100 && (full == nil || w.ResetsAt.After(*full)) {
			full = w.ResetsAt
		}
		if soon == nil || w.ResetsAt.Before(*soon) {
			soon = w.ResetsAt
		}
	}
	q.State = QuotaOK
	q.ResetsAt = soon
	if full != nil || v.Blocked || (h5 != nil && h5.Utilization >= 100) || (h7 != nil && h7.Utilization >= 100) {
		q.State = QuotaLimited
		if full != nil {
			q.ResetsAt = full
		}
	}
}

func providerOf(a store.Account, v *LimitsView) string {
	if (v != nil && v.Source == string(model.SourceCodex)) || a.Source == string(model.SourceCodex) {
		return "codex"
	}
	return "claude"
}

// planName names a subscription with no label by what it is: 「Claude max」.
func planName(a store.Account, provider string) string {
	name := "Claude"
	if provider == "codex" {
		name = "Codex"
	}
	if a.SubscriptionType != "" {
		name += " " + a.SubscriptionType
	}
	return name
}

// poolCreds is the pool's credentials, to name a subscription by the label
// an admin imported it under — the name the Subscriptions page uses.
type poolCreds struct {
	byUUID  map[string]string
	byLabel map[string]string
}

// match is a's pool label: the credential bound to its uuid, else one whose
// label is a's e-mail or its local part (the Subscriptions page's own
// pairing, web/dist/lib/admin.js subscriptions, steps 0 and 1).
func (p poolCreds) match(a store.Account) string {
	if c := p.byUUID[a.AccountUUID]; c != "" {
		return c
	}
	email := strings.ToLower(a.Email)
	local, _, _ := strings.Cut(email, "@")
	for _, k := range []string{email, local} {
		if c := p.byLabel[k]; k != "" && c != "" {
			return c
		}
	}
	return ""
}

// poolNames reads the vault's pool rows and which of them an admin paused.
// No vault: no names, nothing paused.
func (s *Server) poolNames() (poolCreds, map[string]bool, error) {
	p := poolCreds{byUUID: map[string]string{}, byLabel: map[string]string{}}
	paused := map[string]bool{}
	if s.Vault == nil {
		return p, paused, nil
	}
	creds, err := s.Store.Credentials(store.PoolPrincipal)
	if err != nil {
		return p, paused, err
	}
	for _, c := range creds {
		if c.Provider == credvault.GitHub {
			continue
		}
		if u := s.Vault.AccountUUID(c); u != "" {
			p.byUUID[u] = c.Account
		}
		p.byLabel[strings.ToLower(c.Account)] = c.Account
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return p, paused, err
	}
	for _, a := range pausedAccounts(settings) {
		paused[a] = true
	}
	return p, paused, nil
}
