package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet#4057 (EPIC #4048 C9): a person on the list binds the service
// account's WeChat from the console.

// memberBrowser is a browser signed in as GitHub account u, on the list.
func (h *wxHarness) memberBrowser(t *testing.T, u fakeGHUser) (*browser, string) {
	t.Helper()
	h.addUser(t, u)
	_, sess := h.signIn(t, u)
	if sess == nil {
		t.Fatalf("%s could not sign in", u.Login)
	}
	b := newBrowser(t, "")
	b.c.Jar.SetCookies(mustURL(h.http.URL+"/"), []*http.Cookie{sess})
	pid, _ := b.session(h.waysHarness)
	return b, pid
}

// bindJSON calls one of the bind routes as b: the status and the body.
func (h *wxHarness) bindJSON(t *testing.T, b *browser, method, path string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, h.http.URL+path, nil)
	req.Header.Set("Accept", "application/json")
	resp, err := b.c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

func (h *wxHarness) bindCode(t *testing.T, b *browser) int64 {
	t.Helper()
	code, out := h.bindJSON(t, b, http.MethodPost, meWxBindQRPath)
	s, _ := out["s"].(float64)
	if code != http.StatusOK || !wxSceneInRange(int64(s)) || !strings.Contains(out["qr"].(string), `<svg class="qr"`) {
		t.Fatalf("bind-qr = %d %v", code, out)
	}
	return int64(s)
}

func (h *wxHarness) bindPoll(t *testing.T, b *browser, scene int64) string {
	t.Helper()
	code, out := h.bindJSON(t, b, http.MethodGet, meWxBindPollPath+"?s="+strconv.FormatInt(scene, 10))
	if code != http.StatusOK {
		t.Fatalf("bind-poll = %d %v", code, out)
	}
	return out["s"].(string)
}

func (h *wxHarness) meReachOf(t *testing.T, b *browser) *MeReach {
	t.Helper()
	code, out := h.bindJSON(t, b, http.MethodGet, "/v1/me")
	if code != http.StatusOK {
		t.Fatalf("/v1/me = %d", code)
	}
	r, ok := out["reach"].(map[string]any)
	if !ok {
		return nil
	}
	return &MeReach{WeChat: r["wechat"] == true}
}

// A GitHub member binds: /v1/me says unreachable, the code is drawn for
// them, the poll waits, they scan, it binds — one more identity, their
// openid in hub_reach — and /v1/me says reachable. The code binds once.
func TestWxBindMember(t *testing.T) {
	h := newWxHarness(t)
	b, pid := h.memberBrowser(t, ghAlice)
	if r := h.meReachOf(t, b); r == nil || r.WeChat {
		t.Fatalf("before: reach = %+v; want {wechat:false}", r)
	}
	before, _ := h.srv.Store.HubIdentities(pid)
	scene := h.bindCode(t, b)
	if again := h.bindCode(t, b); again != scene {
		t.Fatalf("a second ask drew another code (%d → %d)", scene, again)
	}
	if st := h.bindPoll(t, b, scene); st != wxWait {
		t.Fatalf("before the scan: %s", st)
	}
	h.wb.scan(scene, "open-alice", "union-alice")
	if st := h.bindPoll(t, b, scene); st != wxBound {
		t.Fatalf("after the scan: %s", st)
	}
	after, _ := h.srv.Store.HubIdentities(pid)
	if len(after) != len(before)+1 {
		t.Fatalf("identities %d → %d; want one more", len(before), len(after))
	}
	if got, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-alice"); got != pid {
		t.Fatalf("union-alice signs in %q; want %s", got, pid)
	}
	reach, _ := h.srv.Store.HubReachOf(pid)
	if len(reach) != 1 || reach[0].Channel != store.ReachWeChatMP || reach[0].Addr != "open-alice" || !reach[0].Followed {
		t.Fatalf("reach = %+v", reach)
	}
	if r := h.meReachOf(t, b); r == nil || !r.WeChat {
		t.Fatalf("after: reach = %+v; want {wechat:true}", r)
	}
	if st := h.bindPoll(t, b, scene); st != wxExpired {
		t.Fatalf("the code bound twice: %s", st)
	}
	// Binding again (a new phone, a re-follow) is fine: it is already theirs.
	scene2 := h.bindCode(t, b)
	h.wb.scan(scene2, "open-alice", "union-alice")
	if st := h.bindPoll(t, b, scene2); st != wxBound {
		t.Fatalf("re-binding their own WeChat: %s", st)
	}
}

// A WeChat that already signs another person in is refused, never moved —
// by its unionid, or by the openid it signed in under before one was known.
func TestWxBindTakenRefused(t *testing.T) {
	h := newWxHarness(t)
	other := h.addPerson(t, store.IdentityWeChat, "union-bob")
	mp := h.addPerson(t, store.IdentityWeChatMP, "open-carol")
	b, pid := h.memberBrowser(t, ghAlice)
	for _, c := range []struct{ openid, union string }{{"open-bob", "union-bob"}, {"open-carol", "union-carol"}} {
		scene := h.bindCode(t, b)
		h.wb.scan(scene, c.openid, c.union)
		if st := h.bindPoll(t, b, scene); st != wxTaken {
			t.Fatalf("%s: %s; want taken", c.union, st)
		}
		if reach, _ := h.srv.Store.HubReachOf(pid); len(reach) != 0 {
			t.Fatalf("%s: a refused bind kept reach %+v", c.union, reach)
		}
	}
	if got, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-bob"); got != other {
		t.Fatalf("union-bob moved to %q", got)
	}
	if got, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-carol"); got != "" {
		t.Fatalf("union-carol hung on %q; carol's openid is %s's", got, mp)
	}
	if !h.auditHas(t, "identity.add", "refused", "(wechat)") {
		t.Fatal("no refused identity.add in the audit")
	}
}

// A bind code is the person's who drew it, in the browser that drew it: not
// another browser that learned its number, not a login code's poll, and not
// whoever is signed in in that browser later.
func TestWxBindCodeIsTheirs(t *testing.T) {
	h := newWxHarness(t)
	a, _ := h.memberBrowser(t, ghAlice)
	scene := h.bindCode(t, a)
	h.wb.scan(scene, "open-x", "union-x")
	other, _ := h.memberBrowser(t, ghMallory)
	if st := h.bindPoll(t, other, scene); st != wxExpired {
		t.Fatalf("another browser polled it: %s", st)
	}
	if st := h.pollJSON(t, a, scene); st != wxExpired {
		t.Fatalf("the login poll read a bind code: %s", st)
	}
	// The same browser, now signed in as someone else.
	_, sess := h.signIn(t, ghMallory)
	a.c.Jar.SetCookies(mustURL(h.http.URL+"/"), []*http.Cookie{sess})
	if st := h.bindPoll(t, a, scene); st != wxExpired {
		t.Fatalf("a later sign-in in the same browser bound it: %s", st)
	}
	if got, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-x"); got != "" {
		t.Fatalf("union-x hung on %q", got)
	}
}

// Off: the routes 404 and /v1/me carries no reach, byte for byte as before.
func TestWxBindOff(t *testing.T) {
	h := newWxHarness(t)
	h.srv.WxGW = nil
	b, _ := h.memberBrowser(t, ghAlice)
	if r := h.meReachOf(t, b); r != nil {
		t.Fatalf("reach with the road off: %+v", r)
	}
	for _, c := range []struct{ m, p string }{{http.MethodPost, meWxBindQRPath}, {http.MethodGet, meWxBindPollPath + "?s=3000001"}} {
		if code, _ := h.bindJSON(t, b, c.m, c.p); code != http.StatusNotFound {
			t.Fatalf("%s %s = %d; want 404", c.m, c.p, code)
		}
	}
	// Signed out: the gate, never the handler.
	if code, _ := h.bindJSON(t, newBrowser(t, ""), http.MethodPost, meWxBindQRPath); code != http.StatusUnauthorized && code != http.StatusFound {
		t.Fatalf("signed out = %d", code)
	}
}
