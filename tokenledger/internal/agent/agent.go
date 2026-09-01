// Package agent runs on each endpoint: it scans this machine's transcripts,
// reads this account's true limits locally, and pushes both to the hub.
//
// Two properties matter more than anything else here.
//
// The agent NEVER sends an OAuth token to the hub. It calls Anthropic itself
// and ships only the resulting numbers, so a compromised hub leaks usage
// statistics and never account access.
//
// The agent NEVER refreshes an OAuth token. Refreshing races Claude Code's own
// refresh and could log the user out of the very thing being monitored.
package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"

	"github.com/verkyyi/ccquota/internal/identity"
	"github.com/verkyyi/ccquota/internal/limits"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/scan"
	"github.com/verkyyi/ccquota/internal/sessions"
	"github.com/verkyyi/ccquota/internal/spool"
)

// Config configures one endpoint's collector.
type Config struct {
	HubURL   string // e.g. https://ccquota.example.com
	Token    string // enrollment token
	Home     string // Claude Code home; defaults to the user's home
	StateDir string // cursor + spool live here

	// SessionsDir is where the statusLine hook writes its stamps.
	//
	// Deliberately NOT derived from StateDir. Stamps are written by a hook
	// that knows nothing about which agent instance will read them, so tying
	// them to an agent's private state directory made the two silently
	// disagree — the hook wrote to ~/.ccquota/sessions while an agent started
	// with --state ~/.ccquota/agent looked in ~/.ccquota/agent/sessions and
	// found nothing, with no error anywhere.
	SessionsDir string

	ScanInterval   time.Duration
	LimitsInterval time.Duration
	SpoolMaxBytes  int64
	Version        string

	// LiveInterval is how often the running-session heartbeat is sent.
	//
	// Separate from ScanInterval on purpose: the heartbeat only reads a few
	// small stamp files written by the statusLine hook, so it can be seconds
	// where a transcript scan must be a minute.
	LiveInterval time.Duration

	// MaxBackfill optionally narrows how far back a scan reaches. Zero means
	// "as far as the account boundary allows".
	//
	// Attribution gets less trustworthy the further back you go — the login
	// that produced a turn six months ago is unknowable — so an operator who
	// only cares about recent spend can cut the uncertainty out entirely
	// rather than have it silently attributed to today's account.
	MaxBackfill time.Duration

	// Once runs a single cycle and returns, for cron-driven deployments.
	Once bool

	// AccountsDir holds one file per subscription, named for the account and
	// containing an OAuth token (the shape `claude setup-token` produces).
	//
	// Opt-in and empty by default. Reading a meter this way costs an inference
	// call against that subscription, so it happens only for accounts an
	// operator has explicitly handed over, and only when nothing cheaper has
	// observed them.
	AccountsDir string
}

// Defaults for the intervals.
//
// The scan interval used to be 60s, chosen when every cycle re-opened and
// re-fingerprinted every transcript to verify its cursor. That cost 755ms on a
// machine with 25,164 of them whether or not anything had changed, and it put a
// hard floor under how live the stored totals could be.
//
// The scanner now skips a transcript whose size and mtime both match the
// cursor, using data the directory walk already has: the same no-change cycle
// costs 134ms. Fifteen seconds is affordable at that price — under 1% of a core
// — and it is the single largest term in how stale the dashboard's numbers are.
const (
	DefaultScanInterval   = 15 * time.Second
	DefaultLimitsInterval = 120 * time.Second
	DefaultLiveInterval   = 5 * time.Second
)

// maxEventsPerBatch bounds one push by count.
//
// A first scan on a busy machine can yield tens of thousands of turns, which as
// a single JSON document runs to hundreds of megabytes — past the hub's request
// cap and past the spool's. The hub dedups, so splitting costs nothing.
const maxEventsPerBatch = 2000

// maxBatchBytes bounds one push by size, which is the limit that actually
// matters: a count-only split still produces a batch too big for the spool when
// turns are large, and a batch that cannot ever fit wedges the agent forever.
const maxBatchBytes = 4 << 20

// spoolFraction keeps a single batch to at most this fraction of the spool, so
// several always fit and the queue can never be blocked by one entry.
const spoolFraction = 4

// Agent is a running collector.
type Agent struct {
	cfg     Config
	scanner *scan.Scanner
	spool   *spool.Spool
	limits  *limits.Client
	http    *http.Client

	// lastLimitsPoll throttles the Anthropic call independently of the scan
	// loop, so a fast scan cadence does not hammer the usage endpoint.
	lastLimitsPoll time.Time

	// serverInterval is the poll interval the hub asked for, if any. It lets a
	// noisy fleet be backed off centrally without editing every machine.
	serverInterval time.Duration

	// lastAccountProbe throttles the inference-header probe, per token file.
	lastAccountProbe map[string]time.Time

	// lastStampLimits is the newest statusLine timestamp already reported as a
	// limits reading, per subscription. Without it every scan would re-send the
	// same reading and limit_snapshots would fill with duplicates.
	lastStampLimits map[string]time.Time

	// stamps maps sessions to the subscription they ran on, when the
	// statusLine hook is installed.
	stamps *sessions.Index

	// machineFingerprint is the reset-phase identity of the machine's own
	// login. Sessions matching it are not a separate subscription, they are
	// the default one seen through the heuristic.
	machineFingerprint string

	// consecutiveFailures backs the scan cadence off while the hub is
	// unreachable. A failed cycle leaves the cursor unmoved, so the next scan
	// re-reads everything — cheap once, wasteful every minute for an hour.
	consecutiveFailures int
}

// maxBackoffFactor caps how far a failing agent stretches its scan interval.
const maxBackoffFactor = 16

// stampMaxAge is how long a session stamp is trusted.
//
// A stamp says which subscription a session was on when it was written. Long
// after the session ends, that is history rather than fact — and a session that
// stopped stamping may have been restarted on a different account.
const stampMaxAge = 7 * 24 * time.Hour

// New builds an Agent.
func New(cfg Config) (*Agent, error) {
	if cfg.HubURL == "" {
		return nil, errors.New("hub URL is required")
	}
	if cfg.Token == "" {
		return nil, errors.New("enrollment token is required (run `ccquota enroll` on the hub)")
	}
	if cfg.ScanInterval <= 0 {
		cfg.ScanInterval = DefaultScanInterval
	}
	if cfg.LimitsInterval <= 0 {
		cfg.LimitsInterval = DefaultLimitsInterval
	}
	if cfg.LiveInterval <= 0 {
		cfg.LiveInterval = DefaultLiveInterval
	}
	if cfg.SessionsDir == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("resolve home for the sessions directory: %w", err)
		}
		cfg.SessionsDir = filepath.Join(h, ".ccquota")
	}

	sp, err := spool.New(filepath.Join(cfg.StateDir, "spool"), cfg.SpoolMaxBytes)
	if err != nil {
		return nil, err
	}

	return &Agent{
		cfg:     cfg,
		scanner: scan.NewScanner(identity.ProjectsDir(cfg.Home), filepath.Join(cfg.StateDir, "cursor.json")),
		spool:   sp,
		limits:  limits.New(),
		http:    &http.Client{Timeout: 60 * time.Second},
	}, nil
}

// Run collects until the context is cancelled, or once when cfg.Once is set.
func (a *Agent) Run(ctx context.Context) error {
	if a.cfg.Once {
		return a.cycle(ctx)
	}

	// The heartbeat runs on its own cadence: it reads a handful of small files
	// and must stay responsive even while a first scan is grinding through a
	// machine's whole history.
	go a.runLive(ctx)

	// A transcript being written is the actual signal; the interval is the
	// fallback for when the watch misses one. wake is buffered so a burst of
	// writes collapses into a single pending cycle instead of blocking the
	// watcher or queueing cycles behind each other.
	wake := make(chan struct{}, 1)
	go a.watchTranscripts(ctx, identity.ProjectsDir(a.cfg.Home), func() {
		select {
		case wake <- struct{}{}:
		default:
		}
	})

	// Jitter the first tick so a fleet restarted together by a config
	// management run does not stampede the hub.
	initial := time.Duration(rand.Int63n(int64(a.cfg.ScanInterval)))
	timer := time.NewTimer(initial)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-wake:
			if err := a.cycle(ctx); err != nil {
				log.Printf("collection cycle: %v", err)
			}
			// Reset the fallback: a watch-driven cycle has just done the
			// timer's job, so the next tick should be a full interval away.
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(jitter(a.backoffInterval()))
		case <-timer.C:
			if err := a.cycle(ctx); err != nil {
				// A failed cycle is normal on a flaky link; the transcripts
				// still hold the data and the next tick retries.
				log.Printf("collection cycle: %v", err)
				if a.consecutiveFailures < 30 {
					a.consecutiveFailures++
				}
			} else {
				a.consecutiveFailures = 0
			}
			timer.Reset(jitter(a.backoffInterval()))
		}
	}
}

// backoffInterval doubles the scan interval per consecutive failure, capped.
func (a *Agent) backoffInterval() time.Duration {
	factor := 1 << min(a.consecutiveFailures, 4)
	if factor > maxBackoffFactor {
		factor = maxBackoffFactor
	}
	return a.cfg.ScanInterval * time.Duration(factor)
}

// runLive reports the sessions currently running on this machine.
//
// It sends what each session's own statusLine last said about itself, which is
// seconds old — far fresher than the transcript scan, and Claude Code's own
// arithmetic rather than a re-derivation of it. Nothing here is durable: a
// missed heartbeat costs a few seconds of liveness and no recorded usage.
func (a *Agent) runLive(ctx context.Context) {
	t := time.NewTicker(a.cfg.LiveInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := a.pushLive(ctx); err != nil {
				// Deliberately quiet: the hub being briefly unreachable is
				// normal and this path has nothing to preserve.
				continue
			}
		}
	}
}

// liveStaleAfter bounds how old a stamp may be and still count as running.
//
// The statusLine redraws on every turn, so a working session stamps far more
// often. Anything older has stopped, and showing it as live would be a lie the
// viewer cannot check.
const liveStaleAfter = 2 * time.Minute

func (a *Agent) pushLive(ctx context.Context) error {
	idx, err := sessions.Load(a.cfg.SessionsDir, liveStaleAfter)
	if err != nil || len(idx.BySession) == 0 {
		return err
	}

	out := make([]liveSession, 0, len(idx.BySession))
	for _, st := range idx.BySession {
		if st.Live == nil {
			continue
		}
		out = append(out, liveSession{
			SessionID:      st.SessionID,
			Account:        st.Account(),
			CostUSD:        st.Live.CostUSD,
			InputTokens:    st.Live.InputTokens,
			OutputTokens:   st.Live.OutputTokens,
			LinesAdded:     st.Live.LinesAdded,
			LinesRemoved:   st.Live.LinesRemoved,
			ContextUsedPct: st.Live.ContextUsedPct,
			CacheHitRatio:  st.Live.CacheHitRatio,
			Model:          st.Live.ModelDisplay,
			Effort:         st.Live.Effort,
			Worktree:       st.Live.Worktree,
			CWD:            st.CWD,
			Billing:        st.Billing,
		})
	}
	if len(out) == 0 {
		return nil
	}

	body, err := json.Marshal(map[string]any{"sessions": out})
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		a.cfg.HubURL+"/v1/live/report", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
	return nil
}

// liveSession mirrors the hub's shape without importing the api package, which
// would be a dependency cycle.
type liveSession struct {
	SessionID      string  `json:"session_id"`
	Account        string  `json:"account,omitempty"`
	CostUSD        float64 `json:"cost_usd"`
	InputTokens    int64   `json:"input_tokens"`
	OutputTokens   int64   `json:"output_tokens"`
	LinesAdded     int64   `json:"lines_added"`
	LinesRemoved   int64   `json:"lines_removed"`
	ContextUsedPct float64 `json:"context_used_pct"`
	CacheHitRatio  float64 `json:"cache_hit_ratio"`
	Model          string  `json:"model,omitempty"`
	Effort         string  `json:"effort,omitempty"`
	Worktree       string  `json:"worktree,omitempty"`
	CWD            string  `json:"cwd,omitempty"`
	Billing        string  `json:"billing,omitempty"`
}

// jitter spreads a fleet's requests by ±20%.
func jitter(d time.Duration) time.Duration {
	spread := float64(d) * 0.2
	return d + time.Duration(rand.Float64()*2*spread-spread)
}

// cycle does one scan, one conditional limits poll, and drains the spool.
func (a *Agent) cycle(ctx context.Context) error {
	id, err := identity.Detect(a.cfg.Home)
	if err != nil {
		return fmt.Errorf("identify this machine: %w", err)
	}

	// Reloaded every cycle: sessions start, stop and change subscription while
	// the agent runs.
	if idx, err := sessions.Load(a.cfg.SessionsDir, stampMaxAge); err != nil {
		log.Printf("read session stamps: %v", err)
	} else {
		a.stamps = idx
	}

	evs, err := a.scanner.Scan()
	if err != nil {
		return fmt.Errorf("scan transcripts: %w", err)
	}
	for _, e := range a.scanner.Errs {
		log.Printf("transcript warning: %v", e)
	}

	// Credentials give the account tier as well as the token, so read them even
	// when it is not yet time to poll.
	creds, credErr := identity.LoadCredentials(a.cfg.Home)
	if creds != nil {
		id.SubscriptionType = creds.SubscriptionType
		id.RateLimitTier = creds.RateLimitTier
	}

	var snap *model.LimitsSnapshot
	var unavailable string
	if a.shouldPollLimits() {
		snap, unavailable = a.pollLimits(ctx, creds, credErr)
		a.lastLimitsPoll = time.Now()
	}
	// Learn the machine login's own reset phase, so sessions on that same
	// subscription are not mistaken for a different one.
	if snap != nil {
		a.machineFingerprint = sessions.FingerprintFor(snap.SevenDay.ResetsAt)
	}

	// Grouping must come AFTER the fingerprint is known. Deciding what belongs
	// to "another subscription" while ignorant of this machine's own schedule
	// split the machine's own sessions into a phantom account on every restart.
	// Split by the subscription each SESSION actually ran on, not by the
	// machine's login. Claude Code takes CLAUDE_CODE_OAUTH_TOKEN from the
	// environment, so sessions on one machine can be on different
	// subscriptions at the same moment; ~/.claude.json only records the last
	// interactive login and cannot see them.
	groups, unstamped := a.groupBySubscription(evs, id)
	if len(groups) > 1 {
		log.Printf("this machine has %d subscriptions in play; attributing per session", len(groups))
	}

	evs, attribution := a.filterAttributable(unstamped, id)
	if attribution.DroppedPreAccount > 0 {
		log.Printf("dropped %d turn(s) older than this account (earliest %s): they cannot belong to %s",
			attribution.DroppedPreAccount,
			attribution.EarliestDropped.Format("2006-01-02"), id.Email)
	}
	if attribution.DroppedBeyondBackfill > 0 {
		log.Printf("dropped %d turn(s) beyond the %s backfill window",
			attribution.DroppedBeyondBackfill, attribution.BackfillLimit)
	}

	// Utilization for every subscription a session is running under. Computed
	// BEFORE the early return below: an idle machine has no new turns but its
	// sessions are still reporting their accounts' rate limits every few
	// seconds, and that is precisely the case this exists to capture.
	stampLimits := a.limitsFromStamps(time.Now().UTC())

	// Anything already covered for free this cycle must not be probed: a probe
	// is an inference call, and paying for a reading somebody else just gave us
	// would make watching a subscription part of what consumes it.
	observed := map[string]bool{id.AccountUUID: snap != nil}
	for _, l := range stampLimits {
		observed[l.AccountUUID] = true
	}
	stampLimits = append(stampLimits, a.probeAccounts(ctx, observed)...)

	// Nothing new and nothing to report: skip the round trip entirely.
	if len(evs) == 0 && snap == nil && unavailable == "" && attribution.IsZero() &&
		len(stampLimits) == 0 {
		return a.drain(ctx)
	}

	// Queue every chunk, then advance the cursor ONLY if every one of them
	// landed. The transcripts are the durable copy; the scan position is the
	// only thing that decides whether unqueued events can still be recovered.
	// Advancing it after a partial enqueue is how a first scan against a down
	// hub loses half its data with nothing but a log line to show for it.
	chunks := chunkEvents(evs, maxEventsPerBatch, a.batchByteLimit())
	queuedAll := true
	for i, chunk := range chunks {
		batch := model.Batch{
			AgentVersion: a.cfg.Version,
			Identity:     *id,
			Events:       chunk,
			// This is the machine's own login, read from ~/.claude.json. Only
			// these batches are allowed to move the endpoint's account, so
			// only a change here counts as a real logout/login.
			AccountOrigin: model.OriginLogin,
		}
		if i == 0 {
			// The limits reading and the attribution report ride along with the
			// first chunk so they are not duplicated across every one of them.
			batch.Limits, batch.LimitsUnavailable = snap, unavailable
			if !attribution.IsZero() {
				batch.Attribution = &attribution
			}
		}

		err := a.spool.Enqueue(batch)
		if errors.Is(err, spool.ErrFull) {
			// A full spool is not necessarily a dead hub — a large first scan
			// fills it faster than one drain empties it. Push what is queued,
			// then try this batch once more.
			if derr := a.drain(ctx); derr != nil {
				log.Printf("spool full and the hub is unreachable (%v); holding the scan "+
					"position at batch %d/%d so nothing is lost", derr, i+1, len(chunks))
				queuedAll = false
				break
			}
			err = a.spool.Enqueue(batch)
		}
		if err != nil {
			log.Printf("could not queue batch %d/%d: %v; holding the scan position", i+1, len(chunks), err)
			queuedAll = false
			break
		}
	}

	// Sessions stamped as belonging to another subscription go out under that
	// identity. Their events were already excluded from the default group.
	for key, g := range groups {
		if key == "" {
			continue
		}
		gid := *id
		gid.AccountUUID = key
		// An inferred subscription must NOT inherit the machine login's email.
		// Borrowing it made a third account show up in the hub wearing the
		// name of the second — worse than showing an opaque key, because it
		// looks correct.
		gid.Email, gid.DisplayName, gid.OrgUUID, gid.OrgName = "", "", "", ""
		if g.label != "" {
			gid.Email = g.label
		} else if g.inferred {
			gid.DisplayName = "unidentified subscription"
		}
		// The account-creation boundary belongs to the machine login, not to
		// this subscription; applying it here would drop the wrong turns.
		gid.AccountCreatedAt = time.Time{}
		gid.SubscriptionType, gid.RateLimitTier = "", ""

		for i, chunk := range chunkEvents(g.events, maxEventsPerBatch, a.batchByteLimit()) {
			b := model.Batch{
				AgentVersion: a.cfg.Version,
				Identity:     gid,
				Events:       chunk,
				// A subscription observed in a session's statusLine, not what
				// the machine is logged into. Several of these are live at
				// once; the hub must not read them as the machine changing
				// account back and forth.
				AccountOrigin: model.OriginSession,
			}
			if i == 0 && g.limits != nil {
				b.Limits = g.limits
			}
			if err := a.spool.Enqueue(b); err != nil {
				log.Printf("could not queue a batch for %s: %v; holding the scan position", g.name(key), err)
				queuedAll = false
				break
			}
		}
	}

	// Utilization for every subscription a session is running under, including
	// ones with no new turns to file and ones this machine cannot authenticate
	// as. This is the only source that works when the stored token has expired,
	// which on an idle machine it always eventually has.
	for _, snap := range stampLimits {
		lid := *id
		lid.AccountUUID = snap.AccountUUID
		lid.Email, lid.DisplayName, lid.OrgUUID, lid.OrgName = "", "", "", ""
		lid.AccountCreatedAt = time.Time{}
		lid.SubscriptionType, lid.RateLimitTier = "", ""
		origin := model.OriginSession
		if snap.AccountUUID == id.AccountUUID {
			// This machine's own login, observed through a session rather than
			// through the credentials API. Same account, so say so.
			lid = *id
			origin = model.OriginLogin
		}
		if err := a.spool.Enqueue(model.Batch{
			AgentVersion:  a.cfg.Version,
			Identity:      lid,
			Limits:        snap,
			AccountOrigin: origin,
		}); err != nil {
			log.Printf("could not queue a limits reading for %s: %v", snap.AccountUUID, err)
		}
	}

	if queuedAll {
		if err := a.scanner.Commit(); err != nil {
			// The events are queued and will still be delivered; the cost of a
			// failed commit is re-sending them, which the hub dedups.
			log.Printf("could not save scan position: %v", err)
		}
	}
	err = a.drain(ctx)

	// A first scan holds every event of a busy machine's history in memory at
	// once, and Go does not hand that back on its own — measured at 344 MB RSS
	// still resident long after the scan finished. Steady-state cycles are
	// tiny, so this daemon has no business sitting on a third of a gigabyte
	// for the rest of the day.
	if len(evs) > memoryReleaseThreshold {
		debug.FreeOSMemory()
	}
	return err
}

// memoryReleaseThreshold is the batch size past which returning memory to the
// OS is worth the pause. Ordinary cycles move a handful of events and should
// not pay for a forced GC.
const memoryReleaseThreshold = 5000

// batchByteLimit keeps one batch small enough that several fit in the spool.
func (a *Agent) batchByteLimit() int {
	limit := maxBatchBytes
	if a.cfg.SpoolMaxBytes > 0 {
		if share := int(a.cfg.SpoolMaxBytes) / spoolFraction; share < limit {
			limit = share
		}
	}
	if limit < 4<<10 {
		limit = 4 << 10 // a floor, so a pathological config still makes progress
	}
	return limit
}

// subGroup is one subscription's share of a scan.
type subGroup struct {
	events []model.UsageEvent
	label  string
	limits *model.LimitsSnapshot

	// inferred marks a group identified by the reset-phase heuristic rather
	// than by a token. The hub labels these so nobody reads a guess as a fact.
	inferred bool
}

func (g subGroup) name(key string) string {
	if g.label != "" {
		return g.label
	}
	return key
}

// groupBySubscription splits a scan by the account each session was signed in
// to, using stamps written by `ccquota stamp` from inside those sessions.
//
// Returns the stamped groups plus the events that carry no stamp, which the
// caller attributes to the machine-wide login as before. An unstamped machine
// therefore behaves exactly as it did — the hook is opt-in — but a stamped one
// stops misfiling other subscriptions' spend.
func (a *Agent) groupBySubscription(evs []model.UsageEvent, id *model.Identity) (map[string]*subGroup, []model.UsageEvent) {
	groups := map[string]*subGroup{}
	if a.stamps == nil || len(a.stamps.ByTranscript) == 0 {
		return groups, evs
	}

	var unstamped []model.UsageEvent
	for _, e := range evs {
		st, ok := a.stamps.ByTranscript[e.TranscriptPath]
		key := ""
		if ok {
			key = st.Account()
		}
		// No usable identifier means the session looked like the machine login,
		// which is the default path.
		if key == "" || key == id.AccountUUID || key == a.machineFingerprint {
			unstamped = append(unstamped, e)
			continue
		}
		g := groups[key]
		if g == nil {
			g = &subGroup{label: st.Label, limits: limitsFromStamp(st, key), inferred: st.AccountIsInferred()}
			groups[key] = g
		}
		g.events = append(g.events, e)
	}
	return groups, unstamped
}

// limitsFromStamp turns the rate_limits Claude Code reports in the statusLine
// payload into a snapshot.
//
// This is the only way to learn a per-session subscription's true utilization:
// the agent cannot read that session's token, so it cannot call the usage
// endpoint on its behalf.
func limitsFromStamp(st sessions.Stamp, key string) *model.LimitsSnapshot {
	if st.FiveHourPct == nil && st.SevenDayPct == nil {
		return nil
	}
	snap := &model.LimitsSnapshot{AccountUUID: key, ObservedAt: st.StampedAt}
	if st.FiveHourPct != nil {
		snap.FiveHour = model.Window{Utilization: *st.FiveHourPct, ResetsAt: st.FiveHourAt}
	}
	if st.SevenDayPct != nil {
		snap.SevenDay = model.Window{Utilization: *st.SevenDayPct, ResetsAt: st.SevenDayAt}
	}
	return snap
}

// filterAttributable removes turns this account provably did not produce.
//
// Transcripts carry no account, so a first scan would otherwise stamp a
// machine's ENTIRE history with whichever login happens to be active — the
// single largest source of wrong attribution in this system. Two cuts:
//
//   - Turns older than the account itself. Provably not this subscription's;
//     dropped unconditionally, because ingesting them would be a known lie.
//   - Turns older than an operator-chosen --max-backfill window. Not provably
//     wrong, just not worth trusting.
//
// What is dropped is counted and reported, never silently discarded: a total
// that quietly excludes history is its own kind of lie.
func (a *Agent) filterAttributable(evs []model.UsageEvent, id *model.Identity) ([]model.UsageEvent, model.Attribution) {
	var att model.Attribution
	if a.cfg.MaxBackfill > 0 {
		att.BackfillLimit = a.cfg.MaxBackfill.String()
	}

	accountFloor := id.AccountCreatedAt
	var backfillFloor time.Time
	if a.cfg.MaxBackfill > 0 {
		backfillFloor = time.Now().Add(-a.cfg.MaxBackfill)
	}

	kept := evs[:0]
	for _, e := range evs {
		// A zero timestamp cannot be judged against either floor; keep it and
		// let it be visible rather than silently vanish.
		if !e.TS.IsZero() {
			if !accountFloor.IsZero() && e.TS.Before(accountFloor) {
				att.DroppedPreAccount++
				if att.EarliestDropped == nil || e.TS.Before(*att.EarliestDropped) {
					t := e.TS
					att.EarliestDropped = &t
				}
				continue
			}
			if !backfillFloor.IsZero() && e.TS.Before(backfillFloor) {
				att.DroppedBeyondBackfill++
				continue
			}
		}
		kept = append(kept, e)
	}
	return kept, att
}

// chunkEvents splits events into batches bounded by BOTH a count and a
// serialized byte size.
//
// The byte bound is the one that matters. Splitting on count alone produced
// batches larger than the spool whenever turns were big, and a batch that can
// never fit is not a slow path — it wedges the agent permanently.
//
// Always returns at least one chunk, so a cycle carrying only a limits reading
// still produces a batch.
func chunkEvents(evs []model.UsageEvent, maxCount, maxBytes int) [][]model.UsageEvent {
	if len(evs) == 0 {
		return [][]model.UsageEvent{nil}
	}
	var out [][]model.UsageEvent
	start, bytes := 0, 0
	for i := range evs {
		size := approxSize(&evs[i])
		// Break before adding this event if it would push the batch past
		// either bound — but never emit an empty chunk.
		if i > start && (i-start >= maxCount || bytes+size > maxBytes) {
			out = append(out, evs[start:i])
			start, bytes = i, 0
		}
		bytes += size
	}
	return append(out, evs[start:])
}

// approxSize estimates an event's JSON size without marshalling it. Exactness
// is not needed: the bound only has to keep batches comfortably under the
// spool's cap, and marshalling every event twice would double the cost of a
// scan on a busy machine.
func approxSize(e *model.UsageEvent) int {
	const fixed = 420 // field names, numbers, punctuation
	return fixed + len(e.MessageUUID) + len(e.SessionID) + len(e.RequestID) +
		len(e.Model) + len(e.CWD) + len(e.GitBranch) + len(e.Entrypoint) + len(e.Effort)
}

func (a *Agent) shouldPollLimits() bool {
	interval := a.cfg.LimitsInterval
	if a.serverInterval > 0 {
		interval = a.serverInterval
	}
	return time.Since(a.lastLimitsPoll) >= interval
}

// pollLimits reads the true account-wide numbers, returning a reason instead of
// a zeroed snapshot whenever it cannot.
func (a *Agent) pollLimits(ctx context.Context, creds *identity.Credentials, credErr error) (*model.LimitsSnapshot, string) {
	if credErr != nil {
		if errors.Is(credErr, identity.ErrTokenExpired) {
			// Not repaired on purpose — refreshing would race Claude Code.
			return nil, "the local OAuth token has expired; it refreshes when Claude Code next runs"
		}
		return nil, "no readable credentials on this endpoint: " + credErr.Error()
	}
	if creds == nil {
		return nil, "no readable credentials on this endpoint"
	}

	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	snap, err := a.limits.Fetch(ctx, creds.AccessToken)
	if err != nil {
		return nil, err.Error()
	}
	return snap, ""
}

// drain pushes queued batches until the queue is empty or the hub refuses.
func (a *Agent) drain(ctx context.Context) error {
	for {
		var batch model.Batch
		ack, ok, err := a.spool.Peek(&batch)
		if err != nil {
			return err
		}
		if !ok {
			return nil
		}
		resp, err := a.push(ctx, &batch)
		if err != nil {
			// Leave the batch queued; the next cycle retries it.
			return err
		}
		if err := ack(); err != nil {
			return err
		}
		if resp.LimitsPollIntervalS > 0 {
			a.serverInterval = time.Duration(resp.LimitsPollIntervalS) * time.Second
		}
		if resp.Accepted > 0 || resp.Deduped > 0 {
			log.Printf("pushed %d new, %d already known", resp.Accepted, resp.Deduped)
		}
	}
}

func (a *Agent) push(ctx context.Context, batch *model.Batch) (*model.IngestResponse, error) {
	body, err := json.Marshal(batch)
	if err != nil {
		return nil, fmt.Errorf("encode batch: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		a.cfg.HubURL+"/v1/ingest", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.Token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("push to hub: %w", err)
	}
	defer resp.Body.Close()

	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("hub rejected the batch: HTTP %d: %s", resp.StatusCode, bytes.TrimSpace(rb))
	}

	var out model.IngestResponse
	if err := json.Unmarshal(rb, &out); err != nil {
		return nil, fmt.Errorf("decode hub response: %w", err)
	}
	return &out, nil
}
