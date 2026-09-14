package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/i18n"
	"github.com/verkyyi/ccquota/internal/model"
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
	Source      string               `json:"source,omitempty"`
	Plan        string               `json:"plan,omitempty"`
	Windows     []ProviderWindow     `json:"windows,omitempty"`
	Credits     []model.QuotaCredits `json:"credits,omitempty"`
	Blocked     bool                 `json:"blocked,omitempty"`
	AccountUUID string               `json:"account_uuid"`
	Available   bool                 `json:"available"`
	Reason      string               `json:"reason,omitempty"`

	// ReasonCode names WHICH reason, so the dashboard's handler can restate it
	// in the viewer's language without matching on the English sentence.
	// Unserialised for the same reason store.UnpricedReason.Code is: the wire
	// contract stays the prose.
	ReasonCode string `json:"-"`
	// ReasonEndpoint/ReasonDetail carry an endpoint's OWN reported reason, which
	// is relayed verbatim: only the frame around it is this hub's wording.
	ReasonEndpoint string `json:"-"`
	ReasonDetail   string `json:"-"`

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

type ProviderWindow struct {
	ObservedAt *time.Time `json:"observed_at,omitempty"`
	WindowView
	ID      string `json:"id"`
	Label   string `json:"label"`
	LimitID string `json:"limit_id"`
	Minutes int64  `json:"minutes,omitempty"`
}

func (v *LimitsView) HighestUtilization() float64 {
	if v.Blocked {
		return 100
	}
	var n float64
	if v.FiveHour != nil {
		n = v.FiveHour.Utilization
	}
	for _, w := range v.Windows {
		if w.Utilization > n {
			n = w.Utilization
		}
	}
	return n
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

// shareDisclaimer is what every internal surface carries next to its figures.
//
// It no longer says "costs are notional" flatly. That was true of every source
// this hub had until one started charging per call, and a blanket disclaimer
// that is wrong about one column is worse than none: it tells the reader an
// actual invoice is an estimate. Which kind a figure is now travels WITH the
// figure (pricing.SourceProvenance), and this line says so.
const shareDisclaimer = "The account-wide utilization is exact and already covers every device. " +
	"Per-endpoint shares are proportional estimates. Cost is reported per source and never summed " +
	"across them: Claude and Codex figures are notional API-equivalents, not a bill, while gateway " +
	"figures are actual per-call charges. Real spend is subscription plus gateway."

// LimitsAcross is the answer to "am I about to hit the wall" when more than one
// subscription is in view.
//
// It is a LIST, never a total. Two subscriptions at 4% and 19% are not 23% of
// anything — they are separate quota pools with separate resets, and adding
// them produces a number that means nothing while looking authoritative.
// Tokens and notional cost are additive; utilization is not, and the type
// enforces that rather than trusting a convention.
type LimitsAcross struct {
	// PerAccount holds one entry per subscription, each with its own exact
	// utilization. There is deliberately no aggregate field.
	PerAccount []AccountLimits `json:"per_account"`

	// Worst names the subscription closest to its limit — the only meaningful
	// single answer across several pools.
	Worst *AccountLimits `json:"worst,omitempty"`

	Note string `json:"note"`
}

// AccountLimits pairs a subscription with its own reading.
type AccountLimits struct {
	AccountUUID string      `json:"account_uuid"`
	Label       string      `json:"label"`
	Limits      *LimitsView `json:"limits"`
}

const acrossNote = "Utilization is per subscription and is never summed: separate quota pools " +
	"with separate resets. Tokens and notional costs are additive and may be compared across them."

// LimitsFor builds the view for one account.
func (s *Server) LimitsFor(account string) (*LimitsView, error) {
	source, err := s.Store.SourceForAccount(account)
	if err != nil {
		return nil, err
	}
	if source == model.SourceCodex {
		return s.codexLimitsFor(account)
	}
	view := &LimitsView{AccountUUID: account, Disclaimer: shareDisclaimer}

	snap, err := s.Store.LatestLimits(account)
	if err != nil {
		return nil, err
	}
	if snap == nil {
		source, err := s.Store.SourceForAccount(account)
		if err != nil {
			return nil, err
		}
		if source == model.SourceCodex {
			view.ReasonCode = ReasonCodexNoLimits
			view.Reason = LimitsReasonIn(view.ReasonCode, i18n.EN)
			return view, nil
		}
		ep, reason, err := s.Store.LimitsReason(account)
		if err != nil {
			return nil, err
		}
		if reason != "" {
			// The endpoint's own words, relayed. Only the frame around them is
			// ours to translate -- rewriting what an agent reported would be
			// putting words in its mouth.
			view.ReasonCode, view.ReasonDetail, view.ReasonEndpoint = ReasonEndpointReports, reason, ep
			view.Reason = endpointReports(ep, reason, i18n.EN)
		} else {
			view.ReasonCode = ReasonNoEndpointReading
			view.Reason = LimitsReasonIn(view.ReasonCode, i18n.EN)
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

// LimitsForAll builds one reading per subscription.
func (s *Server) LimitsForAll() (*LimitsAcross, error) {
	return s.LimitsForAllSource("")
}

func (s *Server) LimitsForAllSource(source string) (*LimitsAcross, error) {
	accts, err := s.Store.ListAccounts()
	if err != nil {
		return nil, err
	}
	out := &LimitsAcross{Note: acrossNote, PerAccount: []AccountLimits{}}
	for _, a := range accts {
		if source != "" && model.UsageSource(a.Source) != source {
			continue
		}
		v, err := s.LimitsFor(a.AccountUUID)
		if err != nil {
			return nil, err
		}
		entry := AccountLimits{AccountUUID: a.AccountUUID, Label: a.Label(), Limits: v}
		out.PerAccount = append(out.PerAccount, entry)

		// "Worst" compares readings we actually have; an unavailable one is
		// unknown, not zero, and must not win by default.
		if v.Available && (v.FiveHour != nil || len(v.Windows) > 0 || v.Blocked) {
			if out.Worst == nil || v.HighestUtilization() > out.Worst.Limits.HighestUtilization() {
				w := entry
				out.Worst = &w
			}
		}
	}
	return out, nil
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
	source, valid := querySource(w, r)
	if !valid {
		return
	}
	// Spanning subscriptions returns a different SHAPE — a list, not a total —
	// because utilization cannot be added up. Callers must handle both.
	loc := localeOf(r)
	if isAllAccounts(r.URL.Query().Get("account")) {
		across, err := s.LimitsForAllSource(source)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		across.Note = acrossNoteText.In(loc)
		for i := range across.PerAccount {
			localizeLimits(across.PerAccount[i].Limits, loc)
		}
		if across.Worst != nil {
			localizeLimits(across.Worst.Limits, loc)
		}
		writeJSON(w, http.StatusOK, across)
		return
	}
	account, ok := s.requireAccount(w, r)
	if !ok {
		return
	}
	view, err := s.LimitsForSource(account, source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	localizeLimits(view, loc)
	writeJSON(w, http.StatusOK, view)
}

// isAllAccounts recognises the ways a caller asks to span subscriptions.
func isAllAccounts(v string) bool {
	return v == store.AllAccounts || v == "all"
}

func (s *Server) handleEndpoints(w http.ResponseWriter, r *http.Request) {
	source, ok := querySource(w, r)
	if !ok {
		return
	}
	account := r.URL.Query().Get("account")
	if isAllAccounts(account) {
		account = ""
	}
	eps, err := s.Store.ListEndpoints(account, source)
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
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	dim := store.Dimension(q.Get("by"))
	if dim == "" {
		dim = store.ByEndpoint
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	buckets, err := s.Store.UsageByFiltered(f, dim, limit)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if wantsCompare(r) {
		prev, err := s.Store.UsageByFiltered(f.Prev(), dim, 500)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		byKey := map[string]store.Bucket{}
		for _, b := range prev {
			byKey[b.Key] = b
		}
		for i := range buckets {
			if p, ok := byKey[buckets[i].Key]; ok {
				buckets[i].PrevEvents, buckets[i].PrevTokens = p.Events, p.Tokens
				buckets[i].PrevCost = p.Cost
				buckets[i].PrevUnpriced = p.Unpriced
			}
		}
	}
	if buckets == nil {
		buckets = []store.Bucket{}
	}
	out := map[string]any{
		"account_uuid": f.Account,
		"all_accounts": f.Account == store.AllAccounts,
		"by":           string(dim),
		"since":        f.Start,
		"until":        f.End,
		"buckets":      buckets,
		"disclaimer":   shareDisclaimerText.In(localeOf(r)),
		"scope_note":   scopeNoteIn(f.Account, localeOf(r)),
	}
	// Two different absences share the empty provider bucket -- a source that
	// declares no upstream, and rows that predate the dimension. Naming them
	// beats leaving a blank row for the reader to guess at. Only attached when
	// there IS a blank row: an unconditional note reads as a caveat on figures
	// that have none.
	if dim == store.ByProvider {
		for _, b := range buckets {
			if b.Key == "" {
				out["provider_note"] = store.ProviderNoteIn(localeOf(r))
				break
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	f, ok := s.scope(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	g := q.Get("granularity")
	if g == "" {
		g = "day"
	}
	rows, err := s.Store.HourlyByModel(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	stack := q.Get("stack") == "model"
	top := topModels(rows, 6)
	series, err := FoldHours(rows, g, stack, top)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	models, err := s.Store.UsageByFiltered(f, store.ByModel, 50)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if series == nil {
		series = []Series{}
	}
	if models == nil {
		models = []store.Bucket{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account_uuid": f.Account,
		"all_accounts": f.Account == store.AllAccounts,
		"granularity":  g,
		"since":        f.Start,
		"until":        f.End,
		"series":       series,
		"by_model":     models,
		"stack_models": append(top, "other"),
		"scope_note":   scopeNoteIn(f.Account, localeOf(r)),
	})
}

// handleAccountLabel names a subscription for good.
//
// Fingerprinted subscriptions have no email to discover, so the operator's
// answer is the only source of a readable name — and it has to survive every
// later automatic report, or naming it would be a chore repeated forever.
func (s *Server) handleAccountLabel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	var body struct {
		Account string `json:"account"`
		Label   string `json:"label"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	if err := s.Store.SetAccountLabel(body.Account, strings.TrimSpace(body.Label)); err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account": body.Account, "label": body.Label, "locked": body.Label != "",
	})
}

// handleEndpointAccounts answers "which subscriptions is each machine running",
// which on a machine running several at once is a list, not a single value.
func (s *Server) handleEndpointAccounts(w http.ResponseWriter, r *http.Request) {
	source, ok := querySource(w, r)
	if !ok {
		return
	}
	account := r.URL.Query().Get("account")
	if isAllAccounts(account) {
		account = ""
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	eas, err := s.Store.EndpointAccounts(account, limit, source)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if eas == nil {
		eas = []store.EndpointAccount{}
	}
	writeJSON(w, http.StatusOK, eas)
}

func (s *Server) handleSwitches(w http.ResponseWriter, r *http.Request) {
	source, ok := querySource(w, r)
	if !ok {
		return
	}
	account := r.URL.Query().Get("account")
	if isAllAccounts(account) {
		account = ""
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	sw, err := s.Store.SourceSwitches(account, source, limit)
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
// A specific uuid scopes to one subscription; "all" spans every one. When the
// hub holds exactly one subscription it is inferred, which keeps the
// single-user case frictionless. With several and no choice made, spanning is
// the honest default — it shows everything and labels it as such, rather than
// silently picking one the caller has no way to notice is wrong.
func (s *Server) requireAccount(w http.ResponseWriter, r *http.Request) (string, bool) {
	if a := r.URL.Query().Get("account"); a != "" {
		if isAllAccounts(a) {
			return store.AllAccounts, true
		}
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
		// Everything, explicitly labelled. Refusing used to be the safe answer;
		// it turned the subscription into a mode the whole page was stuck in.
		return store.AllAccounts, true
	}
}

// scopeNote states what a figure spans, so a cross-subscription total is never
// mistaken for one subscription's.
func scopeNote(account string) string {
	if account == store.AllAccounts {
		return "Totals span every subscription on this hub. Tokens and notional costs are " +
			"additive; rate-limit utilization is not and is reported per subscription."
	}
	return ""
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
