package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// svc_degraded (claude-fleet#4007, the SPACE EPIC C5): a back end's runs that
// fail in a batch, or wait too long to start, reach the person on duty within
// minutes instead of the next morning's empty reports. The alert sweep
// (RunNodeAlerts, one replica) looks at each principal's last svcAlertWindow:
//
//   - failures: more than svcAlertFailRate of the runs that ended there failed
//     or expired (a cancel is the caller's own word and counts neither way),
//     and at least svcAlertMinFails of them did. A run retried after an
//     infra_error counts once, by how it finally ended.
//   - waiting: the p95 of how long runs waited from queued to their first
//     start — a run still in the queue counts as waiting until now — is over
//     svcAlertWaitP95, over at least svcAlertMinWaits runs.
//
// Debounced twice: a principal must be degraded on two passes in a row
// (svcAlertEvery apart) before it is raised, and (kind, principal) is raised
// at most once per svcAlertQuiet whether or not it cleared in between. It
// clears on the first pass that finds it well. A raise is one fleet_alerts row,
// one hub_audit svc.alert line, one log line `fleet alert: svc_degraded …` and
// one FLEET_NOTIFY_CMD message (Server.NotifyCmd). What failed and why stays
// on the hub: the message names error codes and counts, nothing a run wrote.

const (
	svcAlertWindow   = 30 * time.Minute
	svcAlertFailRate = 0.20
	svcAlertMinFails = 3
	svcAlertWaitP95  = 10 * time.Minute
	svcAlertMinWaits = 3
	svcAlertQuiet    = time.Hour
	svcNotifyTimeout = 15 * time.Second
)

// svcAlertEvery is how often the sweep looks; a variable so tests can move it.
var svcAlertEvery = time.Minute

// NotifyCmdFromEnv reads the hub's FLEET_NOTIFY_CMD.
func NotifyCmdFromEnv() string { return strings.TrimSpace(os.Getenv("FLEET_NOTIFY_CMD")) }

// svcHealth is one principal's window as the sweep reads it.
type svcHealth struct {
	Principal  string         `json:"principal"`
	WindowSecs int            `json:"window_secs"`
	Ended      int            `json:"ended"`
	Failed     int            `json:"failed"`
	FailRate   float64        `json:"fail_rate"`
	Codes      map[string]int `json:"codes,omitempty"`
	Waits      int            `json:"waits"`
	WaitP95S   int            `json:"wait_p95_secs"`
	Queued     int            `json:"queued"`
	Reasons    []string       `json:"reasons"`
}

func (h svcHealth) degraded() bool { return len(h.Reasons) > 0 }

// svcFirstStart is when a run first started: deadline_at less its deadline
// once a start fixed it (a retry restamps started_at), else started_at.
func svcFirstStart(r store.SvcRun) *time.Time {
	if r.DeadlineAt != nil {
		t := r.DeadlineAt.Add(-time.Duration(r.DeadlineS) * time.Second)
		return &t
	}
	return r.StartedAt
}

// svcP95 is the nearest-rank 95th percentile of ds (sorted in place).
func svcP95(ds []time.Duration) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
	i := (len(ds)*95+99)/100 - 1
	if i < 0 {
		i = 0
	}
	return ds[i]
}

// svcHealthOf reads every principal's window ending at now.
func svcHealthOf(runs []store.SvcRun, now time.Time) map[string]*svcHealth {
	since := now.Add(-svcAlertWindow)
	out := map[string]*svcHealth{}
	waits := map[string][]time.Duration{}
	for _, r := range runs {
		h := out[r.Principal]
		if h == nil {
			h = &svcHealth{Principal: r.Principal, WindowSecs: int(svcAlertWindow / time.Second), Codes: map[string]int{}}
			out[r.Principal] = h
		}
		if r.FinishedAt != nil && !r.FinishedAt.Before(since) {
			switch r.State {
			case store.SvcRunSucceeded:
				h.Ended++
			case store.SvcRunFailed, store.SvcRunExpired:
				h.Ended++
				h.Failed++
				h.Codes[r.ErrorCode]++
			}
		}
		switch {
		case r.State == store.SvcRunQueued && r.Attempt == 0:
			h.Queued++
			waits[r.Principal] = append(waits[r.Principal], now.Sub(r.QueuedAt))
		case r.State == store.SvcRunExpired && r.FinishedAt != nil && !r.FinishedAt.Before(since):
			waits[r.Principal] = append(waits[r.Principal], r.FinishedAt.Sub(r.QueuedAt))
		default:
			if fs := svcFirstStart(r); fs != nil && !fs.Before(since) {
				waits[r.Principal] = append(waits[r.Principal], fs.Sub(r.QueuedAt))
			}
		}
	}
	for p, h := range out {
		if h.Ended > 0 {
			h.FailRate = float64(h.Failed) / float64(h.Ended)
		}
		w := waits[p]
		h.Waits = len(w)
		p95 := svcP95(w)
		h.WaitP95S = int(p95 / time.Second)
		if h.Failed >= svcAlertMinFails && h.FailRate > svcAlertFailRate {
			h.Reasons = append(h.Reasons, fmt.Sprintf("近 %d 分钟 %d/%d 次失败（%s）",
				int(svcAlertWindow/time.Minute), h.Failed, h.Ended, svcCodesLine(h.Codes)))
		}
		if h.Waits >= svcAlertMinWaits && p95 > svcAlertWaitP95 {
			h.Reasons = append(h.Reasons, fmt.Sprintf("排队等待 p95 %s（%d 次，排队中 %d）",
				p95.Round(time.Second), h.Waits, h.Queued))
		}
	}
	return out
}

func svcCodesLine(codes map[string]int) string {
	keys := make([]string, 0, len(codes))
	for k := range codes {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		name := k
		if name == "" {
			name = "?"
		}
		parts = append(parts, fmt.Sprintf("%s×%d", name, codes[k]))
	}
	return strings.Join(parts, " ")
}

// SvcAlertTick is one pass at now.
func (s *Server) SvcAlertTick(now time.Time) {
	if s.Store == nil {
		return
	}
	s.svcAlertMu.Lock()
	defer s.svcAlertMu.Unlock()
	if !s.svcAlertAt.IsZero() && now.Sub(s.svcAlertAt) < svcAlertEvery {
		return
	}
	s.svcAlertAt = now
	runs, err := s.Store.SvcRunsSince(now.Add(-7 * 24 * time.Hour))
	if err != nil {
		log.Printf("fleet alerts: svc runs: %v", err)
		return
	}
	health := svcHealthOf(runs, now)
	svcProbeHealth(health, runs)
	seen := map[string]bool{}
	for p, h := range health {
		if !h.degraded() {
			continue
		}
		seen[p] = true
		if s.svcAlertSeen[p] {
			s.raiseSvcAlert(*h, now)
		}
	}
	s.svcAlertSeen = seen
	open, err := s.Store.OpenFleetAlertSubjects(store.AlertSvcDegraded, "")
	if err != nil {
		return
	}
	for _, p := range open {
		if seen[p] {
			continue
		}
		if cleared, err := s.Store.ClearFleetAlert(store.AlertSvcDegraded, p, now); err != nil {
			log.Printf("fleet alerts: clear svc_degraded %s: %v", p, err)
		} else if cleared {
			log.Printf("fleet alert cleared: svc_degraded %s", p)
		}
	}
}

// Daily probes have a different cadence from the ordinary 30-minute window.
// Count final runs, not engine attempts; a successful fallback breaks a streak.
func svcProbeHealth(health map[string]*svcHealth, runs []store.SvcRun) {
	byPrincipal := map[string][]store.SvcRun{}
	for _, run := range runs {
		if run.Tenant == "probe" && store.SvcRunTerminal(run.State) && run.State != store.SvcRunCancelled {
			byPrincipal[run.Principal] = append(byPrincipal[run.Principal], run)
		}
	}
	for principal, probes := range byPrincipal {
		sort.Slice(probes, func(i, j int) bool { return probes[i].ID > probes[j].ID })
		if len(probes) < 2 || probes[0].State == store.SvcRunSucceeded || probes[1].State == store.SvcRunSucceeded {
			continue
		}
		h := health[principal]
		if h == nil {
			h = &svcHealth{Principal: principal, Codes: map[string]int{}}
			health[principal] = h
		}
		h.Reasons = append(h.Reasons, "每日自检 probe 连续两次失败")
	}
}

func (s *Server) raiseSvcAlert(h svcHealth, now time.Time) {
	last, err := s.Store.LastFleetAlertRaised(store.AlertSvcDegraded, h.Principal)
	if err != nil {
		log.Printf("fleet alerts: read svc_degraded %s: %v", h.Principal, err)
		return
	}
	if !last.IsZero() && now.Sub(last) < svcAlertQuiet {
		return
	}
	b, _ := json.Marshal(h)
	raised, err := s.Store.RaiseFleetAlert(store.AlertSvcDegraded, h.Principal, string(b), now)
	if err != nil {
		log.Printf("fleet alerts: raise svc_degraded %s: %v", h.Principal, err)
		return
	}
	if !raised {
		return
	}
	line := strings.Join(h.Reasons, "；")
	log.Printf("fleet alert: svc_degraded %s: %s", h.Principal, line)
	if err := s.Store.HubAudit("hub", "svc.alert", h.Principal, "degraded", line, now); err != nil {
		log.Printf("fleet alerts: audit svc_degraded %s: %v", h.Principal, err)
	}
	s.notify(fmt.Sprintf("fleet 服务运行告警 svc_degraded · %s：%s — 查 GET %s?state=failed",
		h.Principal, line, SvcRunsPath))
}

// notify hands msg to the hub's notifier, in the background: an alert never
// waits on it, and a notifier that fails is logged, never retried.
func (s *Server) notify(msg string) {
	if s.Notify != nil {
		s.Notify(msg)
		return
	}
	if s.NotifyCmd == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), svcNotifyTimeout)
		defer cancel()
		out, err := exec.CommandContext(ctx, s.NotifyCmd, msg).CombinedOutput()
		if err != nil {
			log.Printf("fleet notify: %v: %s", err, truncate(strings.TrimSpace(string(out)), 200))
		}
	}()
}
