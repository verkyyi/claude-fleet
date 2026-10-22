package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet MRGB: an admin's 试用二维码 — scan and follow the service
// account, and the trial starts with no request to approve.

type trialHarness struct {
	*ghHarness
	admin, user *http.Cookie
	wb          *fakeWorkbench
}

func newTrialHarness(t *testing.T) *trialHarness {
	t.Helper()
	h, admin, user := rolesHarness(t)
	wb := newFakeWorkbench(t)
	h.srv.WxGW = &WxGateway{URL: wb.srv.URL + "/internal/wx", Token: "gate-secret", APIBase: wb.srv.URL}
	h.srv.FleetPublicURL = "https://fleet.example"
	return &trialHarness{ghHarness: h, admin: admin, user: user, wb: wb}
}

// newCode draws a code through the admin API.
func (h *trialHarness) newCode(t *testing.T, body map[string]any) adminTrialCodeDetail {
	t.Helper()
	st, b := requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminTrialCodesPath, body)
	var d adminTrialCodeDetail
	if st != http.StatusOK || json.Unmarshal(b, &d) != nil || d.ID == "" {
		t.Fatalf("create = %d %s", st, b)
	}
	return d
}

// follow: openid (unionid union, "" none) follows the account and scans scene,
// as workbench hands it over; the answer.
func (h *trialHarness) follow(t *testing.T, scene int64, openid, union, event string) (int, trialScanAnswer) {
	t.Helper()
	h.wb.mu.Lock()
	h.wb.users[openid] = wxUser{OpenID: openid, UnionID: union, Followed: true}
	h.wb.mu.Unlock()
	return h.scanAs(t, "gate-secret", fmt.Sprint(scene), openid, event)
}

func (h *trialHarness) scanAs(t *testing.T, token, scene, openid, event string) (int, trialScanAnswer) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"scene": scene, "openid": openid, "event": event})
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+WxTrialScanPath, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("x-internal-token", token)
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var a trialScanAnswer
	_ = json.Unmarshal(raw, &a)
	return resp.StatusCode, a
}

// ageScans moves every scan two minutes back: past the rescan gap.
func (h *trialHarness) ageScans(t *testing.T) {
	t.Helper()
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_trial_scans SET at = at - 120`); err != nil {
		t.Fatal(err)
	}
}

func (h *trialHarness) grants(t *testing.T, code string) []store.TrialGrant {
	t.Helper()
	gs, err := h.srv.Store.TrialGrantsOfCode(code)
	if err != nil {
		t.Fatal(err)
	}
	return gs
}

// The road: an admin draws a permanent code in the trial range; a new WeChat
// scans it and is on the list with the code's limits and the trial's
// subscriptions, its card pointing at the silent sign-in; their first line
// ends the 60 seconds; the funnel counts it all.
func TestTrialCodeScanStartsTheTrial(t *testing.T) {
	h := newTrialHarness(t)
	c := h.newCode(t, map[string]any{"channel": "线下沙龙 · 深圳", "terms": "days=14,tokens=8000000,sessions=2"})
	if !wxTrialSceneInRange(c.Scene) || c.Kind != store.TrialCodeLimit || c.Cap != trialCodeCapDefault || c.URL == "" {
		t.Fatalf("code = %+v", c.TrialCode)
	}
	if len(h.wb.trialDrawn) != 1 || h.wb.trialDrawn[0] != fmt.Sprintf("QR_LIMIT_STR_SCENE:%d", c.Scene) {
		t.Fatalf("drawn = %v; want one permanent code, a numeric scene_str", h.wb.trialDrawn)
	}
	// the printed code is a PNG of what WeChat encodes
	st, png := requestsDo(t, h.ghHarness, h.admin, http.MethodGet, c.Image, nil)
	if st != http.StatusOK || !bytes.HasPrefix(png, []byte("\x89PNG")) {
		t.Fatalf("qr.png = %d %q", st, png[:min(8, len(png))])
	}

	st, a := h.follow(t, c.Scene, "openid-newcomer-0001", "union-newcomer-1", "subscribe")
	if st != http.StatusOK || a.News == nil || a.News.URL != "https://fleet.example/auth/wechat/start" ||
		a.News.Title != "Tokenman 试用已开通 · 14 天" || a.News.Description != "点开直接对话，不用登录、不用申请。" {
		t.Fatalf("answer = %d %+v", st, a.News)
	}
	gs := h.grants(t, c.ID)
	if len(gs) != 1 || gs[0].State != store.GrantGranted || gs[0].Principal == "" {
		t.Fatalf("grants = %+v", gs)
	}
	pid := gs[0].Principal
	if role, _ := h.srv.personRole(pid); role != roleUser {
		t.Fatalf("role = %q; want user", role)
	}
	set, _ := h.srv.Store.FleetSettings()
	if l, ok := memberLimitsOf(set, pid); !ok || l.Tokens != 8_000_000 || l.Sessions != 2 || l.Until.Sub(time.Now()) < 13*24*time.Hour {
		t.Fatalf("limits = %+v %v; want the code's", l, ok)
	}
	if set[credUserKey(pid)] == "" {
		t.Fatal("no subscriptions: their first line would meet the proxy's 403")
	}
	reqs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityWeChat, "union-newcomer-1")
	if len(reqs) != 1 || reqs[0].State != store.RequestApproved || reqs[0].DecidedBy != "qr:"+c.ID {
		t.Fatalf("request = %+v; want one approved by the code", reqs)
	}

	// the first line in the chat ends the 60 seconds, once
	h.srv.trialFirstLine(pid, gs[0].ScannedAt.Add(42*time.Second))
	h.srv.trialFirstLine(pid, gs[0].ScannedAt.Add(90*time.Second))
	st, b := requestsDo(t, h.ghHarness, h.admin, http.MethodGet, AdminTrialCodesPath, nil)
	var v adminTrialCodesView
	if st != http.StatusOK || json.Unmarshal(b, &v) != nil || len(v.Codes) != 1 {
		t.Fatalf("list = %d %s", st, b)
	}
	f := v.Codes[0].Funnel
	if f.Scans != 1 || f.Follows != 1 || f.Granted != 1 || f.First != 1 || f.Converted != 0 || f.P50Secs != 42 {
		t.Fatalf("funnel = %+v", f)
	}
	if v.Totals.Granted != 1 || v.Totals.P50Secs != 42 || v.Today != 1 || v.TermsZH == "" {
		t.Fatalf("totals = %+v", v)
	}
	// 转正: the limits gone, the funnel's last step counts them
	setHubSetting(t, h.srv, MemberLimitsPrefix+pid, "")
	_, b = requestsDo(t, h.ghHarness, h.admin, http.MethodGet, AdminTrialCodesPath+"/"+c.ID, nil)
	var d adminTrialCodeDetail
	if json.Unmarshal(b, &d) != nil || d.Funnel.Converted != 1 || len(d.People) != 1 || !d.People[0].Member {
		t.Fatalf("detail = %s", b)
	}
}

// One trial per WeChat, ever: a second scan — of the same code or another,
// by its openid or after WeChat named its unionid — gives nothing more.
func TestTrialCodeOncePerWeChat(t *testing.T) {
	h := newTrialHarness(t)
	a := h.newCode(t, map[string]any{"channel": "文章 · 十月"})
	b := h.newCode(t, map[string]any{"channel": "海报 · 测试"})
	if b.Scene != a.Scene+1 {
		t.Fatalf("scenes %d, %d; want the next number", a.Scene, b.Scene)
	}
	if _, ans := h.follow(t, a.Scene, "openid-once-00000001", "union-once", "subscribe"); ans.News == nil || !strings.Contains(ans.News.Title, "已开通") {
		t.Fatalf("first = %+v", ans)
	}
	// inside the minute: nothing at all
	if st, ans := h.follow(t, a.Scene, "openid-once-00000001", "union-once", "SCAN"); st != http.StatusOK || ans.News != nil || ans.Reply != "" {
		t.Fatalf("rescan = %d %+v; want no answer", st, ans)
	}
	// another code: their trial runs, nothing new
	_, ans := h.follow(t, b.Scene, "openid-once-00000001", "union-once", "SCAN")
	if ans.News == nil || !strings.Contains(ans.News.Title, "还在进行") {
		t.Fatalf("other code = %+v", ans.News)
	}
	if n := len(h.grants(t, b.ID)); n != 0 {
		t.Fatalf("other code gave %d", n)
	}
	// their trial over: told so, pointed at /apply
	h.ageScans(t)
	gs := h.grants(t, a.ID)
	setHubSetting(t, h.srv, MemberLimitsPrefix+gs[0].Principal, MemberLimits{Until: time.Now().Add(-time.Hour), Since: time.Now().Add(-8 * 24 * time.Hour)}.String())
	_, ans = h.follow(t, b.Scene, "openid-once-00000001", "union-once", "SCAN")
	// a member whose trial ended: the console, where 申请转正 is one tap
	if ans.News == nil || !strings.Contains(ans.News.Title, "已经试用过") || !strings.HasSuffix(ans.News.URL, "/auth/wechat/start") {
		t.Fatalf("after = %+v", ans.News)
	}
	// a member already: the console, no trial
	_, ans = h.follow(t, b.Scene, "openid-member-000001", "", "SCAN")
	if ans.News == nil {
		t.Fatalf("stranger = %+v", ans)
	}
	pid := h.grants(t, b.ID)[0].Principal
	setHubSetting(t, h.srv, MemberLimitsPrefix+pid, "")
	_, ans = h.follow(t, a.Scene, "openid-member-000001", "", "SCAN")
	if ans.News == nil || !strings.Contains(ans.News.Title, "成员") {
		t.Fatalf("member = %+v", ans.News)
	}
	if n := len(h.grants(t, a.ID)); n != 1 {
		t.Fatalf("a member was given a trial: %d", n)
	}
}

// A stopped, past, full code and a spent day each say so and give nothing;
// resuming makes it give again.
func TestTrialCodeLimits(t *testing.T) {
	h := newTrialHarness(t)
	c := h.newCode(t, map[string]any{"channel": "验收", "cap": 1})
	st, b := requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminTrialCodesPath+"/"+c.ID+"/stop", map[string]any{})
	if st != http.StatusOK || !strings.Contains(string(b), `"state":"stopped"`) {
		t.Fatalf("stop = %d %s", st, b)
	}
	if _, ans := h.follow(t, c.Scene, "openid-limit-0000001", "", "subscribe"); !strings.Contains(ans.Reply, "已停用") {
		t.Fatalf("stopped = %+v", ans)
	}
	requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminTrialCodesPath+"/"+c.ID+"/resume", map[string]any{})
	if _, ans := h.follow(t, c.Scene, "openid-limit-0000002", "", "subscribe"); ans.News == nil {
		t.Fatalf("resumed = %+v", ans)
	}
	if _, ans := h.follow(t, c.Scene, "openid-limit-0000003", "", "subscribe"); !strings.Contains(ans.Reply, "名额已经发完") {
		t.Fatalf("full = %+v", ans)
	}
	if n := hubAuditCount(t, h.ghHarness, "trialcode.stop", "ok") + hubAuditCount(t, h.ghHarness, "trialcode.resume", "ok"); n != 2 {
		t.Fatalf("audit rows = %d", n)
	}
	d := h.newCode(t, map[string]any{"channel": "过期", "until": time.Now().In(trialDay).Format("2006-01-02")})
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_trial_codes SET until_at = ? WHERE id = ?`, time.Now().Add(-time.Minute).Unix(), d.ID); err != nil {
		t.Fatal(err)
	}
	if _, ans := h.follow(t, d.Scene, "openid-limit-0000004", "", "subscribe"); !strings.Contains(ans.Reply, "过期") {
		t.Fatalf("expired = %+v", ans)
	}
	e := h.newCode(t, map[string]any{"channel": "每日"})
	setHubSetting(t, h.srv, QRDailyKey, "1") // one given today already
	if _, ans := h.follow(t, e.Scene, "openid-limit-0000005", "", "subscribe"); !strings.Contains(ans.Reply, "明天") {
		t.Fatalf("daily = %+v", ans)
	}
	// a temporary code: QR_STR_SCENE, its days the code's life
	tmp := h.newCode(t, map[string]any{"channel": "活动", "kind": "temp", "days": 3})
	if tmp.Kind != store.TrialCodeTemp || tmp.Until.Sub(time.Now()) > 3*24*time.Hour+time.Minute {
		t.Fatalf("temp = %+v", tmp.TrialCode)
	}
	if st, _ := requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminTrialCodesPath, map[string]any{"channel": "x", "kind": "temp", "days": 31}); st != http.StatusBadRequest {
		t.Fatalf("31 days = %d", st)
	}
}

// Too many trials too fast: the code pauses itself, the alert is raised and
// every admin is told once; resuming clears it.
func TestTrialCodeBurstPauses(t *testing.T) {
	h := newTrialHarness(t)
	setHubSetting(t, h.srv, QRBurstKey, "2")
	c := h.newCode(t, map[string]any{"channel": "朋友圈海报"})
	for i := 1; i <= 3; i++ {
		h.follow(t, c.Scene, fmt.Sprintf("openid-burst-%08d", i), "", "subscribe")
	}
	got, _ := h.srv.Store.TrialCode(c.ID)
	if got.State != store.TrialCodePaused || got.PausedWhy != "3/2" || !strings.Contains(burstWords(got.PausedWhy, false), "开通 3 人") {
		t.Fatalf("code = %+v; want paused", got)
	}
	if _, ans := h.follow(t, c.Scene, "openid-burst-00000004", "", "subscribe"); !strings.Contains(ans.Reply, "已停用") {
		t.Fatalf("after the pause = %+v", ans)
	}
	if _, _, open, err := h.srv.Store.OpenFleetAlert(store.AlertTrialCodeBurst, c.ID); err != nil || !open {
		t.Fatalf("alert open = %v %v", open, err)
	}
	var notices int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM hub_notify_outbox WHERE kind = ?`, store.NotifyKindQRBurst).Scan(&notices); err != nil || notices != 1 {
		t.Fatalf("admin notices = %d %v; want one, to the one admin", notices, err)
	}
	requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminTrialCodesPath+"/"+c.ID+"/resume", map[string]any{})
	if _, _, open, _ := h.srv.Store.OpenFleetAlert(store.AlertTrialCodeBurst, c.ID); open {
		t.Fatal("still open after resume")
	}
}

// The machines full: the scan waits in line and is told how many are ahead;
// the line is served once nothing holds, with a card that it is their turn.
func TestTrialCodeQueue(t *testing.T) {
	h := newTrialHarness(t)
	old := trialPoolLeft
	t.Cleanup(func() { trialPoolLeft = old })
	trialPoolLeft = func(*Server) (float64, bool) { return 5, true } // under the floor
	c := h.newCode(t, map[string]any{"channel": "排队"})
	_, a1 := h.follow(t, c.Scene, "openid-queue-00000001", "", "subscribe")
	_, a2 := h.follow(t, c.Scene, "openid-queue-00000002", "", "subscribe")
	if a1.News == nil || !strings.Contains(a1.News.Description, "前面还有 0 位") || a2.News == nil || !strings.Contains(a2.News.Description, "前面还有 1 位") {
		t.Fatalf("in line = %+v / %+v", a1.News, a2.News)
	}
	h.srv.trialQueuePass(t.Context(), time.Now())
	if gs := h.grants(t, c.ID); gs[0].State != store.GrantQueued || gs[1].State != store.GrantQueued {
		t.Fatalf("served while held: %+v", gs)
	}
	trialPoolLeft = func(*Server) (float64, bool) { return 80, true }
	h.srv.trialQueuePass(t.Context(), time.Now())
	for _, g := range h.grants(t, c.ID) {
		if g.State != store.GrantGranted || g.Principal == "" {
			t.Fatalf("after = %+v", g)
		}
	}
	h.wb.mu.Lock()
	defer h.wb.mu.Unlock()
	if len(h.wb.customs) != 2 || !strings.Contains(h.wb.customs[0], "轮到你了") || !strings.Contains(h.wb.customs[0], `"msgtype":"news"`) {
		t.Fatalf("cards = %v", h.wb.customs)
	}
}

// An approval code files a pending request instead; approving it writes
// that code's limits and counts the grant.
func TestTrialCodeApproval(t *testing.T) {
	h := newTrialHarness(t)
	c := h.newCode(t, map[string]any{"channel": "合作方", "approval": true, "terms": "days=3,tokens=1000000"})
	_, ans := h.follow(t, c.Scene, "openid-approve-000001", "", "subscribe")
	if !strings.Contains(ans.Reply, "申请已提交") {
		t.Fatalf("answer = %+v", ans)
	}
	reqs, _ := h.srv.Store.Requests().ByIdentity(store.IdentityWeChatMP, "openid-approve-000001")
	if len(reqs) != 1 || reqs[0].State != store.RequestPending || reqs[0].Referrer != "qr:"+c.ID {
		t.Fatalf("requests = %+v", reqs)
	}
	st, b := requestsDo(t, h.ghHarness, h.admin, http.MethodPost, AdminRequestsPath+"/"+reqs[0].ID+"/approve", map[string]any{})
	var d adminRequestDetail
	if st != http.StatusOK || json.Unmarshal(b, &d) != nil {
		t.Fatalf("approve = %d %s", st, b)
	}
	set, _ := h.srv.Store.FleetSettings()
	if l, ok := memberLimitsOf(set, d.Person); !ok || l.Tokens != 1_000_000 || l.Until.Sub(time.Now()) > 3*24*time.Hour {
		t.Fatalf("limits = %+v; want the code's", l)
	}
	if gs := h.grants(t, c.ID); len(gs) != 1 || gs[0].State != store.GrantGranted || gs[0].Principal != d.Person {
		t.Fatalf("grant = %+v", gs)
	}
}

// Only workbench, with the gate token, for a scene in the trial range; a
// member is answered the 404 for the admin API.
func TestTrialCodeGates(t *testing.T) {
	h := newTrialHarness(t)
	c := h.newCode(t, map[string]any{"channel": "门"})
	if st, _ := h.scanAs(t, "", fmt.Sprint(c.Scene), "openid-gate-000000001", "subscribe"); st != http.StatusUnauthorized {
		t.Fatalf("no token = %d", st)
	}
	if st, _ := h.scanAs(t, "forged", fmt.Sprint(c.Scene), "openid-gate-000000001", "subscribe"); st != http.StatusUnauthorized {
		t.Fatalf("forged = %d", st)
	}
	if st, _ := h.scanAs(t, "gate-secret", "3000001", "openid-gate-000000001", "subscribe"); st != http.StatusBadRequest {
		t.Fatalf("a login scene = %d", st)
	}
	if st, _ := h.scanAs(t, "gate-secret", fmt.Sprint(c.Scene), "x", "subscribe"); st != http.StatusBadRequest {
		t.Fatalf("bad openid = %d", st)
	}
	if n := len(h.grants(t, c.ID)); n != 0 {
		t.Fatalf("a refused scan gave %d", n)
	}
	if st, _ := requestsDo(t, h.ghHarness, h.user, http.MethodGet, AdminTrialCodesPath, nil); st != http.StatusNotFound {
		t.Fatalf("member = %d", st)
	}
	if st, _ := requestsDo(t, h.ghHarness, h.user, http.MethodPost, AdminTrialCodesPath, map[string]any{"channel": "x"}); st != http.StatusNotFound {
		t.Fatalf("member create = %d", st)
	}
}
