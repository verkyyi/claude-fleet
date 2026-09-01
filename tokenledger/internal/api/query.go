package api

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/verkyyi/ccquota/internal/recon"
	"github.com/verkyyi/ccquota/internal/store"
)

// LimitsView is what the dashboard and MCP see for one account's quota.
//
// Available distinguishes "we know the numbers" from "we do not". When it is
// false the caller must render no gauge at all — a stale or inferred
// percentage shown with the same weight as a live one is the failure this
// whole project exists to avoid.
type LimitsView struct {
	AccountUUID string `json:"account_uuid"`
	Available   bool   `json:"available"`
	Reason      string `json:"reason,omitempty"`

	ObservedAt *time.Time `json:"observed_at,omitempty"`
	// StaleSeconds is how old the reading is. The UI greys out a reading older
	// than a few minutes rather than pretending it is current.
	StaleSeconds int64 `json:"stale_seconds,omitempty"`

	FiveHour *WindowView `json:"five_hour,omitempty"`
	SevenDay *WindowView `json:"seven_day,omitempty"`

	Scoped []ScopedView `json:"scoped,omitempty"`

	// EndpointShares apportions the five-hour window across endpoints. The
	// account total is exact; these shares are estimates.
	EndpointShares []recon.Share `json:"endpoint_shares,omitempty"`

	Disclaimer string `json:"disclaimer"`
}

// WindowView is one rate-limit bucket plus its projection.
type WindowView struct {
	Utilization float64        `json:"utilization"`
	ResetsAt    *time.Time     `json:"resets_at,omitempty"`
	Burn        recon.BurnRate `json:"burn"`
}

// ScopedView is a per-model weekly limit.
type ScopedView struct {
	Model       string     `json:"model"`
	Surface     string     `json:"surface,omitempty"`
	Utilization float64    `json:"utilization"`
	ResetsAt    *time.Time `json:"resets_at,omitempty"`
	IsActive    bool       `json:"is_active"`
}

const shareDisclaimer = "The account-wide utilization is exact and already covers every device. " +
	"Per-endpoint shares are proportional estimates. Costs are notional API-equivalent figures, not a bill."

// LimitsFor builds the view for one account.
func (s *Server) LimitsFor(account string) (*LimitsView, error) {
	view := &LimitsView{AccountUUID: account, Disclaimer: shareDisclaimer}

	snap, err := s.Store.LatestLimits(account)
	if err != nil {
		return nil, err
	}
	if snap == nil {
		ep, reason, err := s.Store.LimitsReason(account)
		if err != nil {
			return nil, err
		}
		if reason != "" {
			view.Reason = fmt.Sprintf("%s reports: %s", ep, reason)
		} else {
			view.Reason = "no endpoint on this subscription has been able to read its account-wide limits"
		}
		return view, nil
	}

	now := time.Now().UTC()
	view.Available = true
	view.ObservedAt = &snap.ObservedAt
	view.StaleSeconds = int64(now.Sub(snap.ObservedAt).Seconds())

	fiveWin := recon.WindowFor(snap.FiveHour.ResetsAt, snap.ObservedAt, recon.FiveHourWindow)
	sevenWin := recon.WindowFor(snap.SevenDay.ResetsAt, snap.ObservedAt, recon.SevenDayWindow)

	view.FiveHour = &WindowView{
		Utilization: snap.FiveHour.Utilization,
		ResetsAt:    snap.FiveHour.ResetsAt,
		Burn:        recon.Burn(fiveWin, snap.FiveHour.Utilization, now),
	}
	view.SevenDay = &WindowView{
		Utilization: snap.SevenDay.Utilization,
		ResetsAt:    snap.SevenDay.ResetsAt,
		Burn:        recon.Burn(sevenWin, snap.SevenDay.Utilization, now),
	}
	for _, sc := range snap.Scoped {
		view.Scoped = append(view.Scoped, ScopedView{
			Model: sc.Model, Surface: sc.Surface,
			Utilization: sc.Utilization, ResetsAt: sc.ResetsAt, IsActive: sc.IsActive,
		})
	}

	evs, err := s.Store.EventsInRange(account, fiveWin.Start, fiveWin.End)
	if err != nil {
		return nil, err
	}
	labels, err := s.endpointLabels(account)
	if err != nil {
		return nil, err
	}
	view.EndpointShares, _ = recon.EndpointShares(snap, evs, s.Pricing, labels)
	return view, nil
}

func (s *Server) endpointLabels(account string) (map[string]string, error) {
	eps, err := s.Store.ListEndpoints(account)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(eps))
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		out[e.ID] = label
	}
	return out, nil
}

// --- HTTP handlers -------------------------------------------------------

func (s *Server) handleAccounts(w http.ResponseWriter, r *http.Request) {
	accts, err := s.Store.ListAccounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if accts == nil {
		accts = []store.Account{}
	}
	writeJSON(w, http.StatusOK, accts)
}

func (s *Server) handleLimits(w http.ResponseWriter, r *http.Request) {
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	view, err := s.LimitsFor(account)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s *Server) handleEndpoints(w http.ResponseWriter, r *http.Request) {
	eps, err := s.Store.ListEndpoints(r.URL.Query().Get("account"))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if eps == nil {
		eps = []store.Endpoint{}
	}
	writeJSON(w, http.StatusOK, eps)
}

func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()

	dim := store.Dimension(q.Get("by"))
	if dim == "" {
		dim = store.ByEndpoint
	}
	start, end := timeRange(q.Get("since"), q.Get("until"))
	limit, _ := strconv.Atoi(q.Get("limit"))

	buckets, err := s.Store.UsageBy(account, dim, start, end, limit)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if buckets == nil {
		buckets = []store.Bucket{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": account,
		"by":           string(dim),
		"since":        start,
		"until":        end,
		"buckets":      buckets,
		"disclaimer":   shareDisclaimer,
	})
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()

	g := store.Granularity(q.Get("granularity"))
	if g == "" {
		g = store.Daily
	}
	start, end := timeRange(q.Get("since"), q.Get("until"))

	series, err := s.Store.History(account, g, start, end)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	models, err := s.Store.ModelSplit(account, start, end)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if series == nil {
		series = []store.Bucket{}
	}
	if models == nil {
		models = []store.Bucket{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": account,
		"granularity":  string(g),
		"since":        start,
		"until":        end,
		"series":       series,
		"by_model":     models,
	})
}

func (s *Server) handleSwitches(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	sw, err := s.Store.AccountSwitches(limit)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if sw == nil {
		sw = []store.AccountSwitch{}
	}
	writeJSON(w, http.StatusOK, sw)
}

// requireAccount resolves the ?account= parameter.
//
// When the hub holds exactly one subscription it is inferred, which keeps the
// single-user case frictionless. With several, an explicit choice is required:
// silently picking one would show a number the caller did not ask for and has
// no way to notice is the wrong account.
func (s *Server) requireAccount(w http.ResponseWriter, r *http.Request) (string, bool) {
	if a := r.URL.Query().Get("account"); a != "" {
		return a, true
	}
	accts, err := s.Store.ListAccounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return "", false
	}
	switch len(accts) {
	case 0:
		httpError(w, http.StatusNotFound, "no subscriptions have reported to this hub yet")
		return "", false
	case 1:
		return accts[0].AccountUUID, true
	default:
		httpError(w, http.StatusBadRequest,
			"this hub holds several subscriptions; pass ?account=<uuid> (see /v1/accounts)")
		return "", false
	}
}

// defaultRange is how far back a query looks when not told otherwise.
const defaultRange = 7 * 24 * time.Hour

// timeRange parses since/until, accepting RFC3339 or a relative "7d"/"24h".
func timeRange(since, until string) (time.Time, time.Time) {
	now := time.Now().UTC()
	end := now
	if t, ok := parseWhen(until, now); ok {
		end = t
	}
	start := end.Add(-defaultRange)
	if t, ok := parseWhen(since, now); ok {
		start = t
	}
	if !start.Before(end) {
		start = end.Add(-defaultRange)
	}
	return start, end
}

func parseWhen(s string, now time.Time) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), true
	}
	// "7d" and "24h" are what a human types; treat both as "ago".
	if d, err := parseDuration(s); err == nil {
		return now.Add(-d), true
	}
	return time.Time{}, false
}

func parseDuration(s string) (time.Duration, error) {
	if n := len(s); n > 1 && s[n-1] == 'd' {
		days, err := strconv.Atoi(s[:n-1])
		if err != nil {
			return 0, err
		}
		return time.Duration(days) * 24 * time.Hour, nil
	}
	return time.ParseDuration(s)
}
