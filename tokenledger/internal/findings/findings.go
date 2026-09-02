// Package findings turns query results into a short list of things worth a
// look. Every rule is a pure function with a fixed threshold; the API layer
// gathers the inputs. No rule fires on absence of data.
package findings

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

type Finding struct {
	Severity string            `json:"severity"` // critical | warning | info
	Kind     string            `json:"kind"`
	Title    string            `json:"title"`
	Detail   string            `json:"detail"`
	Scope    map[string]string `json:"scope,omitempty"` // chips to apply (hash param names)
	Link     string            `json:"link,omitempty"`  // an in-app anchor, e.g. "#sessions"
	weight   float64
}

type SessionStat struct {
	SessionID, CWD, Model string
	Tokens, Turns         int64
	Duration              time.Duration
}
type ModelStat struct {
	Model            string
	Tokens, Unpriced int64
}
type AccountCritical struct {
	Label                string
	Seconds, PrevSeconds int64
	Episodes             int
}
type ProjectStat struct {
	CWD                string
	Turns              int64
	CacheHit           float64
	Tokens, PrevTokens int64
}
type Inputs struct {
	Sessions               []SessionStat
	Models                 []ModelStat
	Critical               []AccountCritical
	SelectionSeconds       int64
	Projects, PrevProjects []ProjectStat
	Tokens, PrevTokens     int64

	// SessionTokenMedian is the median token count across every session in
	// the window with >= 2 turns -- the SAME population runaway() filters
	// Sessions to below, computed by the caller (typically a store query)
	// over the FULL population rather than derived from Sessions here.
	//
	// Sessions is deliberately allowed to be a bounded, tokens-descending
	// sample: a caller only needs enough of it to find candidates above the
	// threshold, and runaway() cannot tell a full population from a sample by
	// looking at it. Deriving the median from Sessions was exactly that
	// mistake -- correct only when Sessions happened to BE the full
	// population, and silently wrong by orders of magnitude once it was a
	// top-N sample, because the top N sessions by tokens are themselves
	// biased high and their OWN median is nowhere near the population's.
	//
	// Zero means "not supplied": runaway() then falls back to deriving the
	// median from Sessions, so a caller with the whole population already in
	// Sessions (every test fixture in this package, and any small enough
	// hub) needs no extra field and gets the identical number either way.
	SessionTokenMedian int64
}

const (
	runawayMultiple   = 20
	runawayFloor      = 100_000_000
	criticalShare     = 0.10
	cacheDropPoints   = 0.05
	cacheMinTurns     = 200
	spikeRatio        = 1.5
	spikeFloor        = 1_000_000_000
	maxFindings       = 8
	windowWarnPct     = 75.0
	windowCriticalPct = 90.0
	staleAfter        = time.Hour
	liveRunawayTokens = 200_000_000
)

var rank = map[string]int{"critical": 0, "warning": 1, "info": 2}

// finish orders by severity, then groups same-kind findings together (kinds
// ordered by first appearance) and ranks each kind's findings by weight,
// descending. Kinds are never compared to each other by weight — the units
// differ (percent, seconds, tokens, a ratio), and mixing them put a stale
// agent's synthetic "never reported" figure ahead of a live runaway session,
// which is backwards. Within one kind the units agree, so the cap below
// keeps the largest findings of a kind rather than whichever were appended
// first — with more than maxFindings same-kind, same-severity findings (a
// real fleet can easily have more than 8 unpriced-model or runaway-session
// hits), dropping the small ones instead of the big ones is the point.
func finish(fs []Finding) []Finding {
	kindOrder := map[string]int{}
	for _, f := range fs {
		if _, ok := kindOrder[f.Kind]; !ok {
			kindOrder[f.Kind] = len(kindOrder)
		}
	}
	sort.SliceStable(fs, func(i, j int) bool {
		if rank[fs[i].Severity] != rank[fs[j].Severity] {
			return rank[fs[i].Severity] < rank[fs[j].Severity]
		}
		if kindOrder[fs[i].Kind] != kindOrder[fs[j].Kind] {
			return kindOrder[fs[i].Kind] < kindOrder[fs[j].Kind]
		}
		return fs[i].weight > fs[j].weight
	})
	if len(fs) > maxFindings {
		fs = fs[:maxFindings]
	}
	if fs == nil {
		fs = []Finding{}
	}
	return fs
}

// Review evaluates the period rules.
func Review(in Inputs) []Finding {
	var fs []Finding
	fs = append(fs, runaway(in.Sessions, in.SessionTokenMedian)...)
	fs = append(fs, unpriced(in.Models)...)
	fs = append(fs, critical(in.Critical, in.SelectionSeconds)...)
	fs = append(fs, cacheDrop(in.Projects, in.PrevProjects)...)
	fs = append(fs, spike(in)...)
	return finish(fs)
}

// runaway flags sessions whose tokens are far past a median: runawayMultiple
// times the population median, floored at runawayFloor so a quiet window
// with a tiny median cannot flag an ordinary session.
//
// populationMedian is the caller's own measurement of the FULL population
// (see Inputs.SessionTokenMedian) and is preferred whenever it is supplied
// (non-zero). Zero falls back to deriving the median from ss itself, exactly
// as this function used to unconditionally do -- correct as long as ss IS
// the population, which every test in this package still hands it, and which
// is also true of any hub small enough that its whole session list fits in
// one gatherer pull.
func runaway(ss []SessionStat, populationMedian int64) []Finding {
	if len(ss) == 0 {
		return nil
	}
	median := populationMedian
	if median == 0 {
		var toks []int64
		for _, s := range ss {
			if s.Turns >= 2 {
				toks = append(toks, s.Tokens)
			}
		}
		if len(toks) == 0 {
			return nil
		}
		sort.Slice(toks, func(i, j int) bool { return toks[i] < toks[j] })
		median = toks[len(toks)/2]
	}
	threshold := median * runawayMultiple
	if threshold < runawayFloor {
		threshold = runawayFloor
	}
	var out []Finding
	for _, s := range ss {
		if s.Tokens < threshold {
			continue
		}
		mult := int64(0)
		if median > 0 {
			mult = s.Tokens / median
		}
		out = append(out, Finding{
			Severity: "critical", Kind: "runaway_session",
			Title:  fmt.Sprintf("session %s burned %s tokens — %d× the median session", short(s.SessionID), tokens(s.Tokens), mult),
			Detail: fmt.Sprintf("%s · %s · %s · %d turns", shortPath(s.CWD), s.Model, dur(s.Duration), s.Turns),
			Scope:  map[string]string{"session": s.SessionID},
			Link:   "#sessions",
			weight: float64(s.Tokens),
		})
	}
	return out
}

func unpriced(ms []ModelStat) []Finding {
	var out []Finding
	for _, m := range ms {
		if m.Unpriced <= 0 {
			continue
		}
		out = append(out, Finding{
			Severity: "warning", Kind: "unpriced_model",
			Title:  fmt.Sprintf("%s has no price: %s tokens over %d turns show as $0", m.Model, tokens(m.Tokens), m.Unpriced),
			Detail: "Spend totals under-count until the model is added to the pricing table.",
			Scope:  map[string]string{"model": m.Model},
			weight: float64(m.Tokens),
		})
	}
	return out
}

func critical(cs []AccountCritical, selectionSeconds int64) []Finding {
	var out []Finding
	for _, c := range cs {
		if c.Seconds <= 0 {
			continue
		}
		sev := "warning"
		if selectionSeconds > 0 && float64(c.Seconds) > criticalShare*float64(selectionSeconds) {
			sev = "critical"
		}
		out = append(out, Finding{
			Severity: sev, Kind: "time_in_critical",
			Title:  fmt.Sprintf("%s spent %s above 90%% of its 5-hour window", c.Label, dur(time.Duration(c.Seconds)*time.Second)),
			Detail: fmt.Sprintf("%d episode(s) · previous period %s", c.Episodes, dur(time.Duration(c.PrevSeconds)*time.Second)),
			Link:   "#wall-history",
			weight: float64(c.Seconds),
		})
	}
	return out
}

func cacheDrop(cur, prev []ProjectStat) []Finding {
	prevBy := map[string]ProjectStat{}
	for _, p := range prev {
		prevBy[p.CWD] = p
	}
	var out []Finding
	for _, p := range cur {
		q, ok := prevBy[p.CWD]
		if !ok || p.Turns < cacheMinTurns || q.Turns < cacheMinTurns {
			continue
		}
		drop := q.CacheHit - p.CacheHit
		if drop < cacheDropPoints {
			continue
		}
		out = append(out, Finding{
			Severity: "info", Kind: "cache_hit_drop",
			Title:  fmt.Sprintf("cache hit on %s fell %.0f%% → %.0f%%", shortPath(p.CWD), q.CacheHit*100, p.CacheHit*100),
			Detail: "Turns there re-read context instead of hitting cache; each turn costs more than it did.",
			Scope:  map[string]string{"project": p.CWD},
			weight: drop,
		})
	}
	return out
}

func spike(in Inputs) []Finding {
	var out []Finding
	if in.PrevTokens > 0 && in.Tokens >= spikeFloor && float64(in.Tokens) >= spikeRatio*float64(in.PrevTokens) {
		ratio := float64(in.Tokens) / float64(in.PrevTokens)
		out = append(out, Finding{
			Severity: "info", Kind: "spend_spike",
			Title:  fmt.Sprintf("tokens are %.1f× the previous period", ratio),
			Detail: fmt.Sprintf("%s vs %s", tokens(in.Tokens), tokens(in.PrevTokens)),
			weight: ratio,
		})
		var top *ProjectStat
		for i := range in.Projects {
			p := &in.Projects[i]
			if top == nil || p.Tokens > top.Tokens {
				top = p
			}
		}
		if top != nil && top.PrevTokens > 0 && float64(top.Tokens) >= spikeRatio*float64(top.PrevTokens) {
			r := float64(top.Tokens) / float64(top.PrevTokens)
			out = append(out, Finding{
				Severity: "info", Kind: "spend_spike",
				Title:  fmt.Sprintf("%s is %.1f× its previous period and the top contributor", shortPath(top.CWD), r),
				Detail: fmt.Sprintf("%s vs %s", tokens(top.Tokens), tokens(top.PrevTokens)),
				Scope:  map[string]string{"project": top.CWD},
				// Same weight as the blended finding above, not its own ratio r: a
				// spike concentrated in one project routinely makes r exceed the
				// blended ratio, so magnitude cannot be trusted to keep this listed
				// second. Tying the weight makes finish's sort a no-op between the
				// two, and its stability then preserves append order — this entry
				// was appended after the one it drills down from.
				weight: ratio,
			})
		}
	}
	return out
}

// ---- Now ----

type WindowStat struct {
	Label       string
	FiveHourPct float64
}
type EndpointSeen struct {
	Label    string
	LastSeen *time.Time
}
type LiveStat struct {
	SessionID, CWD string
	Tokens         int64
}
type NowInputs struct {
	Windows   []WindowStat
	Endpoints []EndpointSeen
	Live      []LiveStat
	Now       time.Time
}

// Now evaluates the minute-scale rules.
func Now(in NowInputs) []Finding {
	var fs []Finding
	for _, w := range in.Windows {
		if w.FiveHourPct < windowWarnPct {
			continue
		}
		sev := "warning"
		if w.FiveHourPct >= windowCriticalPct {
			sev = "critical"
		}
		fs = append(fs, Finding{Severity: sev, Kind: "window_high",
			Title: fmt.Sprintf("%s is at %.0f%% of its 5-hour window", w.Label, w.FiveHourPct),
			Link:  "#wall", weight: w.FiveHourPct})
	}
	for _, e := range in.Endpoints {
		if e.LastSeen != nil && in.Now.Sub(*e.LastSeen) <= staleAfter {
			continue
		}
		title := fmt.Sprintf("%s has never reported", e.Label)
		w := float64(1 << 30)
		if e.LastSeen != nil {
			title = fmt.Sprintf("%s last reported %s ago", e.Label, dur(in.Now.Sub(*e.LastSeen)))
			w = in.Now.Sub(*e.LastSeen).Seconds()
		}
		fs = append(fs, Finding{Severity: "warning", Kind: "stale_agent", Title: title,
			Detail: "Its share of every total is under-counted until it returns.", Link: "#fleet", weight: w})
	}
	for _, l := range in.Live {
		if l.Tokens < liveRunawayTokens {
			continue
		}
		fs = append(fs, Finding{Severity: "warning", Kind: "live_runaway",
			Title:  fmt.Sprintf("live session %s has %s tokens in flight", short(l.SessionID), tokens(l.Tokens)),
			Detail: shortPath(l.CWD), Scope: map[string]string{"session": l.SessionID}, Link: "#live", weight: float64(l.Tokens)})
	}
	return finish(fs)
}

// ---- formatting shared by the templates ----

func tokens(n int64) string {
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.1fB", float64(n)/1e9)
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1e3)
	}
	return fmt.Sprintf("%d", n)
}

func dur(d time.Duration) string {
	d = d.Round(time.Minute)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	return fmt.Sprintf("%dh %dm", h, m)
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// shortPath keeps the last two segments; the last one is what tells sibling
// worktrees apart, so it is never the part that gets clipped.
func shortPath(p string) string {
	if p == "" {
		return "(unknown)"
	}
	parts := strings.FieldsFunc(strings.ReplaceAll(p, "\\", "/"), func(r rune) bool { return r == '/' })
	if len(parts) <= 2 {
		return p
	}
	return "…/" + strings.Join(parts[len(parts)-2:], "/")
}
