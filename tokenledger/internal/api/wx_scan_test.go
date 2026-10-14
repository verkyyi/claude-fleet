package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4054 (EPIC #4048 C6): follow the service account to sign in.

// fakeWorkbench stands in for workbench-api's /internal/wx and for the two
// api.weixin.qq.com calls the token is used for: a code drawn for a scene,
// who scanned which scene, who an openid is.
type fakeWorkbench struct {
	mu      sync.Mutex
	srv     *httptest.Server
	tokens  int              // /internal/wx/token answers given
	drawn   []int64          // scenes qrcode/create was asked for
	asked   []int64          // scenes fleet-scan-login was asked about
	scans   map[int64]string // scene → openid
	users   map[string]wxUser
	down    bool // workbench answers 502
	gone    bool // WeChat says the next token is no longer good (once)
	headers []string
}

func newFakeWorkbench(t *testing.T) *fakeWorkbench {
	f := &fakeWorkbench{scans: map[int64]string{}, users: map[string]wxUser{}}
	mux := http.NewServeMux()
	gate := func(w http.ResponseWriter, r *http.Request) bool {
		f.headers = append(f.headers, r.Header.Get("x-internal-token"))
		if f.down {
			w.WriteHeader(http.StatusBadGateway)
			return false
		}
		if r.Header.Get("x-internal-token") != "gate-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			return false
		}
		return true
	}
	mux.HandleFunc("/internal/wx/token", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if !gate(w, r) {
			return
		}
		if r.URL.Query().Get("appid") != wxServiceAppID {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.tokens++
		writeJSON(w, http.StatusOK, map[string]any{"access_token": "wxtok-" + strconv.Itoa(f.tokens), "expires_at": time.Now().Add(2 * time.Hour).Unix()})
	})
	mux.HandleFunc("/internal/wx/fleet-scan-login", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if !gate(w, r) {
			return
		}
		n, err := strconv.ParseInt(r.URL.Query().Get("scene"), 10, 64)
		f.asked = append(f.asked, n)
		if err != nil || n < 3000000 || n >= 4000000 { // workbench's own range check
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if o := f.scans[n]; o != "" {
			writeJSON(w, http.StatusOK, map[string]any{"openid": o})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	tokenOK := func(w http.ResponseWriter, r *http.Request) bool {
		if f.gone {
			f.gone = false
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 40001, "errmsg": "invalid credential, access_token is " + r.URL.Query().Get("access_token")})
			return false
		}
		if !strings.HasPrefix(r.URL.Query().Get("access_token"), "wxtok-") {
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 40001})
			return false
		}
		return true
	}
	mux.HandleFunc("/cgi-bin/qrcode/create", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.Method != http.MethodPost || !tokenOK(w, r) {
			return
		}
		var body struct {
			Expire     int    `json:"expire_seconds"`
			Action     string `json:"action_name"`
			ActionInfo struct {
				Scene struct {
					ID int64 `json:"scene_id"`
				} `json:"scene"`
			} `json:"action_info"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Action != "QR_SCENE" || body.Expire != 600 {
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 40097})
			return
		}
		f.drawn = append(f.drawn, body.ActionInfo.Scene.ID)
		writeJSON(w, http.StatusOK, map[string]any{"ticket": "tk", "expire_seconds": 600,
			"url": "http://weixin.qq.com/q/fleet" + strconv.FormatInt(body.ActionInfo.Scene.ID, 10)})
	})
	mux.HandleFunc("/cgi-bin/user/info", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if !tokenOK(w, r) {
			return
		}
		u, ok := f.users[r.URL.Query().Get("openid")]
		if !ok {
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 40003})
			return
		}
		sub := 0
		if u.Followed {
			sub = 1
		}
		out := map[string]any{"subscribe": sub, "openid": u.OpenID}
		if u.UnionID != "" {
			out["unionid"] = u.UnionID
		}
		writeJSON(w, http.StatusOK, out)
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

// scan: openid scanned scene (followed, with unionid union — "" for none).
func (f *fakeWorkbench) scan(scene int64, openid, union string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.scans[scene] = openid
	f.users[openid] = wxUser{OpenID: openid, UnionID: union, Followed: true}
}

type wxHarness struct {
	*waysHarness
	wb *fakeWorkbench
}

// newWxHarness: a hub with every way on, the service account's road too.
func newWxHarness(t *testing.T) *wxHarness {
	h := newWaysHarness(t)
	wb := newFakeWorkbench(t)
	h.srv.WxGW = &WxGateway{URL: wb.srv.URL + "/internal/wx", Token: "gate-secret", APIBase: wb.srv.URL}
	return &wxHarness{waysHarness: h, wb: wb}
}

var sceneRE = regexp.MustCompile(`data-s="(\d+)"`)

// signinScene opens /signin in b and returns the code it drew.
func (h *wxHarness) signinScene(t *testing.T, b *browser) (int64, string) {
	t.Helper()
	resp, body := b.do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	m := sceneRE.FindStringSubmatch(body)
	if resp.StatusCode != http.StatusOK || m == nil {
		t.Fatalf("/signin = %d, no code drawn:\n%s", resp.StatusCode, body)
	}
	n, _ := strconv.ParseInt(m[1], 10, 64)
	return n, body
}

// pollJSON is the page's script asking about scene.
func (h *wxHarness) pollJSON(t *testing.T, b *browser, scene int64) string {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+wxPollPath+"?s="+strconv.FormatInt(scene, 10), nil)
	req.Header.Set("Accept", "application/json")
	resp, err := b.c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct{ S string }
	raw, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(raw, &out); err != nil || resp.StatusCode != 200 {
		t.Fatalf("poll = %d %s", resp.StatusCode, raw)
	}
	return out.S
}

func (h *wxHarness) finish(t *testing.T, b *browser, scene int64) *http.Response {
	t.Helper()
	resp, _ := b.do(http.MethodGet, h.http.URL+wxPollPath+"?s="+strconv.FormatInt(scene, 10), nil)
	return resp
}

func (h *wxHarness) addPerson(t *testing.T, kind, subject string) string {
	t.Helper()
	pid, _ := newPersonPrincipal()
	if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "linxiao", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: kind, Subject: subject, PrincipalID: pid, VerifiedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return pid
}

// Someone on the list scans the page's code: the page's script sees wait,
// then ready; the browser that drew it finishes and is in, as the person
// their unionid is hung on. Their openid is kept as where to reach them.
func TestWxScanSignsInListed(t *testing.T) {
	h := newWxHarness(t)
	pid := h.addPerson(t, store.IdentityWeChat, "union-lx")
	pc := newBrowser(t, "Mozilla/5.0 (Macintosh)")
	scene, body := h.signinScene(t, pc)
	if !wxSceneInRange(scene) {
		t.Fatalf("scene %d outside ClaudeFleet's range", scene)
	}
	// The code up front, the other ways folded below it, and the one script.
	iq, io, ie, ig := strings.Index(body, `class="qrcard"`), strings.Index(body, `<details class="other"`),
		strings.Index(body, `action="/auth/email/start"`), strings.Index(body, `href="/auth/github/start"`)
	if iq < 0 || !(iq < io && io < ie && ie < ig) || strings.Contains(body, `<details class="other" id="other" open`) ||
		!strings.Contains(body, `<script src="`+signinPollScriptPath+`">`) || !strings.Contains(body, `<svg class="qr"`) {
		t.Fatalf("page layout: qr %d · other %d · email %d · github %d\n%s", iq, io, ie, ig, body)
	}
	if strings.Contains(body, "/auth/wechat/start") {
		t.Fatal("the open-platform road is offered beside the service account's")
	}
	resp, _ := pc.do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	if csp := resp.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "script-src 'self'") {
		t.Fatalf("CSP %q", csp)
	}
	if again, _ := h.signinScene(t, pc); again != scene {
		t.Fatalf("a reload drew another code (%d → %d)", scene, again)
	}
	if st := h.pollJSON(t, pc, scene); st != wxWait {
		t.Fatalf("before the scan: %s", st)
	}
	h.wb.scan(scene, "open-lx", "union-lx")
	if st := h.pollJSON(t, pc, scene); st != wxReady {
		t.Fatalf("after the scan: %s", st)
	}
	if got, _ := pc.session(h.waysHarness); got != "" {
		t.Fatal("polling signed the browser in")
	}
	fin := h.finish(t, pc, scene)
	if fin.StatusCode != http.StatusFound || fin.Header.Get("Location") != AppPrefix {
		t.Fatalf("finish = %d → %q", fin.StatusCode, fin.Header.Get("Location"))
	}
	if got, via := pc.session(h.waysHarness); got != pid || via != store.IdentityWeChat {
		t.Fatalf("signed in %q via %q; want %s via wechat", got, via, pid)
	}
	reach, err := h.srv.Store.HubReachOf(pid)
	if err != nil || len(reach) != 1 || reach[0].Channel != store.ReachWeChatMP || reach[0].Addr != "open-lx" || !reach[0].Followed {
		t.Fatalf("reach = %+v (%v)", reach, err)
	}
	// The script and the no-script fallback are both on the page.
	if resp, js := pc.do(http.MethodGet, h.http.URL+signinPollScriptPath, nil); resp.StatusCode != 200 ||
		!strings.Contains(js, wxPollPath) || !strings.Contains(resp.Header.Get("Content-Type"), "javascript") {
		t.Fatalf("script = %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if !strings.Contains(body, `<noscript><meta http-equiv="refresh" content="2;url=`+wxPollPath+`?s=`+strconv.FormatInt(scene, 10)) {
		t.Fatal("no <meta refresh> for a browser without script")
	}
	// The gate never reaches a page, a log or the browser.
	if strings.Contains(body, "gate-secret") {
		t.Fatal("the internal token is on the page")
	}
}

// Someone the list does not name: no principal, no session — an applicant,
// sent to /apply; where to reach them is kept under the applicant.
func TestWxScanNotListedApplies(t *testing.T) {
	h := newWxHarness(t)
	before, _ := h.srv.Store.HubUsers()
	b := newBrowser(t, "")
	scene, _ := h.signinScene(t, b)
	h.wb.scan(scene, "open-new", "union-new")
	fin := h.finish(t, b, scene)
	if fin.StatusCode != http.StatusFound || fin.Header.Get("Location") != applicantPath {
		t.Fatalf("not listed → %d %q; want /apply", fin.StatusCode, fin.Header.Get("Location"))
	}
	if got, _ := b.session(h.waysHarness); got != "" {
		t.Fatalf("an applicant got a session as %s", got)
	}
	req := httptest.NewRequest(http.MethodGet, applicantPath, nil)
	for _, c := range b.c.Jar.Cookies(mustURL(h.http.URL + applicantPath)) {
		req.AddCookie(c)
	}
	if a, ok := h.srv.applicantFrom(req); !ok || a.Kind != store.IdentityWeChat || a.Subject != "union-new" {
		t.Fatalf("applicant note = %+v %v; want wechat union-new", a, ok)
	}
	after, _ := h.srv.Store.HubUsers()
	if pid, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-new"); len(after) != len(before) || pid != "" {
		t.Fatalf("a scan made a person: %d → %d users, identity %q", len(before), len(after), pid)
	}
	reach, _ := h.srv.Store.HubReachOf(store.ApplicantReachOwner(store.IdentityWeChat, "union-new"))
	if len(reach) != 1 || reach[0].Addr != "open-new" {
		t.Fatalf("applicant reach = %+v", reach)
	}
}

// BREAK-IT fleet-scene-cross: the hub draws codes only in ClaudeFleet's
// range and asks workbench only about those; a code finishes once, and only
// in the browser that drew it — never by another browser that learned its
// number, never twice.
func TestWxSceneCross(t *testing.T) {
	h := newWxHarness(t)
	pid := h.addPerson(t, store.IdentityWeChat, "union-a")
	// Many browsers, many codes: every one in range.
	for i := 0; i < 40; i++ {
		b := newBrowser(t, "")
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+wxQRPath, strings.NewReader("purpose=login"))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r, err := b.c.Do(req)
		if err != nil || r.StatusCode != 200 {
			t.Fatalf("draw %d = %v %v", i, r.StatusCode, err)
		}
		r.Body.Close()
	}
	for _, n := range h.wb.drawn {
		if !wxSceneInRange(n) {
			t.Fatalf("drew scene %d outside [3000000, 4000000)", n)
		}
	}
	if len(h.wb.drawn) != 40 {
		t.Fatalf("drew %d codes for 40 browsers", len(h.wb.drawn))
	}

	a, other := newBrowser(t, ""), newBrowser(t, "")
	scene, _ := h.signinScene(t, a)
	_, _ = h.signinScene(t, other) // other has a nonce of its own
	h.wb.scan(scene, "open-a", "union-a")
	// Another browser with the number: refused, before workbench is asked.
	asked := len(h.wb.asked)
	if st := h.pollJSON(t, other, scene); st != wxExpired {
		t.Fatalf("another browser polling the code: %s", st)
	}
	if fin := h.finish(t, other, scene); !strings.Contains(fin.Header.Get("Location"), "e=wechat-expired") {
		t.Fatalf("another browser finishing the code → %q", fin.Header.Get("Location"))
	}
	if got, _ := other.session(h.waysHarness); got != "" || len(h.wb.asked) != asked {
		t.Fatalf("another browser took the scan (session %q, workbench asked %d more)", got, len(h.wb.asked)-asked)
	}
	// Another product's number (space / tuoke / aicall's ranges): never asked.
	for _, n := range []int64{12345, 1000001, 2999999, 4000000, 9000000} {
		if st := h.pollJSON(t, a, n); st != wxExpired {
			t.Fatalf("poll of scene %d: %s", n, st)
		}
	}
	if len(h.wb.asked) != asked {
		t.Fatalf("workbench was asked about a scene that is not ours: %v", h.wb.asked[asked:])
	}
	if _, err := h.srv.WxGW.scanOpenid(t.Context(), 1000001); err == nil {
		t.Fatal("the gateway asks about another product's scene")
	}
	// The drawing browser: in, once.
	if fin := h.finish(t, a, scene); fin.Header.Get("Location") != AppPrefix {
		t.Fatalf("finish → %q", fin.Header.Get("Location"))
	}
	if got, _ := a.session(h.waysHarness); got != pid {
		t.Fatalf("signed in %q", got)
	}
	// The same browser again: a traded code is spent.
	if st := h.pollJSON(t, a, scene); st != wxExpired {
		t.Fatalf("a traded code polls %s", st)
	}
	if fin := h.finish(t, a, scene); !strings.Contains(fin.Header.Get("Location"), "e=wechat-expired") {
		t.Fatalf("replayed finish → %q", fin.Header.Get("Location"))
	}
}

// No unionid (the account not bound to the open platform, say): the person
// is known by the openid, wechat-mp — and once a scan carries the unionid,
// it is hung on the same person.
func TestWxScanJoinsUnionLater(t *testing.T) {
	h := newWxHarness(t)
	pid := h.addPerson(t, store.IdentityWeChatMP, "open-mp")
	b := newBrowser(t, "")
	scene, _ := h.signinScene(t, b)
	h.wb.scan(scene, "open-mp", "")
	if fin := h.finish(t, b, scene); fin.Header.Get("Location") != AppPrefix {
		t.Fatalf("by openid → %q", fin.Header.Get("Location"))
	}
	if got, via := b.session(h.waysHarness); got != pid || via != store.IdentityWeChatMP {
		t.Fatalf("signed in %q via %q", got, via)
	}
	b2 := newBrowser(t, "")
	scene, _ = h.signinScene(t, b2)
	h.wb.scan(scene, "open-mp", "union-mp")
	if fin := h.finish(t, b2, scene); fin.Header.Get("Location") != AppPrefix {
		t.Fatalf("with the unionid → %q", fin.Header.Get("Location"))
	}
	if got, via := b2.session(h.waysHarness); got != pid || via != store.IdentityWeChat {
		t.Fatalf("signed in %q via %q; want the same person by the unionid", got, via)
	}
	if owner, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-mp"); owner != pid {
		t.Fatalf("the unionid is %q's", owner)
	}
}

// Off (no workbench road): /signin is byte for byte the page it was, and the
// routes and the script 404.
func TestWxScanOffPageUnchanged(t *testing.T) {
	h := newWaysHarness(t)
	_, body := newBrowser(t, "").do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	want := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, AppPrefix+"/signin", nil)
	req.Header.Set("Accept", "text/html")
	h.srv.renderSigninWays(want, req, "en", "")
	if body != want.Body.String() {
		t.Fatalf("/signin changed with the road off:\n%s", body)
	}
	for _, p := range []string{wxPollPath + "?s=3000001", signinPollScriptPath} {
		if r, _ := newBrowser(t, "").do(http.MethodGet, h.http.URL+p, nil); r.StatusCode != http.StatusNotFound {
			t.Errorf("%s with the road off = %d", p, r.StatusCode)
		}
	}
	if r, _ := newBrowser(t, "").do(http.MethodPost, h.http.URL+wxQRPath, url.Values{"purpose": {"login"}}); r.StatusCode != http.StatusNotFound {
		t.Errorf("%s with the road off = %d", wxQRPath, r.StatusCode)
	}
}

// A phone's browser cannot scan its own screen: 「在微信里打开」 up front, the
// code folded. WeChat not answering: the page says so and unfolds the rest.
func TestWxScanPhoneAndDown(t *testing.T) {
	h := newWxHarness(t)
	_, body := newBrowser(t, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148 Safari/604.1").
		do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	io, iq := strings.Index(body, `id="wxcopy"`), strings.Index(body, `<details class="more">`)
	if io < 0 || iq < io || strings.Contains(body, `class="qrcard"`) {
		t.Fatalf("phone page: copy %d · folded code %d\n%s", io, iq, body)
	}
	h = newWxHarness(t) // no token kept from the draw above
	h.wb.down = true
	resp, body := newBrowser(t, "").do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	if resp.StatusCode != 200 || !strings.Contains(body, `class="qrcard off"`) || !strings.Contains(body, `<details class="other" id="other" open>`) ||
		strings.Contains(body, "data-s=") {
		t.Fatalf("workbench down: %d\n%s", resp.StatusCode, body)
	}
}

// The token is asked of workbench once and kept; a token WeChat says is gone
// is asked for again, once.
func TestWxGatewayToken(t *testing.T) {
	wb := newFakeWorkbench(t)
	g := &WxGateway{URL: wb.srv.URL + "/internal/wx", Token: "gate-secret", APIBase: wb.srv.URL}
	for i := 0; i < 3; i++ {
		if _, err := g.qrCreate(t.Context(), 3000000+int64(i), wxSceneTTL); err != nil {
			t.Fatal(err)
		}
	}
	if wb.tokens != 1 {
		t.Fatalf("token asked %d times for three codes", wb.tokens)
	}
	wb.gone = true
	if _, err := g.qrCreate(t.Context(), 3000009, wxSceneTTL); err != nil || wb.tokens != 2 {
		t.Fatalf("after a gone token: %v, asked %d", err, wb.tokens)
	}
	for _, h := range wb.headers {
		if h != "gate-secret" {
			t.Fatalf("a call without the gate: %q", h)
		}
	}
	// An error never carries the token or the gate.
	bad := &WxGateway{URL: wb.srv.URL + "/internal/wx", Token: "wrong-gate", APIBase: wb.srv.URL}
	if _, err := bad.qrCreate(t.Context(), 3000001, wxSceneTTL); err == nil || strings.Contains(err.Error(), "wrong-gate") {
		t.Fatalf("err = %v", err)
	}
	if _, err := g.qrCreate(t.Context(), 2999999, wxSceneTTL); err == nil {
		t.Fatal("drew a code outside the range")
	}
}

// A `fleet login` waiting on this browser: the scan returns to its
// confirmation page, as GitHub's does.
func TestWxScanReturnsToFleetLogin(t *testing.T) {
	h := newWxHarness(t)
	h.addPerson(t, store.IdentityWeChat, "union-fl")
	b := newBrowser(t, "")
	scene, _ := h.signinScene(t, b)
	b.c.Jar.SetCookies(mustURL(h.http.URL+"/"), []*http.Cookie{{Name: loginCookie, Value: "BCDF-GHJK", Path: "/"}})
	h.wb.scan(scene, "open-fl", "union-fl")
	if fin := h.finish(t, b, scene); fin.Header.Get("Location") != "/fleet/login?code=BCDF-GHJK" {
		t.Fatalf("finish → %q", fin.Header.Get("Location"))
	}
}

// 立即体验 (claude-fleet#4058): a browser on its way to a trial draws a
// trial-purpose code; someone the list does not name who scans it is a trial
// person — signed in as one, sent to /app/try, one trial per unionid —
// someone it names goes straight to /app. A second trial for the same
// WeChat reads 「已试过」.
func TestWxScanStartsATrial(t *testing.T) {
	h := newWxHarness(t)
	h.srv.Fleet = true // the trial is the fleet module's
	setHubSetting(t, h.srv, TrialKey, "on")
	trying := func() *browser {
		b := newBrowser(t, "")
		b.c.Jar.SetCookies(mustURL(h.http.URL+"/"), []*http.Cookie{{Name: tryCookie, Value: "1", Path: "/"}})
		return b
	}
	b := trying()
	scene, body := h.signinScene(t, b)
	if !strings.Contains(body, `data-p="trial"`) || !strings.Contains(body, "p=trial") {
		t.Fatalf("the sign-in page on the way to a trial drew no trial code:\n%s", body)
	}
	if c, _ := h.srv.Store.WxSceneOf(scene); c == nil || c.Purpose != wxPurposeTrial {
		t.Fatalf("scene = %+v; want purpose trial", c)
	}
	// A login poll does not finish a trial code.
	if st := h.pollJSON(t, b, scene); st != wxExpired {
		t.Fatalf("a trial code read as a login code: %s", st)
	}
	h.wb.scan(scene, "open-try", "union-try")
	fin, _ := b.do(http.MethodGet, h.http.URL+wxPollPath+"?p=trial&s="+strconv.FormatInt(scene, 10), nil)
	if fin.StatusCode != http.StatusFound || fin.Header.Get("Location") != TryPagePath {
		t.Fatalf("trial finish = %d → %q; want /app/try", fin.StatusCode, fin.Header.Get("Location"))
	}
	pid, via := b.session(h.waysHarness)
	tr, _ := h.srv.Store.TrialByWay(store.IdentityWeChat, "union-try")
	if pid == "" || via != store.IdentityWeChat || tr == nil || tr.Principal != pid {
		t.Fatalf("signed in %q via %q, trial %+v; want the trial person by unionid", pid, via, tr)
	}
	if role, _ := h.srv.personRole(pid); role != roleTrial {
		t.Fatalf("role %q; want trial", role)
	}
	if reach, _ := h.srv.Store.HubReachOf(pid); len(reach) != 1 || reach[0].Addr != "open-try" {
		t.Fatalf("trial reach = %+v", reach)
	}

	// Someone on the list scans a trial code: the console, no trial.
	listed := h.addPerson(t, store.IdentityWeChat, "union-lx")
	b2 := trying()
	scene2, _ := h.signinScene(t, b2)
	h.wb.scan(scene2, "open-lx", "union-lx")
	fin, _ = b2.do(http.MethodGet, h.http.URL+wxPollPath+"?p=trial&s="+strconv.FormatInt(scene2, 10), nil)
	if fin.StatusCode != http.StatusFound || fin.Header.Get("Location") != AppPrefix {
		t.Fatalf("listed trial scan → %d %q; want /app", fin.StatusCode, fin.Header.Get("Location"))
	}
	if got, _ := b2.session(h.waysHarness); got != listed {
		t.Fatalf("signed in %q; want %s", got, listed)
	}
	if tr, _ := h.srv.Store.Trial(listed); tr != nil {
		t.Fatalf("a listed person got a trial: %+v", tr)
	}

	// The trial ends; the same WeChat scans again: the same person, 已试过.
	now := time.Now()
	_ = h.srv.Store.PlaceTrial(pid, "mac-d", now)
	_ = h.srv.Store.ReclaimTrial(pid, now)
	b3 := trying()
	scene3, _ := h.signinScene(t, b3)
	h.wb.scan(scene3, "open-try", "union-try")
	b3.do(http.MethodGet, h.http.URL+wxPollPath+"?p=trial&s="+strconv.FormatInt(scene3, 10), nil)
	if got, _ := b3.session(h.waysHarness); got != pid {
		t.Fatalf("second scan signed in %q; want the same trial person %s", got, pid)
	}
	if a, err := h.srv.tryClaim(pid, "", now); err != nil || a.State != "tried" {
		t.Fatalf("second trial claim = %+v, %v; want tried", a, err)
	}
}
