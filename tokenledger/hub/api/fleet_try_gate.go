package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// 立即体验 (claude-fleet#4058, EPIC #4048 C10): the trial lets in only a
// VERIFIED sign-in — the service account's code first (a trial-purpose
// scene), then a mailed code or GitHub under 「其他方式登录」 — and holds the
// machine to a budget before it hands anyone a seat:
//
//   - Who: a person the list does not name who signed in while asking for a
//     trial (a trial scene, or the ccq_try note /v1/try/start leaves) becomes
//     a trial person — role trial, a fleet_trials row naming the way they
//     signed in (one trial per way: WeChat by unionid, else openid). No
//     invite, no anonymous way: the note alone opens nothing. Someone the
//     list names goes straight to /app.
//   - What they reach: the chat, their trial and /apply (trialRoute); every
//     other address answers 404.
//   - Admission, before each seat (共同约定「准入」): fleet.trial.slots seats at
//     once; the machine's own admission verdict (its logins' Admit) and its
//     load under fleet.trial.load_ratio × cores; the subscription pool's
//     window left above fleet.trial.quota_floor; at most fleet.trial.daily
//     starts a day (Beijing), halved while the pool has less than half left.
//     Any no ⇒ wait in line with a reason and an ETA (the last ten releases'
//     spacing), never an error; the day's total spent ⇒ 「今天满了」.
//   - fleet.trial.once (on): a trial that ended does not start again for the
//     same way — the page says 「已试过」 and points at /apply.
//
// fleet.trial off: none of it — the routes 404 as before.

// The trial's settings.
const (
	TrialSlotsKey      = "fleet.trial.slots"
	TrialLoadRatioKey  = "fleet.trial.load_ratio"
	TrialQuotaFloorKey = "fleet.trial.quota_floor"
	TrialDailyKey      = "fleet.trial.daily"
	TrialOnceKey       = "fleet.trial.once"

	defaultTrialSlots      = 8
	defaultTrialLoadRatio  = 0.8
	defaultTrialQuotaFloor = 20
	defaultTrialDaily      = 30

	// tryCookie is the note /v1/try/start leaves a signed-out browser: the
	// sign-in it goes on to is asking for a trial. Worth nothing by itself.
	tryCookie    = "ccq_try"
	tryCookieTTL = 15 * time.Minute

	// wxPurposeTrial is a sign-in code drawn on the way to a trial.
	wxPurposeTrial = "trial"
)

// Why a trial person waits (tryAnswer.Reason, the audit's trial.queued).
const (
	trialWaitFull  = "full"  // every seat is taken
	trialWaitBusy  = "busy"  // no machine admits a new one, or none is ready
	trialWaitLoad  = "load"  // the machine is above its load line
	trialWaitQuota = "quota" // the pool is below its floor
	// trialWaitNoSpare: machines are fit, but none holds a ready spare
	// (claude-fleet#4259) — raised as trial_no_spare.
	trialWaitNoSpare = "no_spare"
	// trialWaitNoSub (fleet_trial_cred.go): fleet.trial.cred_allow is []
)

// What exactly held a busy wait (claude-fleet#4251): the audit's
// trial.queued names it, the page reads only the word before the colon.
const (
	trialWaitBusyAdmit  = trialWaitBusy + ":admit"    // the machine's own gate holds new sessions
	trialWaitBusyNoHost = trialWaitBusy + ":no-host"  // no machine fit to open one (leastBusyMachine "")
	trialWaitBusySpare  = trialWaitBusy + ":no-spare" // no ready spare on the machine picked
	trialWaitBusyRoster = trialWaitBusy + ":roster"   // the roster could not be read
)

// trialPageReason is what the page is told of why: busy's detail stays in
// the audit.
func trialPageReason(why string) string {
	if i := strings.IndexByte(why, ':'); i >= 0 {
		return why[:i]
	}
	return why
}

// machineAdmit is the machine's one admission verdict (共同约定 2, the
// newest heartbeat's — fleet_machine_admit): of host's online logins that
// state one, the most recently heard login's. Every login reads the machine
// at its own moment, so one stale «no» among eighteen must not veto the
// machine (claude-fleet#4251). true when none states one.
func machineAdmit(snap NodesSnapshot, host string) bool {
	var newest time.Time
	admit, said := true, false
	for _, n := range snap.Nodes {
		if !strings.EqualFold(n.Hostname, host) || n.Status != "online" || n.Admit == nil {
			continue
		}
		var at time.Time
		if n.LastHeartbeat != nil {
			at = *n.LastHeartbeat
		}
		if !said || at.After(newest) {
			newest, admit, said = at, *n.Admit, true
		}
	}
	return admit
}

// trialDay is the zone the day's total is counted in.
var trialDay = time.FixedZone("CST", 8*3600)

// trialPoolLeft is the subscription pool's window left, in percent, and
// whether any reading exists. A variable so tests can move it.
var trialPoolLeft = func(s *Server) (float64, bool) { return s.poolLeft() }

func checkIntSetting(key string, lo, hi, def int) func(*Server, string) (string, string) {
	return func(_ *Server, v string) (string, string) {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil || n < lo || n > hi {
			return "", fmt.Sprintf("%s is an integer %d–%d, or \"\" for the default (%d)", key, lo, hi, def)
		}
		return strconv.Itoa(n), ""
	}
}

func checkTrialLoadRatio(_ *Server, v string) (string, string) {
	f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || f <= 0 || f > 4 {
		return "", TrialLoadRatioKey + " is a number above 0 and at most 4 (load per core), or \"\" for the default (0.8)"
	}
	return strconv.FormatFloat(f, 'f', -1, 64), ""
}

func (s *Server) settingIntOr(key string, def, lo, hi int) int {
	n, err := strconv.Atoi(strings.TrimSpace(s.setting(key)))
	if err != nil || n < lo || n > hi {
		return def
	}
	return n
}

func (s *Server) trialSlots() int { return s.settingIntOr(TrialSlotsKey, defaultTrialSlots, 0, 200) }
func (s *Server) trialQuotaFloor() int {
	return s.settingIntOr(TrialQuotaFloorKey, defaultTrialQuotaFloor, 0, 100)
}
func (s *Server) trialDaily() int { return s.settingIntOr(TrialDailyKey, defaultTrialDaily, 0, 10000) }
func (s *Server) trialOnce() bool { return s.settingOn(TrialOnceKey) }

func (s *Server) trialLoadRatio() float64 {
	f, err := strconv.ParseFloat(strings.TrimSpace(s.setting(TrialLoadRatioKey)), 64)
	if err != nil || f <= 0 {
		return defaultTrialLoadRatio
	}
	return f
}

// poolLeft is what the trial's default agent subscriptions have left of their tightest
// window, on average over those with a reading (the pool's headroom: the
// proxy picks among them). ok=false with no reading — nothing is held then.
func (s *Server) poolLeft() (float64, bool) {
	agent, err := s.trialDefaultAgent()
	if err != nil {
		return 0, false
	}
	return s.poolLeftForAgent(agent)
}

// A missing team setting retains the dispatch protocol's Claude default.
// Corrupt persisted settings must not silently check one pool and launch another.
func (s *Server) trialDefaultAgent() (string, error) {
	agent := s.setting(ClientDefaultsPrefix + "FLEET_AGENT")
	if agent == "" {
		return "claude", nil
	}
	if !codingAgentOK(agent) {
		return "", errors.New("invalid trial default agent")
	}
	return agent, nil
}

func (s *Server) poolLeftForAgent(agent string) (float64, bool) {
	source := model.SourceClaude
	if agent == "codex" {
		source = model.SourceCodex
	}
	across, err := s.LimitsForAllSource(source)
	if err != nil {
		log.Printf("fleet: trial: pool reading: %v", err)
		return 0, false
	}
	var sum float64
	n := 0
	for _, a := range across.PerAccount {
		v := a.Limits
		if v == nil || !v.Available || (v.FiveHour == nil && len(v.Windows) == 0 && !v.Blocked) {
			continue
		}
		sum += 100 - v.HighestUtilization()
		n++
	}
	if n == 0 {
		return 0, false
	}
	return sum / float64(n), true
}

// Pin the trial's actual provider on the unified open request, before counting
// a line or handing it to another replica/login. Local defaults cannot override
// this admission decision. Explicit choices still use their own pool.
func (s *Server) trialOpenProvider(w http.ResponseWriter, r *http.Request, person string) bool {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, chatBodyMax))
	_ = r.Body.Close()
	if err != nil {
		s.chatRefuse(w, person, "open", http.StatusRequestEntityTooLarge, "too_large", "消息太大 · message too large")
		return false
	}
	var body map[string]json.RawMessage
	if json.Unmarshal(raw, &body) != nil || body == nil {
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "bad_body", "a JSON object")
		return false
	}
	agent := ""
	if value := body["agent"]; len(value) != 0 && string(value) != "null" {
		if json.Unmarshal(value, &agent) != nil || (agent != "" && !codingAgentOK(agent)) {
			s.chatRefuse(w, person, "open", http.StatusBadRequest, "agent", "agent: claude or codex")
			return false
		}
	}
	if agent == "" {
		agent, err = s.trialDefaultAgent()
		if err != nil {
			s.chatRefuse(w, person, "open", http.StatusServiceUnavailable, "trial_provider", "暂时无法开始试用，请稍后再试。")
			return false
		}
	}
	if left, ok := s.poolLeftForAgent(agent); ok && left < float64(s.trialQuotaFloor()) {
		s.chatRefuse(w, person, "open", http.StatusTooManyRequests, "trial_quota", "这个助手的额度暂时不足，请稍后再试。")
		return false
	}
	body["agent"], _ = json.Marshal(agent)
	raw, _ = json.Marshal(body)
	r.Body = io.NopCloser(bytes.NewReader(raw))
	r.ContentLength = int64(len(raw))
	return true
}

// trialDailyNow is today's total: fleet.trial.daily, halved while the pool
// has less than half its window left.
func (s *Server) trialDailyNow() int {
	n := s.trialDaily()
	if left, ok := trialPoolLeft(s); ok && left < 50 {
		n /= 2
	}
	return n
}

// trialDayStart is the start of now's day, Beijing time.
func trialDayStart(now time.Time) time.Time {
	t := now.In(trialDay)
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, trialDay)
}

// trialHold is why no seat is handed out on host now ("" = go ahead).
func (s *Server) trialHold(host string, now time.Time) string {
	if s.trialNoSub() {
		return trialWaitNoSub // a seat would only answer the proxy's 403 (#4260)
	}
	if n, err := s.Store.TrialsHolding(); err != nil || n >= s.trialSlots() {
		return trialWaitFull
	}
	if _, err := s.trialDefaultAgent(); err != nil {
		return trialWaitBusy + ":provider"
	}
	if left, ok := trialPoolLeft(s); ok && left < float64(s.trialQuotaFloor()) {
		return trialWaitQuota
	}
	if host == "" {
		return trialWaitBusyNoHost
	}
	snap, err := s.Nodes(now)
	if err != nil {
		return trialWaitBusyRoster
	}
	if !machineAdmit(snap, host) {
		return trialWaitBusyAdmit // the machine's own gate is holding new sessions
	}
	for _, m := range snap.Machines {
		if strings.EqualFold(m.Hostname, host) && m.NCPU > 0 && m.Load1 > s.trialLoadRatio()*float64(m.NCPU) {
			return trialWaitLoad
		}
	}
	return ""
}

// trialRoute is what a trial person may reach: the chat (/app, its API, and
// /v1/me which draws it), their trial, their own subscriptions. /apply answers its own credential.
func trialRoute(p string) bool {
	switch p {
	case "/", AppPrefix, AppPrefix + "/", ChatPagePath, "/v1/me", "/v1/me/usage",
		TryPagePath, TryClaimPath, TryTimingPath, TryStatePath, TryBeatPath, TryPausePath, HealthPath, AppPrefix + "/health":
		return true
	case TryOwnPagePath, MeSubsPath, MeSubsLoginPath, MeSubsFinishPath, MeSubsPausePath, MeSubsDeletePath:
		// 接上我自己的订阅 (WACK C1): with fleet.trial.sources=byo a trial
		// spends only a subscription of its own — the console's usage page
		// is where one is connected.
		return true
	}
	return strings.HasPrefix(p, ChatPathPrefix)
}

// trialAsked says whether r's sign-in is on its way to a trial: the note
// /v1/try/start left, with fleet.trial on.
func (s *Server) trialAsked(r *http.Request) bool {
	if !s.trialOn() {
		return false
	}
	c, err := r.Cookie(tryCookie)
	return err == nil && c.Value == "1"
}

func setTryCookie(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: tryCookie, Value: "1", Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r), MaxAge: int(tryCookieTTL.Seconds())})
}

// trialSignIn makes a verified sign-in the list refused (kind + subject, pid
// the person that way already is, if any) a trial person, signs them in as
// one and sends them to /app/try. false: not a trial sign-in — the caller
// answers its refusal as before.
func (s *Server) trialSignIn(w http.ResponseWriter, r *http.Request, asked bool, kind, subject, name, pid string, now time.Time) bool {
	if !asked || !s.trialOn() || s.Store == nil {
		return false
	}
	subject = store.NormIdentitySubject(kind, subject)
	if pid == "" {
		var err error
		if pid, err = s.Store.IdentityPrincipal(kind, subject); err != nil {
			log.Printf("fleet: trial sign-in: %v", err)
			return false
		}
	}
	if pid == "" {
		var err error
		if pid, err = newPersonPrincipal(); err != nil {
			log.Printf("fleet: trial sign-in: %v", err)
			return false
		}
	}
	target := orDefault(name, subject) + " (" + kind + ")"
	if err := s.Store.StartTrialAs(pid, kind, subject, now); err != nil {
		log.Printf("fleet: trial of %s: %v", target, err)
		return false
	}
	if err := s.Store.AddHubIdentity(store.HubIdentity{Kind: kind, Subject: subject, PrincipalID: pid,
		VerifiedAt: now, AddedBy: "trial"}); err != nil && !errors.Is(err, store.ErrIdentityTaken) {
		log.Printf("fleet: trial of %s: identity: %v", target, err)
		return false
	}
	_ = s.Store.HubAudit(pid, "trial.start", target, "ok", "试用登录 · signed in for a trial", now)
	clearCookie(w, r, tryCookie, "/")
	if name == "" {
		name = subject
	}
	http.SetCookie(w, s.personCookie(r, kind, pid, name, roleTrial, now))
	http.Redirect(w, r, TryPagePath, http.StatusFound)
	return true
}

// trialETA is roughly how long the person ahead-th in line waits: the spacing
// of the last ten machines given back, once two are known; before that, a
// spare's opening time per batch of spare_max.
func (s *Server) trialETA(host string, ahead int) int {
	if rel, err := s.Store.TrialReleases(10); err == nil && len(rel) >= 2 {
		gap := rel[0].Sub(rel[len(rel)-1]) / time.Duration(len(rel)-1)
		eta := int(gap.Seconds()) * (ahead + 1)
		if eta < 30 {
			eta = 30
		}
		return eta
	}
	each := openingETA
	if host != "" {
		each = s.openingETAFor(host)
	}
	per := s.spareMax()
	if per < 1 {
		per = 1
	}
	return each * (1 + ahead/per)
}

// trialOutside: r carries a trial person's session and asks for something
// beyond trialRoute. The cookie's role only spares the list a read for
// everyone else; the list decides.
func (s *Server) trialOutside(r *http.Request) bool {
	if trialRoute(r.URL.Path) || r.URL.Path == TryStartPath {
		return false
	}
	sess, pid, ok := s.personSession(r)
	if !ok || sess.Role != roleTrial {
		return false
	}
	role, err := s.personRole(pid)
	return err == nil && role == roleTrial
}
