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
	"path/filepath"
	"time"

	"github.com/verkyyi/ccquota/internal/identity"
	"github.com/verkyyi/ccquota/internal/limits"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/scan"
	"github.com/verkyyi/ccquota/internal/spool"
)

// Config configures one endpoint's collector.
type Config struct {
	HubURL   string // e.g. https://ccquota.example.com
	Token    string // enrollment token
	Home     string // Claude Code home; defaults to the user's home
	StateDir string // cursor + spool live here

	ScanInterval   time.Duration
	LimitsInterval time.Duration
	SpoolMaxBytes  int64
	Version        string

	// Once runs a single cycle and returns, for cron-driven deployments.
	Once bool
}

// Defaults for the intervals.
const (
	DefaultScanInterval   = 60 * time.Second
	DefaultLimitsInterval = 120 * time.Second
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

	// consecutiveFailures backs the scan cadence off while the hub is
	// unreachable. A failed cycle leaves the cursor unmoved, so the next scan
	// re-reads everything — cheap once, wasteful every minute for an hour.
	consecutiveFailures int
}

// maxBackoffFactor caps how far a failing agent stretches its scan interval.
const maxBackoffFactor = 16

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

	// Jitter the first tick so a fleet restarted together by a config
	// management run does not stampede the hub.
	initial := time.Duration(rand.Int63n(int64(a.cfg.ScanInterval)))
	timer := time.NewTimer(initial)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
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

	// Nothing new and nothing to report: skip the round trip entirely.
	if len(evs) == 0 && snap == nil && unavailable == "" {
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
		batch := model.Batch{AgentVersion: a.cfg.Version, Identity: *id, Events: chunk}
		if i == 0 {
			// The limits reading rides along with the first chunk so it is not
			// duplicated across every one of them.
			batch.Limits, batch.LimitsUnavailable = snap, unavailable
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

	if queuedAll {
		if err := a.scanner.Commit(); err != nil {
			// The events are queued and will still be delivered; the cost of a
			// failed commit is re-sending them, which the hub dedups.
			log.Printf("could not save scan position: %v", err)
		}
	}
	return a.drain(ctx)
}

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
