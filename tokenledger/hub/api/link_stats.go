package api

import (
	"context"
	"errors"
	"log"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A home's link to the hub, measured from the hub (task PNWW): the record a
// cross-border line would be judged against, kept whether one is bought or
// not. Each link is pinged by the hub once a minute (RTT, or a failure), each
// connect is booked with how long the link was gone and why, and each end this
// hub sees is booked with how it ended. No agent change: the hub pings over
// the websocket it already holds. GET LinkStatsPath (admin) folds it into
// per-link and per-hour (Beijing time) numbers. CCQUOTA_FLEET_LINK_SAMPLE_SECS
// sets the ping period (0: default, negative: off).
const (
	LinkStatsPath      = "/v1/fleet/link/stats"
	linkSampleDefault  = time.Minute
	linkPingTimeout    = 10 * time.Second
	linkKeep           = 90 * 24 * time.Hour
	linkGapOffline     = time.Hour // longer than this was a machine off, not a drop
	linkCauseHub       = "hub_restart"
	linkCauseNetwork   = "network"
	linkCauseFirst     = "first"
	linkCauseOffline   = "offline"
	linkEventUp        = "up"
	linkEventDown      = "down"
	linkEndShutdown    = "hub_shutdown"
	linkEndTimeout     = "read_timeout"
	linkEndClosed      = "closed"
	linkEndSuperseded  = "superseded"
	beijingOffsetHours = 8
)

func (w wsWire) ping(ctx context.Context) error   { return w.c.Ping(ctx) }
func (w *subWire) ping(ctx context.Context) error { return w.c.Ping(ctx) }

func (s *Server) linkSample() time.Duration {
	switch {
	case s.LinkSampleSecs < 0:
		return 0
	case s.LinkSampleSecs > 0:
		return time.Duration(s.LinkSampleSecs) * time.Second
	}
	return linkSampleDefault
}

// linkPrev is what the hub knew of an endpoint before this connect.
type linkPrev struct {
	lastBeat *time.Time
	replica  string
	known    bool
	shutdown bool
}

// linkBefore reads the endpoint's last beat and the replica that last held its
// link, before this connect overwrites them.
func (s *Server) linkBefore(ep *store.Endpoint) linkPrev {
	endpointID := ep.ID
	var p linkPrev
	if last, err := s.Store.LastLinkEvent(ep.Hostname, ep.OSUser); err == nil {
		p.shutdown = last.Event == linkEventDown && last.Cause == linkEndShutdown && time.Since(last.At) < linkGapOffline
	}
	if last, ok, err := s.Store.NodeLastBeat(endpointID); err == nil {
		p.lastBeat, p.known = last, ok
	}
	if s.Replica != nil {
		if c, ok, err := s.Store.NodeConnOf(endpointID); err == nil && ok {
			p.replica = c.Replica
		}
	}
	return p
}

// linkCause says why a link that is up again was gone, and for how long.
func (s *Server) linkCause(p linkPrev, now time.Time) (string, int64) {
	if !p.known || p.lastBeat == nil {
		return linkCauseFirst, 0
	}
	gap := now.Sub(*p.lastBeat)
	if gap < 0 {
		gap = 0
	}
	if gap > linkGapOffline {
		return linkCauseOffline, gap.Milliseconds()
	}
	if p.shutdown {
		return linkCauseHub, gap.Milliseconds()
	}
	if s.Replica != nil && p.replica != "" && p.replica != s.Replica.Name {
		if up, ok := s.replicaNamesUp(now); ok && !up[p.replica] {
			return linkCauseHub, gap.Milliseconds()
		}
	}
	return linkCauseNetwork, gap.Milliseconds()
}

func (s *Server) replicaName() string {
	if s.Replica == nil {
		return ""
	}
	return s.Replica.Name
}

// linkUp books a connect, off the connect's own path: the node's first beat
// is never held behind the record.
func (s *Server) linkUp(ep *store.Endpoint, p linkPrev, now time.Time) {
	go s.linkUpNow(*ep, p, now)
}

func (s *Server) linkUpNow(e store.Endpoint, p linkPrev, now time.Time) {
	ep := &e
	cause, gap := s.linkCause(p, now)
	if err := s.Store.RecordLinkEvent(store.LinkEvent{At: now, Host: ep.Hostname, Login: ep.OSUser, Event: linkEventUp,
		Cause: cause, GapMS: gap, Replica: s.replicaName()}); err != nil {
		log.Printf("node %s: record link up: %v", ep.ID, err)
	}
}

// linkDown books an end this hub saw, by how the read loop ended.
func (s *Server) linkDown(ctx context.Context, ep *store.Endpoint, nc *nodeConn, err error) {
	end := linkEndClosed
	switch {
	case ctx.Err() != nil, s.Draining():
		end = linkEndShutdown
	case errors.Is(err, context.DeadlineExceeded):
		end = linkEndTimeout
	}
	if cur := s.nodes.get(ep.ID); cur != nil && cur != nc {
		end = linkEndSuperseded
	}
	if e := s.Store.RecordLinkEvent(store.LinkEvent{At: time.Now(), Host: ep.Hostname, Login: ep.OSUser, Event: linkEventDown,
		Cause: end, Replica: s.replicaName()}); e != nil {
		log.Printf("node %s: record link down: %v", ep.ID, e)
	}
}

// linkWatch pings the link every period until ctx ends.
func (s *Server) linkWatch(ctx context.Context, ep *store.Endpoint, wire interface {
	ping(context.Context) error
}) {
	every := s.linkSample()
	if every <= 0 {
		return
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		pctx, cancel := context.WithTimeout(ctx, linkPingTimeout)
		start := time.Now()
		err := wire.ping(pctx)
		cancel()
		if ctx.Err() != nil {
			return
		}
		if e := s.Store.RecordLinkPing(ep.Hostname, ep.OSUser, start, time.Since(start).Milliseconds(), err == nil); e != nil {
			log.Printf("node %s: record link ping: %v", ep.ID, e)
		}
	}
}

// ── the admin's read ────────────────────────────────────────────────────

type linkStats struct {
	Days  int            `json:"days"`
	Links []linkOne      `json:"links"`
	Hours []linkHourStat `json:"beijing_hours"`
}

type linkOne struct {
	Host     string           `json:"host"`
	Login    string           `json:"login"`
	Pings    int64            `json:"pings"`
	FailRate float64          `json:"ping_fail_rate"`
	RTTMean  float64          `json:"rtt_mean_ms"`
	RTTP50   int64            `json:"rtt_p50_ms"`
	RTTP90   int64            `json:"rtt_p90_ms"`
	RTTMax   int64            `json:"rtt_max_ms"`
	Drops    map[string]int   `json:"drops_by_cause"`
	PerDay   float64          `json:"drops_per_day"`
	Gaps     map[string]gapMS `json:"gap_by_cause"`
}

type gapMS struct {
	P50 int64 `json:"p50_ms"`
	P90 int64 `json:"p90_ms"`
	Max int64 `json:"max_ms"`
}

type linkHourStat struct {
	Hour     int     `json:"hour"`
	Pings    int64   `json:"pings"`
	FailRate float64 `json:"ping_fail_rate"`
	RTTMean  float64 `json:"rtt_mean_ms"`
	RTTP90   int64   `json:"rtt_p90_ms"`
	Drops    int     `json:"drops"`
}

// bucketPct is the histogram's bound at quantile q (the bucket's upper
// bound; the open bucket answers max).
func bucketPct(b [6]int64, max int64, q float64) int64 {
	var total int64
	for _, v := range b {
		total += v
	}
	if total == 0 {
		return 0
	}
	want := int64(float64(total)*q + 0.5)
	if want < 1 {
		want = 1
	}
	var acc int64
	for i, v := range b {
		acc += v
		if acc >= want {
			if i < len(store.LinkRTTBounds) {
				return store.LinkRTTBounds[i]
			}
			return max
		}
	}
	return max
}

func pctInt(xs []int64, q float64) int64 {
	if len(xs) == 0 {
		return 0
	}
	sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
	i := int(float64(len(xs)-1) * q)
	return xs[i]
}

func linkStatsOf(days int, evs []store.LinkEvent, rtts []store.LinkRTT) linkStats {
	type key struct{ h, l string }
	type acc struct {
		r    store.LinkRTT
		gaps map[string][]int64
		drop map[string]int
	}
	by := map[key]*acc{}
	get := func(h, l string) *acc {
		k := key{h, l}
		if by[k] == nil {
			by[k] = &acc{r: store.LinkRTT{Host: h, Login: l}, gaps: map[string][]int64{}, drop: map[string]int{}}
		}
		return by[k]
	}
	var hours [24]struct {
		r     store.LinkRTT
		drops int
	}
	for _, r := range rtts {
		a := get(r.Host, r.Login)
		a.r.N += r.N
		a.r.Fails += r.Fails
		a.r.SumMS += r.SumMS
		if r.MaxMS > a.r.MaxMS {
			a.r.MaxMS = r.MaxMS
		}
		h := &hours[(int(r.Hour%24)+beijingOffsetHours)%24].r
		h.N += r.N
		h.Fails += r.Fails
		h.SumMS += r.SumMS
		if r.MaxMS > h.MaxMS {
			h.MaxMS = r.MaxMS
		}
		for i := range r.Buckets {
			a.r.Buckets[i] += r.Buckets[i]
			h.Buckets[i] += r.Buckets[i]
		}
	}
	for _, e := range evs {
		// a drop is a connect after a gap: first sight and a machine that was off are not drops
		if e.Event != linkEventUp || e.Cause == linkCauseFirst || e.Cause == linkCauseOffline {
			continue
		}
		a := get(e.Host, e.Login)
		a.drop[e.Cause]++
		a.gaps[e.Cause] = append(a.gaps[e.Cause], e.GapMS)
		hours[(e.At.UTC().Hour()+beijingOffsetHours)%24].drops++
	}
	out := linkStats{Days: days, Links: []linkOne{}, Hours: []linkHourStat{}}
	for _, a := range by {
		one := linkOne{Host: a.r.Host, Login: a.r.Login, Pings: a.r.N + 0, RTTMax: a.r.MaxMS, Drops: a.drop, Gaps: map[string]gapMS{}}
		if a.r.N > 0 {
			one.FailRate = float64(a.r.Fails) / float64(a.r.N)
		}
		if ok := a.r.N - a.r.Fails; ok > 0 {
			one.RTTMean = float64(a.r.SumMS) / float64(ok)
			one.RTTP50 = bucketPct(a.r.Buckets, a.r.MaxMS, 0.5)
			one.RTTP90 = bucketPct(a.r.Buckets, a.r.MaxMS, 0.9)
		}
		total := 0
		for c, g := range a.gaps {
			total += len(g)
			one.Gaps[c] = gapMS{P50: pctInt(g, 0.5), P90: pctInt(g, 0.9), Max: pctInt(g, 1)}
		}
		if days > 0 {
			one.PerDay = float64(total) / float64(days)
		}
		out.Links = append(out.Links, one)
	}
	sort.Slice(out.Links, func(i, j int) bool {
		if out.Links[i].Host != out.Links[j].Host {
			return out.Links[i].Host < out.Links[j].Host
		}
		return out.Links[i].Login < out.Links[j].Login
	})
	for h, v := range hours {
		st := linkHourStat{Hour: h, Pings: v.r.N, Drops: v.drops}
		if v.r.N > 0 {
			st.FailRate = float64(v.r.Fails) / float64(v.r.N)
		}
		if ok := v.r.N - v.r.Fails; ok > 0 {
			st.RTTMean = float64(v.r.SumMS) / float64(ok)
			st.RTTP90 = bucketPct(v.r.Buckets, v.r.MaxMS, 0.9)
		}
		out.Hours = append(out.Hours, st)
	}
	return out
}

func (s *Server) handleLinkStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	days := 7
	if v := r.URL.Query().Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 90 {
			httpError(w, http.StatusBadRequest, "days: 1 to 90")
			return
		}
		days = n
	}
	now := time.Now()
	since := now.Add(-time.Duration(days) * 24 * time.Hour)
	// old rows go as the stats are read: nothing else writes here but the links
	if err := s.Store.PruneLinkStats(now.Add(-linkKeep)); err != nil {
		log.Printf("link stats: prune: %v", err)
	}
	evs, err := s.Store.LinkEvents(since)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rtts, err := s.Store.LinkRTTs(since)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, linkStatsOf(days, evs, rtts))
}
