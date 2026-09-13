package store

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/verkyyi/ccquota/internal/model"
)

// SourceCost is one source's cost over some scope, and the two facts needed to
// read it: which source, and which kind of money.
//
// Events is carried so that zero is legible. A cost of 0 with events > 0 is a
// real figure (unpriced or genuinely free work); a cost of 0 with events == 0
// is an absence. Collapsing the two would put "$0.00" on a column no usage ever
// touched, which is the same "zero is a claim" mistake UsageEvent.CostUSD's nil
// exists to avoid.
type SourceCost struct {
	Source   string  `json:"source"`
	Kind     string  `json:"kind"`
	Events   int64   `json:"events"`
	CostUSD  float64 `json:"cost_usd"`
	Unpriced int64   `json:"unpriced_events"`
}

// CostBySource is a cost aggregate that has been kept apart by source.
//
// Every cost aggregate in this package returns one of these instead of a
// float64, and that is the point: there is deliberately NO Total() method and
// no blended field. The three kinds of money this hub holds — subscription
// spend, notional token cost, and metered gateway cost — produce a number that
// means nothing when any two are added, and the failure is silent because the
// result is always plausible. Removing the single-figure accessor is what turns
// that runtime hazard into a compile error.
//
// The two folds that ARE legitimate are named for what they mean rather than
// for the arithmetic: Notional (Claude + Codex, both answering "what would this
// have cost at API rates") and Billed (the gateway, an actual charge). Real
// spend is Billed plus SubscriptionSpend; Notional is never part of it.
type CostBySource []SourceCost

// Of returns one source's figure, and whether the scope knew about that source
// at all.
func (c CostBySource) Of(source string) (SourceCost, bool) {
	want := model.UsageSource(source)
	for _, sc := range c {
		if sc.Source == want {
			return sc, true
		}
	}
	return SourceCost{Source: want, Kind: model.CostKind(want)}, false
}

// Notional totals the sources whose cost_usd is an API-equivalent estimate.
//
// Summing Claude and Codex is legitimate because they are the SAME kind of
// money — both answer "what would this have cost at API rates" for work nobody
// is billed per token for. Nothing billed can enter this sum, and an
// unclassified source cannot either.
func (c CostBySource) Notional() float64 { return c.sumKind(model.CostNotional) }

// Billed totals the sources that are actually invoiced per call. This is the
// only cost figure from this column that may be added to subscription spend.
func (c CostBySource) Billed() float64 { return c.sumKind(model.CostBilled) }

func (c CostBySource) sumKind(kind string) float64 {
	var out float64
	for _, sc := range c {
		if sc.Kind == kind {
			out += sc.CostUSD
		}
	}
	return out
}

// Unclassified lists sources this build has no cost kind for. They belong to no
// total, so a surface that has any shows them apart rather than dropping them:
// a figure missing from every column is how an unreviewed source stays
// unreviewed.
func (c CostBySource) Unclassified() []SourceCost {
	var out []SourceCost
	for _, sc := range c {
		if sc.Kind == model.CostUnknown {
			out = append(out, sc)
		}
	}
	return out
}

// Events totals the requests behind the figures. A COUNT is not money: events
// from different sources are the same kind of thing and add up fine.
func (c CostBySource) Events() int64 {
	var out int64
	for _, sc := range c {
		out += sc.Events
	}
	return out
}

// Unpriced totals the requests with no price. Also a count, also addable — and
// the denominator that says how much of the figures above is missing.
func (c CostBySource) Unpriced() int64 {
	var out int64
	for _, sc := range c {
		out += sc.Unpriced
	}
	return out
}

// Add folds another scope's split into this one, per source. Used where a
// breakdown is assembled in Go rather than by one query — folding hours into
// days, merging a previous period — so that the fold cannot accidentally
// flatten what the query kept apart.
func (c *CostBySource) Add(in CostBySource) {
	for _, sc := range in {
		c.add(sc)
	}
}

func (c *CostBySource) add(in SourceCost) {
	for i := range *c {
		if (*c)[i].Source == in.Source {
			(*c)[i].Events += in.Events
			(*c)[i].CostUSD += in.CostUSD
			(*c)[i].Unpriced += in.Unpriced
			return
		}
	}
	*c = append(*c, in)
}

// zeroCosts is the empty split: every source this build knows, at zero, with
// no events. Breakdowns start here so that a bucket's columns are the same
// columns on every row even when one source is idle.
func zeroCosts() CostBySource {
	out := make(CostBySource, 0, len(model.Sources))
	for _, s := range model.Sources {
		out = append(out, SourceCost{Source: s, Kind: model.CostKind(s)})
	}
	return out
}

// sourceExpr is the SQL twin of model.UsageSource: rows written before the
// source column existed, and any row that somehow stored the empty string, are
// Claude usage. Kept beside the Go function it mirrors so the two are edited
// together.
const sourceExpr = `COALESCE(NULLIF(source, ''), '` + model.SourceClaude + `')`

// otherSource is the bucket for a source this build does not know. It is not a
// source name, and it is spelled so it can never collide with one (KnownSource
// rejects it, and safeSource below rejects the parenthesis in a real one).
const otherSource = "(other)"

// safeSource is what lets the fragment below inline source names rather than
// bind them.
//
// The rest of this package's rule is that column names are fixed in the source
// and caller strings only ever become bind arguments — see Filter.where. These
// names are not caller strings: they are this build's own constants, and
// validating them here means a source added with a quote in it fails loudly at
// the first query rather than producing SQL nobody reads.
var safeSource = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)

// costSplit is the SELECT fragment that keeps cost_usd apart by source, plus
// the source each column group belongs to.
//
// One conditional column group per known source (and one for anything else) is
// how an aggregate keyed on some OTHER dimension still refuses to blend: no
// column in the result holds two sources' money. Conditional columns rather
// than an extra GROUP BY term because these queries rank and LIMIT on the
// dimension — adding source to the grouping would make "the top 50" mean the
// top 50 (key, source) pairs, quietly dropping keys.
type costSplit struct {
	sel     string
	sources []string
}

// newCostSplit builds the fragment for one table. eventsExpr and unpricedExpr
// are that table's per-ROW expressions: usage_events counts rows and reads
// nullability, usage_hourly reads columns that are already per-hour sums.
func newCostSplit(eventsExpr, unpricedExpr string) costSplit {
	sources := append(append([]string{}, model.Sources...), otherSource)
	cols := make([]string, 0, len(sources)*3)
	known := make([]string, 0, len(model.Sources))
	for _, s := range model.Sources {
		if !safeSource.MatchString(s) {
			panic(fmt.Sprintf("store: source %q cannot be inlined into SQL", s))
		}
		known = append(known, "'"+s+"'")
	}
	for _, s := range sources {
		cond := sourceExpr + " = '" + s + "'"
		if s == otherSource {
			cond = sourceExpr + " NOT IN (" + strings.Join(known, ", ") + ")"
		}
		cols = append(cols,
			"COALESCE(SUM(CASE WHEN "+cond+" THEN "+eventsExpr+" ELSE 0 END), 0)",
			"COALESCE(SUM(CASE WHEN "+cond+" THEN cost_usd END), 0)",
			"COALESCE(SUM(CASE WHEN "+cond+" THEN "+unpricedExpr+" ELSE 0 END), 0)")
	}
	return costSplit{sel: strings.Join(cols, ", "), sources: sources}
}

// The two tables every cost aggregate in this package reads.
var (
	eventCostSplit  = newCostSplit("1", "(cost_usd IS NULL)")
	hourlyCostSplit = newCostSplit("events", "unpriced_events")
)

// costScan holds the destinations for one costSplit's columns and turns them
// back into a CostBySource. Scanning through it, rather than into named
// variables, is what keeps the column order and the read order from drifting.
type costScan struct {
	split    costSplit
	events   []int64
	cost     []float64
	unpriced []int64
}

func (cs costSplit) scan() *costScan {
	n := len(cs.sources)
	return &costScan{split: cs, events: make([]int64, n), cost: make([]float64, n), unpriced: make([]int64, n)}
}

// dest returns the Scan targets, in the fragment's column order.
func (c *costScan) dest() []any {
	out := make([]any, 0, len(c.split.sources)*3)
	for i := range c.split.sources {
		out = append(out, &c.events[i], &c.cost[i], &c.unpriced[i])
	}
	return out
}

// costs returns the split. Known sources are always present, idle or not, so a
// caller rendering columns gets the same ones on every row; the unknown bucket
// appears only when something actually landed in it, because a column headed
// "(other)" with nothing in it invites the reader to ignore it the day it fills.
func (c *costScan) costs() CostBySource {
	out := make(CostBySource, 0, len(c.split.sources))
	for i, s := range c.split.sources {
		if s == otherSource && c.events[i] == 0 && c.cost[i] == 0 && c.unpriced[i] == 0 {
			continue
		}
		out = append(out, SourceCost{
			Source: s, Kind: model.CostKind(s),
			Events: c.events[i], CostUSD: c.cost[i], Unpriced: c.unpriced[i],
		})
	}
	return out
}
