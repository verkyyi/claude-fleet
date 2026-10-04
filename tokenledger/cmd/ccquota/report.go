package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/verkyyi/ccquota/internal/identity"
	"github.com/verkyyi/ccquota/internal/limits"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/scan"
)

// runReport produces a local report with no hub and, unless asked, no network.
//
// It exists first and standalone on purpose: if the transcript parser is
// wrong, every number the hub and dashboard show is confidently wrong. This is
// the command you point at a real machine to check that.
func runReport(args []string) error {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	home := fs.String("home", "", "user home directory (default: your home)")
	sourcesFlag := fs.String("sources", os.Getenv("CCQUOTA_SOURCES"), "usage sources: all (default), claude, codex, or claude,codex")
	codexHome := fs.String("codex-home", "", "Codex data directory (default: CODEX_HOME or <home>/.codex)")
	days := fs.Int("days", 7, "how many days back to report")
	asJSON := fs.Bool("json", false, "emit JSON instead of a table")
	noLimits := fs.Bool("no-limits", false, "skip the account-wide limits lookup (no network at all)")
	pricingFile := fs.String("pricing", "", "path to a pricing override file")
	top := fs.Int("top", 10, "how many rows in each breakdown")
	if err := fs.Parse(args); err != nil {
		return err
	}

	h, err := homeDir(*home)
	if err != nil {
		return err
	}

	sources, err := scan.ParseSources(*sourcesFlag)
	if err != nil {
		return err
	}
	id := identity.Local()
	var warnings []string
	var claudeLogin bool

	// A one-shot report must not disturb a running agent's position, so the
	// cursor lives in a scratch file that is discarded afterwards.
	cursorDir, err := os.MkdirTemp("", "ccquota-report-*")
	if err != nil {
		return fmt.Errorf("create scratch cursor: %w", err)
	}
	defer os.RemoveAll(cursorDir)
	var evs []model.UsageEvent
	for _, source := range sources {
		var sc *scan.Scanner
		switch source {
		case model.SourceClaude:
			if detected, err := identity.Detect(h); err == nil {
				id, claudeLogin = detected, true
			} else if !errors.Is(err, os.ErrNotExist) {
				warnings = append(warnings, err.Error())
			}
			sc = scan.NewScanner(identity.ProjectsDir(h), filepath.Join(cursorDir, "claude.json"))
		case model.SourceCodex:
			sc = scan.NewCodexScanner(scan.CodexHome(h, *codexHome), filepath.Join(cursorDir, "codex.json"))
		}
		events, err := sc.Scan()
		if err != nil {
			return err
		}
		evs = append(evs, events...)
		for _, warning := range sc.Errs {
			warnings = append(warnings, warning.Error())
		}
	}

	table := pricing.Default()
	if *pricingFile != "" {
		if err := table.LoadOverrides(*pricingFile); err != nil {
			return err
		}
	}
	table.Apply(evs)

	since := time.Now().AddDate(0, 0, -*days).UTC()
	evs = filterSince(evs, since)

	rep := buildReport(id, evs, table, since, *top)

	rep.Sources = sources
	rep.ScanWarnings = warnings
	if !*noLimits && claudeLogin {
		rep.Limits, rep.LimitsUnavailable = fetchLimits(h)
	} else if *noLimits {
		rep.LimitsUnavailable = "skipped (--no-limits)"
	} else {
		rep.LimitsUnavailable = "Claude limits require a Claude login; Codex collection reports tokens only"
	}

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(rep)
	}
	return rep.writeText(os.Stdout)
}

// fetchLimits reads the true account-wide numbers, degrading to an explanation
// rather than a zero.
func fetchLimits(home string) (*model.LimitsSnapshot, string) {
	creds, err := identity.LoadCredentials(home)
	if err != nil {
		if errors.Is(err, identity.ErrTokenExpired) {
			return nil, "Claude Code's OAuth token has expired; it refreshes on its own next time Claude Code runs"
		}
		return nil, "no readable credentials on this machine: " + err.Error()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	snap, err := limits.New().Fetch(ctx, creds.AccessToken)
	if err != nil {
		return nil, err.Error()
	}
	return snap, ""
}

func filterSince(evs []model.UsageEvent, since time.Time) []model.UsageEvent {
	out := evs[:0]
	for _, e := range evs {
		if !e.TS.Before(since) {
			out = append(out, e)
		}
	}
	return out
}

// costs is one row's money, kept apart by kind.
//
// This report groups by model, project and day -- axes that cut ACROSS sources
// -- so a single cost field here would blend an API-equivalent estimate with a
// real per-call charge the first time a machine runs both. Two named fields
// cost nothing and cannot be added by accident; see model.CostKind.
type costs struct {
	Notional     float64 `json:"notional_usd"`
	Billed       float64 `json:"billed_usd"`
	Unclassified float64 `json:"unclassified_usd,omitempty"`
}

func (c *costs) add(e *model.UsageEvent) {
	if e.CostUSD == nil {
		return
	}
	switch model.CostKind(e.Source) {
	case model.CostNotional:
		c.Notional += *e.CostUSD
	case model.CostBilled:
		c.Billed += *e.CostUSD
	default:
		c.Unclassified += *e.CostUSD
	}
}

// text renders the row for a human. Billed money is named as such and only
// shown when there is some -- a machine running Claude alone should not have
// to read a column of zeroes to find its one figure.
func (c costs) text() string {
	out := fmt.Sprintf("$%.2f notional", c.Notional)
	if c.Billed != 0 {
		out += fmt.Sprintf(" + $%.2f billed", c.Billed)
	}
	if c.Unclassified != 0 {
		out += fmt.Sprintf(" + $%.2f unclassified", c.Unclassified)
	}
	return out
}

// bucket accumulates one breakdown row.
type bucket struct {
	Key       string  `json:"key"`
	Events    int     `json:"events"`
	Tokens    int64   `json:"tokens"`
	Cost      costs   `json:"cost"`
	Unpriced  int     `json:"unpriced_events"`
	SortValue float64 `json:"-"`
}

type report struct {
	Sources      []string        `json:"sources"`
	BySource     []bucket        `json:"by_source"`
	Identity     *model.Identity `json:"identity"`
	Since        time.Time       `json:"since"`
	Events       int             `json:"events"`
	Tokens       int64           `json:"tokens"`
	Cost         costs           `json:"cost"`
	UnpricedRows int             `json:"unpriced_events"`

	// Pricing is one entry per source in this report, each with its own rate
	// date and note. It replaces a single rates_as_of, which could only ever
	// be right about one source and was printed beside figures from all of
	// them.
	Pricing []pricing.SourceProvenance `json:"pricing"`

	ByModel   []bucket `json:"by_model"`
	ByProject []bucket `json:"by_project"`
	ByDay     []bucket `json:"by_day"`

	SidechainTokens int64 `json:"sidechain_tokens"`

	Limits            *model.LimitsSnapshot `json:"limits"`
	LimitsUnavailable string                `json:"limits_unavailable,omitempty"`
	ScanWarnings      []string              `json:"scan_warnings,omitempty"`
}

func buildReport(id *model.Identity, evs []model.UsageEvent, table *pricing.Table, since time.Time, top int) *report {
	rep := &report{Identity: id, Since: since}

	byModel := map[string]*bucket{}
	bySource := map[string]*bucket{}
	byProject := map[string]*bucket{}
	byDay := map[string]*bucket{}

	add := func(m map[string]*bucket, key string, e *model.UsageEvent) {
		b := m[key]
		if b == nil {
			b = &bucket{Key: key}
			m[key] = b
		}
		b.Events++
		b.Tokens += e.TotalTokens()
		b.Cost.add(e)
		if e.CostUSD == nil {
			b.Unpriced++
		}
	}

	for i := range evs {
		e := &evs[i]
		rep.Events++
		rep.Tokens += e.TotalTokens()
		rep.Cost.add(e)
		if e.CostUSD == nil {
			rep.UnpricedRows++
		}
		if e.IsSidechain {
			rep.SidechainTokens += e.TotalTokens()
		}
		add(byModel, orUnknown(e.Model), e)
		add(bySource, model.UsageSource(e.Source), e)
		add(byProject, projectLabel(e.CWD), e)
		add(byDay, e.TS.Format("2006-01-02"), e)
	}

	rep.ByModel = rank(byModel, top)
	rep.BySource = rank(bySource, 0)
	for _, b := range rep.BySource {
		rep.Pricing = append(rep.Pricing, pricing.ProvenanceFor(b.Key))
	}
	rep.ByProject = rank(byProject, top)
	rep.ByDay = chronological(byDay)
	return rep
}

func orUnknown(s string) string {
	if s == "" {
		return "(unknown)"
	}
	return s
}

// projectLabel shortens a working directory to its last two path segments,
// which is enough to tell projects apart without leaking a full home path into
// a shared dashboard.
func projectLabel(cwd string) string {
	if cwd == "" {
		return "(unknown)"
	}
	cwd = filepath.ToSlash(cwd)
	parts := strings.Split(strings.Trim(cwd, "/"), "/")
	if len(parts) <= 2 {
		return cwd
	}
	return ".../" + strings.Join(parts[len(parts)-2:], "/")
}

func rank(m map[string]*bucket, top int) []bucket {
	out := make([]bucket, 0, len(m))
	for _, b := range m {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Tokens != out[j].Tokens {
			return out[i].Tokens > out[j].Tokens
		}
		return out[i].Key < out[j].Key
	})
	if top > 0 && len(out) > top {
		out = out[:top]
	}
	return out
}

func chronological(m map[string]*bucket) []bucket {
	out := make([]bucket, 0, len(m))
	for _, b := range m {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out
}

func (r *report) writeText(f *os.File) error {
	fmt.Fprintf(f, "ccquota report — local usage on %s (%s/%s) · sources: %s\n",
		r.Identity.Hostname, r.Identity.OS, r.Identity.Arch, strings.Join(r.Sources, ", "))
	fmt.Fprintf(f, "since %s · %d turns · %s tokens · ~%s\n\n",
		r.Since.Format("2006-01-02"), r.Events, humanInt(r.Tokens), r.Cost.text())

	r.writeLimits(f)

	writeBuckets(f, "By source", r.BySource)
	writeBuckets(f, "By model", r.ByModel)
	writeBuckets(f, "By project", r.ByProject)
	writeBuckets(f, "By day", r.ByDay)

	if r.SidechainTokens > 0 {
		pct := float64(r.SidechainTokens) / float64(r.Tokens) * 100
		fmt.Fprintf(f, "Subagents accounted for %s tokens (%.0f%%).\n\n", humanInt(r.SidechainTokens), pct)
	}
	if r.UnpricedRows > 0 {
		fmt.Fprintf(f, "%d turns ran on models with no rate on file, so they are excluded from the cost.\n",
			r.UnpricedRows)
	}
	for _, p := range r.Pricing {
		fmt.Fprintf(f, "%s\n", p.Note)
	}

	if n := len(r.ScanWarnings); n > 0 {
		fmt.Fprintf(f, "\n%d transcript(s) could not be fully read:\n", n)
		for i, w := range r.ScanWarnings {
			if i == 5 {
				fmt.Fprintf(f, "  ... and %d more\n", n-5)
				break
			}
			fmt.Fprintf(f, "  %s\n", w)
		}
	}
	return nil
}

func (r *report) writeLimits(f *os.File) {
	if r.Limits == nil {
		// Never print a percentage we do not have. An absent gauge with a
		// reason is honest; a 0%% would not be.
		fmt.Fprintf(f, "Claude account-wide limits: unavailable — %s\n\n", r.LimitsUnavailable)
		return
	}
	fmt.Fprintf(f, "Claude account-wide limits (exact, all devices):\n")
	fmt.Fprintf(f, "  5-hour  %s  %s\n", gauge(r.Limits.FiveHour.Utilization), resetIn(r.Limits.FiveHour.ResetsAt))
	fmt.Fprintf(f, "  7-day   %s  %s\n", gauge(r.Limits.SevenDay.Utilization), resetIn(r.Limits.SevenDay.ResetsAt))
	for _, s := range r.Limits.Scoped {
		label := s.Model
		if label == "" {
			label = s.Kind
		}
		fmt.Fprintf(f, "  %-7s %s  %s\n", label, gauge(s.Utilization), resetIn(s.ResetsAt))
	}
	fmt.Fprintln(f)
}

// gauge renders a percentage as a bar so the shape carries the signal and
// colour is never load-bearing.
func gauge(pct float64) string {
	const width = 20
	filled := int(pct / 100 * width)
	if filled > width {
		filled = width
	}
	if filled < 0 {
		filled = 0
	}
	return fmt.Sprintf("[%s%s] %5.1f%%",
		strings.Repeat("#", filled), strings.Repeat(".", width-filled), pct)
}

func resetIn(t *time.Time) string {
	if t == nil {
		return "reset time unknown"
	}
	d := time.Until(*t)
	if d < 0 {
		return "resetting now"
	}
	if d < time.Hour {
		return fmt.Sprintf("resets in %dm", int(d.Minutes()))
	}
	if d < 24*time.Hour {
		return fmt.Sprintf("resets in %dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("resets in %dd%dh", int(d.Hours())/24, int(d.Hours())%24)
}

func writeBuckets(f *os.File, title string, bs []bucket) {
	if len(bs) == 0 {
		return
	}
	fmt.Fprintf(f, "%s\n", title)
	w := tabwriter.NewWriter(f, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "  \tturns\ttokens\tcost")
	for _, b := range bs {
		cost := b.Cost.text()
		if b.Unpriced > 0 {
			cost += fmt.Sprintf(" (+%d unpriced)", b.Unpriced)
		}
		fmt.Fprintf(w, "  %s\t%d\t%s\t%s\n", b.Key, b.Events, humanInt(b.Tokens), cost)
	}
	w.Flush()
	fmt.Fprintln(f)
}

func humanInt(n int64) string {
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.1fB", float64(n)/1e9)
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1e3)
	default:
		return fmt.Sprintf("%d", n)
	}
}
