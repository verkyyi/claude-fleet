package api

import (
	"sync"
	"time"
)

// The hero counter: one all-time token total that only ever grows.
//
// It cannot tick by itself. Neither source of usage is per-token — a transcript
// records a turn's usage when the turn ENDS, and a statusLine reports a
// session's running totals when it redraws. The finest real granularity is a
// turn, arriving in a batch up to a minute late. So the page projects between
// measurements, and everything here exists to keep that projection honest.
//
// The policy lives in Go rather than in the page because it is the part with
// rules worth testing. The browser only animates.

// counterTTL is how long a lifetime total is reused before being recomputed.
//
// The query is a full scan of usage_events, and the SSE stream pushes on every
// live report — several times a second across a fleet. Recomputing per push
// would spend a table scan to move a number by a few hundred tokens.
const counterTTL = 30 * time.Second

// projectionWindow is how far past the last measurement the page may keep
// counting.
//
// This is the safeguard the whole feature turns on. Extrapolation with no
// deadline means a dead fleet still shows a number climbing confidently, which
// is the one way a projected counter genuinely misleads: not by being a little
// off, but by asserting work that is not happening. Ninety seconds is longer
// than the agents' scan interval and shorter than anyone's attention.
const projectionWindow = 90 * time.Second

// rateWindow is the minimum span the growth rate is measured over.
//
// The rate is deliberately NOT the live per-session figure. That one is the
// delta between two consecutive statusLine reports, and between turns the delta
// is genuinely zero — measured on this hub, five active sessions reported
// 0 tokens/min because no turn happened to complete in the last few seconds. A
// counter driven by it would stutter: freeze, lurch, freeze.
//
// So the rate is measured from the growth of the stored total itself — the
// exact quantity being projected — over a window longer than the agents' scan
// interval, so it spans whole scans rather than sampling the gaps between them.
const rateWindow = 90 * time.Second

// Counter is the cached lifetime total plus the rate at which it is growing.
type Counter struct {
	mu         sync.Mutex
	turns      int64
	tokens     int64
	measuredAt time.Time

	// The older sample the rate is measured against. Rolled forward only once
	// it is at least rateWindow old, so the rate always spans whole scans.
	rateBase   int64
	rateBaseAt time.Time
	perMin     float64
}

// CounterView is what the page needs to animate honestly.
type CounterView struct {
	// Tokens and Turns are MEASURED: the durable store's whole history. The
	// live per-session figures are never added here — a completed turn appears
	// in both the transcript and its session's running total, so summing them
	// counts it twice.
	Tokens int64 `json:"tokens"`
	Turns  int64 `json:"turns"`

	// MeasuredAt is when Tokens was read. The page projects forward from here.
	MeasuredAt time.Time `json:"measured_at"`

	// TokensPerMin is the measured live rate to project at. Zero means do not
	// project at all.
	TokensPerMin float64 `json:"tokens_per_min"`

	// ProjectUntil is the instant after which the page must STOP counting and
	// show that it has stopped. Nil means do not project at all.
	//
	// A pointer because `omitempty` does nothing for a time.Time — it is a
	// struct, never "empty" — so a value field shipped 0001-01-01 to the page
	// as though it were a deadline. Absent has to be absent: the client tests
	// this field for presence, and a zero date is a claim about the past
	// rather than an admission that there is nothing to project from.
	ProjectUntil *time.Time `json:"project_until,omitempty"`
}

// Total returns the lifetime total, recomputing at most once per counterTTL.
func (c *Counter) Total(load func() (int64, int64, error)) (turns, tokens int64, measuredAt time.Time, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.measuredAt.IsZero() && time.Since(c.measuredAt) < counterTTL {
		return c.turns, c.tokens, c.measuredAt, nil
	}
	t, tok, err := load()
	if err != nil {
		// Serve the previous reading rather than nothing: a momentarily
		// unreadable database should not blank the headline figure.
		if !c.measuredAt.IsZero() {
			return c.turns, c.tokens, c.measuredAt, nil
		}
		return 0, 0, time.Time{}, err
	}
	// The store total can only grow. If a read comes back smaller — a merge
	// mid-flight, a partial scan — keep the larger one. The counter's whole
	// promise is that it never goes backwards.
	if tok >= c.tokens {
		c.turns, c.tokens = t, tok
	}
	c.measuredAt = time.Now().UTC()

	switch {
	case c.rateBaseAt.IsZero():
		c.rateBase, c.rateBaseAt = c.tokens, c.measuredAt
	case c.measuredAt.Sub(c.rateBaseAt) >= rateWindow:
		mins := c.measuredAt.Sub(c.rateBaseAt).Minutes()
		if grown := c.tokens - c.rateBase; grown > 0 && mins > 0 {
			c.perMin = float64(grown) / mins
		} else {
			// No growth over a whole window: nothing is running. Say so with a
			// zero rate rather than carrying the last busy one forward.
			c.perMin = 0
		}
		c.rateBase, c.rateBaseAt = c.tokens, c.measuredAt
	}
	return c.turns, c.tokens, c.measuredAt, nil
}

// Rate is the measured growth of the stored total, in tokens per minute.
func (c *Counter) Rate() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.perMin
}

// counterView assembles the projection contract from a measurement and a rate.
//
// A zero rate means nothing has been recorded for a whole window: there is
// nothing to project from, so the page holds the measured number still —
// correct, and visibly not animating.
func counterView(turns, tokens int64, measuredAt time.Time, tokensPerMin float64) CounterView {
	v := CounterView{Turns: turns, Tokens: tokens, MeasuredAt: measuredAt}
	if tokensPerMin <= 0 || measuredAt.IsZero() {
		return v
	}
	v.TokensPerMin = tokensPerMin
	until := measuredAt.Add(projectionWindow)
	v.ProjectUntil = &until
	return v
}

// LastReport is the most recent time any live session was heard from.
func (l *Live) LastReport() time.Time {
	l.mu.RLock()
	defer l.mu.RUnlock()
	var last time.Time
	for _, s := range l.sessions {
		if s.SeenAt.After(last) {
			last = s.SeenAt
		}
	}
	return last
}

// attachCounter fills in a snapshot's hero counter.
//
// A failure here leaves Counter nil rather than zero. The page then shows no
// counter at all, which is the honest rendering of "not known" — a zero would
// claim this hub had never seen a token.
func (s *Server) attachCounter(snap *Snapshot) {
	if s.Store == nil {
		return
	}
	turns, tokens, measuredAt, err := s.counter.Total(s.Store.LifetimeTotals)
	if err != nil {
		return
	}
	v := counterView(turns, tokens, measuredAt, s.counter.Rate())
	snap.Counter = &v
}
