package api

import (
	"encoding/json"
	"html/template"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The 60-second trial (claude-fleet#3590, EPIC #3569 C20): a person from the
// website presses 「60 秒试用」, signs in, is handed a spare login — or, with
// none free, waits in line and is told roughly how long — and says their first
// line in the browser conversation; the page stops the clock at the first
// reply and tells them 「你用了 0:47」. It only strings together what exists:
//
//   - Who may come in: a trial invite. POST TryStartPath mints a one-use
//     invite (created_by trialInviter, 10 minutes) into the invite cookie, so
//     the sign-in — GitHub, WeChat, mail — admits a stranger through the very
//     road an admin's invite takes (admitInviteAs), which records them here
//     (store.StartTrial) as waiting.
//   - The login: never opened for them at the sign-in (placePrincipal leaves a
//     trial person alone). POST TryClaimPath is the one place they are placed:
//     the first in line, by waiting_since, takes a ready spare
//     (claimSpares, EPIC #3500) on the machine placement picks; everyone else
//     is told their place and an ETA. A person who walked away from the page
//     (not seen for trialFresh) holds no one up.
//   - The conversation: /app, the console's chat (claude-fleet#3567). The
//     clock lives in the browser (sessionStorage), from the press on the site
//     (performance.timeOrigin of /app/try?go=1) to the first text of the first
//     reply; POST TryTimingPath keeps it once per person, anonymously — the
//     table holds when and how long, never who. GET TryStatsPath (admin) is
//     the p50 / p90.
//   - Seven days unused (trialIdle, last_seen: the trial page and every chat
//     call), their login goes back through the operator's remove — a
//     recycling machine washes it into a spare (claude-fleet#3504).
//
// fleet.trial is off by default: /app/try opens the console as before
// (TestTryOffIsTheOldRedirect), the three routes 404, nothing is recorded.

const (
	// TrialKey turns the trial road on.
	TrialKey = "fleet.trial"

	TryPagePath   = AppPrefix + "/try"
	tryScriptPath = AppPrefix + "/try.js"
	TryStartPath  = "/v1/try/start"
	TryClaimPath  = "/v1/try/claim"
	TryTimingPath = "/v1/try/timing"
	TryStatsPath  = "/v1/fleet/try/stats"

	// trialInviter is the created_by of a trial invite: no person made it.
	trialInviter = "trial"
	// tryHeader is what the page's own fetches carry: a header a cross-site
	// form cannot set.
	tryHeader = "X-Fleet-Try"
)

var (
	// trialIdle is how long a trial login may go unused before it is reclaimed.
	trialIdle = 7 * 24 * time.Hour
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

// trialPerson says whether pid came in through the trial road.
func (s *Server) trialPerson(pid string) bool {
	if s.Store == nil || pid == "" {
		return false
	}
	t, err := s.Store.Trial(pid)
	return err == nil && t != nil
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
	State    string `json:"state"`              // ready · opening · waiting · member · off
	Next     string `json:"next,omitempty"`     // where to go now
	Position int    `json:"position,omitempty"` // people ahead in line
	ETASecs  int    `json:"eta_secs,omitempty"` // roughly how long until a seat
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
	now := time.Now()
	if !trialStarts.take(now) {
		refuseJSON(w, http.StatusTooManyRequests, "busy", "试用的人太多了，过一分钟再试")
		return
	}
	code, err := randomToken(24)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	id, err := randomToken(6)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.Store.CreateInvite(store.Invite{ID: "try-" + id, CodeHash: inviteHash(code),
		CreatedBy: trialInviter, CreatedAt: now, ExpiresAt: now.Add(inviteCookieTTL)}); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.setInviteCookie(w, r, code)
	http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: TryPagePath, Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r), MaxAge: int(loginCookieTTL.Seconds())})
	writeJSON(w, http.StatusOK, tryAnswer{State: "signin", Next: AppPrefix + "/signin"})
}

// trialAdmitted records a person a trial invite just let in.
func (s *Server) trialAdmitted(pid string, inv *store.Invite, now time.Time) {
	if inv == nil || inv.CreatedBy != trialInviter {
		return
	}
	if err := s.Store.StartTrial(pid, now); err != nil {
		log.Printf("fleet: trial of %s: %v", pid, err)
	}
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
	a, err := s.tryClaim(pid, name, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

// tryClaim is the claim at now.
func (s *Server) tryClaim(pid, name string, now time.Time) (tryAnswer, error) {
	t, err := s.Store.Trial(pid)
	if err != nil {
		return tryAnswer{}, err
	}
	if t == nil {
		// Already a member: the console is theirs.
		return tryAnswer{State: "member", Next: AppPrefix}, nil
	}
	if err := s.Store.TouchTrial(pid, now); err != nil {
		return tryAnswer{}, err
	}
	if t.State == store.TrialReclaimed {
		// Back after the 7 days: to the end of the line.
		if err := s.Store.RejoinTrial(pid, now); err != nil {
			return tryAnswer{}, err
		}
		if t, err = s.Store.Trial(pid); err != nil || t == nil {
			return tryAnswer{}, err
		}
	}
	if t.State == store.TrialPlaced {
		return s.tryHome(pid, now)
	}
	ahead, err := s.Store.TrialsAhead(t, now.Add(-trialFresh))
	if err != nil {
		return tryAnswer{}, err
	}
	host := s.leastBusyMachine(now, s.drillComputer(pid)...)
	if ahead == 0 && host != "" {
		if claimed := s.claimSpares(pid, name, pid, []string{host}, now); len(claimed) > 0 {
			if err := s.Store.PlaceTrial(pid, claimed[0], now); err != nil {
				return tryAnswer{}, err
			}
			_ = s.Store.HubAudit(pid, "trial", pid, "ok", "试用领到备用登录 · trial seat on "+claimed[0], now)
			return s.tryHome(pid, now)
		}
	}
	return tryAnswer{State: "waiting", Position: ahead, ETASecs: s.trialETA(host, ahead)}, nil
}

// tryHome: placed — ready once their home is set, which needs the login live.
func (s *Server) tryHome(pid string, now time.Time) (tryAnswer, error) {
	if _, ok, err := s.Store.EntryHomeOf(pid); err != nil {
		return tryAnswer{}, err
	} else if ok {
		return tryAnswer{State: "ready", Next: AppPrefix}, nil
	}
	choices, err := s.entryHomeChoices(pid, now)
	if err != nil {
		return tryAnswer{}, err
	}
	if h, err := s.entryEnsureHome(pid, choices, now); err != nil {
		return tryAnswer{}, err
	} else if h != nil {
		return tryAnswer{State: "ready", Next: AppPrefix}, nil
	}
	return tryAnswer{State: "opening"}, nil
}

// trialETA is roughly how long the person ahead-th in line waits: a seat
// frees when the pool refills, which opens spare_max logins at a time, each
// as long as an opening takes on host.
func (s *Server) trialETA(host string, ahead int) int {
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

// SweepTrials gives back every trial login unused for trialIdle: the
// operator's remove on each of the person's logins (recycled into a spare
// where the machine recycles), then the trial is marked reclaimed. It runs
// whatever fleet.trial says now — a login handed out while it was on still
// goes back.
func (s *Server) SweepTrials(now time.Time) {
	if s.Store == nil {
		return
	}
	idle, err := s.Store.IdleTrials(now.Add(-trialIdle))
	if err != nil {
		log.Printf("fleet: trial sweep: %v", err)
		return
	}
	sent := false
	for _, t := range idle {
		as, err := s.Store.FleetAccounts(t.Principal)
		if err != nil {
			log.Printf("fleet: trial sweep: accounts of %s: %v", t.Principal, err)
			continue
		}
		ok := true
		for _, a := range as {
			if a.State != store.AccountActive || !a.Managed() {
				continue
			}
			if err := s.changeAccount(FleetAccountRequest{Action: "remove", PrincipalID: t.Principal, Hostname: a.Hostname}, trialInviter); err != nil {
				log.Printf("fleet: trial sweep: remove %s on %s: %v", t.Principal, a.Hostname, err)
				ok = false
				continue
			}
			sent = true
		}
		if !ok {
			continue
		}
		if err := s.Store.ReclaimTrial(t.Principal, now); err != nil {
			log.Printf("fleet: trial sweep: %s: %v", t.Principal, err)
			continue
		}
		_ = s.Store.HubAudit(trialInviter, "trial", t.Principal, "ok",
			"试用 7 天没用，登录收回 · trial login reclaimed after "+trialIdle.String()+" unused", now)
		log.Printf("fleet: trial of %s unused since %s — login given back", t.Principal, t.LastSeen.Format(time.RFC3339))
	}
	if sent {
		s.dispatchAccounts()
	}
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
 data-w-busy="{{t "try.busy"}}" data-w-fail="{{t "try.fail"}}" data-w-min="{{t "try.min"}}">
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
    if (main.getAttribute("data-in") === "1") { claim(); return; }
    step(1);
    fetch("` + TryStartPath + `", { method: "POST", headers: H, credentials: "same-origin" })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (x) {
        if (x.ok && x.j.next) { location.assign(x.j.next); return; }
        say(x.j.code === "busy" ? w("busy") : w("fail")); go.disabled = false;
      })
      .catch(function () { say(w("fail")); go.disabled = false; });
  };
  var claim = function () {
    step(2);
    fetch("` + TryClaimPath + `", { method: "POST", headers: H, credentials: "same-origin" })
      .then(function (r) { if (r.redirected || !r.ok) throw r; return r.json(); })
      .then(function (j) {
        if (j.state === "ready" || j.state === "member") { step(3); location.assign(j.next || "/app"); return; }
        if (j.state === "opening") { say(w("opening")); setTimeout(claim, 3000); return; }
        var mins = Math.max(1, Math.round((j.eta_secs || 60) / 60));
        say((j.position ? w("wait").replace("{n}", j.position) : w("first")).replace("{m}", mins + " " + w("min")));
        setTimeout(claim, 10000);
      })
      .catch(function () { say(w("fail")); go.disabled = false; });
  };
  go.addEventListener("click", start);
  setInterval(tick, 250);
  if (main.getAttribute("data-in") === "1") { if (t0) start(); else step(2); }
  else if (new URLSearchParams(location.search).get("go") === "1") start();
  else step(1);
})();
`

func init() {
	for k, v := range map[string]i18n.Text{
		"try.title": {i18n.EN: "Try it in 60 seconds · ClaudeFleet", i18n.ZhCN: "60 秒试用 · ClaudeFleet"},
		"try.h1":    {i18n.EN: "Try it in 60 seconds", i18n.ZhCN: "60 秒试用"},
		"try.lead": {i18n.EN: "Sign in, get a machine, say your first line. The clock runs from the press to the first reply.",
			i18n.ZhCN: "登录、领一台机器、说第一句话。从按下按钮到看到第一句回复，都在计时。"},
		"try.s1": {i18n.EN: "Sign in", i18n.ZhCN: "登录"},
		"try.s2": {i18n.EN: "Get a machine", i18n.ZhCN: "领一台机器"},
		"try.s3": {i18n.EN: "Say your first line", i18n.ZhCN: "说第一句话"},
		"try.go": {i18n.EN: "Start the 60-second trial", i18n.ZhCN: "开始 60 秒试用"},
		"try.fine": {i18n.EN: "Free while you try, on a subscription we provide. Unused for 7 days, the machine goes back.",
			i18n.ZhCN: "试用期间用我们提供的订阅。7 天没用，机器会收回。"},
		"try.wait": {i18n.EN: "All machines are taken. {n} ahead of you — about {m}. Keep this page open to hold your place.",
			i18n.ZhCN: "机器都被领走了。前面还有 {n} 人，大约 {m}。开着这页就保住你的位置。"},
		"try.first": {i18n.EN: "You are next — a machine frees up in about {m}. Keep this page open.",
			i18n.ZhCN: "下一个就是你，大约 {m}后空出一台。开着这页就好。"},
		"try.opening": {i18n.EN: "Your machine is getting ready…", i18n.ZhCN: "你的机器正在准备……"},
		"try.busy":    {i18n.EN: "Many people are trying right now. Try again in a minute.", i18n.ZhCN: "试用的人太多了，过一分钟再试。"},
		"try.fail":    {i18n.EN: "That did not go through. Press the button again.", i18n.ZhCN: "没走通，再按一次按钮。"},
		"try.min":     {i18n.EN: "min", i18n.ZhCN: "分钟"},
	} {
		pageText[k] = v
	}
}
