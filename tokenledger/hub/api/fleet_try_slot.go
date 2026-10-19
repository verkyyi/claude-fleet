package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 机器快放快回，对话按人单独存 (claude-fleet#4060, EPIC #4048 C12). The machine
// is dear, the conversation is light, so they part:
//
//   - The page beats: while it is visible the chat POSTs TryBeatPath every 30
//     seconds with the person's last input (and whether a reply is running).
//     The claim's own polls on /app/try beat too, so a seat that is still
//     opening is not «hidden».
//   - The patrol, every 15 seconds (SweepTrialSlots, on the alerts tick): no
//     beat for fleet.trial.hidden_secs (120) ⇒ release, reason hidden; no input
//     for fleet.trial.idle_warn_secs (180) ⇒ the next beat answers warn (the page
//     says 「1 分钟后暂停」); for fleet.trial.idle_secs (240) ⇒ release, idle.
//     Both idle lines count only from the moment the seat is ready (ready_at:
//     its home set, the conversation in — claude-fleet#4235): a seat still
//     opening cannot be typed into, so it is never «idle». One that is not
//     ready within fleet.trial.open_slow_secs (300) goes back as open_slow —
//     uncharged, the person waiting again in their place (not 「已试过」), and
//     a trial_open_slow alert names the machine.
//     「先暂停」 on the page is TryPausePath, reason pause. The trial's budget
//     (#4059: fleet.trial.max_secs of a machine across every seat, max_msgs
//     lines) ends it through the same road (SweepTrials, reason time · msgs),
//     run here off the tick.
//   - endTrial (fleet_try_budget.go) is the ONE way a trial's machine goes back
//     (trialSlot.Release; trialRelease guards it to one at a time per person):
//     ① the conversation is taken out through the person's own chat relay
//     (webchat's /api/export) and kept in hub_trial_convos sealed to that
//     principal — a key derived for it (credvault SealPerson) — for 24 hours;
//     ② the login goes back through the operator's remove, which on a recycling
//     machine is #3504's wash: reset → bin/fleet-login-reset-check.py +
//     recycleLeftovers, and only a clean answer makes it a spare again (a dirty
//     one is failed and never handed out — TestRecycleNeverHandsOutAnUncleanWash
//     — and raises spare_failed). The washing row is handed to a spare holder
//     of its own (store.HandOffWash) and the person's home on it cleared, so the
//     person may take another login on the same machine before the wash ends;
//     ③ one trial.release audit row with the reason. The seat is free the moment
//     the row says reclaimed: the next in line takes another ready spare, while
//     this login washes in the background (#4044).
//   - trialSeed is the one way it comes back (trialSlot.Claim's half): once the
//     person's new seat is ready, their OWN kept conversation — opened with the
//     session's principal, never an id — is imported into the clean login
//     (webchat's /api/import: the history on the page, the next turn a new
//     session seeded with the last words). A paused, hidden or idle trial with
//     budget left is 「已暂停」 on /app/try and 继续 puts it back in line (the
//     same trial, what is left of its budget); a spent one is 「用完了」 and
//     pointed at /apply. An approved person's next home gets it too
//     (carryTrialConvo), and their request starts with its first words
//     (trialFirstWords).
//   - The kept conversations are purged hourly once 24 hours old, ciphertext
//     and all. No vault key ⇒ nothing is kept (the release goes on; isolation
//     first).
//
// fleet.trial off: the routes 404, the patrol releases what is still placed by
// the same rules — a seat handed out while it was on still goes back.

const (
	TrialHiddenSecsKey = "fleet.trial.hidden_secs"
	TrialIdleWarnKey   = "fleet.trial.idle_warn_secs"
	TrialIdleKey       = "fleet.trial.idle_secs"
	TrialOpenSlowKey   = "fleet.trial.open_slow_secs"

	defaultTrialHiddenSecs   = 120
	defaultTrialIdleWarnSecs = 180
	defaultTrialIdleSecs     = 240
	defaultTrialOpenSlowSecs = 300

	TryBeatPath  = "/v1/try/beat"
	TryPausePath = "/v1/try/pause"

	// Why a trial's machine went back (fleet_trials.release_reason, the
	// trial.release audit).
	trialReleaseHidden = "hidden"
	trialReleaseIdle   = "idle"
	trialReleasePause  = "pause"

	// trialReleaseOpenSlow: the seat did not open in time — put back and the
	// person requeued, never counted as a trial spent (claude-fleet#4235).
	trialReleaseOpenSlow = "open_slow"

	// trialConvoPurpose is what a kept conversation is sealed for.
	trialConvoPurpose = "trial-convo"
	// trialConvoMax bounds what the hub keeps of one conversation.
	trialConvoMax = 24 << 20
)

var (
	// trialConvoKeep is how long a trial's conversation is kept apart.
	trialConvoKeep = 24 * time.Hour
	// trialConvoTimeout bounds one export or import.
	trialConvoTimeout = 20 * time.Second
	// trialSeedGiveUp: a seat this old whose conversation will not import
	// opens empty rather than wait on forever.
	trialSeedGiveUp = 60 * time.Second
	// trialPurgeEvery is how often the expired conversations are deleted.
	trialPurgeEvery = time.Hour
	// trialRegiveEvery: how often one ended trial's leftover login is sent
	// back again (claude-fleet#4262).
	trialRegiveEvery = 10 * time.Minute
)

func (s *Server) trialHiddenSecs() int {
	return s.settingIntOr(TrialHiddenSecsKey, defaultTrialHiddenSecs, 30, 3600)
}
func (s *Server) trialIdleWarnSecs() int {
	return s.settingIntOr(TrialIdleWarnKey, defaultTrialIdleWarnSecs, 30, 3600)
}
func (s *Server) trialIdleSecs() int {
	return s.settingIntOr(TrialIdleKey, defaultTrialIdleSecs, 60, 7200)
}

func (s *Server) trialOpenSlowSecs() int {
	return s.settingIntOr(TrialOpenSlowKey, defaultTrialOpenSlowSecs, 60, 3600)
}

// trialSlotState: which trials are being released now (one release per
// person at a time), and when the patrol last purged.
type trialSlotState struct {
	mu       sync.Mutex
	inflight map[string]bool
	sweeping bool
	purgedAt time.Time
	// regiven: when an ended trial's leftover login was last sent back
	// (SweepTrialStragglers), so a remove that keeps failing is retried
	// every trialRegiveEvery, not every patrol.
	regiven map[string]time.Time
}

func (t *trialSlotState) begin(pid string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.inflight == nil {
		t.inflight = map[string]bool{}
	}
	if t.inflight[pid] {
		return false
	}
	t.inflight[pid] = true
	return true
}

func (t *trialSlotState) end(pid string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.inflight, pid)
}

// trialConvoIO moves a conversation in and out of a login.
type trialConvoIO interface {
	Export(ctx context.Context, person, machine, login string) ([]byte, error)
	Import(ctx context.Context, person, machine, login string, bundle []byte) error
}

// errConvoTaken: the login already holds a conversation of its own.
var errConvoTaken = errors.New("the login already has a conversation")

func (s *Server) convoIO() trialConvoIO {
	if s.trialConvoIO != nil {
		return s.trialConvoIO
	}
	return relayConvoIO{s}
}

// relayConvoIO reaches the login's conversation service the way the page
// does: the person's own chat relay, the person's statement on it.
type relayConvoIO struct{ s *Server }

func (r relayConvoIO) do(ctx context.Context, person, machine, login, method, path string, body []byte) ([]byte, int, error) {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return r.s.dialChatRelay(ctx, person, machine, login)
		},
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	defer tr.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, method, "http://webchat"+path, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set(control.ChatPersonHeader, person)
	if method == http.MethodPost {
		req.Header.Set("X-Fleet-Webchat", "1")
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := (&http.Client{Transport: tr}).Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, trialConvoMax+1))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	if len(b) > trialConvoMax {
		return nil, resp.StatusCode, fmt.Errorf("the conversation is over %d bytes", trialConvoMax)
	}
	return b, resp.StatusCode, nil
}

func (r relayConvoIO) Export(ctx context.Context, person, machine, login string) ([]byte, error) {
	b, code, err := r.do(ctx, person, machine, login, http.MethodGet, "/api/export", nil)
	if err == nil && code != http.StatusOK {
		err = fmt.Errorf("export answered %d", code)
	}
	return b, err
}

func (r relayConvoIO) Import(ctx context.Context, person, machine, login string, bundle []byte) error {
	_, code, err := r.do(ctx, person, machine, login, http.MethodPost, "/api/import", bundle)
	switch {
	case err != nil:
		return err
	case code == http.StatusConflict:
		return errConvoTaken
	case code != http.StatusOK:
		return fmt.Errorf("import answered %d", code)
	}
	return nil
}

// trialKeepConvo takes pid's conversation out of their home login and keeps
// it sealed to pid for trialConvoKeep: what happened, for the audit.
func (s *Server) trialKeepConvo(pid string, now time.Time) string {
	if s.Vault == nil {
		return "convo=none(no key)"
	}
	home, ok, err := s.Store.EntryHomeOf(pid)
	if err != nil || !ok || home.Machine == "" || home.Login == "" {
		return "convo=none(no home)"
	}
	ctx, cancel := context.WithTimeout(context.Background(), trialConvoTimeout)
	defer cancel()
	bundle, err := s.convoIO().Export(ctx, pid, home.Machine, home.Login)
	if err != nil {
		log.Printf("fleet: trial of %s: conversation export: %v", pid, err)
		return "convo=lost(export failed)"
	}
	var probe struct {
		Sessions []json.RawMessage `json:"sessions"`
	}
	if json.Unmarshal(bundle, &probe) != nil {
		return "convo=lost(unreadable)"
	}
	if len(probe.Sessions) == 0 {
		return "convo=none(empty)"
	}
	sealed, err := s.Vault.SealPerson(json.RawMessage(bundle), pid, trialConvoPurpose)
	if err != nil {
		log.Printf("fleet: trial of %s: conversation seal: %v", pid, err)
		return "convo=lost(seal failed)"
	}
	if err := s.Store.PutTrialConvo(pid, sealed, now.Add(trialConvoKeep), now); err != nil {
		log.Printf("fleet: trial of %s: conversation keep: %v", pid, err)
		return "convo=lost(keep failed)"
	}
	return "convo=kept"
}

// trialRelease gives pid's machine back now, why — endTrial, one release
// per person at a time. Nothing for a trial that holds no machine.
func (s *Server) trialRelease(pid, reason string, now time.Time) error {
	if s.Store == nil || !s.trialSlotSt.begin(pid) {
		return nil
	}
	defer s.trialSlotSt.end(pid)
	t, err := s.Store.Trial(pid)
	if err != nil || t == nil || t.State != store.TrialPlaced {
		return err
	}
	ok, sent := s.endTrial(*t, reason, now)
	if sent {
		s.dispatchAccounts()
	}
	if !ok {
		return fmt.Errorf("the machine of %s was not given back", pid)
	}
	return nil
}

// trialGiveBack is endTrial's middle, per login removed (claude-fleet#4060):
// the login washes on under a spare holder of its own, and it is nobody's
// home now — pid may be handed another login on the same machine at once,
// while this one is still being washed.
func (s *Server) trialGiveBack(pid string, a store.FleetAccount, now time.Time) {
	if _, err := s.Store.HandOffWash(pid, a.Hostname, now); err != nil {
		log.Printf("fleet: trial release: hand off %s on %s: %v", pid, a.Hostname, err)
	}
	if _, err := s.Store.ClearEntryHome(pid, a.Hostname, a.Login); err != nil {
		log.Printf("fleet: trial release: home of %s: %v", pid, err)
	}
}

// trialEndNote is the audit's words for why a trial's machine went back.
var trialEndNote = map[string]string{
	trialReleaseHidden:   "试用页关了或切走，机器放回 · page closed or hidden",
	trialReleaseIdle:     "试用没动静，机器放回 · no input",
	trialReleasePause:    "试用者先暂停，机器放回 · paused by the person",
	trialReleaseOpenSlow: "试用的机器迟迟没开好，放回并重新排队（不算试过） · seat did not open in time, requeued",
	trialEndTime:         "试用用完，登录收回 · trial spent, login given back",
	trialEndMsgs:         "试用用完，登录收回 · trial spent, login given back",
}

// trialSlotVerdict is what the patrol does with a placed trial at now: a
// release reason, "warn", or "". The budget is SweepTrials'.
func (s *Server) trialSlotVerdict(t store.Trial, now time.Time) string {
	since := func(at time.Time) time.Duration {
		if at.Before(t.PlacedAt) {
			at = t.PlacedAt
		}
		return now.Sub(at)
	}
	if since(t.BeatAt) >= time.Duration(s.trialHiddenSecs())*time.Second {
		return trialReleaseHidden
	}
	if t.ReadyAt.IsZero() {
		// Still opening: no idle clock (claude-fleet#4235), only its own line.
		if since(t.PlacedAt) >= time.Duration(s.trialOpenSlowSecs())*time.Second {
			return trialReleaseOpenSlow
		}
		return ""
	}
	quiet := since(trialLastInput(t))
	switch {
	case quiet >= time.Duration(s.trialIdleSecs())*time.Second:
		return trialReleaseIdle
	case quiet >= time.Duration(s.trialIdleWarnSecs())*time.Second:
		return "warn"
	}
	return ""
}

// trialLastInput is where t's idle clock starts: its last input, never
// before the seat was ready.
func trialLastInput(t store.Trial) time.Time {
	last := t.InputAt
	if last.Before(t.ReadyAt) {
		last = t.ReadyAt
	}
	if last.Before(t.PlacedAt) {
		last = t.PlacedAt
	}
	return last
}

// trialReady stamps pid's seat ready at now (the first time) — the idle
// clock starts here — and clears the machine's trial_open_slow alert.
func (s *Server) trialReady(pid string, now time.Time) {
	moved, err := s.Store.ReadyTrial(pid, now)
	if err != nil || !moved {
		return
	}
	if t, err := s.Store.Trial(pid); err == nil && t != nil && t.Host != "" {
		_, _ = s.Store.ClearFleetAlert(store.AlertTrialOpenSlow, t.Host, now)
	}
}

// trialOpenSlowAlert tells the operator a seat on host did not open in time.
func (s *Server) trialOpenSlowAlert(t store.Trial, now time.Time) {
	if t.Host == "" {
		return
	}
	b, _ := json.Marshal(map[string]any{"hostname": t.Host, "after_secs": s.trialOpenSlowSecs(),
		"placed_at": t.PlacedAt.UTC()})
	raised, err := s.Store.RaiseFleetAlert(store.AlertTrialOpenSlow, t.Host, string(b), now)
	if err != nil {
		log.Printf("fleet: trial open slow alert %s: %v", t.Host, err)
		return
	}
	if raised {
		_ = s.Store.HubAudit(trialInviter, "trial.alert", t.Host, "raised",
			fmt.Sprintf("%s: %s %s", store.AlertTrialOpenSlow, t.Host, trialEndNote[trialReleaseOpenSlow]), now)
	}
}

// SweepTrialSlots is the 15-second patrol, off the alerts tick: the spent
// trials go back (SweepTrials), every placed trial past one of its lines goes
// back; one quiet past the warning line is told so on its next beat; the kept
// conversations past 24 hours are purged hourly. One sweep at a time.
func (s *Server) SweepTrialSlots(now time.Time) {
	if s.Store == nil {
		return
	}
	s.trialSlotSt.mu.Lock()
	if s.trialSlotSt.sweeping {
		s.trialSlotSt.mu.Unlock()
		return
	}
	s.trialSlotSt.sweeping = true
	purge := now.Sub(s.trialSlotSt.purgedAt) >= trialPurgeEvery
	if purge {
		s.trialSlotSt.purgedAt = now
	}
	s.trialSlotSt.mu.Unlock()
	defer func() {
		s.trialSlotSt.mu.Lock()
		s.trialSlotSt.sweeping = false
		s.trialSlotSt.mu.Unlock()
	}()
	if purge {
		if n, err := s.Store.PurgeTrialConvos(now); err != nil {
			log.Printf("fleet: trial conversations purge: %v", err)
		} else if n > 0 {
			log.Printf("fleet: %d trial conversation(s) past %s deleted", n, trialConvoKeep)
		}
	}
	s.SweepTrials(now)
	if s.SweepTrialStragglers(now) {
		s.dispatchAccounts()
	}
	placed, err := s.Store.PlacedTrials()
	if err != nil {
		log.Printf("fleet: trial patrol: %v", err)
		return
	}
	for _, t := range placed {
		switch v := s.trialSlotVerdict(t, now); v {
		case "":
		case "warn":
			if t.WarnedAt.IsZero() {
				_ = s.Store.WarnTrial(t.Principal, now)
			}
		default:
			if v == trialReleaseOpenSlow {
				s.trialOpenSlowAlert(t, now)
			}
			if err := s.trialRelease(t.Principal, v, now); err != nil {
				log.Printf("fleet: trial patrol: release %s (%s): %v", t.Principal, v, err)
			}
		}
	}
}

// trialSeed puts pid's own kept conversation into the seat t is on, once per
// keeping. done: go ahead (seeded, nothing to seed, or given up); false: try
// again on the next poll.
func (s *Server) trialSeed(t *store.Trial, now time.Time) (resumed, done bool) {
	if t == nil {
		return false, true
	}
	resumed, err := s.seedConvo(t.Principal, now)
	if err != nil {
		if now.Sub(t.PlacedAt) < trialSeedGiveUp {
			return false, false
		}
		log.Printf("fleet: trial of %s: conversation import given up: %v", t.Principal, err)
		_ = s.Store.SeededTrialConvo(t.Principal, now)
	}
	return resumed, true
}

// seedKeptConvo is carryTrialConvo's: an approved person's kept conversation
// into their home once it is there, tried again on each conversation read.
func (s *Server) seedKeptConvo(pid string, now time.Time) {
	if _, err := s.seedConvo(pid, now); err != nil {
		log.Printf("fleet: conversation of %s not carried yet: %v", pid, err)
	}
}

// seedConvo imports pid's own kept conversation — opened with pid, never an
// id the caller names — into pid's home, when it was kept after it was last
// put back. resumed: it went in now; an error: try again later (no home yet,
// the home not answering).
func (s *Server) seedConvo(pid string, now time.Time) (resumed bool, err error) {
	if s.Vault == nil || s.Store == nil {
		return false, nil
	}
	c, err := s.Store.TrialConvo(pid, now)
	if err != nil || c == nil || !c.SeededAt.IsZero() {
		return false, err
	}
	var bundle json.RawMessage
	if err := s.Vault.OpenPerson(c.Sealed, &bundle, pid, trialConvoPurpose); err != nil {
		log.Printf("fleet: %s: kept conversation does not open: %v", pid, err)
		return false, nil
	}
	home, ok, err := s.Store.EntryHomeOf(pid)
	if err != nil {
		return false, err
	}
	if !ok || home.Machine == "" || home.Login == "" {
		return false, errors.New("no home yet")
	}
	ctx, cancel := context.WithTimeout(context.Background(), trialConvoTimeout)
	defer cancel()
	err = s.convoIO().Import(ctx, pid, home.Machine, home.Login, bundle)
	if err != nil && !errors.Is(err, errConvoTaken) {
		return false, err
	}
	_ = s.Store.SeededTrialConvo(pid, now)
	if err == nil {
		_ = s.Store.HubAudit(pid, "trial.resume", pid, "ok", "对话续上 · conversation carried to "+home.Machine+"/"+home.Login, now)
	}
	return err == nil, nil
}

// trialFirstWords is what the trial person first asked of it, to start their
// request with (claude-fleet#4059's stub): the first line of their own
// conversation — the kept one, else the live one on their seat. "" for none.
func (s *Server) trialFirstWords(pid string) string {
	now := time.Now()
	var bundle json.RawMessage
	if c, err := s.Store.TrialConvo(pid, now); err == nil && c != nil && s.Vault != nil {
		if s.Vault.OpenPerson(c.Sealed, &bundle, pid, trialConvoPurpose) != nil {
			bundle = nil
		}
	}
	if bundle == nil {
		home, ok, err := s.Store.EntryHomeOf(pid)
		if err != nil || !ok || home.Login == "" {
			return ""
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		b, err := s.convoIO().Export(ctx, pid, home.Machine, home.Login)
		if err != nil {
			return ""
		}
		bundle = b
	}
	return firstWords(bundle)
}

// convoWrapRE is what the conversation service puts before a person's words
// (a relay's seed, the browser's one line).
var convoWrapRE = regexp.MustCompile(`(?s)^\s*(<fleet-webchat-[a-z]+>.*?</fleet-webchat-[a-z]+>\s*)+`)

// firstWords is the first thing the person said in an exported conversation,
// at most 500 characters.
func firstWords(bundle []byte) string {
	var b struct {
		Sessions []struct {
			JSONL string `json:"jsonl"`
		} `json:"sessions"`
	}
	if json.Unmarshal(bundle, &b) != nil {
		return ""
	}
	for _, sess := range b.Sessions {
		for _, line := range strings.Split(sess.JSONL, "\n") {
			var m struct {
				Type        string `json:"type"`
				IsMeta      bool   `json:"isMeta"`
				IsSidechain bool   `json:"isSidechain"`
				Message     struct {
					Content json.RawMessage `json:"content"`
				} `json:"message"`
			}
			if json.Unmarshal([]byte(line), &m) != nil || m.Type != "user" || m.IsMeta || m.IsSidechain {
				continue
			}
			var text string
			if json.Unmarshal(m.Message.Content, &text) != nil {
				var parts []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				}
				if json.Unmarshal(m.Message.Content, &parts) != nil {
					continue
				}
				for _, p := range parts {
					if p.Type == "text" {
						text = p.Text
						break
					}
				}
			}
			text = strings.TrimSpace(convoWrapRE.ReplaceAllString(text, ""))
			if text == "" || strings.HasPrefix(text, "<") {
				continue
			}
			if r := []rune(text); len(r) > 500 {
				text = string(r[:500])
			}
			return text
		}
	}
	return ""
}

// trialResumable: t's machine went back — hidden, idle or paused — with
// budget left, within its conversation's 24 hours: 继续 is the same trial.
func (s *Server) trialResumable(t *store.Trial, now time.Time) bool {
	switch t.EndedReason {
	case trialReleaseHidden, trialReleaseIdle, trialReleasePause:
	default:
		return false
	}
	secs, msgs := s.trialLeft(t, now)
	return secs > 0 && msgs > 0 && now.Sub(t.ReclaimedAt) < trialConvoKeep
}

// beatAnswer is what the chat's heartbeat reads.
type beatAnswer struct {
	State string `json:"state"` // placed · released · waiting · member
	// Warn: no input for the warning line — the page says 「1 分钟后暂停」,
	// PauseIn seconds before the machine goes back.
	Warn     bool   `json:"warn,omitempty"`
	PauseIn  int    `json:"pause_in_secs,omitempty"`
	LeftSecs int    `json:"left_secs,omitempty"`
	Reason   string `json:"reason,omitempty"`
	Next     string `json:"next,omitempty"`
}

// handleTryBeat: the chat page is visible — its last input, whether a reply
// is running.
func (s *Server) handleTryBeat(w http.ResponseWriter, r *http.Request) {
	if !s.trialOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost || r.Header.Get(tryHeader) != "1" {
		httpError(w, http.StatusBadRequest, "POST from the trial page only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var in struct {
		InputAt int64 `json:"input_at"` // ms since the epoch
		Busy    bool  `json:"busy"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&in); err != nil && !errors.Is(err, io.EOF) {
		httpError(w, http.StatusBadRequest, "input_at is the person's last input, ms since the epoch")
		return
	}
	now := time.Now()
	input := time.Time{}
	if in.InputAt > 0 {
		input = time.UnixMilli(in.InputAt)
	}
	if in.Busy {
		input = now // a reply is running: they are waiting on it, not away
	}
	a, err := s.tryBeat(principalOf(r.Context()), input, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *Server) tryBeat(pid string, input, now time.Time) (beatAnswer, error) {
	t, err := s.Store.Trial(pid)
	if err != nil {
		return beatAnswer{}, err
	}
	if t == nil {
		return beatAnswer{State: "member"}, nil
	}
	switch t.State {
	case store.TrialReclaimed:
		return beatAnswer{State: "released", Reason: t.EndedReason, Next: TryPagePath}, nil
	case store.TrialWaiting:
		return beatAnswer{State: "waiting", Next: TryPagePath}, nil
	}
	// The chat page beats only once the seat is usable: ready, if the
	// claim's poll did not say so first.
	s.trialReady(pid, now)
	if _, err := s.Store.BeatTrial(pid, now, input); err != nil {
		return beatAnswer{}, err
	}
	if t, err = s.Store.Trial(pid); err != nil || t == nil {
		return beatAnswer{}, err
	}
	secs, _ := s.trialLeft(t, now)
	a := beatAnswer{State: "placed", LeftSecs: secs}
	if !t.WarnedAt.IsZero() {
		a.Warn = true
		a.PauseIn = s.trialIdleSecs() - int(now.Sub(trialLastInput(*t)).Seconds())
		if a.PauseIn < 0 {
			a.PauseIn = 0
		}
	}
	return a, nil
}

// handleTryPause: 「先暂停」 — the machine goes back now, the conversation kept.
func (s *Server) handleTryPause(w http.ResponseWriter, r *http.Request) {
	if !s.trialOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost || r.Header.Get(tryHeader) != "1" {
		httpError(w, http.StatusBadRequest, "POST from the trial page only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	pid := principalOf(r.Context())
	if err := s.trialRelease(pid, trialReleasePause, time.Now()); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	a, err := s.tryBeat(pid, time.Time{}, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

// regive says pid's leftover login may be sent back at now, and marks it.
func (t *trialSlotState) regive(pid string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.regiven == nil {
		t.regiven = map[string]time.Time{}
	}
	if at, ok := t.regiven[pid]; ok && now.Sub(at) < trialRegiveEvery {
		return false
	}
	t.regiven[pid] = now
	return true
}
