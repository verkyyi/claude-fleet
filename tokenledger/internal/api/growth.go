// internal/api/growth.go
package api

import (
	"bytes"
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/badge"
	"github.com/verkyyi/ccquota/internal/i18n"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

// maxGrowthBody caps one business-facts push. The whole contract is a handful
// of integers; a megabyte is four orders of magnitude of headroom and still
// refuses a runaway shipper.
const maxGrowthBody = 1 << 20

// handleGrowthIngest accepts one day of the business ledger.
//
// Deliberately shaped like handleRepoIngest, down to the vague 401: a shipper
// is a cron job with a credential and no identity, so it authenticates on its
// own enrollment token and nothing in the body is trusted to say who it is.
// What it must NOT share is the token itself — one shipper, one token, because
// a token shared between the gateway, the billing job and this one makes
// revoking any of them a way to stop all of them.
func (s *Server) handleGrowthIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		// Same deliberate vagueness as /v1/ingest and /v1/ingest/repo:
		// distinguishing "unknown token" from "known token, other failure"
		// tells a prober which guesses were close.
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}

	var snap model.GrowthSnapshot
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxGrowthBody))
	if err := dec.Decode(&snap); err != nil {
		httpError(w, http.StatusBadRequest, "malformed snapshot: "+err.Error())
		return
	}
	now := time.Now()
	// A 400, not a 500: everything Validate rejects is a shipper bug the
	// shipper can fix, and these are revenue figures — refusing half a
	// document is the whole point, because the half that got stored would be
	// read aloud as if it were the document.
	if err := snap.Validate(now); err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := s.Store.UpsertGrowthFacts(snap, now.UTC()); err != nil {
		log.Printf("growth ingest from %s: %v", ep.ID, err)
		httpError(w, http.StatusInternalServerError, "could not store snapshot")
		return
	}
	// This token is a nightly business-facts job, not an agent. Saying so is
	// what keeps the fleet roster and the stale-agent finding from spending
	// forever reporting a machine that will never push usage.
	//
	// After the write and non-fatal, for the reason the repo path gives: the
	// facts are already stored, and failing the push over a label would turn a
	// cosmetic problem into a lost day.
	if err := s.Store.MarkGrowthShipper(ep.ID); err != nil {
		log.Printf("mark growth shipper %s: %v", ep.ID, err)
	}
	writeJSON(w, http.StatusOK, map[string]any{"source": snap.Source, "day": snap.Day})
}

// serveGrowthPage renders the board at /growth.
//
// Server-rendered, which every other human surface on this hub is not, and for
// one reason: this page is a PROJECTION of a handful of stored figures with no
// question to ask of it — no scope, no brush, no picker. The dashboard is an
// explorer and earns its module set; a ledger that says one day's numbers does
// not, and rendering it here means the staleness rule below is decided once,
// in Go, where a test can read the answer in the bytes that go out rather than
// in a browser nobody runs in CI.
//
// It sits behind viewerOnly like every other human surface: revenue figures
// are the most sensitive thing this binary holds, and the design's own posture
// test for this hub is "open the board with no credential → 401".
func (s *Server) serveGrowthPage(w http.ResponseWriter, r *http.Request) {
	if p := strings.TrimSuffix(r.URL.Path, "/"); p != "/growth" {
		http.NotFound(w, r)
		return
	}
	row, err := s.Store.LatestGrowth()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	v := growthViewOf(row, growthLocale(r), time.Now())
	// Rendered whole before anything is written: a template that failed
	// halfway would otherwise leave a 200 holding half a board of figures.
	var buf bytes.Buffer
	if err := growthTmpl.Execute(&buf, v); err != nil {
		log.Printf("render /growth: %v", err)
		httpError(w, http.StatusInternalServerError, "could not render the board")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// Same reasoning as the embedded dashboard: one binary, no cache-busting
	// path, so a cached copy would outlive a release that fixed a figure.
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(buf.Bytes())
}

// growthLocale resolves the language this board is drawn in.
//
// Chinese is the BASE here rather than the fallback, which is the one place
// this hub departs from i18n.FromRequest. The readers are one named WeCom staff
// list, every term on the page is a Chinese business term, and the board is
// reached by typing /growth — often with no Accept-Language worth the name. An
// English default would mean the people this page exists for get the
// translation. Anyone who asks for English, by header or by ?locale=en, still
// gets it.
func growthLocale(r *http.Request) string {
	if v := r.URL.Query().Get("locale"); v != "" {
		return i18n.Normalize(v)
	}
	if h := r.Header.Get("Accept-Language"); strings.TrimSpace(h) != "" {
		return i18n.FromAcceptLanguage(h)
	}
	return i18n.ZhCN
}

// growthStat is one label/value pair on the board.
type growthStat struct{ Label, Value string }

// growthView is the finished page: every field is already a string in the
// reader's language.
//
// The template is deliberately dumb — no arithmetic, no formatting, no
// staleness test — because the staleness rule is the one piece of logic on
// this page that can print a falsehood, and it belongs where a unit test can
// reach it rather than inside a template's {{if}}.
type growthView struct {
	Lang  string
	Title string
	Empty bool

	EmptyTitle, EmptyHint string

	DayLabel, Day           string
	SourceLabel, Source     string
	ReceivedLabel, Received string

	H5Title string
	H5      []growthStat

	AITitle, AIHint string
	AI              []growthStat
	// AIStale suppresses the figures above and prints AIStaleLine instead.
	AIStale                              bool
	AIStaleLine, AIStaleWhy, AILastFiled string
	AIUpdatedLine                        string

	OKRTitle string
	OKR      []growthStat

	BackLabel string
}

// growthViewOf turns the stored row into the finished page.
//
// The rule that matters is the AI half. Those three figures are typed in by a
// person, and when nobody has typed for longer than model.AIStaleAfter they
// stop being facts about the business and become facts about somebody's
// calendar. So they leave the value slots entirely and the board says how long
// it has been instead — the last filing is still shown, but dated and named as
// a filing, which is the difference between reporting a number and printing it
// as today's.
func growthViewOf(row *store.GrowthRow, locale string, now time.Time) growthView {
	v := growthView{
		Lang:      htmlLang(locale),
		Title:     gt("title", locale, nil),
		BackLabel: gt("back", locale, nil),
	}
	if row == nil {
		v.Empty = true
		v.EmptyTitle = gt("empty.title", locale, nil)
		v.EmptyHint = gt("empty.hint", locale, nil)
		return v
	}

	v.DayLabel, v.Day = gt("meta.day", locale, nil), row.Day
	v.SourceLabel, v.Source = gt("meta.source", locale, nil), row.Source
	v.ReceivedLabel, v.Received = gt("meta.received", locale, nil), growthWhen(row.ReceivedAt)

	v.H5Title = gt("h5.title", locale, nil)
	v.H5 = []growthStat{
		{gt("h5.arr", locale, nil), cny(row.H5.ARRCNY)},
		{gt("h5.expiring", locale, nil), cny(row.H5.ExpiringInWindowCNY)},
		{gt("h5.expiringAccounts", locale, nil), badge.GroupDigits(int64(row.H5.ExpiringAccounts))},
		{gt("h5.churned", locale, nil), badge.GroupDigits(int64(row.H5.ChurnedAccounts))},
		{gt("h5.active", locale, nil), badge.GroupDigits(int64(row.H5.ActiveAccounts))},
	}

	v.OKRTitle = gt("okr.title", locale, nil)
	v.AITitle = gt("ai.title", locale, nil)
	v.AIHint = gt("ai.hint", locale, nil)
	days := row.AI.DaysSinceUpdate(now)
	if row.AI.Stale(now) {
		v.AIStale = true
		v.AIStaleLine = gt("ai.stale", locale, map[string]string{"days": strconv.Itoa(days)})
		v.AIStaleWhy = gt("ai.staleWhy", locale, map[string]string{
			"limit": strconv.Itoa(int(model.AIStaleAfter / (24 * time.Hour))),
		})
		v.AILastFiled = gt("ai.lastFiled", locale, map[string]string{
			"when":   growthWhen(row.AI.UpdatedAt),
			"signed": badge.GroupDigits(int64(row.AI.SignedDeals)),
			"leads":  badge.GroupDigits(int64(row.AI.QualifiedLeads)),
			"arr":    cny(row.AI.ARRCNY),
		})
		v.OKR = okrStats(row.OKR, locale)
		return v
	}
	v.AI = []growthStat{
		{gt("ai.signed", locale, nil), badge.GroupDigits(int64(row.AI.SignedDeals))},
		{gt("ai.leads", locale, nil), badge.GroupDigits(int64(row.AI.QualifiedLeads))},
		{gt("ai.arr", locale, nil), cny(row.AI.ARRCNY)},
	}
	v.AIUpdatedLine = gt("ai.updated", locale, map[string]string{
		"when": growthWhen(row.AI.UpdatedAt),
	})
	v.OKR = okrStats(row.OKR, locale)
	return v
}

// okrStats is the target line, drawn the same whether or not the hand-filled
// half went stale: the goal does not change because nobody updated a figure.
func okrStats(okr model.GrowthOKR, locale string) []growthStat {
	return []growthStat{
		{gt("okr.focus", locale, nil), okr.Focus},
		{gt("okr.quarter", locale, nil), okr.Quarter},
		{gt("okr.target", locale, nil), cny(okr.TargetAnnualized)},
		{gt("okr.killSwitch", locale, nil), killSwitch(okr.DaysToKillSwitch, locale)},
	}
}

// killSwitch words the countdown, including after it has run out. A board that
// clamped this at zero would hide exactly the week somebody needs to see.
func killSwitch(days int, locale string) string {
	if days < 0 {
		return gt("okr.killSwitch.past", locale, map[string]string{"days": strconv.Itoa(-days)})
	}
	return gt("okr.killSwitch.left", locale, map[string]string{"days": strconv.Itoa(days)})
}

// cny renders whole yuan with thousands separators, sharing the badge's
// grouping so one hub never prints a figure two ways.
func cny(n int64) string { return "¥" + badge.GroupDigits(n) }

func growthWhen(t time.Time) string { return t.UTC().Format("2006-01-02 15:04 UTC") }

func htmlLang(locale string) string {
	if i18n.Normalize(locale) == i18n.ZhCN {
		return "zh-CN"
	}
	return "en"
}

var growthTmpl = template.Must(template.New("growth").Parse(`<!doctype html>
<html lang="{{.Lang}}" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{{.Title}}</title>
<!-- The dashboard's own stylesheet, served from this same gated origin: the
     board is a third view of one internal ledger, not a second product, and
     it should not have a palette of its own. A build without the dashboard
     404s it and the page degrades to unstyled and still readable. -->
<link rel="stylesheet" href="/styles.css">
<style>
  .kpis.growth { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }
  .growth-meta { color: var(--ink-3); font-size: 12.5px; display: flex; gap: 16px; flex-wrap: wrap; margin-top: 6px; }
  .growth-stale { border-left: 3px solid var(--warning); padding: 10px 14px; background: var(--surface); border-radius: 0 8px 8px 0; }
  .growth-stale .v { font-size: 20px; font-weight: 600; }
  .growth-filed { color: var(--ink-3); font-size: 12.5px; margin: 10px 0 0; }
</style>
</head>
<body>
<div class="wrap">
  <header class="scope"><div class="row1"><h1>{{.Title}}</h1></div></header>
{{if .Empty}}
  <div class="card">
    <div class="empty">{{.EmptyTitle}}</div>
    <p class="hint">{{.EmptyHint}}</p>
  </div>
{{else}}
  <div class="growth-meta">
    <span>{{.DayLabel}} {{.Day}}</span>
    <span>{{.SourceLabel}} {{.Source}}</span>
    <span>{{.ReceivedLabel}} {{.Received}}</span>
  </div>

  <div class="card" id="growth-h5">
    <h2>{{.H5Title}}</h2>
    <div class="kpis growth">
      {{range .H5}}<div class="kpi"><div class="v">{{.Value}}</div><div class="l">{{.Label}}</div></div>{{end}}
    </div>
  </div>

  <div class="card" id="growth-ai">
    <h2>{{.AITitle}}</h2>
    <p class="hint">{{.AIHint}}</p>
{{if .AIStale}}
    <div class="growth-stale">
      <div class="v">{{.AIStaleLine}}</div>
      <div class="l">{{.AIStaleWhy}}</div>
    </div>
    <p class="growth-filed">{{.AILastFiled}}</p>
{{else}}
    <div class="kpis growth">
      {{range .AI}}<div class="kpi"><div class="v">{{.Value}}</div><div class="l">{{.Label}}</div></div>{{end}}
    </div>
    <p class="growth-filed">{{.AIUpdatedLine}}</p>
{{end}}
  </div>

  <div class="card" id="growth-okr">
    <h2>{{.OKRTitle}}</h2>
    <div class="kpis growth">
      {{range .OKR}}<div class="kpi"><div class="v">{{.Value}}</div><div class="l">{{.Label}}</div></div>{{end}}
    </div>
  </div>
{{end}}
  <footer><p class="hint"><a href="/">{{.BackLabel}}</a></p></footer>
</div>
</body>
</html>
`))
