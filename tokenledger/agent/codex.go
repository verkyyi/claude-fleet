package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/identity"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/scan"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/spool"
)

type codexCollector struct {
	home, id, statePath string
	name                string
	selected            bool
	managed             bool
	scanner             *scan.Scanner
	binding             struct {
		Account string    `json:"account"`
		Since   time.Time `json:"since"`
	}
	lastReport     time.Time
	lastResultSent time.Time
	mu             sync.Mutex
	polling        bool
	lastPoll       time.Time
	pollAccount    string
	result         codex.Result
	resultAt       time.Time
	pollError      string
	// failStreak counts account reads that failed in a row; the quota
	// lease request carries it so a collector that keeps failing gives the
	// account up to another (claude-fleet#2169).
	failStreak int
	live       []liveSession // snapshots guarded by mu; scanner itself has one owner
	handedBack bool          // a machine tenant's home: the agent's own leftovers handed to the login
	// handBackReason: the agent's own auth.json from an earlier version was
	// left as it is (codex_handback.go); shown until the login's own reads
	handBackReason string
}

func (a *Agent) codexProfileSnapshot() []*codexCollector {
	a.codexProfilesMu.RLock()
	defer a.codexProfilesMu.RUnlock()
	return append([]*codexCollector(nil), a.codexProfiles...)
}

func (a *Agent) initCodex() error {
	profiles, err := codex.ProfilesWith(a.cfg.Home, a.cfg.CodexHome, a.cfg.CodexHomes, a.loginReader(smallFileMax))
	if err != nil {
		return err
	}
	if ra := a.cfg.RunAs; ra != nil {
		if err := tenantProfilesOK(ra, profiles); err != nil {
			return err
		}
	}
	existing := map[string]*codexCollector{}
	for _, p := range a.codexProfileSnapshot() {
		existing[p.id] = p
	}
	var next []*codexCollector
	for _, profile := range profiles {
		home, id := profile.Home, codex.ProfileID(profile.Home)
		p := existing[id]
		if p == nil {
			cursor := filepath.Join(a.cfg.StateDir, "codex-"+id+"-cursor.json")
			if id == codex.ProfileID(a.cfg.CodexHome) {
				cursor = filepath.Join(a.cfg.StateDir, "codex-cursor.json")
			}
			p = &codexCollector{home: home, id: id, statePath: filepath.Join(a.cfg.StateDir, "codex-"+id+"-account.json"), scanner: scan.NewCodexScanner(home, cursor)}
			p.scanner.Open = a.loginOpener()
			if b, err := os.ReadFile(p.statePath); err == nil {
				if json.Unmarshal(b, &p.binding) != nil {
					return errors.New("invalid Codex account binding state")
				}
			}
		}
		p.name, p.selected, p.managed = profile.Name, profile.Default, profile.Managed
		next = append(next, p)
	}
	a.codexProfilesMu.Lock()
	a.codexProfiles = next
	a.codexProfilesMu.Unlock()
	if a.codex == nil && len(next) > 0 {
		a.codex = next[0].scanner
	}
	return nil
}

// tenantCodexProfilesMax is the most Codex profiles one machine tenant's
// registry may list (each is scanned, renewed and read on the login's behalf);
// far above any real use.
const tenantCodexProfilesMax = 16

// fleetStateDirs are the fleet's own directories in a login's home (its
// state, the agent's records and session stamps, Claude's home); a Codex
// profile is never one of them or inside one.
var fleetStateDirs = []string{".config/claude-fleet", ".ccquota", ".claude"}

// tenantProfilesOK holds a machine tenant's Codex profiles to its login's own
// directories (the registry is the login's to write): each inside the login's
// home and not in one of the fleet's own directories there, and at most
// tenantCodexProfilesMax of them. The error is the reason the hub shows.
func tenantProfilesOK(ra *RunAs, profiles []codex.Profile) error {
	if len(profiles) > tenantCodexProfilesMax {
		return fmt.Errorf("the Codex profile registry lists %d profiles; at most %d are collected for a login", len(profiles), tenantCodexProfilesMax)
	}
	home := filepath.Clean(ra.Home)
	for _, profile := range profiles {
		if !underLogin(ra, profile.Home) {
			return fmt.Errorf("Codex profile %s: %s is not inside %s's home", profile.Name, profile.Home, ra.Login)
		}
		// compared without case: a default macOS volume is case-insensitive
		p := strings.ToLower(filepath.Clean(profile.Home))
		for _, d := range fleetStateDirs {
			d = filepath.Join(home, filepath.FromSlash(d))
			if l := strings.ToLower(d); p == l || strings.HasPrefix(p, l+string(os.PathSeparator)) {
				return fmt.Errorf("Codex profile %s: %s is in the fleet's own directory %s, not a Codex home", profile.Name, profile.Home, d)
			}
		}
	}
	return nil
}

func (p *codexCollector) bind(account string, now time.Time) error {
	if p.binding.Account == account && !p.binding.Since.IsZero() {
		return nil
	}
	previous := p.binding
	p.binding.Account = account
	p.binding.Since = now
	b, _ := json.Marshal(p.binding)
	if err := os.WriteFile(p.statePath+".tmp", b, 0600); err != nil {
		p.binding = previous
		return err
	}
	if err := os.Rename(p.statePath+".tmp", p.statePath); err != nil {
		p.binding = previous
		return err
	}
	p.mu.Lock()
	if p.pollAccount != account {
		p.lastPoll = time.Time{}
	}
	p.mu.Unlock()
	return nil
}

// Already-running and historical sessions keep their unassigned usage pool.
func (p *codexCollector) owns(t scan.CodexTelemetry, at time.Time) bool {
	return p.binding.Account != "" && t.Provider == "openai" && !t.StartedAt.IsZero() && !t.StartedAt.Before(p.binding.Since) && !at.Before(p.binding.Since)
}

func (p *codexCollector) poll(ctx context.Context, acct codexAccount, auth *codex.Auth, binary string, interval time.Duration, once bool, autoRefresh bool, lease func(failures int) bool) {
	if auth == nil || auth.Mode != "subscription" {
		return
	}
	p.mu.Lock()
	if p.polling || (!p.lastPoll.IsZero() && time.Since(p.lastPoll) < interval) {
		p.mu.Unlock()
		return
	}
	p.polling = true
	p.lastPoll = time.Now()
	p.mu.Unlock()
	run := func() {
		// Each credential profile renews independently, even when another
		// endpoint holds this account's quota-query lease.
		var renewalErr error
		if autoRefresh {
			fresh, err := acct.maintain(ctx, binary, p.home, false)
			renewalErr = err
			if fresh != nil && fresh.Identity.AccountUUID == auth.Identity.AccountUUID {
				auth = fresh
			}
			if fresh != nil && fresh.Identity.AccountUUID != auth.Identity.AccountUUID {
				p.mu.Lock()
				p.polling = false
				p.lastPoll = time.Time{}
				p.mu.Unlock()
				return
			}
		}
		p.mu.Lock()
		streak := p.failStreak
		p.mu.Unlock()
		if (auth.ExpiresAt.IsZero() || auth.ExpiresAt.After(time.Now())) && lease != nil && !lease(streak) {
			p.mu.Lock()
			p.polling = false
			p.pollAccount = auth.Identity.AccountUUID
			p.pollError = "quota query delegated to another online collector"
			p.mu.Unlock()
			return
		}
		result, err := acct.query(ctx, binary, p.home, auth, autoRefresh)
		if renewalErr != nil && !auth.ExpiresAt.IsZero() && !auth.ExpiresAt.After(time.Now()) {
			err = renewalErr
		}
		p.mu.Lock()
		defer p.mu.Unlock()
		p.result = result
		p.resultAt = time.Now().UTC()
		p.pollAccount = auth.Identity.AccountUUID
		p.polling = false
		p.pollError = ""
		p.failStreak = 0
		if err != nil {
			p.pollError = err.Error()
			p.failStreak++
		}
	}
	if once {
		run()
	} else {
		go run()
	}
}

func (a *Agent) cycleCodex(ctx context.Context) error {
	var errs []error
	if err := a.initCodex(); err != nil {
		// Keep known scanners alive if an operator is editing the registry.
		if a.cfg.RunAs == nil {
			errs = append(errs, err)
		} else if msg := err.Error(); msg != a.codexInitErr {
			// a machine tenant's: this login's Codex only, said once per change
			// (a cycle error would slow the login's whole collection down)
			log.Printf("machine agent: %s: Codex profiles: %v", a.cfg.RunAs.Login, err)
			a.codexInitErr = msg
		}
	} else {
		a.codexInitErr = ""
	}
	if a.codexInitErr != "" && len(a.codexProfileSnapshot()) == 0 && time.Since(a.codexInitSent) >= time.Minute {
		// no profile to carry it: the registry's own status, so the hub shows
		// why this login's Codex is not collected
		now := time.Now().UTC()
		st := model.CollectorStatus{Source: model.SourceCodex, ProfileID: "default", ObservedAt: now, State: "degraded",
			Reason: clipLine("Codex collection off: "+a.codexInitErr, reasonMax), Capabilities: []string{}}
		if err := a.enqueueCodex(ctx, model.Batch{AgentVersion: a.cfg.Version, Identity: *identity.Codex(), AccountOrigin: model.OriginSession, Collector: &st}); err != nil {
			errs = append(errs, err)
		} else {
			a.codexInitSent = now
			if err := a.drain(ctx); err != nil {
				errs = append(errs, err)
			}
		}
	}
	for _, p := range a.codexProfileSnapshot() {
		if err := a.cycleCodexProfile(ctx, p); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (a *Agent) enqueueCodex(ctx context.Context, b model.Batch) error {
	err := a.spool.Enqueue(b)
	if errors.Is(err, spool.ErrFull) {
		if err := a.drain(ctx); err != nil {
			return err
		}
		err = a.spool.Enqueue(b)
	}
	return err
}

func (a *Agent) cycleCodexProfile(ctx context.Context, p *codexCollector) error {
	now := time.Now().UTC()
	if ra := a.cfg.RunAs; ra != nil && !p.handedBack {
		// once, before the login's first machine-op and the reads below
		res, err := handBackCodexHome(ra, p.home, p.binding.Account)
		switch {
		case err != nil && !os.IsNotExist(err):
			log.Printf("machine agent: %s: Codex home %s: hand back: %v", ra.Login, p.home, err)
		case res.dirs+res.removed > 0 || res.auth:
			log.Printf("machine agent: %s: Codex home %s: earlier agent files repaired (%d directories handed to the login, %d records removed, login file rewritten: %v)", ra.Login, p.home, res.dirs, res.removed, res.auth)
		}
		if res.degraded != "" {
			log.Printf("machine agent: %s: %s", ra.Login, res.degraded)
		}
		p.handBackReason = clipLine(res.degraded, reasonMax)
		p.handedBack = true
	}
	rf := a.loginReader(smallFileMax)
	auth, authErr := codex.ReadAuthWith(p.home, rf)
	current := *identity.Codex()
	billing := "unknown"
	if auth != nil {
		billing = auth.Mode
		if auth.Identity.AccountUUID != "" {
			current.AccountUUID = auth.Identity.AccountUUID
			current.Email = auth.Identity.Email
			current.OrgUUID = auth.Identity.OrgUUID
			current.SubscriptionType = auth.Identity.SubscriptionType
			current.DisplayName = auth.Identity.DisplayName
		}
	}
	bound := ""
	if auth != nil && auth.Identity.AccountUUID != "" {
		bound = auth.Identity.AccountUUID
	}
	if err := p.bindObserved(bound, auth, now, rf); err != nil {
		return fmt.Errorf("save Codex account binding: %w", err)
	}
	interval := a.cfg.LimitsInterval
	if interval < 2*time.Minute {
		interval = 2 * time.Minute
	}
	if a.serverInterval > interval {
		interval = a.serverInterval
	}
	p.poll(ctx, a.codexAcct, auth, a.codexBinary(), jitter(interval), a.cfg.Once, !a.cfg.CodexDisableRefresh, func(failures int) bool {
		return a.codexQuotaLease(ctx, current.AccountUUID, p.id, interval, failures)
	})
	// a machine tenant's linked Codex home or session dir is not followed
	skipped := a.linkedHomePath(p.home, filepath.Join(p.home, "sessions"), filepath.Join(p.home, "archived_sessions"))
	var events []model.UsageEvent
	var err error
	if skipped == "" {
		events, err = p.scanner.Scan()
	} else {
		p.scanner.Errs = nil
	}
	if err != nil {
		return fmt.Errorf("scan Codex transcripts: %w", err)
	}
	// Same declaration as the Claude path, same resolver: a cwd is a cwd.
	a.repos.stampRepos(ctx, events)
	sessions := p.scanner.CodexSessions()
	for _, warning := range p.scanner.Errs {
		log.Printf("Codex transcript warning: %v", warning)
	}
	var live []liveSession
	for _, t := range sessions {
		if t.State != "recent_activity" || t.SeenAt.IsZero() || now.Sub(t.SeenAt) > liveStaleAfter {
			continue
		}
		l := liveSession{Source: model.SourceCodex, ProfileID: p.id, SessionID: t.SessionID, ObservedAt: t.SeenAt, State: t.State, Account: "codex:local", Billing: "unknown", InputTokens: t.InputTokens, OutputTokens: t.OutputTokens, Model: t.Model, Effort: t.Effort, CWD: t.CWD, CostUnknown: true, LinesUnknown: true, ContextUnknown: t.ContextUsedPct == nil}
		if p.owns(t, t.SeenAt) {
			l.Account = current.AccountUUID
			l.Billing = billing
		}
		if t.ContextUsedPct != nil {
			l.ContextUsedPct = *t.ContextUsedPct
		}
		if t.InputTokens > 0 {
			l.CacheHitRatio = float64(t.CacheRead) / float64(t.InputTokens)
		}
		live = append(live, l)
	}
	p.mu.Lock()
	p.live = live
	p.mu.Unlock()
	bySession := map[string]scan.CodexTelemetry{}
	status := model.CollectorStatus{ProfileManaged: p.managed, ProfileName: p.name, ProfileDefault: p.selected, Login: codex.LoginHealthWith(p.home, auth, !a.cfg.CodexDisableRefresh, rf), Source: model.SourceCodex, ProfileID: p.id, ObservedAt: now, State: "idle", BillingMode: billing, Files: p.scanner.FileCount(), Capabilities: []string{"usage", "recent_activity", "quota_snapshots"}}
	if authErr != nil {
		status.LimitsReason = authErr.Error()
	}
	if billing == "api" {
		status.LimitsReason = "API-key usage does not have ChatGPT subscription quota"
	}
	if auth != nil && auth.Mode == "subscription" {
		status.Capabilities = append(status.Capabilities, "account", "quota_query", "account_usage")
	}
	var versionAt time.Time
	for _, t := range sessions {
		bySession[t.SessionID] = t
		if status.LastEventAt == nil || t.UsageAt.After(*status.LastEventAt) {
			if !t.UsageAt.IsZero() {
				v := t.UsageAt
				status.LastEventAt = &v
			}
		}
		at := t.SeenAt
		if at.IsZero() {
			at = t.StartedAt
		}
		if t.ClientVersion != "" && (status.ClientVersion == "" || at.After(versionAt)) {
			status.ClientVersion = t.ClientVersion
			status.ClientVersionBasis = "recent_transcript"
			versionAt = at
		}
	}
	if status.Files == 0 {
		status.State = "no_logs"
	}
	if _, err := os.Stat(p.home); os.IsNotExist(err) {
		status.State = "not_installed"
		status.Reason = "Codex data directory not present"
	}
	if len(p.scanner.Errs) > 0 {
		status.State = "degraded"
		status.Reason = fmt.Sprintf("%d transcript read/parse warning(s); see agent log", len(p.scanner.Errs))
	}
	if skipped != "" {
		status.State, status.Reason = "degraded", skipped
	} else if p.handBackReason != "" {
		if authErr == nil {
			p.handBackReason = "" // signed in again: the login's own file now
		} else {
			status.State, status.Reason = "degraded", p.handBackReason
		}
	}
	if a.codexInitErr != "" && status.Reason == "" {
		status.State, status.Reason = "degraded", clipLine("Codex profiles not reread: "+a.codexInitErr, reasonMax)
	}
	groups := map[string][]model.UsageEvent{}
	ids := map[string]model.Identity{current.AccountUUID: current, "codex:local": *identity.Codex()}
	for _, event := range events {
		if a.cfg.MaxBackfill > 0 && event.TS.Before(now.Add(-a.cfg.MaxBackfill)) {
			continue
		}
		account := "codex:local"
		if p.owns(bySession[event.SessionID], event.TS) {
			account = current.AccountUUID
		}
		if event.Details != nil {
			event.Details.ProfileID = p.id
			if account != "codex:local" {
				event.Details.AccountBasis = "observed_profile_login"
				event.Details.BillingMode = billing
			}
		}
		groups[account] = append(groups[account], event)
	}
	quotas := map[string][]model.QuotaSnapshot{}
	for _, ob := range p.scanner.CodexQuotas {
		if !p.owns(bySession[ob.SessionID], ob.Snapshot.ObservedAt) {
			continue
		}
		if a.cfg.MaxBackfill > 0 && ob.Snapshot.ObservedAt.Before(now.Add(-a.cfg.MaxBackfill)) {
			continue
		}
		q := ob.Snapshot
		q.ProfileID = p.id
		quotas[current.AccountUUID] = append(quotas[current.AccountUUID], q)
	}
	p.mu.Lock()
	result, resultAt, pollAccount, pollError := p.result, p.resultAt, p.pollAccount, p.pollError
	p.mu.Unlock()
	var usage *model.AccountUsage
	if pollAccount == current.AccountUUID && !resultAt.IsZero() {
		status.LimitsCheckedAt = &resultAt
		status.LimitsReason = result.LimitsError
		if pollError != "" {
			status.LimitsReason = pollError
		}
		if result.Version != "" {
			status.ClientVersion = result.Version
			status.ClientVersionBasis = "account_query"
		}
		if resultAt.After(p.lastResultSent) {
			if result.Quota != nil {
				q := *result.Quota
				q.ProfileID = p.id
				quotas[current.AccountUUID] = append(quotas[current.AccountUUID], q)
			}
			usage = result.Usage
		}
	}
	if pollAccount == current.AccountUUID && resultAt.IsZero() && pollError != "" {
		status.LimitsReason = pollError
	}
	status.QueueBytes, _ = a.spool.Bytes()
	if len(events) > 0 && status.State == "idle" {
		status.State = "ok"
	}
	if len(events) == 0 && len(quotas) == 0 && usage == nil && time.Since(p.lastReport) < time.Minute {
		if err := p.scanner.Commit(); err != nil {
			return err
		}
		return a.drain(ctx)
	}
	groups[current.AccountUUID] = append(groups[current.AccountUUID], []model.UsageEvent{}...)
	keys := make([]string, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, account := range keys {
		chunks := chunkEvents(groups[account], maxEventsPerBatch, a.batchByteLimit())
		if len(chunks) == 0 {
			chunks = [][]model.UsageEvent{nil}
		}
		for i, chunk := range chunks {
			b := model.Batch{AgentVersion: a.cfg.Version, Identity: ids[account], Events: chunk, AccountOrigin: model.OriginSession}
			if account == current.AccountUUID && i == 0 {
				b.Collector = &status
				b.AccountUsage = usage
			}
			if err := a.enqueueCodex(ctx, b); err != nil {
				return err
			}
		}
		qs := quotas[account]
		for len(qs) > 0 {
			n := min(50, len(qs))
			b := model.Batch{AgentVersion: a.cfg.Version, Identity: ids[account], AccountOrigin: model.OriginSession, Quotas: qs[:n]}
			if err := a.enqueueCodex(ctx, b); err != nil {
				return err
			}
			qs = qs[n:]
		}
	}
	if err := p.scanner.Commit(); err != nil {
		return err
	}
	p.lastReport = now
	p.lastResultSent = resultAt
	return a.drain(ctx)
}

func (p *codexCollector) bindObserved(account string, auth *codex.Auth, now time.Time, rf codex.ReadFile) error {
	at := now
	if account != "" && p.binding.Account != account {
		observed := codex.LoginObservedAtWith(p.home, auth, rf)
		if !observed.IsZero() && !observed.Before(p.binding.Since) && !observed.After(now) {
			at = observed
		}
	}
	return p.bind(account, at)
}

func (a *Agent) codexQuotaLease(ctx context.Context, account, profile string, interval time.Duration, failures int) bool {
	b, _ := json.Marshal(map[string]any{"account_uuid": account, "profile_id": profile, "seconds": int(interval.Seconds() * 1.5), "failures": failures})
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.hub()+"/v1/collectors/quota-lease", bytes.NewReader(b))
	if err != nil {
		return false
	}
	a.authorize(req)
	req.Header.Set("Content-Type", "application/json")
	r, err := a.http.Do(req)
	if err != nil {
		return false
	}
	defer r.Body.Close()
	if r.StatusCode == http.StatusNotFound {
		return true
	} // rolling upgrade from an older hub
	if r.StatusCode != http.StatusOK {
		return false
	}
	var out struct {
		Granted bool `json:"granted"`
	}
	if json.NewDecoder(r.Body).Decode(&out) != nil {
		return false
	}
	return out.Granted
}
