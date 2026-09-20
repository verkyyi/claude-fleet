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

// The sentence templates this package emits. One id per SENTENCE, not per
// Kind: two spend_spike findings say different things, and a stale agent reads
// differently depending on whether it has ever reported at all.
const (
	TmplRunawaySession    = "runaway_session"
	TmplUnpricedModel     = "unpriced_model"
	TmplTimeInCritical    = "time_in_critical"
	TmplCacheHitDrop      = "cache_hit_drop"
	TmplSpendSpikeTotal   = "spend_spike_total"
	TmplSpendSpikeProject = "spend_spike_project"
	TmplWindowHigh        = "window_high"
	TmplStaleAgentNever   = "stale_agent_never"
	TmplStaleAgentLast    = "stale_agent_last"
	TmplLiveRunaway       = "live_runaway"
	TmplFreeAllowanceGone = "free_allowance_exceeded"
	TmplFreeAllowanceNear = "free_allowance_near"
)

// Templates is every id above, so a translation table can be checked for
// completeness rather than discovered to be missing one in production.
var Templates = []string{
	TmplRunawaySession, TmplUnpricedModel, TmplTimeInCritical, TmplCacheHitDrop,
	TmplSpendSpikeTotal, TmplSpendSpikeProject, TmplWindowHigh,
	TmplStaleAgentNever, TmplStaleAgentLast, TmplLiveRunaway,
	TmplFreeAllowanceGone, TmplFreeAllowanceNear,
}

// Owner is "who should this finding go to". Both halves are optional and an
// empty Owner is the normal case: most rules run over an aggregate (a model, a
// project, the period as a whole) that no one person owns.
//
// It is deliberately NOT an assignee. Nothing here is claimed, acknowledged or
// routed anywhere -- a finding is still recomputed on every read. This says
// only what the hub already knows about where the subject lives, so a reader
// who has to act on it does not have to go look that up by hand.
//
// Guessing is worse than saying nothing: an owner attributed to the wrong
// person sends someone after a machine that is not theirs, and it is believed
// because the page printed it. A rule that cannot name the owner exactly
// leaves this zero.
//
// User and Team are identifiers of PEOPLE and ORG UNITS -- an OS login, an
// operator's own team name. Like Severity/Kind/Scope they are never
// translated: there is nothing in them to translate.
//
// Which rules fill it, and why the rest do not:
//
//	stale_agent      yes -- an endpoint IS a (machine, login) pair
//	runaway_session  yes -- a session ran as one login on one endpoint
//	live_runaway     yes -- same, for a session still in flight
//	unpriced_model   no  -- a model, used fleet-wide
//	free_allowance   no  -- a model's month, fleet-wide
//	cache_hit_drop   no  -- a project, which several logins share
//	spend_spike      no  -- the period, or the project driving it
//	time_in_critical no  -- a subscription, not a person: the label is an
//	                        account, and the endpoints drawing on it are many
//	window_high      no  -- same, a subscription's rate-limit window
//
// The "no" rows are not gaps waiting to be filled in. Each one's subject is an
// aggregate over several people, so any single name on it would be the guess
// this type refuses to make.
type Owner struct {
	// User is the OS login the work runs as -- store.Endpoint.OSUser.
	User string `json:"user,omitempty"`
	// Team is the operator's allocation for the subject -- store.Endpoint.Team.
	// Empty means unassigned, and the surfaces say so rather than inventing one.
	Team string `json:"team,omitempty"`
}

// Zero reports whether this Owner names nobody, so a surface can skip the line
// entirely instead of rendering an empty one.
func (o Owner) Zero() bool { return o.User == "" && o.Team == "" }

// owner is what a rule calls with whatever attribution it happens to hold. Two
// empty strings give nil, not a pointer to an empty struct: "nobody named"
// must be one shape on the wire (the key absent), so a consumer's `if
// (f.owner)` cannot be true for a finding that names no one. Half-known is
// still worth carrying -- a login with no team assigned is the normal state of
// an unallocated endpoint.
func owner(user, team string) *Owner {
	o := Owner{User: user, Team: team}
	if o.Zero() {
		return nil
	}
	return &o
}

type Finding struct {
	// ID is this finding's stable identity: the same problem computes the
	// same id on every request, so something can be attached to it. See
	// identity.go for exactly what "the same problem" means.
	//
	// Assigned by finish(), never by a rule -- a rule states its subject and
	// the hashing happens in one place. Always present on the wire (not
	// omitempty): a consumer that has to key on it must not have to handle
	// the key being absent.
	ID string `json:"id"`

	Severity string            `json:"severity"` // critical | warning | info
	Kind     string            `json:"kind"`
	Title    string            `json:"title"`
	Detail   string            `json:"detail"`
	Scope    map[string]string `json:"scope,omitempty"` // chips to apply (hash param names)
	Link     string            `json:"link,omitempty"`  // an in-app anchor, e.g. "#sessions"

	// Muted is set when the operator has silenced this finding and the
	// silence has not expired. The finding is STILL HERE -- muting ranks it
	// below the live ones and out of their cap, it does not delete it. A
	// muted alert that vanished would be indistinguishable from a condition
	// that cleared, which is the one thing an operator must not have to
	// guess about.
	//
	// Absent from the wire when the finding is not muted, so a consumer tests
	// for the key exactly as it does for Scope, Link and Owner.
	Muted *Mute `json:"muted,omitempty"`

	// Owner is who to go to about this finding, when the hub knows. Omitted
	// from the wire when it names nobody -- a consumer tests for the key's
	// absence, exactly as it does for Scope and Link.
	Owner *Owner `json:"owner,omitempty"`

	// Template names WHICH sentence this is, and Args holds the values
	// interpolated into it. Together they let a surface re-render the finding in
	// another language without parsing English back out of Title.
	//
	// Kind is not enough on its own: two spend_spike findings say different
	// things (the period as a whole, and the project driving it), and a stale
	// agent reads differently depending on whether it has ever reported at all.
	//
	// Neither field is serialised. The wire contract is still the rendered
	// prose, and internal/mcp -- whose consumer is an agent quoting the text --
	// keeps getting exactly what it got before.
	Template string            `json:"-"`
	Args     map[string]string `json:"-"`

	// subject is WHAT this finding is about, as an identifier rather than as
	// prose -- a session id, a model name, an account uuid. Every rule sets
	// it; finish() hashes it into ID. Never serialised: it is an input to the
	// identity, and the identity is what consumers key on.
	//
	// An empty subject is legal and means "this rule produces exactly one
	// finding of this sentence per request" -- see identity.go on
	// spend_spike's blended sentence, the only case in tree.
	subject string

	weight float64
}

type SessionStat struct {
	SessionID, CWD, Model string
	Tokens, Turns         int64
	Duration              time.Duration

	// OSUser and Team are who the session ran as, when the caller knows.
	// A session belongs to exactly one (machine, login) pair, so this is a
	// lookup rather than an inference. Empty stays empty.
	OSUser, Team string
}
type ModelStat struct {
	Model            string
	Tokens, Unpriced int64
}

// FreeAllowanceStat is one model's CALENDAR-MONTH token total against the free
// monthly allowance its rate declares.
//
// The month, never the selection: an allowance resets on the first, so "have we
// used it up" is a question about the month whatever window the page is showing.
type FreeAllowanceStat struct {
	Model     string
	Tokens    int64 // month to date
	Allowance int64 // as declared by the rate
}
type AccountCritical struct {
	// AccountUUID is the subscription this is about, when the caller has it.
	// Label is what the sentence PRINTS; this is what the finding's identity
	// is keyed on, because a label is renameable and not unique -- see
	// identity.go. Empty falls back to Label, for a caller with no uuid.
	AccountUUID          string
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
	FreeAllowances         []FreeAllowanceStat
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

	// Mutes are the silences in force for this reader, keyed by Finding.ID.
	// Nil is the normal state of a hub nobody has muted anything on, and of
	// every caller that does not care — the rules are unchanged by it, only
	// the ranking and the cap are (see finish).
	Mutes Mutes
}

const (
	runawayMultiple = 20
	runawayFloor    = 100_000_000
	criticalShare   = 0.10
	cacheDropPoints = 0.05
	cacheMinTurns   = 200
	spikeRatio      = 1.5
	spikeFloor      = 1_000_000_000
	maxFindings     = 8
	// maxMutedFindings bounds the folded tail of silenced findings. The tail
	// is still a wire payload and still becomes DOM, and a fleet that has
	// muted forty things does not need all forty echoed back on every poll —
	// the mute roster is its own question, answered by GET /v1/findings/mutes.
	maxMutedFindings  = 8
	windowWarnPct     = 75.0
	windowCriticalPct = 90.0
	liveRunawayTokens = 200_000_000
)

// StaleAfter is how long an endpoint may go without reporting before it counts
// as stale — the one definition of the word for endpoints, exported because it
// is not only this package's business.
//
// The dashboard's endpoint roster used to dim a row after ten minutes while
// this alert waited an hour, so the same machine was "stale" in one place and
// fine in another, on one page. The roster now reads this number (web/dist has
// no build step and cannot import Go, so it carries the literal and
// web/embed_test.go fails the build if the two ever drift).
//
// Not to be confused with the limits banner's ten-minute threshold, which is
// about the age of a rate-limit READING, not about an endpoint being quiet.
const StaleAfter = time.Hour

var rank = map[string]int{"critical": 0, "warning": 1, "info": 2}

// finish names, ranks, annotates and caps.
//
// Ordering: by severity, then same-kind findings grouped together (kinds
// ordered by first appearance), then by weight within a kind, descending.
// Kinds are never compared to each other by weight — the units differ
// (percent, seconds, tokens, a ratio), and mixing them put a stale agent's
// synthetic "never reported" figure ahead of a live runaway session, which is
// backwards. Within one kind the units agree, so the cap keeps the largest
// findings of a kind rather than whichever were appended first — with more
// than maxFindings same-kind, same-severity findings (a real fleet can easily
// have more than 8 unpriced-model or runaway-session hits), dropping the small
// ones instead of the big ones is the point.
//
// # Muting and the cap
//
// The cap and the mute list interact, and the interaction had to be decided
// rather than fallen into. maxFindings exists to keep the card readable: show
// the handful that matter and drop the tail. Muting says a finding does NOT
// matter right now. Two wrong answers were available:
//
//   - Leave muted findings in the ranking. Then silencing an alert buys
//     nothing: it still occupies one of the eight slots, and the ninth
//     finding — the one the operator would now have room to see — stays
//     hidden behind something they have explicitly dealt with.
//   - Rank muted findings last and apply the one cap to the whole list. Then
//     muting DELETES them: on a fleet with nine findings the muted one falls
//     off the end and the page can no longer say it is muted rather than
//     resolved. That contradicts the whole point of a mute having an expiry.
//
// So the cap is applied per tier. The live findings are ranked and capped at
// maxFindings exactly as before — a muted finding gives up its slot, which is
// what silencing it was for. The muted ones follow, ranked among themselves
// and capped at maxMutedFindings, as a tail the surfaces render folded. A
// muted finding therefore never costs a live one its place, and never
// disappears while its silence holds.
//
// mutes is treated as already filtered to what is in force (see Mutes).
func finish(fs []Finding, mutes Mutes) []Finding {
	kindOrder := map[string]int{}
	for i := range fs {
		f := &fs[i]
		f.ID = findingID(f.Kind, f.Template, f.Severity, f.subject)
		if m, ok := mutes[f.ID]; ok {
			cp := m
			f.Muted = &cp
		}
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
	live, muted := make([]Finding, 0, len(fs)), []Finding{}
	for _, f := range fs {
		if f.Muted != nil {
			muted = append(muted, f)
			continue
		}
		live = append(live, f)
	}
	if len(live) > maxFindings {
		live = live[:maxFindings]
	}
	if len(muted) > maxMutedFindings {
		muted = muted[:maxMutedFindings]
	}
	return append(live, muted...)
}

// Review evaluates the period rules.
func Review(in Inputs) []Finding {
	var fs []Finding
	fs = append(fs, runaway(in.Sessions, in.SessionTokenMedian)...)
	fs = append(fs, unpriced(in.Models)...)
	fs = append(fs, freeAllowance(in.FreeAllowances)...)
	fs = append(fs, critical(in.Critical, in.SelectionSeconds)...)
	fs = append(fs, cacheDrop(in.Projects, in.PrevProjects)...)
	fs = append(fs, spike(in)...)
	return finish(fs, in.Mutes)
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
			Title:    fmt.Sprintf("session %s burned %s tokens — %d× the median session", short(s.SessionID), tokens(s.Tokens), mult),
			Detail:   fmt.Sprintf("%s · %s · %s · %d turns", shortPath(s.CWD), s.Model, dur(s.Duration), s.Turns),
			Template: TmplRunawaySession,
			Args: map[string]string{
				"session": short(s.SessionID), "tokens": tokens(s.Tokens), "mult": fmt.Sprint(mult),
				"project": shortPath(s.CWD), "model": s.Model, "duration": dur(s.Duration),
				"turns": fmt.Sprint(s.Turns),
			},
			Owner: owner(s.OSUser, s.Team),
			Scope: map[string]string{"session": s.SessionID},
			Link:  "#sessions",
			// The FULL id, not short(): Title shows eight characters because
			// that is enough to read, and an identity built from a truncation
			// would merge two sessions that happen to share a prefix.
			subject: s.SessionID,
			weight:  float64(s.Tokens),
		})
	}
	return out
}

// freeAllowanceNearFull is where "plenty left" turns into "worth knowing".
const freeAllowanceNearFull = 0.80

// freeAllowance watches a declared free monthly allowance.
//
// This rule is the other half of pricing.Rates.FreeMonthlyTokens. An event
// inside the allowance prices to 0 because that is what the vendor charges, but
// Table.Cost is a pure function of one event and cannot see the month's total --
// so nothing in the pricing path can notice the month crossing the line. The
// store can, exactly, and this says so.
//
// Without it the failure is silent and expensive: the allowance is exceeded, the
// vendor starts charging, and every one of those calls keeps reporting 0.00.
func freeAllowance(as []FreeAllowanceStat) []Finding {
	var out []Finding
	for _, a := range as {
		if a.Allowance <= 0 {
			continue
		}
		used := float64(a.Tokens) / float64(a.Allowance)
		if used >= 1 {
			out = append(out, Finding{
				Severity: "critical", Kind: "free_allowance",
				Title: fmt.Sprintf("%s has used its whole free monthly allowance (%s of %s tokens)",
					a.Model, tokens(a.Tokens), tokens(a.Allowance)),
				Detail: "Calls beyond the allowance are charged, and this build still reports them as free — " +
					"its cost for this model is a floor, not a bill. Set a rate for it in --pricing.",
				Template: TmplFreeAllowanceGone,
				Args: map[string]string{
					"model": a.Model, "used": tokens(a.Tokens), "allowance": tokens(a.Allowance),
				},
				Scope:   map[string]string{"model": a.Model},
				subject: a.Model,
				weight:  used * 1e6,
			})
			continue
		}
		if used >= freeAllowanceNearFull {
			out = append(out, Finding{
				Severity: "warning", Kind: "free_allowance",
				Title: fmt.Sprintf("%s is at %.0f%% of its free monthly allowance (%s of %s tokens)",
					a.Model, used*100, tokens(a.Tokens), tokens(a.Allowance)),
				Detail:   "Past it the vendor charges, and this build would keep reporting the calls as free.",
				Template: TmplFreeAllowanceNear,
				Args: map[string]string{
					"model": a.Model, "pct": fmt.Sprintf("%.0f", used*100),
					"used": tokens(a.Tokens), "allowance": tokens(a.Allowance),
				},
				Scope:   map[string]string{"model": a.Model},
				subject: a.Model,
				weight:  used * 1e5,
			})
		}
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
			Title:    fmt.Sprintf("%s: %d requests have incomplete pricing", m.Model, m.Unpriced),
			Detail:   "A price or required usage metadata is missing. These requests are excluded from cost totals; their cost is unknown.",
			Template: TmplUnpricedModel,
			Args:     map[string]string{"model": m.Model, "n": fmt.Sprint(m.Unpriced)},
			Scope:    map[string]string{"model": m.Model},
			subject:  m.Model,
			weight:   float64(m.Tokens),
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
			Title:    fmt.Sprintf("%s spent %s above 90%% of its 5-hour window", c.Label, dur(time.Duration(c.Seconds)*time.Second)),
			Detail:   fmt.Sprintf("%d episode(s) · previous period %s", c.Episodes, dur(time.Duration(c.PrevSeconds)*time.Second)),
			Template: TmplTimeInCritical,
			Args: map[string]string{
				"label": c.Label, "duration": dur(time.Duration(c.Seconds) * time.Second),
				"episodes": fmt.Sprint(c.Episodes), "prev": dur(time.Duration(c.PrevSeconds) * time.Second),
			},
			Link: "#wall-history",
			// The uuid when the caller has one: Label is the operator's
			// display name, which they can rename and which two
			// subscriptions may share -- see identity.go.
			subject: firstNonEmpty(c.AccountUUID, c.Label),
			weight:  float64(c.Seconds),
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
			Title:    fmt.Sprintf("cache hit on %s fell %.0f%% → %.0f%%", shortPath(p.CWD), q.CacheHit*100, p.CacheHit*100),
			Detail:   "Turns there re-read context instead of hitting cache; each turn costs more than it did.",
			Template: TmplCacheHitDrop,
			Args: map[string]string{
				"project": shortPath(p.CWD),
				"from":    fmt.Sprintf("%.0f%%", q.CacheHit*100),
				"to":      fmt.Sprintf("%.0f%%", p.CacheHit*100),
			},
			Scope: map[string]string{"project": p.CWD},
			// The full path; Title shows shortPath(), and two sibling
			// worktrees can shorten to the same two segments.
			subject: p.CWD,
			weight:  drop,
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
			Title:    fmt.Sprintf("tokens are %.1f× the previous period", ratio),
			Detail:   fmt.Sprintf("%s vs %s", tokens(in.Tokens), tokens(in.PrevTokens)),
			Template: TmplSpendSpikeTotal,
			Args: map[string]string{
				"ratio":  fmt.Sprintf("%.1f", ratio),
				"tokens": tokens(in.Tokens), "prev": tokens(in.PrevTokens),
			},
			// No subject, and that is the honest answer: this sentence is
			// about the SELECTION as a whole, there is exactly one of it per
			// request, and kind+template+severity already names it. Muting it
			// means "I know spend is up" and holds however the brush moves --
			// see identity.go.
			subject: "",
			weight:  ratio,
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
				Title:    fmt.Sprintf("%s is %.1f× its previous period and the top contributor", shortPath(top.CWD), r),
				Detail:   fmt.Sprintf("%s vs %s", tokens(top.Tokens), tokens(top.PrevTokens)),
				Template: TmplSpendSpikeProject,
				Args: map[string]string{
					"project": shortPath(top.CWD), "ratio": fmt.Sprintf("%.1f", r),
					"tokens": tokens(top.Tokens), "prev": tokens(top.PrevTokens),
				},
				Scope:   map[string]string{"project": top.CWD},
				subject: top.CWD,
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
	// AccountUUID as on AccountCritical: the identity key behind the
	// printed Label. Empty falls back to Label.
	AccountUUID string
	Window      string
	Label       string
	FiveHourPct float64
}
type EndpointSeen struct {
	// ID is the endpoint id, the identity key behind the printed Label. A
	// label defaults to the hostname and two machines can carry the same
	// one, so muting by label would silence both -- see identity.go. Empty
	// falls back to Label.
	ID       string
	Label    string
	LastSeen *time.Time

	// OSUser and Team come straight off the endpoint record. An endpoint IS a
	// (machine, login) pair, which makes this the one rule whose owner is
	// never in doubt -- "go make the agent on this machine live again" has an
	// exact addressee, and the hub has always had it.
	OSUser, Team string
}
type LiveStat struct {
	SessionID, CWD string
	Tokens         int64

	// OSUser and Team are who is burning the tokens right now, when known.
	OSUser, Team string
}
type NowInputs struct {
	Windows   []WindowStat
	Endpoints []EndpointSeen
	Live      []LiveStat
	Now       time.Time

	// Mutes as on Inputs: the silences in force, keyed by Finding.ID.
	Mutes Mutes
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
		window := w.Window
		if window == "" {
			window = "5-hour window"
		}
		fs = append(fs, Finding{Severity: sev, Kind: "window_high",
			Title:    fmt.Sprintf("%s is at %.0f%% of its %s", w.Label, w.FiveHourPct, window),
			Template: TmplWindowHigh,
			// `window` is a label off the reading when the provider states one
			// and a default otherwise. The default is ours to translate; a
			// provider's own wording is not, so `windowDefaulted` says which
			// this is rather than leaving a translator to guess.
			Args: map[string]string{
				"label": w.Label, "pct": fmt.Sprintf("%.0f", w.FiveHourPct),
				"window": window, "windowDefaulted": fmt.Sprint(w.Window == ""),
			},
			Link: "#wall",
			// Account AND window: one subscription has several windows and
			// they run hot independently, so silencing the weekly must not
			// silence the 5-hour. `window` here is the DEFAULTED label, which
			// is a constant when the provider states none -- w.Window itself
			// would make the identity depend on whether a reading happened to
			// carry a label.
			subject: subjectKey(firstNonEmpty(w.AccountUUID, w.Label), window),
			weight:  w.FiveHourPct})
	}
	for _, e := range in.Endpoints {
		if e.LastSeen != nil && in.Now.Sub(*e.LastSeen) <= StaleAfter {
			continue
		}
		title := fmt.Sprintf("%s has never reported", e.Label)
		tmpl := TmplStaleAgentNever
		args := map[string]string{"label": e.Label}
		w := float64(1 << 30)
		if e.LastSeen != nil {
			title = fmt.Sprintf("%s last reported %s ago", e.Label, dur(in.Now.Sub(*e.LastSeen)))
			tmpl = TmplStaleAgentLast
			args["ago"] = dur(in.Now.Sub(*e.LastSeen))
			w = in.Now.Sub(*e.LastSeen).Seconds()
		}
		fs = append(fs, Finding{Severity: "warning", Kind: "stale_agent", Title: title,
			Detail:   "Its share of every total is under-counted until it returns.",
			Template: tmpl, Args: args, Owner: owner(e.OSUser, e.Team),
			Link: "#fleet",
			// The endpoint id when the caller has one: a label defaults to
			// the hostname and two machines can share it.
			subject: firstNonEmpty(e.ID, e.Label),
			weight:  w})
	}
	for _, l := range in.Live {
		if l.Tokens < liveRunawayTokens {
			continue
		}
		fs = append(fs, Finding{Severity: "warning", Kind: "live_runaway",
			Title:    fmt.Sprintf("live session %s has %s tokens in flight", short(l.SessionID), tokens(l.Tokens)),
			Detail:   shortPath(l.CWD),
			Template: TmplLiveRunaway,
			Args:     map[string]string{"session": short(l.SessionID), "tokens": tokens(l.Tokens), "project": shortPath(l.CWD)},
			Owner:    owner(l.OSUser, l.Team),
			Scope:    map[string]string{"session": l.SessionID}, Link: "#live", weight: float64(l.Tokens),
			subject: l.SessionID})
	}
	return finish(fs, in.Mutes)
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
