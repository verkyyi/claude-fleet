package api

import (
	"context"
	"crypto/hmac"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 扫码关注即试用 (claude-fleet MRGB): someone scans one of an admin's 试用二维码
// (trial_codes.go) and the trial starts — no request, no one to approve it.
// The service account's events reach only the company's workbench; a scan in
// the fleet-trial range (wxTrialSceneMin..Max) is handed to us at once
//
//	POST /internal/wx/trial-scan   x-internal-token: <CCQUOTA_WX_INTERNAL_TOKEN>
//	{"scene": "2800001", "openid": "…", "event": "subscribe" | "SCAN"}
//
// and what we answer — {"news": {title, description, picUrl, url}} or
// {"reply": "…"} — is the passive reply workbench sends (the space-sub road,
// monorepo Helper/FleetTrialNotify.js). WeChat waits five seconds for it and
// workbench two, so nothing here waits on a machine: the home opens behind the
// answer (placePrincipal), and the card it sends lands on the chat, where 「正在
// 准备」 shows until it is ready.
//
// The gate is the same token workbench holds and the hub already sends it
// (wxgw.go), compared in constant time; it never enters a log.
//
// One trial per WeChat, ever (fleet_trial_grants' key: wx:<unionid>, else
// mp:<openid>). A trial is the approval road (admitRequest + the code's
// limits), its request recorded approved by qr:<code>, so 申请 / 成员 / 转正 see
// it as any other. A code may be stopped, paused by the burst alarm, past its
// date or full; the day may be spent (fleet.qr.daily); the machines may be
// full — then the person waits in line and is told when it is their turn
// (RunTrialQueue). A code that needs approval files a pending request instead.

// WxTrialScanPath is workbench's door.
const WxTrialScanPath = "/internal/wx/trial-scan"

// The settings.
const (
	QRDailyKey = "fleet.qr.daily"
	QRBurstKey = "fleet.qr.burst"

	defaultQRDaily = 100
	defaultQRBurst = 30
	// qrBurstWindow is the burst alarm's window.
	qrBurstWindow = 10 * time.Minute
	// qrRescanGap: the same WeChat scanning the same code again inside it
	// is answered nothing — the first answer is on its screen.
	qrRescanGap = time.Minute
	// qrQueueTick is how often the line is looked at.
	qrQueueTick = 30 * time.Second
	// qrQueueMax: a place in line older than this is not served — WeChat
	// lets us message them for 48 hours after their scan.
	qrQueueMax = 47 * time.Hour
)

// What a scan was answered (fleet_trial_scans.outcome).
const (
	qrGranted = "granted"
	qrQueued  = "queued"
	qrPending = "pending"
	qrTried   = "tried"
	qrMember  = "member"
	qrOn      = "on" // their trial from a code is running
	qrStopped = "stopped"
	qrFull    = "full"
	qrExpired = "expired"
	qrDaily   = "daily"
	qrRefused = "refused"
	qrAgain   = "again"
)

func init() {
	hubSettings[QRDailyKey] = hubSetting{def: strconv.Itoa(defaultQRDaily),
		help:  "at most this many trials start from 试用二维码 a day (Beijing time); past it a scan is told to come back tomorrow (claude-fleet MRGB)",
		check: checkIntSetting(QRDailyKey, 0, 100000, defaultQRDaily)}
	hubSettings[QRBurstKey] = hubSetting{def: strconv.Itoa(defaultQRBurst),
		help:  "a 试用二维码 that starts more than this many trials in 10 minutes pauses itself and tells the admins (claude-fleet MRGB); 0 = no alarm",
		check: checkIntSetting(QRBurstKey, 0, 100000, defaultQRBurst)}
}

func (s *Server) qrDaily() int { return s.settingIntOr(QRDailyKey, defaultQRDaily, 0, 100000) }
func (s *Server) qrBurst() int { return s.settingIntOr(QRBurstKey, defaultQRBurst, 0, 100000) }

// wxNews is a card as workbench passes it on (FleetPoster's shape).
type wxNews struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	PicURL      string `json:"picUrl"`
	URL         string `json:"url"`
}

type trialScanAnswer struct {
	News  *wxNews `json:"news,omitempty"`
	Reply string  `json:"reply,omitempty"`
}

func (s *Server) handleWxTrialScan(w http.ResponseWriter, r *http.Request) {
	if s.Store == nil || !s.WxGW.ready() || r.URL.Path != WxTrialScanPath {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	got := r.Header.Get("x-internal-token")
	if got == "" || !hmac.Equal([]byte(got), []byte(strings.TrimSpace(s.WxGW.Token))) {
		httpError(w, http.StatusUnauthorized, "not workbench")
		return
	}
	var in struct {
		Scene  json.Number `json:"scene"`
		OpenID string      `json:"openid"`
		Event  string      `json:"event"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.UseNumber()
	if err := dec.Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, `want {"scene", "openid", "event"}`)
		return
	}
	scene, err := strconv.ParseInt(strings.TrimSpace(in.Scene.String()), 10, 64)
	if err != nil || !wxTrialSceneInRange(scene) {
		httpError(w, http.StatusBadRequest, "scene is not a trial code's")
		return
	}
	if !wxOpenidRE.MatchString(in.OpenID) {
		httpError(w, http.StatusBadRequest, "openid")
		return
	}
	event := "SCAN"
	if strings.EqualFold(in.Event, "subscribe") {
		event = "subscribe"
	}
	ctx, cancel := context.WithTimeout(r.Context(), 1500*time.Millisecond)
	defer cancel()
	writeJSON(w, http.StatusOK, s.trialScan(ctx, scene, in.OpenID, event, time.Now()))
}

// trialScan decides one scan and records it.
func (s *Server) trialScan(ctx context.Context, scene int64, openid, event string, now time.Time) trialScanAnswer {
	code, err := s.Store.TrialCodeByScene(scene)
	if err != nil {
		log.Printf("trial code: scene %d: %v", scene, err)
	}
	if code == nil {
		return trialScanAnswer{Reply: s.qrText("", qrStopped, nil)}
	}
	if n, err := s.Store.TrialScansSince(code.ID, openid, now.Add(-qrRescanGap)); err == nil && n > 0 {
		s.recordScan(code.ID, openid, event, qrAgain, now)
		return trialScanAnswer{}
	}
	u, err := s.WxGW.userInfo(ctx, openid)
	if err != nil {
		// WeChat is slow: they just scanned, so they follow; who they are
		// is the openid alone until the next scan.
		u = wxUser{OpenID: openid, Followed: true}
	}
	lang := wxLang(u.Language)
	outcome, ans := s.trialScanDecide(ctx, code, u, lang, now)
	s.recordScan(code.ID, openid, event, outcome, now)
	return ans
}

func (s *Server) recordScan(codeID, openid, event, outcome string, now time.Time) {
	id, err := randomToken(12)
	if err != nil {
		return
	}
	if err := s.Store.AddTrialScan(store.TrialScan{ID: "ts-" + id, CodeID: codeID, OpenID: openid,
		Event: event, Outcome: outcome, At: now}); err != nil {
		log.Printf("trial code %s: record scan: %v", codeID, err)
	}
}

// wxLang is the language a card is written in: Chinese for a Chinese
// WeChat (and an unknown one), English otherwise.
func wxLang(l string) string {
	l = strings.ToLower(strings.TrimSpace(l))
	if l == "" || strings.HasPrefix(l, "zh") {
		return "zh"
	}
	return "en"
}

// trialWho is a WeChat's one-trial key.
func trialWho(u wxUser) string {
	if u.UnionID != "" {
		return "wx:" + u.UnionID
	}
	return "mp:" + u.OpenID
}

func (s *Server) trialScanDecide(ctx context.Context, code *store.TrialCode, u wxUser, lang string, now time.Time) (string, trialScanAnswer) {
	text := func(outcome string) (string, trialScanAnswer) {
		return outcome, trialScanAnswer{Reply: s.qrText(lang, outcome, code)}
	}
	// A WeChat a code reached before: its one trial, wherever it stands.
	who := trialWho(u)
	g, err := s.Store.TrialGrantOf(who)
	if err == nil && g == nil && u.UnionID != "" {
		g, err = s.Store.TrialGrantOf("mp:" + u.OpenID) // reached before WeChat named the unionid
	}
	if err != nil {
		log.Printf("trial code %s: %v", code.ID, err)
		return text(qrRefused)
	}
	if g != nil {
		switch g.State {
		case store.GrantQueued:
			return qrQueued, s.queueAnswer(lang, g)
		case store.GrantPending:
			return text(qrPending)
		}
		return s.personAnswer(lang, g.Principal, now)
	}
	kind, subject, err := s.wxIdentity(u, now)
	if err != nil {
		log.Printf("trial code %s: identity: %v", code.ID, err)
		return text(qrRefused)
	}
	if pid, err := s.Store.IdentityPrincipal(kind, subject); err == nil && pid != "" {
		if role, _ := s.personRole(pid); role == roleUser || role == roleAdmin {
			return s.personAnswer(lang, pid, now) // on the list already
		}
	}
	switch {
	case code.State != store.TrialCodeLive:
		return text(qrStopped)
	case !code.Until.IsZero() && now.After(code.Until):
		return text(qrExpired)
	}
	if s.inCooldown(kind, subject, now) {
		return text(qrRefused) // turned down at /apply lately: not by a code either
	}
	if code.Approval {
		return s.trialScanApproval(code, u, kind, subject, lang, now)
	}
	if n, err := s.Store.TrialGrantedSince("", trialDayStart(now)); err == nil && n >= s.qrDaily() {
		return text(qrDaily)
	}
	hold := s.qrHold(now)
	g = &store.TrialGrant{Who: who, CodeID: code.ID, OpenID: u.OpenID, State: store.GrantQueued, Lang: lang, ScannedAt: now}
	ok, err := s.Store.ClaimTrialGrant(*g, code.Cap)
	switch {
	case errors.Is(err, store.ErrTrialCodeFull):
		return text(qrFull)
	case err != nil:
		log.Printf("trial code %s: claim: %v", code.ID, err)
		return text(qrRefused)
	case !ok:
		return text(qrTried) // the same WeChat, a moment ago, on another replica
	}
	if hold != "" {
		log.Printf("trial code %s: %s waits in line (%s)", code.ID, u.OpenID, hold)
		return qrQueued, s.queueAnswer(lang, g)
	}
	pid, err := s.trialAdmit(code, g, kind, subject, now)
	if err != nil {
		log.Printf("trial code %s: admit: %v — left in line", code.ID, err)
		return qrQueued, s.queueAnswer(lang, g)
	}
	s.trialBurstCheck(code, now)
	return qrGranted, trialScanAnswer{News: s.trialCard(lang, qrGranted, code, pid, now)}
}

// trialScanApproval files an approval code's scan as a pending request.
func (s *Server) trialScanApproval(code *store.TrialCode, u wxUser, kind, subject, lang string, now time.Time) (string, trialScanAnswer) {
	rid, err := randomToken(12)
	if err != nil {
		return qrRefused, trialScanAnswer{Reply: s.qrText(lang, qrRefused, code)}
	}
	req := store.AccessRequest{ID: "rq-" + rid, Kind: kind, Subject: subject, Display: wxDisplay(lang, u.OpenID),
		Use: qrUse(code), Referrer: trialReferrer(code.ID), NotifyChannel: store.NotifyWeChat, CreatedAt: now}
	rq := s.Store.Requests()
	got, err := rq.Create(req)
	var cool *store.CooldownError
	switch {
	case errors.As(err, &cool):
		return qrRefused, trialScanAnswer{Reply: s.qrText(lang, qrRefused, code)}
	case errors.Is(err, store.ErrRequestPending):
		return qrPending, trialScanAnswer{Reply: s.qrText(lang, qrPending, code)}
	case err != nil:
		log.Printf("trial code %s: request: %v", code.ID, err)
		return qrRefused, trialScanAnswer{Reply: s.qrText(lang, qrRefused, code)}
	}
	_ = rq.SetLang(got.ID, lang)
	if err := s.Store.SetHubReach(store.HubReach{Owner: store.ApplicantReachOwner(kind, subject), Channel: store.ReachWeChatMP,
		Addr: u.OpenID, Followed: true, UpdatedAt: now}); err != nil {
		log.Printf("trial code %s: reach: %v", code.ID, err)
	}
	if _, err := s.Store.ClaimTrialGrant(store.TrialGrant{Who: trialWho(u), CodeID: code.ID, OpenID: u.OpenID,
		State: store.GrantPending, Lang: lang, ScannedAt: now}, code.Cap); errors.Is(err, store.ErrTrialCodeFull) {
		return qrFull, trialScanAnswer{Reply: s.qrText(lang, qrFull, code)}
	}
	_ = s.Store.HubAudit("qr:"+code.ID, "request.submit", req.Display+" ("+kind+")", "ok", got.ID+" · 试用码 "+code.Channel, now)
	s.notifyAdmins(got)
	return qrPending, trialScanAnswer{Reply: s.qrText(lang, qrPending, code)}
}

// inCooldown: kind/subject's last request was turned down and its cooldown
// runs still.
func (s *Server) inCooldown(kind, subject string, now time.Time) bool {
	reqs, err := s.Store.Requests().ByIdentity(kind, subject)
	if err != nil {
		return false
	}
	for _, r := range reqs {
		if r.State == store.RequestRejected && now.Before(r.CooldownUntil) {
			return true
		}
	}
	return false
}

func trialReferrer(codeID string) string { return "qr:" + codeID }

// trialCodeOf is the code a request came in by, "" for none.
func trialCodeOf(req *store.AccessRequest) string {
	if strings.HasPrefix(req.Referrer, "qr:") {
		return strings.TrimPrefix(req.Referrer, "qr:")
	}
	return ""
}

func qrUse(code *store.TrialCode) string { return "扫试用码 · " + code.Channel }

func wxDisplay(lang, openid string) string {
	tail := openid[max(0, len(openid)-4):]
	if lang == "en" {
		return "WeChat user·" + tail
	}
	return "微信用户·" + tail
}

// qrHold is why a trial waits in line now ("" = go ahead): no subscription
// a trial may use, the pool below its floor, no machine fit to open a home.
func (s *Server) qrHold(now time.Time) string {
	if s.trialNoSub() {
		return trialWaitNoSub
	}
	if left, ok := trialPoolLeft(s); ok && left < float64(s.trialQuotaFloor()) {
		return trialWaitQuota
	}
	if s.Fleet && s.autoAssignOn() && len(s.autoAssign()) == 0 {
		return trialWaitBusy
	}
	return ""
}

// trialAdmit gives g's WeChat its trial: the approval road with the code's
// limits, the grant marked granted, their home opening behind the answer.
func (s *Server) trialAdmit(code *store.TrialCode, g *store.TrialGrant, kind, subject string, now time.Time) (string, error) {
	by := "qr:" + code.ID
	rid, err := randomToken(12)
	if err != nil {
		return "", err
	}
	rq := s.Store.Requests()
	req, err := rq.Create(store.AccessRequest{ID: "rq-" + rid, Kind: kind, Subject: subject, Display: wxDisplay(g.Lang, g.OpenID),
		Use: qrUse(code), Referrer: trialReferrer(code.ID), NotifyChannel: store.NotifyWeChat, CreatedAt: now})
	if errors.Is(err, store.ErrRequestPending) {
		// They had asked at /apply already: that request is the one decided.
		reqs, lerr := rq.ByIdentity(kind, subject)
		if lerr != nil {
			return "", lerr
		}
		req = nil
		for i := range reqs {
			if reqs[i].State == store.RequestPending {
				req = &reqs[i]
			}
		}
		if req == nil {
			return "", err
		}
	} else if err != nil {
		return "", err
	}
	_ = rq.SetLang(req.ID, g.Lang)
	got, err := rq.Decide(req.ID, store.RequestApproved, "", time.Time{}, by, now)
	if err != nil && !errors.Is(err, store.ErrRequestNotPending) {
		return "", err
	}
	if got != nil {
		req = got
	}
	target := req.Display + " (" + req.Kind + ")"
	_ = s.Store.HubAudit(by, "request.approve", target, "ok", req.ID+" · 试用码 "+code.Channel, now)
	pid, err := s.admitRequest(req, by, now)
	if err != nil {
		_ = s.Store.HubAudit(by, "user.add", target, "error", req.ID+": "+err.Error(), now)
		return "", err
	}
	if err := s.writeMemberLimits(pid, code.Terms, by, now); err != nil {
		return "", err
	}
	if _, err := s.Store.SetTrialGrant(g.Who, "", store.GrantGranted, pid, now); err != nil {
		return "", err
	}
	if err := s.Store.SetHubReach(store.HubReach{Owner: pid, Channel: store.ReachWeChatMP, Addr: g.OpenID,
		Followed: true, UpdatedAt: now}); err != nil {
		log.Printf("trial code %s: reach: %v", code.ID, err)
	}
	g.State, g.Principal, g.GrantedAt = store.GrantGranted, pid, now
	go s.placePrincipal(pid, req.Display, by)
	return pid, nil
}

// trialBurstCheck pauses code when it gave more than fleet.qr.burst trials in
// the last ten minutes, raises the alert and tells every admin — once a pause.
func (s *Server) trialBurstCheck(code *store.TrialCode, now time.Time) {
	limit := s.qrBurst()
	if limit <= 0 {
		return
	}
	n, err := s.Store.TrialGrantedSince(code.ID, now.Add(-qrBurstWindow))
	if err != nil || n <= limit {
		return
	}
	why := strconv.Itoa(n) + "/" + strconv.Itoa(limit) // read by burstWords
	changed, err := s.Store.SetTrialCodeState(code.ID, store.TrialCodePaused, why, now)
	if err != nil || !changed {
		return
	}
	log.Printf("trial code %s (%s) paused: %s", code.ID, code.Channel, why)
	_ = s.Store.HubAudit("hub", "trialcode.pause", code.Channel+" ("+code.ID+")", "ok", why, now)
	if _, err := s.Store.RaiseFleetAlert(store.AlertTrialCodeBurst, code.ID, `{"channel":`+strconv.Quote(code.Channel)+`,"trials":`+strconv.Itoa(n)+`}`, now); err != nil {
		log.Printf("trial code %s: alert: %v", code.ID, err)
	}
	s.notifyTrialBurst(code.ID, now)
}

// burstWords says a pause's why ("34/30": trials in 10 minutes / the alarm
// line) in words.
func burstWords(why string, en bool) string {
	n, limit, ok := strings.Cut(why, "/")
	if !ok {
		return why
	}
	if en {
		return n + " trials in 10 minutes, over the alarm line of " + limit
	}
	return "10 分钟内开通 " + n + " 人，超过告警线 " + limit
}

// personAnswer is the card for a WeChat that has its trial (or is on the
// list): go on, a member's console, or — the trial over — 申请转正.
func (s *Server) personAnswer(lang, pid string, now time.Time) (string, trialScanAnswer) {
	set, _ := s.Store.FleetSettings()
	l, limited := memberLimitsOf(set, pid)
	switch {
	case pid == "":
		return qrTried, trialScanAnswer{News: s.trialCard(lang, qrTried, nil, "", now)}
	case !limited:
		return qrMember, trialScanAnswer{News: s.trialCard(lang, qrMember, nil, pid, now)}
	case !l.Until.IsZero() && now.After(l.Until):
		return qrTried, trialScanAnswer{News: s.trialCard(lang, qrTried, nil, pid, now)}
	}
	return qrOn, trialScanAnswer{News: s.trialCard(lang, qrOn, nil, pid, now)}
}

// queueAnswer is a person in line's card: how many are ahead.
func (s *Server) queueAnswer(lang string, g *store.TrialGrant) trialScanAnswer {
	ahead := 0
	if q, err := s.Store.QueuedTrialGrants(); err == nil {
		for _, o := range q {
			if o.Who == g.Who {
				break
			}
			ahead++
		}
	}
	base := strings.TrimRight(s.FleetPublicURL, "/")
	n := &wxNews{PicURL: base + "/site/og/cover-" + lang + ".png", URL: base + "/"}
	if lang == "en" {
		n.Title = "ClaudeFleet trial · in line"
		n.Description = strconv.Itoa(ahead) + " ahead of you. The trials are all in use — no need to keep it open: we message you when it is your turn."
	} else {
		n.Title = "ClaudeFleet 试用 · 排队中"
		n.Description = "前面还有 " + strconv.Itoa(ahead) + " 位。试用名额正被用满，不用一直开着，轮到你我们发消息。"
	}
	return trialScanAnswer{News: n}
}

// trialCard is the card a scan is answered with.
func (s *Server) trialCard(lang, outcome string, code *store.TrialCode, pid string, now time.Time) *wxNews {
	base := strings.TrimRight(s.FleetPublicURL, "/")
	start := base + "/auth/wechat/start"
	n := &wxNews{PicURL: base + "/site/og/cover-" + lang + ".png", URL: start}
	en := lang == "en"
	days := "" // 「 · 7 天」: the trial's length in the card's title
	if code != nil {
		if t := s.codeTerms(code); !t.Off && t.Days > 0 {
			days = " · " + strconv.Itoa(t.Days) + ternary(en, " days", " 天")
		}
	}
	switch outcome {
	case qrGranted:
		if en {
			n.Title = "Your ClaudeFleet trial is on" + days
			n.Description = "Opens straight into the chat — no sign-in, no request."
		} else {
			n.Title = "ClaudeFleet 试用已开通" + days
			n.Description = "点开直接对话，不用登录、不用申请。"
		}
	case qrOn:
		if en {
			n.Title, n.Description = "Your ClaudeFleet trial is running", "Tap to go on where you left off."
		} else {
			n.Title, n.Description = "你的 ClaudeFleet 试用还在进行", "点开接着用。"
		}
	case qrMember:
		if en {
			n.Title, n.Description = "You are a ClaudeFleet member already", "Tap to open it."
		} else {
			n.Title, n.Description = "你已经是 ClaudeFleet 成员", "点开继续用。"
		}
	default: // qrTried
		if pid == "" {
			n.URL = base + ApplyPath // a WeChat the list does not name: ask at /apply
		}
		if en {
			n.Title, n.Description = "You have tried ClaudeFleet", "One trial per WeChat. Want to keep using it? Tap to ask to become a member — the answer comes here."
		} else {
			n.Title, n.Description = "你已经试用过 ClaudeFleet", "每个微信号试用一次。想继续用？点开申请转正，通过后结果推到这里。"
		}
	}
	return n
}

// codeTerms is the trial a code gives, its own or fleet.apply.trial.
func (s *Server) codeTerms(code *store.TrialCode) trialTerms {
	v := code.Terms
	if strings.TrimSpace(v) == "" {
		v = s.setting(ApplyTrialKey)
	}
	t, _ := parseTrialTerms(v)
	return t
}

// termsWords says a trial's terms: 「7 天 · 300 万 tokens · 同时 1 个会话」.
func termsWords(t trialTerms, en bool) string {
	if t.Off {
		return ""
	}
	var p []string
	if t.Days > 0 {
		p = append(p, strconv.Itoa(t.Days)+ternary(en, " days", " 天"))
	}
	if t.Tokens > 0 {
		if en {
			p = append(p, strconv.FormatFloat(float64(t.Tokens)/1e6, 'f', -1, 64)+"M tokens")
		} else {
			p = append(p, strconv.FormatFloat(float64(t.Tokens)/1e4, 'f', -1, 64)+" 万 tokens")
		}
	}
	if t.Sessions > 0 {
		p = append(p, ternary(en, strconv.Itoa(t.Sessions)+" at a time", "同时 "+strconv.Itoa(t.Sessions)+" 个会话"))
	}
	return strings.Join(p, " · ")
}

// qrText is a scan's answer in words, for the outcomes with no card.
func (s *Server) qrText(lang, outcome string, code *store.TrialCode) string {
	en := lang == "en"
	apply := strings.TrimRight(s.FleetPublicURL, "/") + ApplyPath
	switch outcome {
	case qrStopped:
		return ternary(en, "This trial code has stopped. To use ClaudeFleet, ask here — the answer comes to this chat: "+apply,
			"这张试用码已停用。想用 ClaudeFleet 可以点下面申请，结果会推到这里："+apply)
	case qrExpired:
		return ternary(en, "This trial code has expired. To use ClaudeFleet, ask here — the answer comes to this chat: "+apply,
			"这张试用码已过期。想用 ClaudeFleet 可以点下面申请，结果会推到这里："+apply)
	case qrFull:
		return ternary(en, "This trial code has given every trial it had. To use ClaudeFleet, ask here — the answer comes to this chat: "+apply,
			"这张试用码的名额已经发完了。想用 ClaudeFleet 可以点下面申请，结果会推到这里："+apply)
	case qrDaily:
		return ternary(en, "Today's trials are all given out. Scan again tomorrow.",
			"今天的试用名额发完了，明天再扫一次就好。")
	case qrPending:
		return ternary(en, "Got it — your request to try ClaudeFleet is with us. The answer comes to this chat.",
			"收到，你的 ClaudeFleet 试用申请已提交，结果会推到这里。")
	}
	return ternary(en, "ClaudeFleet cannot start a trial for you right now. You can ask here — the answer comes to this chat: "+apply,
		"ClaudeFleet 暂时不能为你开通试用。可以点下面申请，结果会推到这里："+apply)
}

// RunTrialQueue serves the line: every qrQueueTick, while nothing holds,
// the first in line gets their trial and a card saying so.
func (s *Server) RunTrialQueue(ctx context.Context) {
	if s.Store == nil {
		return
	}
	t := time.NewTicker(qrQueueTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.trialQueuePass(ctx, time.Now())
		}
	}
}

func (s *Server) trialQueuePass(ctx context.Context, now time.Time) {
	q, err := s.Store.QueuedTrialGrants()
	if err != nil || len(q) == 0 {
		return
	}
	for i := range q {
		g := &q[i]
		if now.Sub(g.ScannedAt) > qrQueueMax {
			continue
		}
		if s.qrHold(now) != "" {
			return
		}
		if n, err := s.Store.TrialGrantedSince("", trialDayStart(now)); err != nil || n >= s.qrDaily() {
			return
		}
		code, err := s.Store.TrialCode(g.CodeID)
		if err != nil || code == nil {
			continue
		}
		u, err := s.WxGW.userInfo(ctx, g.OpenID)
		if err != nil {
			u = wxUser{OpenID: g.OpenID, Followed: true}
		}
		kind, subject, err := s.wxIdentity(u, now)
		if err != nil {
			continue
		}
		// the claim: one replica serves each place in line
		if ok, err := s.Store.SetTrialGrant(g.Who, store.GrantQueued, store.GrantGranted, "", now); err != nil || !ok {
			continue
		}
		pid, err := s.trialAdmit(code, g, kind, subject, now)
		if err != nil {
			log.Printf("trial code %s: line: %v", code.ID, err)
			_, _ = s.Store.SetTrialGrant(g.Who, store.GrantGranted, store.GrantQueued, "", now)
			continue
		}
		card := s.trialCard(g.Lang, qrGranted, code, pid, now)
		if g.Lang == "en" {
			card.Title, card.Description = "Your turn — your ClaudeFleet trial is on", "Opens straight into the chat."
		} else {
			card.Title, card.Description = "轮到你了 · ClaudeFleet 试用已开通", "点开直接对话。"
		}
		if err := s.WxGW.customNews(ctx, g.OpenID, wxArticle{Title: card.Title, Description: card.Description,
			URL: card.URL, PicURL: card.PicURL}); err != nil {
			log.Printf("trial code %s: tell %s it is their turn: %s", code.ID, pid, wxWhy(wxCode(err)))
		}
		s.trialBurstCheck(code, now)
	}
}

// trialFirstLine records a trial person's first line in the chat (the
// 60-second metric's end).
func (s *Server) trialFirstLine(person string, now time.Time) {
	if s.Store == nil || !isPerson(person) {
		return
	}
	if _, err := s.Store.MarkTrialFirstLine(person, now); err != nil {
		log.Printf("trial code: first line of %s: %v", person, err)
	}
}

// trialApproved is an admin approving an approval code's request: the code's
// terms are the limits, and the WeChat's grant is granted.
func (s *Server) trialApproved(req *store.AccessRequest, pid string, now time.Time) {
	if trialCodeOf(req) == "" {
		return
	}
	g, err := s.Store.TrialGrantByOpenID(req.Subject)
	if err != nil || g == nil {
		if req.Kind == store.IdentityWeChat {
			g, err = s.Store.TrialGrantOf("wx:" + req.Subject)
		}
		if err != nil || g == nil {
			return
		}
	}
	if _, err := s.Store.SetTrialGrant(g.Who, store.GrantPending, store.GrantGranted, pid, now); err != nil {
		log.Printf("trial code %s: approved %s: %v", g.CodeID, pid, err)
	}
}

// trialTermsOf is the limits an approval writes for req when the admin named
// none: its code's terms ("" = fleet.apply.trial).
func (s *Server) trialTermsOf(req *store.AccessRequest) string {
	id := trialCodeOf(req)
	if id == "" {
		return ""
	}
	code, err := s.Store.TrialCode(id)
	if err != nil || code == nil {
		return ""
	}
	return code.Terms
}

// notifyTrialBurst tells every admin code paused itself at now.
func (s *Server) notifyTrialBurst(codeID string, now time.Time) {
	users, err := s.Store.HubUsers()
	if err != nil {
		log.Printf("notify admins of trial code %s: %v", codeID, err)
		return
	}
	set, _ := s.Store.FleetSettings()
	for _, u := range users {
		if u.Role != roleAdmin {
			continue
		}
		to := Recipient{Owner: u.PrincipalID, Lang: parseLang(set[langSettingKey(u.PrincipalID)])}
		if err := s.Tell(context.Background(), to, store.NotifyKindQRBurst, Fields{Code: codeID, At: now}); err != nil {
			log.Printf("notify %s of trial code %s: %v", u.PrincipalID, codeID, err)
		}
	}
}
