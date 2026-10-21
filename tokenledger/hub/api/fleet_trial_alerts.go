package api

import (
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// When a trial gets stuck, the operator hears it (claude-fleet QSSW, EPIC WACK
// C7). Two alerts join the table, both on the alert sweep (RunNodeAlerts, one
// replica):
//
//   - queue_long: someone still on the page has waited in the trial line —
//     the one line a person waits in for a seat; a member is placed or told
//     no, never queued — for more than queueLongAfter. The same line
//     GET TryStatsPath counts as waiting_now. Subject "trial".
//   - start_failed: startFailedMin session starts or more failed hub-wide
//     within startFailedWindow, whoever asked — a start a machine declined
//     (at capacity, a disk gate, the issue claimed) is not a failure.
//     Subject "hub".
//
// Each clears on the first pass that finds it well. And every alert raised
// anywhere — these, node_lost, the rest — reaches the hub's notifier
// (FLEET_NOTIFY_CMD → FLEET_NOTIFY_KF_*, ccquota notify): AlertNotifyTick
// hands each new row over once, and one kind is sent at most once per
// fleet.alert.quiet_mins (default 30) — the rest are marked quiet, still in
// GET /v1/fleet/fleet_alerts. A kind whose raiser tells people its own way
// (selfNotifiedAlerts) is marked self and left to it.

const (
	queueLongAfter    = 10 * time.Minute
	startFailedWindow = 15 * time.Minute
	startFailedMin    = 3

	queueLongSubject   = "trial"
	startFailedSubject = "hub"

	// AlertQuietMinsKey: one kind of alert reaches the notifier at most once
	// in this many minutes.
	AlertQuietMinsKey      = "fleet.alert.quiet_mins"
	defaultAlertQuietMins  = 30
	maxAlertQuietMins      = 24 * 60
	alertNotifyDetailRunes = 120
)

func init() {
	hubSettings[AlertQuietMinsKey] = hubSetting{def: strconv.Itoa(defaultAlertQuietMins),
		help: "every fleet alert is pushed to the admins (FLEET_NOTIFY_KF_*), one kind at most once in this many minutes; 0 = every raise (claude-fleet QSSW) · " +
			"每条 fleet 告警推给管理员，同一类这么多分钟内只推一次；0 = 每次都推",
		check: checkIntSetting(AlertQuietMinsKey, 0, maxAlertQuietMins, defaultAlertQuietMins)}
}

func (s *Server) alertQuiet() time.Duration {
	return time.Duration(s.settingIntOr(AlertQuietMinsKey, defaultAlertQuietMins, 0, maxAlertQuietMins)) * time.Minute
}

// selfNotifiedAlerts tell people themselves: svc_degraded and
// entry_hostkey_changed through the notifier, trial_code_burst on the admins'
// WeChat.
var selfNotifiedAlerts = map[string]bool{
	store.AlertSvcDegraded:         true,
	store.AlertEntryHostKeyChanged: true,
	store.AlertTrialCodeBurst:      true,
}

// alertWords is each kind in words, zh / en: the pushed message's title.
var alertWords = map[string]string{
	store.AlertNodeLost:            "机器掉线 / machine lost",
	store.AlertLeaseConflict:       "两个会话抢同一单 / two sessions on one issue",
	store.AlertServiceFailed:       "机器上的服务没在跑 / a machine's service is down",
	store.AlertSpareEmpty:          "没有就绪备用登录 / no spare ready",
	store.AlertSpareFailed:         "备用登录做坏了 / a spare went bad",
	store.AlertTrialOpenSlow:       "试用座位打不开 / a trial seat would not open",
	store.AlertTrialNoSpare:        "试用在排队，没有备用登录 / trial waits, no spare",
	store.AlertUsageSilent:         "用量不再上报 / usage went quiet",
	store.AlertPoolUsageSilent:     "池子用量不再上报 / pool usage went quiet",
	store.AlertPoolUsageUnowned:    "用量找不到人 / usage with no person",
	store.AlertQueueLong:           "试用排队超过 10 分钟 / trial line over 10 min",
	store.AlertStartFailed:         "开会话连续失败 / session starts keep failing",
	store.AlertSvcDegraded:         "服务运行告警 / service runs degraded",
	store.AlertTrialCodeBurst:      "试用二维码暂停 / trial code paused",
	store.AlertEntryHostKeyChanged: "入口主机钥匙换了 / entry host key changed",
}

// queueLongDetail is queue_long's detail.
type queueLongDetail struct {
	WaitingNow  int       `json:"waiting_now"`
	OldestSince time.Time `json:"oldest_since"`
	OldestSecs  int       `json:"oldest_secs"`
	AfterSecs   int       `json:"after_secs"`
}

// QueueLongTick raises or clears queue_long at now.
func (s *Server) QueueLongTick(now time.Time) {
	if s.Store == nil {
		return
	}
	since, n, err := s.Store.OldestTrialWaiting(now.Add(-trialFresh))
	if err != nil {
		log.Printf("fleet alerts: trial line: %v", err)
		return
	}
	if n == 0 || now.Sub(since) <= queueLongAfter {
		if cleared, err := s.Store.ClearFleetAlert(store.AlertQueueLong, queueLongSubject, now); err == nil && cleared {
			log.Printf("fleet alert cleared: queue_long — nobody on the page has waited %s", queueLongAfter)
		}
		return
	}
	d := queueLongDetail{WaitingNow: n, OldestSince: since.UTC(), OldestSecs: int(now.Sub(since) / time.Second),
		AfterSecs: int(queueLongAfter / time.Second)}
	b, _ := json.Marshal(d)
	if raised, err := s.Store.RaiseFleetAlert(store.AlertQueueLong, queueLongSubject, string(b), now); err != nil {
		log.Printf("fleet alerts: raise queue_long: %v", err)
	} else if raised {
		log.Printf("fleet alert: queue_long — %d waiting, the first for %s", n, now.Sub(since).Round(time.Second))
	}
}

// startFailedDetail is start_failed's detail: how many in the window and the
// last few, each its operation and what the node said.
type startFailedDetail struct {
	Failures   int              `json:"failures"`
	WindowSecs int              `json:"window_secs"`
	Last       []startFailedOne `json:"last"`
}

type startFailedOne struct {
	OperationID string    `json:"operation_id"`
	FleetID     string    `json:"fleet_id"`
	At          time.Time `json:"at"`
	Why         string    `json:"why"`
}

// startFailures are the starts that failed since — a machine declining one
// (outcomeOf's refused, exit 2 or 3) is not among them.
func (s *Server) startFailures(since time.Time) ([]startFailedOne, error) {
	fs, err := s.Store.FailedStartsSince(since)
	if err != nil {
		return nil, err
	}
	var out []startFailedOne
	for _, f := range fs {
		oc := outcomeOf(map[string]any{"status": "failed", "result": json.RawMessage(f.Result)}, "")
		if oc.State == "refused" && (oc.Exit == nil || *oc.Exit != 1) {
			continue
		}
		out = append(out, startFailedOne{OperationID: f.ID, FleetID: f.FleetID, At: f.Updated,
			Why: truncate(oneLine(oc.Stderr), alertNotifyDetailRunes)})
	}
	return out, nil
}

// StartFailedTick raises or clears start_failed at now.
func (s *Server) StartFailedTick(now time.Time) {
	if s.Store == nil {
		return
	}
	fails, err := s.startFailures(now.Add(-startFailedWindow))
	if err != nil {
		log.Printf("fleet alerts: failed starts: %v", err)
		return
	}
	if len(fails) < startFailedMin {
		if cleared, err := s.Store.ClearFleetAlert(store.AlertStartFailed, startFailedSubject, now); err == nil && cleared {
			log.Printf("fleet alert cleared: start_failed — under %d in %s", startFailedMin, startFailedWindow)
		}
		return
	}
	d := startFailedDetail{Failures: len(fails), WindowSecs: int(startFailedWindow / time.Second)}
	d.Last = fails[max(0, len(fails)-3):]
	b, _ := json.Marshal(d)
	if raised, err := s.Store.RaiseFleetAlert(store.AlertStartFailed, startFailedSubject, string(b), now); err != nil {
		log.Printf("fleet alerts: raise start_failed: %v", err)
	} else if raised {
		log.Printf("fleet alert: start_failed — %d session starts failed in %s", len(fails), startFailedWindow)
	}
}

// alertMessage is what one raised row says to the notifier: a title line,
// then a line of its own and where to read the rest.
func alertMessage(a store.FleetAlert) string {
	words := alertWords[a.Kind]
	if words == "" {
		words = a.Kind
	}
	title := "fleet 告警 · " + words + " · " + a.Kind + " " + a.Subject
	var line string
	switch a.Kind {
	case store.AlertQueueLong:
		var d queueLongDetail
		if json.Unmarshal([]byte(a.Detail), &d) == nil {
			line = fmt.Sprintf("%d 人在排队，最早的已等 %d 分钟 · %d waiting, the first for %d min",
				d.WaitingNow, d.OldestSecs/60, d.WaitingNow, d.OldestSecs/60)
		}
	case store.AlertStartFailed:
		var d startFailedDetail
		if json.Unmarshal([]byte(a.Detail), &d) == nil {
			line = fmt.Sprintf("%d 分钟内 %d 次开会话失败 · %d starts failed in %d min",
				d.WindowSecs/60, d.Failures, d.Failures, d.WindowSecs/60)
			if n := len(d.Last); n > 0 && d.Last[n-1].Why != "" {
				line += "：" + d.Last[n-1].Why
			}
		}
	case store.AlertNodeLost:
		var d struct {
			Hostname string `json:"hostname"`
			OSUser   string `json:"os_user"`
		}
		if json.Unmarshal([]byte(a.Detail), &d) == nil && d.OSUser != "" {
			line = d.OSUser + "@" + nodeLabel(d.Hostname) + " 没有心跳 · no heartbeat"
		}
	}
	body := "查 GET /v1/fleet/fleet_alerts · read GET /v1/fleet/fleet_alerts"
	if line != "" {
		body = line + "\n" + body
	}
	return title + "\n" + body
}

// AlertNotifyTick hands every row raised at or after since that no pass has
// handled to the notifier, once: one kind at most once per
// fleet.alert.quiet_mins (the rest marked quiet), a self-telling kind marked
// self. No notifier configured ⇒ nothing is read or marked.
func (s *Server) AlertNotifyTick(since, now time.Time) {
	if s.Store == nil || (s.Notify == nil && s.NotifyCmd == "") {
		return
	}
	rows, err := s.Store.UnnotifiedFleetAlerts(since)
	if err != nil {
		log.Printf("fleet alerts: unnotified: %v", err)
		return
	}
	quiet := s.alertQuiet()
	for _, a := range rows {
		how := store.AlertNotifySent
		switch {
		case selfNotifiedAlerts[a.Kind]:
			how = store.AlertNotifySelf
		case quiet > 0:
			last, err := s.Store.LastFleetAlertSent(a.Kind)
			if err != nil {
				log.Printf("fleet alerts: last sent %s: %v", a.Kind, err)
				continue
			}
			if !last.IsZero() && now.Sub(last) < quiet {
				how = store.AlertNotifyQuiet
			}
		}
		marked, err := s.Store.MarkFleetAlertNotified(a.ID, how, now)
		if err != nil {
			log.Printf("fleet alerts: mark %s %s: %v", a.Kind, a.Subject, err)
			continue
		}
		if !marked || how != store.AlertNotifySent {
			continue
		}
		s.notify(alertMessage(a))
		log.Printf("fleet alert pushed: %s %s", a.Kind, a.Subject)
	}
}
