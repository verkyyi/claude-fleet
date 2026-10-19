package api

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet#4055 (EPIC #4048 C7): open ClaudeFleet inside WeChat and be
// in — through workbench's web-authorisation relay, no code to scan.

const testRelayURL = "https://relay.example/node_w/wx/oauth/relay"

// newRelayHarness: the service account's road with the relay on.
func newRelayHarness(t *testing.T) *wxHarness {
	h := newWxHarness(t)
	h.srv.WxGW.RelayURL = testRelayURL
	h.srv.WxGW.AuthorizeBase = "https://open.example"
	return h
}

// relayStart opens /app/signin in WeChat's browser b and follows the hub to
// WeChat's authorize page; the nonce it carries.
func (h *wxHarness) relayStart(t *testing.T, b *browser) string {
	t.Helper()
	resp, _ := b.do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/auth/wechat/start" {
		t.Fatalf("/signin in WeChat = %d → %q; want /auth/wechat/start", resp.StatusCode, resp.Header.Get("Location"))
	}
	resp, _ = b.do(http.MethodGet, h.http.URL+"/auth/wechat/start", nil)
	loc := resp.Header.Get("Location")
	if resp.StatusCode != http.StatusFound || !strings.HasPrefix(loc, "https://open.example/connect/oauth2/authorize?appid="+wxServiceAppID+"&") ||
		!strings.HasSuffix(loc, "#wechat_redirect") {
		t.Fatalf("start = %d → %q", resp.StatusCode, loc)
	}
	u, _ := url.Parse(loc)
	q := u.Query()
	if q.Get("redirect_uri") != testRelayURL || q.Get("scope") != "snsapi_base" || q.Get("response_type") != "code" ||
		q.Get("component_appid") != wxComponentAppID {
		t.Fatalf("authorize query %v", q)
	}
	parts := strings.Split(q.Get("state"), ".")
	if len(parts) != 3 || parts[0] != "fleet" || parts[2] != wxServiceAppID || len(parts[1]) < 8 || len(parts[1]) > 64 || len(q.Get("state")) > 128 {
		t.Fatalf("state %q is not <target>.<nonce>.<appid>", q.Get("state"))
	}
	return parts[1]
}

// relayBack is the relay sending b back, signed with key at time ts.
func (h *wxHarness) relayBack(t *testing.T, b *browser, nonce, openid, key string, ts time.Time) *http.Response {
	t.Helper()
	tv := strconv.FormatInt(ts.Unix(), 10)
	q := url.Values{"n": {nonce}, "o": {openid}, "t": {tv}, "sig": {wxRelaySig(key, "fleet", nonce, openid, tv)}}
	resp, _ := b.do(http.MethodGet, h.http.URL+wxRelayCBPath+"?"+q.Encode(), nil)
	return resp
}

// Someone on the list opens /app/signin in WeChat: no code is drawn, the
// relay's signed openid signs them in as the person their unionid is hung
// on — and a non-follower known only by their openid comes in too.
func TestWxRelaySignsInListed(t *testing.T) {
	h := newRelayHarness(t)
	pid := h.addPerson(t, store.IdentityWeChat, "union-lx")
	h.wb.users["open-lx-0123456789abc"] = wxUser{OpenID: "open-lx-0123456789abc", UnionID: "union-lx", Followed: true}
	b := newBrowser(t, wechatUA)
	nonce := h.relayStart(t, b)
	resp := h.relayBack(t, b, nonce, "open-lx-0123456789abc", "gate-secret", time.Now())
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != AppPrefix {
		t.Fatalf("relay-cb = %d → %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	if got, via := b.session(h.waysHarness); got != pid || via != store.IdentityWeChat {
		t.Fatalf("signed in %q via %q; want %s via wechat", got, via, pid)
	}
	if len(h.wb.drawn) != 0 {
		t.Fatalf("a QR code was drawn for WeChat's browser: %v", h.wb.drawn)
	}
	if reach, _ := h.srv.Store.HubReachOf(pid); len(reach) != 1 || reach[0].Addr != "open-lx-0123456789abc" {
		t.Fatalf("reach = %+v", reach)
	}

	// Not following: no unionid — wechat-mp by the openid.
	mp := h.addPerson(t, store.IdentityWeChatMP, "open-mp-0123456789abc")
	h.wb.users["open-mp-0123456789abc"] = wxUser{OpenID: "open-mp-0123456789abc"}
	b2 := newBrowser(t, wechatUA)
	nonce = h.relayStart(t, b2)
	if resp := h.relayBack(t, b2, nonce, "open-mp-0123456789abc", "gate-secret", time.Now()); resp.Header.Get("Location") != AppPrefix {
		t.Fatalf("non-follower → %q", resp.Header.Get("Location"))
	}
	if got, via := b2.session(h.waysHarness); got != mp || via != store.IdentityWeChatMP {
		t.Fatalf("non-follower signed in %q via %q; want %s via wechat-mp", got, via, mp)
	}
}

// Someone the list does not name lands on /apply, as an applicant.
func TestWxRelayNotListedApplies(t *testing.T) {
	h := newRelayHarness(t)
	h.wb.users["open-new-0123456789ab"] = wxUser{OpenID: "open-new-0123456789ab", UnionID: "union-new", Followed: true}
	b := newBrowser(t, wechatUA)
	nonce := h.relayStart(t, b)
	resp := h.relayBack(t, b, nonce, "open-new-0123456789ab", "gate-secret", time.Now())
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != applicantPath {
		t.Fatalf("not listed → %d %q; want /apply", resp.StatusCode, resp.Header.Get("Location"))
	}
	if got, _ := b.session(h.waysHarness); got != "" {
		t.Fatalf("an applicant got a session as %s", got)
	}
	if pid, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-new"); pid != "" {
		t.Fatal("the relay made a person")
	}
}

// BREAK-IT wx-relay-forged: a callback signs someone in only with the
// relay's signature, a fresh time, the nonce THIS browser started, once.
// Each refusal goes back to /signin with ?e=, which stops the automatic hop.
func TestWxRelayRefused(t *testing.T) {
	h := newRelayHarness(t)
	h.addPerson(t, store.IdentityWeChat, "union-lx")
	const oid = "open-lx-0123456789abc"
	h.wb.users[oid] = wxUser{OpenID: oid, UnionID: "union-lx", Followed: true}
	refused := func(name string, b *browser, resp *http.Response) {
		t.Helper()
		loc := resp.Header.Get("Location")
		if resp.StatusCode != http.StatusFound || !strings.HasPrefix(loc, AppPrefix+"/signin?e=") {
			t.Fatalf("%s: %d → %q; want /signin?e=…", name, resp.StatusCode, loc)
		}
		if got, _ := b.session(h.waysHarness); got != "" {
			t.Fatalf("%s: signed in as %s", name, got)
		}
		// The note stops the hop: WeChat's browser now gets the page.
		if again, _ := b.do(http.MethodGet, h.http.URL+loc, nil); again.StatusCode != http.StatusOK {
			t.Fatalf("%s: %s = %d; want the page, not another hop", name, loc, again.StatusCode)
		}
	}
	for _, c := range []struct {
		name string
		key  string
		at   time.Duration
	}{
		{"wrong key", "not-the-gate", 0},
		{"too old", "gate-secret", -6 * time.Minute},
		{"from the future", "gate-secret", 6 * time.Minute},
	} {
		b := newBrowser(t, wechatUA)
		nonce := h.relayStart(t, b)
		refused(c.name, b, h.relayBack(t, b, nonce, oid, c.key, time.Now().Add(c.at)))
	}

	// Another browser that learned the URL: its flow cookie is not that nonce.
	a, other := newBrowser(t, wechatUA), newBrowser(t, wechatUA)
	nonce := h.relayStart(t, a)
	h.relayStart(t, other)
	refused("another browser", other, h.relayBack(t, other, nonce, oid, "gate-secret", time.Now()))
	bare := newBrowser(t, wechatUA)
	refused("no flow at all", bare, h.relayBack(t, bare, nonce, oid, "gate-secret", time.Now()))

	// The relay could not trade the code: err=, no openid.
	b := newBrowser(t, wechatUA)
	nonce = h.relayStart(t, b)
	resp, _ := b.do(http.MethodGet, h.http.URL+wxRelayCBPath+"?n="+nonce+"&err=exchange_failed", nil)
	refused("relay error", b, resp)

	// A replay of a callback that worked, in the same browser with a fresh hop.
	b = newBrowser(t, wechatUA)
	nonce = h.relayStart(t, b)
	ts := time.Now()
	if ok := h.relayBack(t, b, nonce, oid, "gate-secret", ts); ok.Header.Get("Location") != AppPrefix {
		t.Fatalf("the genuine callback → %q", ok.Header.Get("Location"))
	}
	replay := newBrowser(t, wechatUA)
	h.relayStart(t, replay)
	// The replaying browser carries a flow for ITS nonce; forge the cookie
	// for the spent one instead: still refused, the nonce is spent.
	f := `{"s":"` + nonce + `","r":"relay","e":` + strconv.FormatInt(time.Now().Add(time.Minute).Unix(), 10) + `}`
	replay.c.Jar.SetCookies(mustURL(h.http.URL+wechatFlowPath), []*http.Cookie{{Name: wechatFlowCookie, Value: signBlob([]byte(f), h.srv.sessionKey()), Path: wechatFlowPath}})
	refused("replay", replay, h.relayBack(t, replay, nonce, oid, "gate-secret", ts))
}

// The relay unset: WeChat's browser gets the code page as before, and the
// callback does not exist.
func TestWxRelayOff(t *testing.T) {
	h := newWxHarness(t)
	h.srv.WeChat.MPAppID, h.srv.WeChat.MPSecret = "", "" // the harness's own in-WeChat road, never set in prod
	b := newBrowser(t, wechatUA)
	if scene, _ := h.signinScene(t, b); !wxSceneInRange(scene) {
		t.Fatalf("scene %d", scene)
	}
	if resp, _ := b.do(http.MethodGet, h.http.URL+wxRelayCBPath+"?n=x&o=y", nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("relay-cb with the relay off = %d", resp.StatusCode)
	}
	// On, but outside WeChat: the computer still gets the code.
	h = newRelayHarness(t)
	if scene, _ := h.signinScene(t, newBrowser(t, "Mozilla/5.0 (Macintosh)")); !wxSceneInRange(scene) {
		t.Fatalf("scene %d", scene)
	}
}
