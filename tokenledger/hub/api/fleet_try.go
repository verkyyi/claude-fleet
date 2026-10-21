package api

import (
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// The 60-second trial (claude-fleet#3590, EPIC #3569 C20): a person from the
// website presses 「60 秒试用」, signs in, is handed a spare login — or, with
// none free, waits in line and is told roughly how long — and says their first
// line in the browser conversation; the page stops the clock at the first
// reply and tells them 「你用了 0:47」. It only strings together what exists:
//
//   - Who may come in: a verified sign-in on its way to a trial
//     (claude-fleet#4058, fleet_try_gate.go) — POST TryStartPath leaves the
//     ccq_try note and sends the browser to sign in; the service account's
//     code, a mailed code or GitHub then makes someone the list does not
//     name a trial person (trialSignIn), recorded here as waiting. Until
//     #4058 a trial invite did this; it no longer admits anyone.
//   - The login: never opened for them at the sign-in (placePrincipal leaves a
//     trial person alone). POST TryClaimPath is the one place they are placed:
//     the first in line, by waiting_since, takes a ready spare
//     (claimSpares, EPIC #3500) on the machine placement picks, once the
//     admission (trialHold) says yes; everyone else is told their place, why
//     and an ETA. A person who walked away from the page
//     (not seen for trialFresh) holds no one up.
//   - The conversation: /app, the console's chat (claude-fleet#3567). The
//     clock lives in the browser (sessionStorage), from the press on the site
//     (performance.timeOrigin of /app/try?go=1) to the first text of the first
//     reply; POST TryTimingPath keeps it once per person, anonymously — the
//     table holds when and how long, never who. GET TryStatsPath (admin) is
//     the p50 / p90.
//   - Spent (fleet.trial.max_secs on a machine or fleet.trial.max_msgs
//     lines, claude-fleet#4059 — fleet_try_budget.go; it replaced the 7-day
//     reclaim), their login goes back through the operator's remove — a
//     recycling machine washes it into a spare (claude-fleet#3504).
//
// fleet.trial is off by default: /app/try says 试用暂未开放 and offers to
// apply (TestTryOffSaysApply, claude-fleet#4269), the three routes 404,
// nothing is recorded.

const (
	// TrialKey turns the trial road on.
	TrialKey = "fleet.trial"

	TryPagePath   = AppPrefix + "/try"
	tryScriptPath = AppPrefix + "/try.js"
	TryStartPath  = "/v1/try/start"
	TryClaimPath  = "/v1/try/claim"
	TryTimingPath = "/v1/try/timing"
	TryStatsPath  = "/v1/fleet/try/stats"
	// TryOwnPagePath is where a trial connects its own subscription: the
	// console's usage page, which carries 我自己的订阅 (WACK C1).
	TryOwnPagePath = AppPrefix + "/me/usage"

	// trialInviter is the created_by of a trial invite: no person made it.
	trialInviter = "trial"
	// tryHeader is what the page's own fetches carry: a header a cross-site
	// form cannot set.
	tryHeader = "X-Fleet-Try"
)

var (
	// trialFresh: a waiting person not seen for this long holds no one up.
	trialFresh = 2 * time.Minute
	// trialStartsPerMinute bounds the trial invites minted hub-wide.
	trialStartsPerMinute = 30
	// trialMaxMS is the longest timing kept (an hour): anything longer was
	// not one sitting.
	trialMaxMS int64 = 3600 * 1000
)

// trialOn is fleet.trial.
func (s *Server) trialOn() bool { return s.settingOn(TrialKey) }

// trialPerson says whether pid came in through the trial road and is not a
// member since (an approved trial is converted, claude-fleet#4059).
func (s *Server) trialPerson(pid string) bool {
	if s.Store == nil || pid == "" {
		return false
	}
	t, err := s.Store.Trial(pid)
	return err == nil && t != nil && t.State != store.TrialConverted
}

// tryStarts is the hub-wide minute window of trial invites minted.
type tryStarts struct {
	mu    sync.Mutex
	since time.Time
	n     int
}

var trialStarts tryStarts

func (t *tryStarts) take(now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if now.Sub(t.since) >= time.Minute {
		t.since, t.n = now, 0
	}
	if t.n >= trialStartsPerMinute {
		return false
	}
	t.n++
	return true
}

// tryAnswer is what the page reads.
type tryAnswer struct {
	State    string `json:"state"`              // ready · opening · waiting · member · tried · day_full · signin · signed_in
	Next     string `json:"next,omitempty"`     // where to go now
	Position int    `json:"position,omitempty"` // people ahead in line
	ETASecs  int    `json:"eta_secs,omitempty"` // roughly how long until a seat
	Reason   string `json:"reason,omitempty"`   // why waiting: full · busy · load · quota · nosub · byo · no_spare
	// Applied is a tried person's request state (pending · approved ·
	// rejected · withdrawn), "" for none.
	Applied string `json:"applied,omitempty"`
	// Resumed: the seat is ready with the person's kept conversation in it
	// (claude-fleet#4060).
	Resumed bool `json:"resumed,omitempty"`
	// LeftSecs is the trial's machine time left; KeptUntil (unix seconds) is
	// when a paused trial's conversation goes (state paused).
	LeftSecs  int   `json:"left_secs,omitempty"`
	KeptUntil int64 `json:"kept_until,omitempty"`
}

// handleTryStart: a signed-out browser gets a trial invite and is sent to
// sign in; a signed-in one goes straight back to the page.
func (s *Server) handleTryStart(w http.ResponseWriter, r *http.Request) {
	if !s.trialOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost || r.Header.Get(tryHeader) != "1" {
		httpError(w, http.StatusBadRequest, "POST from the trial page only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if _, pid, ok := s.personSession(r); ok {
		if role, err := s.personRole(pid); err == nil && role != "" {
			writeJSON(w, http.StatusOK, tryAnswer{State: "signed_in", Next: TryPagePath})
			return
		}
	}
	if !trialStarts.take(time.Now()) {
		refuseJSON(w, http.StatusTooManyRequests, "busy", "试用的人太多了，过一分钟再试")
		return
	}
	// The note alone opens nothing: the sign-in it leads to must verify
	// someone (claude-fleet#4058).
	setTryCookie(w, r)
	http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: TryPagePath, Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r), MaxAge: int(loginCookieTTL.Seconds())})
	writeJSON(w, http.StatusOK, tryAnswer{State: "signin", Next: AppPrefix + "/signin"})
}

// handleTryClaim places the person if they are first in line, and says where
// they stand.
func (s *Server) handleTryClaim(w http.ResponseWriter, r *http.Request) {
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
	name := ""
	if sess := sessionOf(r.Context()); sess != nil {
		name = sess.Name
	}
	a, err := s.tryClaimAs(pid, name, r.URL.Query().Get("resume") == "1", time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

// tryClaim is the claim at now.
func (s *Server) tryClaim(pid, name string, now time.Time) (tryAnswer, error) {
	return s.tryClaimAs(pid, name, false, now)
}

// tryClaimAs is the claim at now; resume: the person pressed 继续 on a paused
// trial (claude-fleet#4060).
func (s *Server) tryClaimAs(pid, name string, resume bool, now time.Time) (tryAnswer, error) {
	t, err := s.Store.Trial(pid)
	if err != nil {
		return tryAnswer{}, err
	}
	if t == nil || t.State == store.TrialConverted {
		// Already a member (or approved since): the console is theirs.
		return tryAnswer{State: "member", Next: AppPrefix}, nil
	}
	if err := s.Store.TouchTrial(pid, now); err != nil {
		return tryAnswer{}, err
	}
	if t.State == store.TrialReclaimed && s.trialResumable(t, now) {
		// Paused, hidden or idle with time left (claude-fleet#4060): the same
		// trial — 「已暂停」 until they press 继续, then back in line.
		if !resume {
			kept := int64(0)
			if c, err := s.Store.TrialConvo(pid, now); err == nil && c != nil {
				kept = c.ExpiresAt.Unix()
			}
			secs, _ := s.trialLeft(t, now)
			return tryAnswer{State: "paused", Reason: t.EndedReason, LeftSecs: secs, KeptUntil: kept}, nil
		}
		if err := s.Store.ResumeTrial(pid, now); err != nil {
			return tryAnswer{}, err
		}
		if t, err = s.Store.Trial(pid); err != nil || t == nil {
			return tryAnswer{}, err
		}
	}
	if t.State == store.TrialReclaimed {
		if s.trialOnce() {
			// One trial per way (claude-fleet#4058): /apply is what is left.
			return tryAnswer{State: "tried", Next: ApplyPath, Applied: s.trialApplied(pid), Reason: t.EndedReason}, nil
		}
		// Back after their machine went back: to the end of the line.
		if err := s.Store.RejoinTrial(pid, now); err != nil {
			return tryAnswer{}, err
		}
		if t, err = s.Store.Trial(pid); err != nil || t == nil {
			return tryAnswer{}, err
		}
	}
	if t.State == store.TrialPlaced {
		// The claim's own poll keeps a seat that is still opening from
		// reading as «hidden» (claude-fleet#4060).
		if _, err := s.Store.BeatTrial(pid, now, time.Time{}); err != nil {
			return tryAnswer{}, err
		}
		return s.tryHome(pid, now)
	}
	if n, err := s.Store.TrialsStartedSince(trialDayStart(now)); err != nil {
		return tryAnswer{}, err
	} else if n >= s.trialDailyNow() {
		s.trialQueued(pid, "daily", now)
		return tryAnswer{State: "day_full"}, nil
	}
	ahead, err := s.Store.TrialsAhead(t, now.Add(-trialFresh))
	if err != nil {
		return tryAnswer{}, err
	}
	host, noSpare := s.trialMachine(now)
	why := s.trialHold(host, now)
	if s.trialNeedsOwn(pid) {
		// fleet.trial.sources leaves it only its own subscription, and it
		// has none: a seat would only answer the proxy's refusal (WACK C1).
		why = trialWaitBYO
	}
	if why == trialWaitBusyNoHost && noSpare {
		why = trialWaitNoSpare
		s.trialNoSpareAlert(now)
	}
	if ahead == 0 && why == "" {
		if claimed := s.claimSpares(pid, name, pid, []string{host}, now); len(claimed) > 0 {
			if err := s.Store.PlaceTrial(pid, claimed[0], now); err != nil {
				return tryAnswer{}, err
			}
			_, _ = s.Store.ClearFleetAlert(store.AlertTrialNoSpare, trialNoSpareSubject, now)
			_ = s.Store.HubAudit(pid, "trial.claim", pid, "ok", "试用领到备用登录 · trial seat on "+claimed[0], now)
			return s.tryHome(pid, now)
		}
		why = trialWaitBusySpare // no ready spare there
	}
	if why == "" {
		why = trialWaitFull // someone is ahead
	}
	s.trialQueued(pid, why, now)
	return tryAnswer{State: "waiting", Position: ahead, ETASecs: s.trialETA(host, ahead), Reason: trialPageReason(why)}, nil
}

// trialNoSpareSubject is trial_no_spare's one subject: the whole hub.
const trialNoSpareSubject = "hub"

// trialNoSpareAlert tells the operator a trial waits because no fit machine
// holds a ready spare; cleared by the next trial that claims one.
func (s *Server) trialNoSpareAlert(now time.Time) {
	raised, err := s.Store.RaiseFleetAlert(store.AlertTrialNoSpare, trialNoSpareSubject, "{}", now)
	if err != nil {
		log.Printf("fleet: trial no spare alert: %v", err)
		return
	}
	if raised {
		_ = s.Store.HubAudit(trialInviter, "trial.alert", trialNoSpareSubject, "raised",
			store.AlertTrialNoSpare+": 试用在排队，可放的机器上都没有就绪备用 · no fit machine holds a ready spare", now)
	}
}

// trialQueued audits why pid waits, once per change of reason.
func (s *Server) trialQueued(pid, why string, now time.Time) {
	if changed, err := s.Store.SetTrialQueueReason(pid, why); err == nil && changed {
		_ = s.Store.HubAudit(pid, "trial.queued", pid, "waiting", "reason="+why, now)
	}
}

// trialApplied is the state of pid's newest request, "" for none.
func (s *Server) trialApplied(pid string) string {
	a, ok := s.trialApplicant(pid)
	if !ok {
		return ""
	}
	if rs, err := s.Store.Requests().ByIdentity(a.Kind, a.Subject); err == nil && len(rs) > 0 {
		return rs[0].State
	}
	return ""
}

// tryHome: placed — ready once their home is set, which needs the login live,
// and their own kept conversation is in it (claude-fleet#4060).
func (s *Server) tryHome(pid string, now time.Time) (tryAnswer, error) {
	_, ok, err := s.Store.EntryHomeOf(pid)
	if err != nil {
		return tryAnswer{}, err
	}
	if !ok {
		choices, err := s.entryHomeChoices(pid, now)
		if err != nil {
			return tryAnswer{}, err
		}
		h, err := s.entryEnsureHome(pid, choices, now)
		if err != nil {
			return tryAnswer{}, err
		}
		if h == nil {
			return tryAnswer{State: "opening"}, nil
		}
	}
	t, err := s.Store.Trial(pid)
	if err != nil {
		return tryAnswer{}, err
	}
	resumed, done := s.trialSeed(t, now)
	if !done {
		return tryAnswer{State: "opening"}, nil
	}
	s.trialReady(pid, now) // the idle clock starts now (claude-fleet#4235)
	a := tryAnswer{State: "ready", Next: AppPrefix, Resumed: resumed}
	if t != nil {
		a.LeftSecs, _ = s.trialLeft(t, now)
	}
	return a, nil
}

// handleTryTiming keeps the page's one timing, anonymously.
func (s *Server) handleTryTiming(w http.ResponseWriter, r *http.Request) {
	if !s.trialOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost || r.Header.Get(tryHeader) != "1" {
		httpError(w, http.StatusBadRequest, "POST from the trial page only")
		return
	}
	var in struct {
		MS int64 `json:"ms"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&in); err != nil || in.MS <= 0 || in.MS > trialMaxMS {
		httpError(w, http.StatusBadRequest, "ms is the milliseconds from the press to the first reply, at most an hour")
		return
	}
	kept, err := s.Store.RecordTrialTiming(principalOf(r.Context()), in.MS, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"kept": kept})
}

// trialStats is the admin's read: the line now and the timings' spread.
type trialStats struct {
	On         bool           `json:"on"`
	Trials     map[string]int `json:"trials"`
	WaitingNow int            `json:"waiting_now"`
	Last7d     durStats       `json:"last_7d"`
	All        durStats       `json:"all"`
}

func (s *Server) handleTryStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	now := time.Now()
	out, err := s.trialStatsAt(now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) trialStatsAt(now time.Time) (trialStats, error) {
	out := trialStats{On: s.trialOn()}
	var err error
	if out.Trials, err = s.Store.TrialCounts(); err != nil {
		return out, err
	}
	if out.WaitingNow, err = s.Store.TrialsWaiting(now.Add(-trialFresh)); err != nil {
		return out, err
	}
	spread := func(since time.Time) (durStats, error) {
		ms, err := s.Store.TrialTimings(since)
		if err != nil {
			return durStats{}, err
		}
		xs := make([]float64, len(ms))
		for i, v := range ms {
			xs[i] = float64(v) / 1000
		}
		return durStats{N: len(xs), MedianSecs: percentile(xs, 0.5), P90Secs: percentile(xs, 0.9)}, nil
	}
	if out.Last7d, err = spread(now.Add(-7 * 24 * time.Hour)); err != nil {
		return out, err
	}
	out.All, err = spread(time.Time{})
	return out, err
}

// ── the page ────────────────────────────────────────────────────────────

// tryCSP is entryCSP with the page's own script allowed.
const tryCSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

const tryCSS = `
.steps{list-style:none;margin:0 0 24px;padding:0;display:grid;gap:8px}
.steps li{display:flex;gap:12px;align-items:center;padding:12px 16px;border:1px solid var(--border);border-radius:var(--radius);background:var(--card);font-size:15px}
.steps .n{width:24px;height:24px;flex:none;border-radius:9999px;display:grid;place-items:center;background:var(--muted);color:var(--muted-foreground);font:500 13px/1 var(--fleet-font-mono)}
.steps li[data-s=now]{border-color:var(--fleet-clay)}
.steps li[data-s=now] .n{background:var(--fleet-clay);color:var(--primary-foreground)}
.steps li[data-s=done] .n{background:var(--fleet-ok);color:var(--primary-foreground)}
.clock{margin:0 0 20px;text-align:center;font:500 44px/1 var(--fleet-font-mono);letter-spacing:.04em;font-variant-numeric:tabular-nums}
.clock[hidden],.alert[hidden]{display:none}
`

var tryTmpl = template.Must(template.New("try").Funcs(pageFuncs(i18n.EN)).Parse(entryHead + `<style>` + tryCSS + `</style>
<title>{{t "try.title"}}</title></head><body><div class="page">` + entryTop + `
<main class="col" id="try" data-in="{{if .In}}1{{end}}"
 data-w-wait="{{t "try.wait"}}" data-w-first="{{t "try.first"}}" data-w-opening="{{t "try.opening"}}"
 data-w-busy="{{t "try.busy"}}" data-w-fail="{{t "try.fail"}}" data-w-min="{{t "try.min"}}"
 data-w-tried="{{t "try.tried"}}" data-w-applied="{{t "try.applied"}}" data-w-apply="{{t "try.apply"}}" data-w-see="{{t "try.see"}}"
 data-w-dayfull="{{t "try.dayfull"}}" data-w-r-full="{{t "try.r.full"}}" data-w-r-busy="{{t "try.r.busy"}}"
 data-w-r-load="{{t "try.r.load"}}" data-w-r-quota="{{t "try.r.quota"}}" data-w-r-nosub="{{t "try.r.nosub"}}"
 data-w-r-no_spare="{{t "try.r.no_spare"}}" data-w-reach="{{t "try.reach"}}"
 data-w-r-byo="{{t "try.r.byo"}}" data-w-own="{{t "try.own"}}"
 data-w-paused="{{t "try.paused"}}" data-w-resume="{{t "try.resume"}}" data-w-resuming="{{t "try.resuming"}}" data-w-capped="{{t "try.capped"}}">
<h1>{{t "try.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{t "try.lead"}}</p>
<ol class="steps">
<li data-step="1"><span class="n">1</span>{{t "try.s1"}}</li>
<li data-step="2"><span class="n">2</span>{{t "try.s2"}}</li>
<li data-step="3"><span class="n">3</span>{{t "try.s3"}}</li>
</ol>
<p class="clock" id="clock" hidden>0:00</p>
<div class="alert" id="msg" role="status" hidden>` + alertIcon + `<span></span></div>
<button class="btn primary" id="go" type="button">{{t "try.go"}}</button>
<p class="fine">{{t "try.fine"}}</p>
</main></div><script src="` + tryScriptPath + `"></script></body></html>`))

// serveTryPage is /app/try with fleet.trial on: open to anyone.
func (s *Server) serveTryPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	loc := s.pageLocale(w, r)
	entryHeaders(w, loc)
	w.Header().Set("Content-Security-Policy", tryCSP)
	in := false
	if _, pid, ok := s.personSession(r); ok {
		if role, err := s.personRole(pid); err == nil && role != "" {
			in = true
			_ = s.Store.TouchTrial(pid, time.Now())
		}
	}
	if r.Method == http.MethodHead {
		return
	}
	c, err := tryTmpl.Clone()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	_ = c.Funcs(pageFuncs(loc)).Execute(w, struct {
		pageView
		In bool
	}{newPageView(r, loc), in})
}

// serveTryScript is the page's script.
func serveTryScript(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Type", "text/javascript; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=300")
	h.Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write([]byte(tryScript))
}

// tryScript runs the page: the clock from the press, the start, the claim
// and its line, then /app — where the chat stops the clock at the first
// reply (extras/web-console src/app/chat/try.ts reads the same key).
const tryScript = `(function () {
  "use strict";
  var KEY = "fleet.try.t0", H = { "X-Fleet-Try": "1" };
  var main = document.getElementById("try"), clock = document.getElementById("clock");
  var msg = document.getElementById("msg"), go = document.getElementById("go");
  var w = function (k) { return main.getAttribute("data-w-" + k) || ""; };
  var t0 = Number(sessionStorage.getItem(KEY)) || 0;
  var fmt = function (ms) { var s = Math.max(0, Math.floor(ms / 1000)); return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2); };
  var tick = function () { if (t0) { clock.hidden = false; clock.textContent = fmt(Date.now() - t0); } };
  var say = function (text) { msg.hidden = !text; msg.lastChild.textContent = text || ""; };
  var done = false;
  var step = function (n) {
    [].forEach.call(main.querySelectorAll(".steps li"), function (li) {
      var k = Number(li.getAttribute("data-step"));
      li.setAttribute("data-s", k < n ? "done" : k === n ? "now" : "");
    });
  };
  var start = function () {
    if (!t0) {
      t0 = new URLSearchParams(location.search).get("go") === "1" && performance.timeOrigin ? Math.round(performance.timeOrigin) : Date.now();
      sessionStorage.setItem(KEY, String(t0));
    }
    go.disabled = true;
    tick();
    if (main.getAttribute("data-in") === "1") { claim(false); return; }
    step(1);
    fetch("` + TryStartPath + `", { method: "POST", headers: H, credentials: "same-origin" })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (x) {
        if (x.ok && x.j.next) { location.assign(x.j.next); return; }
        say(x.j.code === "busy" ? w("busy") : w("fail")); go.disabled = false;
      })
      .catch(function () { say(w("fail")); go.disabled = false; });
  };
  var paused = false, own = false, resumeAt = 0;
  var claim = function (resume) {
    step(2);
    if (resume) { resumeAt = Date.now(); say(w("resuming")); }
    fetch("` + TryClaimPath + `" + (resume ? "?resume=1" : ""), { method: "POST", headers: H, credentials: "same-origin" })
      .then(function (r) { if (r.redirected || !r.ok) throw r; return r.json(); })
      .then(function (j) {
        if (j.state === "ready" || j.state === "member") {
          step(3);
          var next = j.next || "/app";
          // back on a clean machine with their own conversation (issue #4060)
          if (j.resumed) next += (next.indexOf("?") < 0 ? "?" : "&") + "resumed=" + Math.max(1, Math.round((Date.now() - (resumeAt || Date.now())) / 1000));
          location.assign(next); return;
        }
        if (j.state === "opening") { say(w(resumeAt ? "resuming" : "opening")); setTimeout(function () { claim(false); }, 2000); return; }
        if (j.state === "paused") {
          // the machine went back; the conversation is kept — 继续 is the same trial
          paused = true; clock.hidden = true;
          var left = j.left_secs || 0, until = j.kept_until ? new Date(j.kept_until * 1000) : null;
          say(w("paused").replace("{left}", Math.floor(left / 60) + ":" + ("0" + (left % 60)).slice(-2))
            .replace("{until}", until ? until.toLocaleString([], { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "—"));
          go.textContent = w("resume"); go.disabled = false;
          return;
        }
        if (j.state === "tried") {
          // One trial per account: what is left is applying.
          done = true; clock.hidden = true; sessionStorage.removeItem(KEY);
          say((j.reason === "time" || j.reason === "msgs") && !j.applied ? w("capped") : j.applied ? w("applied") : w("tried"));
          go.textContent = j.applied ? w("see") : w("apply"); go.disabled = false;
          return;
        }
        if (j.reason === "byo") {
          // only their own subscription may be spent, and none is connected
          own = true; clock.hidden = true;
          say(w("r-byo"));
          go.textContent = w("own"); go.disabled = false;
          return;
        }
        if (j.state === "day_full") { say(w("dayfull")); setTimeout(function () { claim(false); }, 60000); return; }
        var mins = Math.max(1, Math.round((j.eta_secs || 60) / 60));
        var why = j.reason ? w("r-" + j.reason) : "";
        say((why ? why + " " : "") + (j.position ? w("wait").replace("{n}", j.position) : w("first")).replace("{m}", mins + " " + w("min")) + " " + w("reach"));
        // first in line asks often: a seat freed is taken within seconds
        setTimeout(function () { claim(false); }, j.position ? 10000 : 3000);
      })
      .catch(function () { say(w("fail")); go.disabled = false; });
  };
  go.addEventListener("click", function () {
    if (own) location.assign("` + TryOwnPagePath + `");
    else if (done) location.assign("` + ApplyPath + `");
    else if (paused) { paused = false; go.disabled = true; claim(true); }
    else start();
  });
  setInterval(tick, 250);
  var q = new URLSearchParams(location.search);
  if (main.getAttribute("data-in") === "1") { if (t0) start(); else if (q.get("paused") === "1") claim(false); else step(2); }
  else if (new URLSearchParams(location.search).get("go") === "1") start();
  else step(1);
})();
`

func init() {
	for k, v := range map[string]i18n.Text{
		"try.title": {i18n.EN: "Try it now · ClaudeFleet", i18n.ZhCN: "立即体验 · ClaudeFleet"},
		"try.h1":    {i18n.EN: "Try it now", i18n.ZhCN: "立即体验"},
		"try.lead": {i18n.EN: "Scan with WeChat and follow 二四网络科技, get a machine, say your first line. The clock runs from the press to the first reply.",
			i18n.ZhCN: "扫码关注「二四网络科技」、领一台机器、说第一句话。从按下按钮到看到第一句回复，都在计时。"},
		"try.s1": {i18n.EN: "Scan and follow to sign in", i18n.ZhCN: "扫码关注即登录"},
		"try.s2": {i18n.EN: "Get a machine", i18n.ZhCN: "领一台机器"},
		"try.s3": {i18n.EN: "Say your first line", i18n.ZhCN: "说第一句话"},
		"try.go": {i18n.EN: "Start the trial", i18n.ZhCN: "开始试用"},
		"try.fine": {i18n.EN: "ClaudeFleet is open to a limited few for now. A trial is free, on a subscription we provide; one per account. Files made in a trial are not kept.",
			i18n.ZhCN: "ClaudeFleet 目前限定开放。试用免费，用我们提供的订阅；一个账号试一次。试用里生成的文件不保留。"},
		"try.tried": {i18n.EN: "You have already had your trial with this account. To keep using ClaudeFleet, apply — the answer usually comes within one working day.",
			i18n.ZhCN: "这个账号已经试用过了。想长期使用，就申请吧——通常 1 个工作日内答复。"},
		"try.applied": {i18n.EN: "You have already had your trial, and your application is in. See where it stands on your application page.",
			i18n.ZhCN: "这个账号已经试用过了，你的申请也已经交了。在「我的申请」里看进度。"},
		"try.apply":   {i18n.EN: "Apply to use it", i18n.ZhCN: "申请使用"},
		"try.see":     {i18n.EN: "See my application", i18n.ZhCN: "看我的申请"},
		"try.dayfull": {i18n.EN: "Today's trials are all taken. Come back tomorrow — or apply to use it now.", i18n.ZhCN: "今天的试用名额满了。明天再来，或者现在就申请使用。"},
		"try.r.full":  {i18n.EN: "Every trial seat is taken.", i18n.ZhCN: "试用名额都在用。"},
		"try.r.busy":  {i18n.EN: "The machines are busy right now.", i18n.ZhCN: "机器这会儿正忙。"},
		"try.r.load":  {i18n.EN: "The machines are under load right now.", i18n.ZhCN: "机器这会儿负载高。"},
		"try.r.quota": {i18n.EN: "The shared subscription is running low for now.", i18n.ZhCN: "共用的订阅额度这会儿偏紧。"},
		"try.r.byo":   {i18n.EN: "The trial now runs on your own subscription only, and you have not connected one yet.", i18n.ZhCN: "试用现在只用你自己的订阅，你还没有接上。"},
		"try.own":     {i18n.EN: "Connect my own subscription", i18n.ZhCN: "接上我自己的订阅"},
		"try.r.nosub": {i18n.EN: "The trial has no subscription to use right now.", i18n.ZhCN: "试用暂时没有可用订阅。"},
		"try.reach":   {i18n.EN: "Following 二四网络科技? We'll tell you on WeChat when it's your turn.", i18n.ZhCN: "关注了「二四网络科技」的，排到时微信通知你。"},

		"try.r.no_spare": {i18n.EN: "No ready machine is free right now.", i18n.ZhCN: "这会儿没有备好的空机器。"},
		"try.wait": {i18n.EN: "All machines are taken. {n} ahead of you — about {m}. Keep this page open to hold your place.",
			i18n.ZhCN: "机器都被领走了。前面还有 {n} 人，大约 {m}。开着这页就保住你的位置。"},
		"try.first": {i18n.EN: "You are next — a machine frees up in about {m}. Keep this page open.",
			i18n.ZhCN: "下一个就是你，大约 {m}后空出一台。开着这页就好。"},
		"try.opening": {i18n.EN: "Your machine is getting ready…", i18n.ZhCN: "你的机器正在准备……"},
		"try.busy":    {i18n.EN: "Many people are trying right now. Try again in a minute.", i18n.ZhCN: "试用的人太多了，过一分钟再试。"},
		"try.fail":    {i18n.EN: "That did not go through. Press the button again.", i18n.ZhCN: "没走通，再按一次按钮。"},
		"try.min":     {i18n.EN: "min", i18n.ZhCN: "分钟"},
		"try.paused": {i18n.EN: "Paused. Your machine went to someone else and was wiped clean; your conversation is kept apart — only you can get it back — until {until}. Trial time left: {left}.",
			i18n.ZhCN: "已暂停。机器已经让给别人了，上面你的东西已清干净。你的对话单独存着，只有你能取回，保存到 {until}；试用还剩 {left}。"},
		"try.resume":   {i18n.EN: "Continue", i18n.ZhCN: "继续"},
		"try.resuming": {i18n.EN: "Getting a clean machine and picking your conversation back up…", i18n.ZhCN: "正在换一台干净的机器，接上你的对话……"},
		"try.capped": {i18n.EN: "This trial is used up. Found it useful? Apply — once you're in, you go on in this same conversation.",
			i18n.ZhCN: "这次试用用完了。觉得有用？申请吧——通过后就在这段对话里接着用。"},
	} {
		pageText[k] = v
	}
}
