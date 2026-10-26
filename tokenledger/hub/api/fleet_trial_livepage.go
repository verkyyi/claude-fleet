package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 试用网页直接在微信打开 (task XA4R, fleet's half; 活页's half is HBXZ). A
// trial person's web pages go to their own 活页 (LivePage) account — the same
// service account 「二四网络科技」 knows them by — opened FOR them the first
// time their session publishes, never before (no empty accounts):
//
//   - the session talks to `space` through this machine's credential proxy
//     (bin/mcp-space.py → 127.0.0.1:<port>/space/mcp); the proxy asks THIS
//     endpoint, with the login's node token, for the person's workspace key
//     and puts it on the request — the key never enters the session;
//   - the first ask provisions: POST <活页>/internal/partner/provision
//     with the person's service-account openid and the trial terms version
//     they agreed to; the key comes back sealed into hub_partner_creds;
//   - the trial ending (spent, its until passed, 转正, removed) revokes it
//     here at once and tells 活页 (POST /internal/partner/revoke), retried by
//     the sweep until it was told; the pages stay theirs, 活页 keeps them 30
//     days.
//
// fleet.trial.livepage = off (the default) | on. Off — or no partner
// configured (CCQUOTA_LIVEPAGE_PARTNER_URL + _KEY / _KEY_FILE: 活页's base URL and
// its partner-provision-token) — and the endpoint answers
// 403 off, nothing is provisioned, and a trial's chat is as before (its card
// says 「这台机器还没连活页」). Revoking never waits for the switch: a key handed
// out while it was on still goes when the trial ends.

// TrialLivePageKey is the switch.
const TrialLivePageKey = "fleet.trial.livepage"

// LivePageTokenNodePath is the proxy's ask: GET = may this login's person
// have one (no key in the answer), POST = the key (provisioned the first time).
const LivePageTokenNodePath = "/v1/node/livepage-token"

// livePageTermsVersion is the trial terms that say 「会用你的微信为你开活页账号」
// (site/legal/trial.*.md); sent with the provision as what they agreed to.
const livePageTermsVersion = "claudefleet-trial-terms-2026-10-21"

// livePageSource is how 活页 marks the accounts it opens for a trial.
const livePageSource = "claudefleet-trial"

// livePageDefaultDays is a key's life when the trial carries no end of its
// own (a 60-second trial: it ends by its budget, and the sweep revokes then).
const livePageDefaultDays = 7

// livePagePurpose seals the key to its person (credvault SealPerson).
const livePagePurpose = "livepage-key"

// The revoke reasons 活页 is told.
const (
	livePageExpired   = "expired"
	livePageConverted = "converted"
	livePageErase     = "erase"
)

func checkTrialLivePage(_ *Server, v string) (string, string) {
	v = strings.ToLower(strings.TrimSpace(v))
	if v == "off" || v == "on" {
		return v, ""
	}
	return "", TrialLivePageKey + ` is off | on, or "" for the default (off)`
}

// LivePagePartner is 活页's partner door (HBXZ): provision and revoke, under
// its base URL. Key is 活页's partner-provision-token (a Secret, never the
// hub's own), sent as X-Partner-Token; nothing the door answers is logged as is.
type LivePagePartner struct {
	URL  string
	Key  string
	HTTP *http.Client
}

func (p *LivePagePartner) ready() bool {
	return p != nil && strings.TrimSpace(p.URL) != "" && strings.TrimSpace(p.Key) != ""
}

func (p *LivePagePartner) client() *http.Client {
	if p.HTTP != nil {
		return p.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

// livePageProvision is the provision's body (HBXZ's contract).
type livePageProvision struct {
	OpenID       string `json:"openid"`
	UnionID      string `json:"unionid,omitempty"`
	Nickname     string `json:"nickname,omitempty"`
	Source       string `json:"source"`
	ConsentTerms string `json:"consent_terms"`
	ConsentAt    string `json:"consent_at"`
	Until        string `json:"until"`
	// EmbedOrigins joins the workspace's embed allowlist: the entry, so the
	// conversation's card can preview the page in place.
	EmbedOrigins []string `json:"embed_origins,omitempty"`
}

// errPartnerRefused: the door answered and said no (a closed account) —
// worth no quick retry, unlike a door that is down.
var errPartnerRefused = errors.New("refused")

func (p *LivePagePartner) post(ctx context.Context, path string, body, out any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(p.URL, "/")+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("X-Partner-Token", p.Key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client().Do(req)
	if err != nil {
		return fmt.Errorf("%s unreachable", path)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		if out != nil && json.Unmarshal(raw, out) != nil {
			return fmt.Errorf("%s: an answer that is not JSON", path)
		}
		return nil
	case resp.StatusCode == http.StatusNotFound && out == nil:
		return nil // a revoke of what 活页 no longer has: done
	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		var e struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(raw, &e)
		return fmt.Errorf("%w: %s HTTP %d %s", errPartnerRefused, path, resp.StatusCode, clipRunes(e.Code, 40))
	}
	return fmt.Errorf("%s HTTP %d", path, resp.StatusCode)
}

// Provision opens (or finds) the account and issues a key (a second call
// revokes the last key and issues a new one); created says the account was
// opened now. 409 account_inactive (closing) is a refusal.
func (p *LivePagePartner) Provision(ctx context.Context, in livePageProvision) (token string, created bool, err error) {
	var out struct {
		User struct {
			IsNew bool `json:"is_new"`
		} `json:"user"`
		Token struct {
			Plain string `json:"plain"`
		} `json:"token"`
	}
	if err := p.post(ctx, "/internal/partner/provision", in, &out); err != nil {
		return "", false, err
	}
	if strings.TrimSpace(out.Token.Plain) == "" {
		return "", false, errors.New("/internal/partner/provision: no token in the answer")
	}
	return out.Token.Plain, out.User.IsNew, nil
}

// Revoke tells 活页 the key is over; erase also closes the account the trial
// opened (deregister) — their pages are otherwise kept, and 活页 closes an
// account nobody converted or signed into after 30 days by itself.
func (p *LivePagePartner) Revoke(ctx context.Context, openid, reason string) error {
	return p.post(ctx, "/internal/partner/revoke", map[string]any{"openid": openid, "source": livePageSource,
		"deregister": reason == livePageErase}, nil)
}

// livePageOn: the switch is on and the door configured.
func (s *Server) livePageOn() bool {
	v, why := checkTrialLivePage(s, s.setting(TrialLivePageKey))
	return why == "" && v == "on" && s.LivePage.ready()
}

// livePageOpenID is pid's service-account openid ("" for none).
func (s *Server) livePageOpenID(pid string) string {
	rs, err := s.Store.HubReachOf(pid)
	if err != nil {
		return ""
	}
	for _, r := range rs {
		if r.Channel == store.ReachWeChatMP && r.Addr != "" {
			return r.Addr
		}
	}
	return ""
}

// livePageUnionID is pid's WeChat unionid ("" for none).
func (s *Server) livePageUnionID(pid string) string {
	ids, err := s.Store.HubIdentities(pid)
	if err != nil {
		return ""
	}
	for _, i := range ids {
		if i.Kind == store.IdentityWeChat {
			return i.Subject
		}
	}
	return ""
}

// livePageEnd is why pid's key must not live at now ("" = it may): the
// trial is over — spent (time · msgs) or its until passed: expired — or pid
// is no trial at all any more (转正, or never one): converted.
func (s *Server) livePageEnd(settings map[string]string, pid string, now time.Time) string {
	if t, err := s.Store.Trial(pid); err == nil && t != nil && t.State == store.TrialReclaimed &&
		(t.EndedReason == trialEndTime || t.EndedReason == trialEndMsgs) {
		return livePageExpired
	}
	if l, ok := memberLimitsOf(settings, pid); ok && !l.Until.IsZero() && !now.Before(l.Until) {
		return livePageExpired
	}
	if !s.trialIdentity(settings, pid) {
		return livePageConverted
	}
	return ""
}

// livePageUntil is how long a key opened at now lives: the trial's own end,
// else livePageDefaultDays.
func livePageUntil(settings map[string]string, pid string, now time.Time) time.Time {
	if l, ok := memberLimitsOf(settings, pid); ok && !l.Until.IsZero() {
		return l.Until
	}
	return now.Add(livePageDefaultDays * 24 * time.Hour)
}

// livePageEntryOrigin is the entry's https origin ("" for none).
func livePageEntryOrigin(public string) string {
	u, err := url.Parse(strings.TrimSpace(public))
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return ""
	}
	return "https://" + u.Host
}

// livePageBackoff is how long a failed provision waits before the next ask.
func livePageBackoff(fails int) time.Duration {
	d := 30 * time.Second
	for i := 1; i < fails && d < 10*time.Minute; i++ {
		d *= 2
	}
	if d > 10*time.Minute {
		d = 10 * time.Minute
	}
	return d
}

// livePageLocks makes one provision per person at a time.
var livePageLocks sync.Map // pid → *sync.Mutex

func livePageLock(pid string) *sync.Mutex {
	m, _ := livePageLocks.LoadOrStore(pid, &sync.Mutex{})
	return m.(*sync.Mutex)
}

// livePageAnswer is LivePageTokenNodePath's answer. Token only on a POST.
type livePageAnswer struct {
	Eligible   bool   `json:"eligible"`
	Ready      bool   `json:"ready"`
	Token      string `json:"token,omitempty"`
	Until      string `json:"until,omitempty"`
	New        bool   `json:"new,omitempty"`
	Code       string `json:"code,omitempty"`
	Message    string `json:"message,omitempty"`
	RetryAfter int    `json:"retry_after,omitempty"`
}

var livePageWords = map[string]string{
	"off":       "活页 is not switched on for trials here (fleet.trial.livepage)",
	"not_trial": "this login's person is not on a trial: they connect 活页 themselves",
	"ended":     "the trial is over: its 活页 key was taken back",
	"no_wechat": "no service-account WeChat on record for this person",
	"failed":    "活页 could not open the account yet; asked again shortly",
	"vault":     "the hub has no vault to keep the key in",
}

func livePageRefuse(w http.ResponseWriter, status int, code string, retry int) {
	writeJSON(w, status, livePageAnswer{Code: code, Message: livePageWords[code], RetryAfter: retry})
}

// handleNodeLivePageToken serves LivePageTokenNodePath.
func (s *Server) handleNodeLivePageToken(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	if !s.livePageOn() {
		livePageRefuse(w, http.StatusForbidden, "off", 0)
		return
	}
	host, user := s.nodeIdentity(ep)
	pid, err := s.principalOnNode(ep.ID, host, user)
	if err != nil {
		livePageRefuse(w, http.StatusForbidden, "not_trial", 0)
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	switch s.livePageEnd(settings, pid, now) {
	case livePageExpired:
		livePageRefuse(w, http.StatusForbidden, "ended", 0)
		return
	case livePageConverted:
		livePageRefuse(w, http.StatusForbidden, "not_trial", 0)
		return
	}
	openid := s.livePageOpenID(pid)
	if openid == "" {
		livePageRefuse(w, http.StatusForbidden, "no_wechat", 0)
		return
	}
	c, err := s.Store.PartnerCred(pid, store.PartnerLivePage)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, livePageAnswer{Eligible: true, Ready: c.Live(now)})
		return
	}
	if s.Vault == nil {
		livePageRefuse(w, http.StatusServiceUnavailable, "vault", 0)
		return
	}
	mu := livePageLock(pid)
	mu.Lock()
	defer mu.Unlock()
	if c, err = s.Store.PartnerCred(pid, store.PartnerLivePage); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if c.Live(now) {
		var tok string
		if err := s.Vault.OpenPerson(c.Sealed, &tok, pid, livePagePurpose); err == nil && tok != "" {
			writeJSON(w, http.StatusOK, livePageAnswer{Eligible: true, Ready: true, Token: tok, Until: c.Until.UTC().Format(time.RFC3339)})
			return
		}
		log.Printf("fleet: livepage: the kept key of %s does not open — provisioning again", pid)
	}
	if c != nil && c.FailCount > 0 && c.CreatedAt.Before(c.FailAt) {
		if wait := c.FailAt.Add(livePageBackoff(c.FailCount)).Sub(now); wait > 0 {
			livePageRefuse(w, http.StatusServiceUnavailable, "failed", int(wait/time.Second)+1)
			return
		}
	}
	until := livePageUntil(settings, pid, now)
	at := now
	if t, err := s.Store.Trial(pid); err == nil && t != nil && !t.StartedAt.IsZero() {
		at = t.StartedAt
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	in := livePageProvision{
		OpenID: openid, UnionID: s.livePageUnionID(pid), Source: livePageSource,
		ConsentTerms: livePageTermsVersion, ConsentAt: at.UTC().Format(time.RFC3339), Until: until.UTC().Format(time.RFC3339),
	}
	if o := livePageEntryOrigin(s.FleetPublicURL); o != "" {
		in.EmbedOrigins = []string{o}
	}
	if s.PortalURL != "" {
		in.EmbedOrigins = []string{s.PortalURL}
		if s.WeChatPublicURL != "" {
			in.EmbedOrigins = append(in.EmbedOrigins, s.WeChatPublicURL)
		}
	}
	tok, created, err := s.LivePage.Provision(ctx, in)
	if err != nil {
		why := clipRunes(err.Error(), 120)
		if ferr := s.Store.PartnerCredFailed(pid, store.PartnerLivePage, why, now); ferr != nil {
			log.Printf("fleet: livepage: %s: %v", pid, ferr)
		}
		_ = s.Store.HubAudit(trialInviter, "livepage.provision", pid, "failed", why, now)
		fails := 1
		if c != nil && c.CreatedAt.Before(c.FailAt) {
			fails = c.FailCount + 1
		}
		livePageRefuse(w, http.StatusServiceUnavailable, "failed", int(livePageBackoff(fails)/time.Second))
		return
	}
	sealed, err := s.Vault.SealPerson(tok, pid, livePagePurpose)
	if err == nil {
		err = s.Store.PutPartnerCred(pid, store.PartnerLivePage, openid, sealed, until, now)
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, "keep the 活页 key: "+err.Error())
		return
	}
	_ = s.Store.HubAudit(trialInviter, "livepage.provision", pid, "ok",
		fmt.Sprintf("created=%t until=%s terms=%s · 为试用者开好活页账号 · a 活页 account for the trial", created,
			until.UTC().Format(time.RFC3339), livePageTermsVersion), now)
	writeJSON(w, http.StatusOK, livePageAnswer{Eligible: true, Ready: true, Token: tok, Until: until.UTC().Format(time.RFC3339), New: created})
}

// revokeLivePage takes pid's key back now for reason and tells 活页 (the
// sweep tells it again if it could not be reached). Nothing to take back —
// never provisioned, revoked already — does nothing. A trial's end
// (expired) also tells them, once, in WeChat.
func (s *Server) revokeLivePage(pid, reason string, now time.Time) {
	if s.Store == nil {
		return
	}
	changed, err := s.Store.RevokePartnerCred(pid, store.PartnerLivePage, reason, now)
	if err != nil {
		log.Printf("fleet: livepage revoke %s: %v", pid, err)
		return
	}
	if !changed {
		return
	}
	_ = s.Store.HubAudit(trialInviter, "livepage.revoke", pid, "ok", "reason="+reason+" · 收回活页钥匙 · the 活页 key taken back", now)
	if reason == livePageExpired {
		if err := s.Tell(context.Background(), Recipient{Owner: pid}, store.NotifyKindLivePageEnd, Fields{Person: pid, At: now}); err != nil {
			log.Printf("fleet: livepage end notice %s: %v", pid, err)
		}
	}
	if c, err := s.Store.PartnerCred(pid, store.PartnerLivePage); err == nil && c != nil {
		s.tellLivePageRevoke(*c, now)
	}
}

// eraseLivePage: pid deleted their data (or was removed from the list) — 活页
// closes their account at once, whatever became of the key before.
func (s *Server) eraseLivePage(pid string, now time.Time) {
	if s.Store == nil || pid == "" {
		return
	}
	changed, err := s.Store.ErasePartnerCred(pid, store.PartnerLivePage, now)
	if err != nil || !changed {
		if err != nil {
			log.Printf("fleet: livepage erase %s: %v", pid, err)
		}
		return
	}
	_ = s.Store.HubAudit(trialInviter, "livepage.revoke", pid, "ok", "reason=erase · 删除数据：活页账号一起注销 · their 活页 account closed with their data", now)
	if c, err := s.Store.PartnerCred(pid, store.PartnerLivePage); err == nil && c != nil {
		s.tellLivePageRevoke(*c, now)
	}
}

// tellLivePageRevoke tells 活页 c is over; the sweep calls it again until done.
func (s *Server) tellLivePageRevoke(c store.PartnerCred, now time.Time) {
	if !s.LivePage.ready() || c.Subject == "" {
		return // nobody to tell yet: the sweep tries once the door is configured
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result := "ok"
	if err := s.LivePage.Revoke(ctx, c.Subject, c.RevokeReason); err != nil {
		log.Printf("fleet: livepage: tell 活页 of %s: %v", c.Principal, err)
		if !errors.Is(err, errPartnerRefused) {
			return
		}
		result = "refused"
	}
	if err := s.Store.PartnerCredRemoteDone(c.Principal, c.Kind); err != nil {
		log.Printf("fleet: livepage: %s: %v", c.Principal, err)
	}
	_ = s.Store.HubAudit(trialInviter, "livepage.revoke.told", c.Principal, result, "reason="+c.RevokeReason, now)
}

// livePageSweepEvery bounds the sweep (the trial patrol runs every 15 s).
const livePageSweepEvery = time.Minute

// livePageSweepState is the sweep's last run (Server.livePageSweep).
type livePageSweepState struct {
	mu sync.Mutex
	at time.Time
}

// SweepLivePage takes back every key whose trial is over and tells 活页 of
// each revoke it has not heard of yet — at most once a minute.
func (s *Server) SweepLivePage(now time.Time) {
	if s.Store == nil {
		return
	}
	st := &s.livePageSweep
	st.mu.Lock()
	if !st.at.IsZero() && now.Sub(st.at) < livePageSweepEvery && now.After(st.at) {
		st.mu.Unlock()
		return
	}
	st.at = now
	st.mu.Unlock()
	cs, err := s.Store.PartnerCreds(store.PartnerLivePage)
	if err != nil || len(cs) == 0 {
		if err != nil {
			log.Printf("fleet: livepage sweep: %v", err)
		}
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		log.Printf("fleet: livepage sweep: %v", err)
		return
	}
	for _, c := range cs {
		if !c.RevokedAt.IsZero() {
			s.tellLivePageRevoke(c, now)
			continue
		}
		reason := s.livePageEnd(settings, c.Principal, now)
		if reason == "" && !c.Until.IsZero() && !now.Before(c.Until) {
			reason = livePageExpired
		}
		if reason != "" {
			s.revokeLivePage(c.Principal, reason, now)
		}
	}
}

// livePageEndMsg: the trial is over; their pages stay 30 days.
func livePageEndMsg(at time.Time, en bool, base string) noticeMsg {
	m := noticeMsg{}
	if base != "" {
		m.Link = base + "/app"
	}
	var head, content string
	if en {
		head = "ClaudeFleet: your trial has ended"
		content = "Your trial has ended. Your pages are kept for 30 days — become a member to keep using them, or close your LivePage account to delete them now."
	} else {
		head = "ClaudeFleet：试用已结束"
		content = "试用已结束。你的网页保留 30 天，申请转正后接着用；也可以在活页里注销、立即删除。"
	}
	m.Tpl = map[string]string{
		"thing3":             ternary(en, "ClaudeFleet trial", "ClaudeFleet 试用"),
		"character_string14": "trial",
		"thing5":             ternary(en, "Ended", "已结束"),
		"time6":              noticeTime(at, false),
	}
	m.Subject = head
	m.Body = content + "\n"
	if m.Link != "" {
		m.Body += "\n" + m.Link + "\n"
	}
	m.Text = content
	if m.Link != "" {
		m.Text += "\n" + m.Link
	}
	return m
}

// livePageEnded says pid's 活页 key was taken back because the trial ended
// (the console's banner then says what became of their pages).
func (s *Server) livePageEnded(pid string) bool {
	if s.Store == nil || pid == "" {
		return false
	}
	c, err := s.Store.PartnerCred(pid, store.PartnerLivePage)
	return err == nil && c != nil && !c.RevokedAt.IsZero() && c.RevokeReason == livePageExpired
}
