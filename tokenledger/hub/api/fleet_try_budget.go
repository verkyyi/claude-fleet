package api

import (
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 试用中 (claude-fleet#4059, EPIC #4048 C11): a trial is 15 minutes on a
// machine or 20 lines, whichever comes first, and the person always sees how
// much is left and the one way on — 「申请正式使用」:
//
//   - The budget: fleet.trial.max_secs of a machine (used_secs, summed over
//     its seats — only the time it holds one counts) and fleet.trial.max_msgs
//     lines (msgs, counted at each POST /v1/chat/turn, given back when the
//     turn gets no reply — claude-fleet#4248). A line past the last
//     is refused (trial_over); the last one's reply gets trialCapGrace, then
//     the machine goes back.
//   - The sweep (SweepTrials, every alert tick — it replaced #3590's 7-day
//     reclaim): a spent trial's login is given back through the operator's
//     remove (recycled into a spare), the row ends with its reason (time ·
//     msgs), audited trial.release.
//   - GET TryStatePath: what is left (seconds, lines) and where the trial
//     stands — the chat's top bar reads it every 15 seconds and after each
//     line; every turn's answer carries the same two numbers
//     (X-Fleet-Trial-Left: <secs>,<msgs>).
//   - Approval (admitRequest): the trial person becomes a member — role
//     user, the trial converted; the login they hold stays theirs and the
//     conversation on it goes on; a person whose machine already went back
//     is placed as any member (placePrincipal) and C12 carries the kept
//     conversation in (carryTrialConvo). A refusal leaves the trial to run
//     out; C12 deletes its conversation 24 hours after.
//
// fleet.trial off: GET TryStatePath 404s; the sweep still gives back what a
// trial holds, as #3590's did.

const (
	TrialMaxSecsKey = "fleet.trial.max_secs"
	TrialMaxMsgsKey = "fleet.trial.max_msgs"

	defaultTrialMaxSecs = 900
	defaultTrialMaxMsgs = 20

	TryStatePath = "/v1/try/state"

	// trialLeftHeader rides every turn's answer: seconds and lines left.
	trialLeftHeader = "X-Fleet-Trial-Left"

	// Why a trial ended (fleet_trials.ended_reason, the audit's trial.release).
	trialEndTime = "time"
	trialEndMsgs = "msgs"
)

// trialCapGrace is how long the last line's reply has to arrive before the
// machine goes back.
var trialCapGrace = 2 * time.Minute

func (s *Server) trialMaxSecs() int {
	return s.settingIntOr(TrialMaxSecsKey, defaultTrialMaxSecs, 60, 86400)
}
func (s *Server) trialMaxMsgs() int {
	return s.settingIntOr(TrialMaxMsgsKey, defaultTrialMaxMsgs, 1, 1000)
}

// trialLeft is what t has left at now: seconds of a machine, lines.
func (s *Server) trialLeft(t *store.Trial, now time.Time) (secs, msgs int) {
	secs = s.trialMaxSecs() - int(t.Used(now)/time.Second)
	msgs = s.trialMaxMsgs() - t.Msgs
	return max(secs, 0), max(msgs, 0)
}

// trialState is what the chat's top bar reads.
type trialState struct {
	// State: running (holding a machine) · waiting · ended · member (a
	// member, or approved: no trial to show) — and none, alone, when the
	// trial is off.
	State    string `json:"state"`
	SecsLeft int    `json:"secs_left"`
	MsgsLeft int    `json:"msgs_left"`
	MaxSecs  int    `json:"max_secs"`
	MaxMsgs  int    `json:"max_msgs"`
	// Ended is why it ended: time · msgs (C12 adds its own).
	Ended string `json:"ended,omitempty"`
	// Applied is their newest request's state, "" for none.
	Applied string `json:"applied,omitempty"`
	// Apply is where 「申请正式使用」 goes.
	Apply string `json:"apply"`
}

func (s *Server) trialStateOf(pid string, now time.Time) (trialState, error) {
	out := trialState{MaxSecs: s.trialMaxSecs(), MaxMsgs: s.trialMaxMsgs(), Apply: ApplyPath + "?from=trial"}
	t, err := s.Store.Trial(pid)
	if err != nil {
		return out, err
	}
	if t == nil || t.State == store.TrialConverted {
		out.State = "member"
		return out, nil
	}
	out.SecsLeft, out.MsgsLeft = s.trialLeft(t, now)
	out.Applied = s.trialApplied(pid)
	switch t.State {
	case store.TrialPlaced:
		out.State = "running"
	case store.TrialWaiting:
		out.State = "waiting"
	default:
		out.State, out.Ended = "ended", t.EndedReason
		if out.Ended == "" {
			out.Ended = trialEndTime
		}
	}
	return out, nil
}

// handleTryState answers GET TryStatePath for the signed-in trial person.
// With the trial off it is {"state":"none"}, 200 (task J091): a signed-in page
// asking is no error — only a request with no session is refused (401).
func (s *Server) handleTryState(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	_, pid, ok := s.personSession(r)
	if !ok {
		refuseJSON(w, http.StatusUnauthorized, "signin", "sign in first")
		return
	}
	if !s.trialOn() {
		writeJSON(w, http.StatusOK, map[string]string{"state": "none"})
		return
	}
	st, err := s.trialStateOf(pid, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// trialTurn decides a trial person's line before it is relayed: "" lets it
// through (counted, the header set), else the refusal's code and words. A
// person with no running trial is not held here. counted says a line was
// taken — trialRefund gives it back when the turn gets no reply.
func (s *Server) trialTurn(w http.ResponseWriter, pid string, now time.Time) (code, msg string, counted bool) {
	t, err := s.Store.Trial(pid)
	if err != nil || t == nil || t.State == store.TrialConverted {
		return "", "", false
	}
	if t.State != store.TrialPlaced {
		return "trial_over", "这次试用已经结束 · this trial has ended", false
	}
	if secs, _ := s.trialLeft(t, now); secs <= 0 {
		return "trial_over", "试用时间用完了 · the trial's time is up", false
	}
	n, ok, err := s.Store.CountTrialMsg(pid, s.trialMaxMsgs(), now)
	if err != nil {
		log.Printf("fleet: trial line of %s: %v", pid, err)
		return "", "", false // never stop a conversation on a bookkeeping error
	}
	if !ok {
		return "trial_over", "试用的消息条数用完了 · the trial's lines are used up", false
	}
	secs, _ := s.trialLeft(t, now)
	w.Header().Set(trialLeftHeader, strconv.Itoa(secs)+","+strconv.Itoa(max(s.trialMaxMsgs()-n, 0)))
	return "", "", true
}

// trialRefund gives pid's counted line back: the turn got no reply
// (claude-fleet#4248 — the service did not answer, no session credential).
func (s *Server) trialRefund(pid, why string) {
	if err := s.Store.UncountTrialMsg(pid); err != nil {
		log.Printf("fleet: trial line of %s: give back (%s): %v", pid, why, err)
		return
	}
	log.Printf("fleet: trial line of %s given back (%s)", pid, why)
}

// turnWatch reads a /api/turn NDJSON stream as it passes to the page and says,
// once it closes, whether the turn failed with no reply: an error frame and
// none of text · tool · ask · tool_result · done before it. Only then onFail
// runs; a page that went away mid-turn saw no error frame, so it is never one.
type turnWatch struct {
	io.ReadCloser
	outcome control.ChatOutcome
	onFail  func()
	closed  bool
}

func (tw *turnWatch) Read(p []byte) (int, error) {
	n, err := tw.ReadCloser.Read(p)
	tw.outcome.Feed(p[:n])
	return n, err
}
func (tw *turnWatch) Close() error {
	err := tw.ReadCloser.Close()
	if !tw.closed {
		tw.closed = true
		if tw.outcome.Refund() {
			tw.onFail()
		}
	}
	return err
}

// endTrial gives t's logins back and ends it for reason; false when a
// remove failed (tried again next sweep). sent says a remove went out.
func (s *Server) endTrial(t store.Trial, reason string, now time.Time) (ok, sent bool) {
	// The conversation goes apart first, sealed to the person (#4060).
	convo := s.trialKeepConvo(t.Principal, now)
	logins, ok, sent := s.trialGiveBackAll(t.Principal, now)
	if !ok {
		return false, sent
	}
	release := s.Store.ReleaseTrial
	if reason == trialReleaseOpenSlow {
		release = s.Store.RequeueTrial // not a trial spent (claude-fleet#4235)
	}
	if moved, err := release(t.Principal, reason, now); err != nil || !moved {
		if err != nil {
			log.Printf("fleet: trial end: %s: %v", t.Principal, err)
		}
		return false, sent
	}
	_ = s.Store.HubAudit(trialInviter, "trial.release", t.Principal, "ok",
		"reason="+reason+" "+convo+" "+logins+" · "+trialEndNote[reason], now)
	log.Printf("fleet: trial of %s released (%s, %s, %s)", t.Principal, reason, convo, logins)
	return true, sent
}

// trialWashable says a's login goes back when its trial ends: every managed
// row the operator's remove takes — a failed or unknown one too
// (claude-fleet#4262: a seat whose last op had failed was skipped, the trial
// released anyway, and the login was never washed — the machine's spares ran
// out). A row with an op in flight, or already going, is not touched.
func trialWashable(a store.FleetAccount) bool {
	if !a.Managed() {
		return false
	}
	switch a.State {
	case store.AccountActive, store.AccountFailed, store.AccountUnknown:
		return true
	}
	return false
}

// trialGiveBackAll sends every washable login pid holds back through the
// operator's remove (a recycling machine's wash), each handed to a spare
// holder of its own. logins is the audit's record of what each one did —
// logins=<login>@<machine>:<state before>→<state now>, or logins=none.
func (s *Server) trialGiveBackAll(pid string, now time.Time) (logins string, ok, sent bool) {
	as, err := s.Store.FleetAccounts(pid)
	if err != nil {
		log.Printf("fleet: trial end: accounts of %s: %v", pid, err)
		return "", false, false
	}
	ok = true
	var parts []string
	for _, a := range as {
		if !trialWashable(a) {
			continue
		}
		if err := s.changeAccount(FleetAccountRequest{Action: "remove", PrincipalID: pid, Hostname: a.Hostname}, trialInviter); err != nil {
			log.Printf("fleet: trial end: remove %s on %s: %v", pid, a.Hostname, err)
			parts = append(parts, a.Login+"@"+a.Hostname+":"+a.State+"→kept(remove failed)")
			ok = false
			continue
		}
		sent = true
		to := store.AccountRemovePending
		if after, err := s.Store.FleetAccounts(pid); err == nil {
			for _, b := range after {
				if strings.EqualFold(b.Hostname, a.Hostname) {
					to = b.State
				}
			}
		}
		s.trialGiveBack(pid, a, now)
		parts = append(parts, a.Login+"@"+a.Hostname+":"+a.State+"→"+to)
	}
	if len(parts) == 0 {
		return "logins=none", ok, sent
	}
	return "logins=" + strings.Join(parts, ","), ok, sent
}

// SweepTrialStragglers washes what an ended trial still holds: a reclaimed
// trial with a login left on it (claude-fleet#4262 — given back before the
// failed row was washable, or a remove that went out and was answered
// failed) has it washed now, with one trial.regive audit row. A converted
// trial keeps its login (it is theirs); a placed one is the patrol's.
func (s *Server) SweepTrialStragglers(now time.Time) (sent bool) {
	ended, err := s.Store.ReclaimedTrialsHolding()
	if err != nil {
		log.Printf("fleet: trial stragglers: %v", err)
		return false
	}
	for _, pid := range ended {
		if !s.trialSlotSt.regive(pid, now) || !s.trialSlotSt.begin(pid) {
			continue
		}
		logins, ok, did := s.trialGiveBackAll(pid, now)
		s.trialSlotSt.end(pid)
		sent = sent || did
		if logins == "logins=none" {
			continue
		}
		result := "ok"
		if !ok {
			result = "failed"
		}
		_ = s.Store.HubAudit(trialInviter, "trial.regive", pid, result,
			logins+" · 试用已结束，留下的登录补洗 · an ended trial's login washed", now)
		log.Printf("fleet: ended trial of %s still held a login: %s", pid, logins)
	}
	return sent
}

// SweepTrials gives back every spent trial's login: fleet.trial.max_secs of
// a machine, or the last line's reply given trialCapGrace. It runs whatever
// fleet.trial says now — a login handed out while it was on still goes back.
func (s *Server) SweepTrials(now time.Time) {
	if s.Store == nil {
		return
	}
	spent, err := s.Store.SpentTrials(now, int64(s.trialMaxSecs()), trialCapGrace)
	if err != nil {
		log.Printf("fleet: trial sweep: %v", err)
		return
	}
	sentAny := false
	for _, t := range spent {
		reason := trialEndTime
		if !t.CappedAt.IsZero() && t.Used(now) < time.Duration(s.trialMaxSecs())*time.Second {
			reason = trialEndMsgs
		}
		ok, sent := s.endTrial(t, reason, now)
		sentAny = sentAny || sent
		if ok {
			log.Printf("fleet: trial of %s spent (%s) — login given back", t.Principal, reason)
		}
	}
	if sentAny {
		s.dispatchAccounts()
	}
}

// convertTrial turns pid's trial over once their request is approved: the
// trial ends as approved; the login a running trial holds stays theirs (its
// conversation goes on), a person with none is placed as any member.
func (s *Server) convertTrial(pid, display, by string, now time.Time) {
	t, err := s.Store.Trial(pid)
	if err != nil || t == nil || t.State == store.TrialConverted {
		return
	}
	if changed, err := s.Store.ConvertTrial(pid, now); err != nil || !changed {
		if err != nil {
			log.Printf("fleet: trial of %s: convert: %v", pid, err)
		}
		return
	}
	_ = s.Store.HubAudit(by, "trial.convert", pid, "ok", "试用转正式 · trial became a member", now)
	s.trialCredOnConvert(pid, by, now)
	if t.State != store.TrialPlaced {
		s.placePrincipal(pid, display, by)
		s.carryTrialConvo(pid)
	}
}

// carryTrialConvo brings pid's kept trial conversation into their new home
// (claude-fleet#4060): at once when the home is there, else on their first
// conversation read (handleChat → seedKeptConvo).
func (s *Server) carryTrialConvo(pid string) {
	go s.seedKeptConvo(pid, time.Now())
}
