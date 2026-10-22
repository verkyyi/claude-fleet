package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// An ended trial's data goes on a schedule (claude-fleet WACK C8). A trial
// member — trialIdentity, with fleet.member_limits.<pid> carrying an end
// (until=) that has passed; 转正 clears the key, so a converted person is
// never on it — is walked hourly (TrialRetentionTick, on the alert sweep's
// one replica):
//
//   - at the end: every session on their logins is stopped (worker_stop, the
//     operator's own write), once — hub audit trial.expire_stop;
//   - at end + retain − 7 and − 3 days (+23 · +27 by default): a notice to
//     them through the notice desk (the service account's template, else a
//     customer-service message, else mail) saying when their data goes and
//     that 转正 keeps it — once each, by the notice's id;
//   - at end + fleet.trial.retain_days (30): their logins go back through the
//     operator's remove — the recycling machine's wash (#3504), which deletes
//     the home and checks it clean before the login is a spare again, nothing
//     new on the root side — and the hub's copies go: the conversation mirror,
//     a kept trial conversation, attachments they sent. One hub audit
//     trial.purge (what each login did, how many rows went — never content)
//     and one fleet_audit trial.purge. A remove that could not be sent is
//     tried again next hour; the row is written only when every one went.
//
// fleet.trial.retain_days 0 purges on the first pass after the end, with no
// notice. An admin is never touched.

const (
	TrialRetainDaysKey     = "fleet.trial.retain_days"
	defaultTrialRetainDays = 30
	maxTrialRetainDays     = 365
	// trialRetainEvery is how often the walk runs.
	trialRetainEvery = time.Hour
	// trialRetainActor is the audit trail's actor and the writes' journal
	// actor.
	trialRetainActor = "trial-retention"

	auditTrialStop  = "trial.expire_stop"
	auditTrialPurge = "trial.purge"
)

// trialRemindBefore are the days before the purge a notice goes out.
var trialRemindBefore = []int{7, 3}

func init() {
	hubSettings[TrialRetainDaysKey] = hubSetting{def: strconv.Itoa(defaultTrialRetainDays),
		help: "days an ended trial member's data is kept: at the end their sessions stop, 7 and 3 days before the purge they are told, then their login's home, conversation copy and uploads are deleted and the login washed back to the spare pool; 0 = at once (claude-fleet WACK C8) · " +
			"试用到期后数据保留天数：到期即停会话，删除前 7 天和 3 天各提醒一次，到期删登录家目录、对话镜像与上传文件并洗回备用池；0 = 立即删",
		check: checkIntSetting(TrialRetainDaysKey, 0, maxTrialRetainDays, defaultTrialRetainDays)}
}

func (s *Server) trialRetainDays() int {
	return s.settingIntOr(TrialRetainDaysKey, defaultTrialRetainDays, 0, maxTrialRetainDays)
}

// trialRetainAt is each server's last walk (the tick is hourly).
var trialRetainAt sync.Map // *Server → time.Time

// TrialRetentionTick walks at most once an hour.
func (s *Server) TrialRetentionTick(now time.Time) {
	if v, ok := trialRetainAt.Load(s); ok && now.Sub(v.(time.Time)) < trialRetainEvery {
		return
	}
	trialRetainAt.Store(s, now)
	s.SweepTrialRetention(now)
}

// trialEnded is one ended trial member.
type trialEnded struct {
	pid   string
	until time.Time
}

// endedTrials are the trial members whose end has passed, by pid.
func (s *Server) endedTrials(now time.Time) ([]trialEnded, map[string]string, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, nil, err
	}
	admins := map[string]bool{}
	if users, err := s.Store.HubUsers(); err == nil {
		for _, u := range users {
			if u.Role == roleAdmin {
				admins[u.PrincipalID] = true
			}
		}
	} else {
		return nil, nil, err
	}
	var out []trialEnded
	for k := range settings {
		pid, ok := strings.CutPrefix(k, MemberLimitsPrefix)
		if !ok || pid == "" || admins[pid] {
			continue
		}
		l, ok := memberLimitsOf(settings, pid)
		if !ok || l.Until.IsZero() || now.Before(l.Until) || !s.trialIdentity(settings, pid) {
			continue
		}
		out = append(out, trialEnded{pid: pid, until: l.Until})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].pid < out[j].pid })
	return out, settings, nil
}

// SweepTrialRetention is one walk at now.
func (s *Server) SweepTrialRetention(now time.Time) {
	if s.Store == nil {
		return
	}
	ended, settings, err := s.endedTrials(now)
	if err != nil {
		log.Printf("fleet: trial retention: %v", err)
		return
	}
	retain := time.Duration(s.trialRetainDays()) * 24 * time.Hour
	sent := false
	for _, t := range ended {
		if done, err := s.Store.HubAuditTargetHas(auditTrialPurge, t.pid); err != nil || done {
			continue
		}
		purgeAt := t.until.Add(retain)
		if stopped, err := s.Store.HubAuditTargetHas(auditTrialStop, t.pid); err == nil && !stopped {
			s.trialExpireStop(t.pid, now)
		}
		if now.Before(purgeAt) {
			s.trialRemind(t.pid, purgeAt, parseLang(settings[langSettingKey(t.pid)]), now)
			continue
		}
		did, _ := s.trialPurge(t.pid, now)
		sent = sent || did
	}
	if sent {
		s.dispatchAccounts()
	}
}

// trialStopWorker stops one session (a seam: tests answer it).
func (s *Server) trialStopWorker(ctx context.Context, wid string) error {
	if s.trialStopHook != nil {
		return s.trialStopHook(ctx, wid)
	}
	_, err := s.SubmitWrite(ctx, fleetPrincipal{Actor: trialRetainActor}, "worker_stop", map[string]any{
		"worker_id": wid, "idempotency_key": "trial-stop-" + HashToken(wid)[:24]})
	return err
}

// trialSessions are the worker ids running on pid's logins.
func (s *Server) trialSessions(pid string) ([]string, error) {
	as, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil, err
	}
	rows, err := s.Store.Fleets()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, r := range rows {
		if !r.Present {
			continue
		}
		mine := false
		for _, a := range as {
			if a.Login != "" && a.Login == r.OSUser && sameMachine(a.Hostname, r.Hostname) {
				mine = true
			}
		}
		if !mine {
			continue
		}
		var ws []map[string]any
		_ = json.Unmarshal([]byte(r.WorkersJSON), &ws)
		for _, w := range ws {
			if id, _ := w["worker_id"].(string); id != "" {
				out = append(out, id)
			}
		}
	}
	return out, nil
}

// trialExpireStop stops every session on pid's logins; the audit row is
// written once every stop was taken (a machine away: next hour).
func (s *Server) trialExpireStop(pid string, now time.Time) {
	ids, err := s.trialSessions(pid)
	if err != nil {
		log.Printf("fleet: trial retention: sessions of %s: %v", pid, err)
		return
	}
	var failed []string
	for _, id := range ids {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		err := s.trialStopWorker(ctx, id)
		cancel()
		if err != nil {
			failed = append(failed, id)
			log.Printf("fleet: trial retention: stop %s of %s: %v", id, pid, err)
		}
	}
	if len(failed) > 0 {
		return
	}
	_ = s.Store.HubAudit(trialRetainActor, auditTrialStop, pid, "ok",
		fmt.Sprintf("sessions=%d · 试用到期，会话已停 · trial ended, sessions stopped", len(ids)), now)
	log.Printf("fleet: trial of %s ended — %d session(s) stopped", pid, len(ids))
}

// trialRemind writes the notice due at now, if one is (each once).
func (s *Server) trialRemind(pid string, purgeAt time.Time, lang string, now time.Time) {
	for _, d := range trialRemindBefore {
		at := purgeAt.Add(-time.Duration(d) * 24 * time.Hour)
		if now.Before(at) {
			continue
		}
		n := store.Notice{ID: "nt-trialpurge-" + pid + "-" + strconv.Itoa(d), Kind: store.NotifyKindTrialPurge,
			Owner: pid, Lang: lang, Refs: []string{pid, purgeAt.UTC().Format(time.RFC3339)}}
		if err := s.Store.EnqueueNotice(n, now); err != nil {
			if !isDupNotice(s, n.ID) {
				log.Printf("fleet: trial retention: notice %s: %v", n.ID, err)
			}
			continue
		}
		log.Printf("fleet: trial retention: %s told their data goes %s", pid, purgeAt.UTC().Format(time.RFC3339))
		s.notifyKick()
	}
}

// trialPurgeNoticeMsg puts a trialpurge notice into words; nothing to say
// once they are converted or their data is gone.
func (s *Server) trialPurgeNoticeMsg(n store.Notice, en bool, base string) (noticeMsg, bool, error) {
	if len(n.Refs) < 2 {
		return noticeMsg{}, false, nil
	}
	pid := n.Refs[0]
	purgeAt, err := time.Parse(time.RFC3339, n.Refs[1])
	if err != nil {
		return noticeMsg{}, false, nil
	}
	set, err := s.Store.FleetSettings()
	if err != nil {
		return noticeMsg{}, false, err
	}
	if l, ok := memberLimitsOf(set, pid); !ok || l.Until.IsZero() {
		return noticeMsg{}, false, nil // 转正 already
	}
	if gone, err := s.Store.HubAuditTargetHas(auditTrialPurge, pid); err != nil || gone {
		return noticeMsg{}, false, err
	}
	var body string
	if en {
		body = "Your trial has ended. Your login's files, your conversation and your uploads will be deleted on " +
			noticeTime(purgeAt, true) + ". Ask an admin to make you a member to keep them."
	} else {
		body = "你的试用已结束：登录里的文件、对话和上传的文件将于 " + noticeTime(purgeAt, false) +
			" 删除。想保留，请联系管理员转正。"
	}
	sn := &store.ServiceNotice{Body: body, CreatedAt: n.Created}
	if sn.CreatedAt.IsZero() {
		sn.CreatedAt = time.Now()
	}
	fields := [][2]string{{"thing1", "title"}, {"thing2", "body"}, {"time3", "time"}}
	if s.WxGW != nil {
		fields = s.noticeTplFields()
	}
	return serviceNoticeMsg(sn, en, base, fields), true, nil
}

// trialPurge deletes pid's data and washes their logins back; false when a
// remove could not be sent (tried again next hour). sent: a remove went out.
func (s *Server) trialPurge(pid string, now time.Time) (sent, ok bool) {
	logins, ok, sent := s.trialGiveBackAll(pid, now)
	if !ok {
		log.Printf("fleet: trial retention: purge of %s waits: %s", pid, logins)
		return sent, false
	}
	parts := []string{logins}
	if err := s.Store.DeleteChatMirror(pid); err != nil {
		log.Printf("fleet: trial retention: mirror of %s: %v", pid, err)
		return sent, false
	}
	parts = append(parts, "mirror=deleted")
	if err := s.Store.DeleteTrialConvo(pid); err != nil {
		log.Printf("fleet: trial retention: kept conversation of %s: %v", pid, err)
		return sent, false
	}
	n, err := s.Store.DeleteFleetAttachmentsOf(pid)
	if err != nil {
		log.Printf("fleet: trial retention: attachments of %s: %v", pid, err)
		return sent, false
	}
	parts = append(parts, "attachments="+strconv.FormatInt(n, 10))
	_ = s.Store.HubAudit(trialRetainActor, auditTrialPurge, pid, "ok",
		strings.Join(parts, " ")+" · 试用数据已按期删除 · an ended trial's data deleted", now)
	_ = s.Store.FleetAudit(trialRetainActor, auditTrialPurge, pid, "ok", "", now)
	log.Printf("fleet: trial of %s purged (%s)", pid, strings.Join(parts, " "))
	return sent, true
}
