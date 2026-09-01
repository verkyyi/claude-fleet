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

// maxEventsPerBatch bounds one push.
//
// A first scan on a busy machine can yield tens of thousands of turns, which
// as a single JSON document runs to hundreds of megabytes — past the hub's
// request cap and past the spool's. Chunking keeps every batch comfortably
// inside both, and the hub dedups so the split costs nothing.
const maxEventsPerBatch = 2000

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
}

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
				// A failed cycle is normal on a flaky link; the spool holds the
				// data and the next tick retries.
				log.Printf("collection cycle: %v", err)
			}
			timer.Reset(jitter(a.cfg.ScanInterval))
		}
	}
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

	// Queue every chunk before advancing the cursor. If any enqueue fails the
	// cursor stays put and the whole scan is retried next cycle — losing a
	// batch silently is the one outcome worth paying a re-read to avoid.
	for i, chunk := range chunkEvents(evs, maxEventsPerBatch) {
		batch := model.Batch{AgentVersion: a.cfg.Version, Identity: *id, Events: chunk}
		if i == 0 {
			// The limits reading rides along with the first chunk so it is not
			// duplicated across every one of them.
			batch.Limits, batch.LimitsUnavailable = snap, unavailable
		}
		if err := a.spool.Enqueue(batch); err != nil {
			return fmt.Errorf("queue batch: %w", err)
		}
	}

	if err := a.scanner.Commit(); err != nil {
		// The events are queued and will still be delivered; the cost of a
		// failed commit is re-sending them, which the hub dedups.
		log.Printf("could not save scan position: %v", err)
	}
	return a.drain(ctx)
}

// chunkEvents splits events into batches of at most n.
//
// Always returns at least one chunk, so a cycle carrying only a limits reading
// still produces a batch.
func chunkEvents(evs []model.UsageEvent, n int) [][]model.UsageEvent {
	if len(evs) == 0 {
		return [][]model.UsageEvent{nil}
	}
	var out [][]model.UsageEvent
	for start := 0; start < len(evs); start += n {
		end := start + n
		if end > len(evs) {
			end = len(evs)
		}
		out = append(out, evs[start:end])
	}
	return out
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
