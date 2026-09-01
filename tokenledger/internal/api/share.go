package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// The public view is a SEPARATE DOCUMENT, not the dashboard with fields hidden.
//
// Redacting a rich payload is a losing game: every field added later is exposed
// by default, and one forgotten `cwd` publishes a client's name. So the share
// token is accepted on these routes ONLY, and these routes build their own
// object from scratch. A field cannot leak into it by being forgotten — it can
// only appear by being written here on purpose.
//
// What is deliberately absent, and why:
//   - account emails and uuids   → who you are, and who you work for
//   - project paths (cwd)        → client names, unreleased product names
//   - machine names, OS logins   → your infrastructure and your colleagues
//   - session ids, git branches  → what you were doing and when
//
// What remains is shape: how much, over time, split by model, across how many
// of things — enough for "here is what running a fleet actually costs", which
// is the honest reason to show anyone this.

// ShareScale is the size of the operation as COUNTS. "Six machines" is
// interesting; their hostnames are nobody's business.
type ShareScale struct {
	Subscriptions int `json:"subscriptions"`
	Machines      int `json:"machines"`
	Logins        int `json:"logins"`
	Projects      int `json:"projects"`
	Sessions      int `json:"sessions"`
}

// ShareSubscription is one plan, pseudonymously. Utilization is a percentage of
// an allowance nobody outside can size, so it reveals nothing on its own.
type ShareSubscription struct {
	Name        string  `json:"name"` // "Subscription A"
	Plan        string  `json:"plan,omitempty"`
	FiveHourPct float64 `json:"five_hour_pct"`
	SevenDayPct float64 `json:"seven_day_pct"`
	Available   bool    `json:"available"`
}

// ShareView is everything the public page can ever see.
type ShareView struct {
	Title       string    `json:"title"`
	GeneratedAt time.Time `json:"generated_at"`
	SinceDays   int       `json:"since_days"`

	Scale         ShareScale          `json:"scale"`
	Subscriptions []ShareSubscription `json:"subscriptions"`

	Turns  int64 `json:"turns"`
	Tokens int64 `json:"tokens"`

	// CostUSD is present only when the link was minted with --with-costs, and
	// is notional either way. A dollar figure shown to someone who does not
	// know that reads as a bill.
	ShowCosts bool     `json:"show_costs"`
	CostUSD   *float64 `json:"cost_usd,omitempty"`

	History    []store.Bucket `json:"history"`
	ModelSplit []store.Bucket `json:"model_split"`

	Disclaimer string `json:"disclaimer"`
}

const publicDisclaimer = "Utilization percentages come from Anthropic and cover every device on " +
	"the plan. Token counts are measured. Any cost shown is NOTIONAL — what the same tokens " +
	"would cost at pay-as-you-go API rates — and is not an amount anyone was billed."

// shareOnly gates a handler behind a share link OR the operator's own viewer
// token (so the owner can preview exactly what a recipient sees).
//
// Mounted on the share routes only. The share token is never accepted anywhere
// else — that is the containment, and it is structural rather than a matter of
// remembering to filter.
func (s *Server) shareOnly(next func(http.ResponseWriter, *http.Request, *store.ShareLink)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := bearer(r)
		if tok == "" {
			tok = r.URL.Query().Get("token")
		}
		if tok == "" {
			if c, err := r.Cookie("ccquota_share"); err == nil {
				tok = c.Value
			}
		}
		if tok == "" {
			httpError(w, http.StatusUnauthorized, "a share link is required")
			return
		}

		// The owner previewing their own page.
		if s.ViewerToken != "" && constantTimeEqual(tok, s.ViewerToken) {
			next(w, r, &store.ShareLink{ID: "preview", Label: "operator preview", ShowCosts: true})
			return
		}

		link, err := s.Store.ShareLinkByToken(HashToken(tok))
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if link == nil {
			// Deliberately the same answer for unknown, revoked and expired: a
			// former recipient probing the link learns nothing about why.
			httpError(w, http.StatusUnauthorized, "this share link is not valid")
			return
		}
		// Move the secret out of the URL bar, as the dashboard does.
		if r.URL.Query().Get("token") != "" {
			http.SetCookie(w, &http.Cookie{
				// Path "/" rather than "/share": the page is served from
				// /share but fetches its data from /v1/share, and a cookie
				// scoped to the page's own path is never sent to the second.
				// Widening it is safe — this value is only ever accepted by
				// shareOnly, and the dashboard's cookie has a different name.
				Name: "ccquota_share", Value: tok, Path: "/",
				HttpOnly: true, SameSite: http.SameSiteLaxMode,
				Secure: r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
				MaxAge: 7 * 24 * 3600,
			})
			http.Redirect(w, r, stripToken(r), http.StatusFound)
			return
		}
		next(w, r, link)
	})
}

func (s *Server) handleShareData(w http.ResponseWriter, r *http.Request, link *store.ShareLink) {
	days := 30
	if d, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && d > 0 && d <= 365 {
		days = d
	}
	view, err := s.BuildShareView(link, days)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// A cached share page is a share page that outlives its revocation.
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, view)
}

// BuildShareView assembles the redacted document.
func (s *Server) BuildShareView(link *store.ShareLink, days int) (*ShareView, error) {
	end := time.Now().UTC()
	start := end.AddDate(0, 0, -days)

	v := &ShareView{
		Title:       link.Label,
		GeneratedAt: end,
		SinceDays:   days,
		ShowCosts:   link.ShowCosts,
		Disclaimer:  publicDisclaimer,
	}
	if v.Title == "" {
		v.Title = "Claude Code usage"
	}

	accts, err := s.Store.ListAccounts()
	if err != nil {
		return nil, err
	}
	v.Scale.Subscriptions = len(accts)

	for i, a := range accts {
		sub := ShareSubscription{Name: subscriptionAlias(i), Plan: a.SubscriptionType}
		if lv, err := s.LimitsFor(a.AccountUUID); err == nil && lv.Available {
			sub.Available = true
			if lv.FiveHour != nil {
				sub.FiveHourPct = lv.FiveHour.Utilization
			}
			if lv.SevenDay != nil {
				sub.SevenDayPct = lv.SevenDay.Utilization
			}
		}
		v.Subscriptions = append(v.Subscriptions, sub)
	}

	// Counts, never names. Each of these dimensions is an identifier set; the
	// only safe projection of it is its size.
	for dim, into := range map[store.Dimension]*int{
		store.ByEndpoint: &v.Scale.Machines,
		store.ByUser:     &v.Scale.Logins,
		store.ByProject:  &v.Scale.Projects,
		store.BySession:  &v.Scale.Sessions,
	} {
		b, err := s.Store.UsageBy(store.AllAccounts, dim, start, end, 100000)
		if err != nil {
			return nil, err
		}
		*into = len(b)
	}

	// Totals, from a dimension whose KEYS are discarded.
	totals, err := s.Store.UsageBy(store.AllAccounts, store.ByAccount, start, end, 1000)
	if err != nil {
		return nil, err
	}
	var cost float64
	for _, b := range totals {
		v.Turns += b.Events
		v.Tokens += b.Tokens
		cost += b.CostUSD
	}
	if link.ShowCosts {
		v.CostUSD = &cost
	}

	g := store.Daily
	if days <= 2 {
		g = store.Hourly
	}
	if v.History, err = s.Store.History(store.AllAccounts, g, start, end); err != nil {
		return nil, err
	}
	if v.ModelSplit, err = s.Store.ModelSplit(store.AllAccounts, start, end); err != nil {
		return nil, err
	}
	// Model names are Anthropic's product names, but a bucket's LABEL is filled
	// in elsewhere from account and endpoint tables; clear it so no labelling
	// change upstream can quietly start publishing one.
	for i := range v.ModelSplit {
		v.ModelSplit[i].Label = ""
	}
	for i := range v.History {
		v.History[i].Label = ""
	}
	return v, nil
}

// subscriptionAlias names plans by position: "Subscription A", "B", ...
func subscriptionAlias(i int) string {
	if i < 26 {
		return "Subscription " + string(rune('A'+i))
	}
	return "Subscription " + string(rune('A'+i/26-1)) + string(rune('A'+i%26))
}

// serveSharePage serves the public page. It is a different file from the
// dashboard, embedded separately, so a change to the dashboard cannot alter
// what a share recipient sees.
func (s *Server) serveSharePage(w http.ResponseWriter, r *http.Request, _ *store.ShareLink) {
	if s.UI == nil {
		httpError(w, http.StatusNotFound, "this binary was built without the UI")
		return
	}
	f, err := s.UI.Open("share.html")
	if err != nil {
		httpError(w, http.StatusNotFound, "no public page in this build")
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	rs, ok := f.(interface {
		Read([]byte) (int, error)
		Seek(int64, int) (int64, error)
	})
	if !ok {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.ServeContent(w, r, "share.html", st.ModTime(), rs)
}
