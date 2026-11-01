package api

import (
	"context"
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestReviewSubscriptionDelivery(t *testing.T) {
	for _, tc := range []struct {
		name            string
		grant, followed bool
		code            int
		prefer, via     string
	}{
		{"accepted", true, true, 0, store.NotifyWeChat, viaSubscribe},
		{"not-following", true, false, 0, store.NotifyWeChat, viaSubscribe},
		{"not-authorized", false, true, 0, store.NotifyWeChat, viaTemplate},
		{"not-authorized-mail", false, false, 0, store.NotifyWeChat, viaMail},
		{"wechat-refused", true, true, 43101, store.NotifyWeChat, viaTemplate},
		{"refused-mail", true, false, 43101, store.NotifyWeChat, viaMail},
		{"email-preference", true, true, 0, store.NotifyEmail, viaMail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newNotifyHarness(t)
			h.srv.WxGW.SubReview = "sub-review"
			h.wb.subErr = tc.code
			h.applicant(t, "rq-sub", store.IdentityWeChat, "union-sub", store.NotifyWeChat, "test@example.com", "openid-sub", tc.followed, time.Now())
			if tc.grant {
				if ok, err := h.srv.Store.GrantRequestSubscribe("rq-sub", store.IdentityWeChat, "union-sub", "openid-sub", "sub-review"); err != nil || !ok {
					t.Fatalf("grant %v %v", ok, err)
				}
			}
			h.decide(t, "rq-sub", store.RequestApproved, "")
			n := *h.notice(t, "nt-review-rq-sub")
			n.Prefer = tc.prefer
			n.Email = "test@example.com"
			h.srv.deliverNotice(context.Background(), n, time.Now())
			if got := h.notice(t, n.ID); got.Channel != tc.via {
				t.Fatalf("got %+v", got)
			}
			if !tc.grant && len(h.wb.sub) != 0 {
				t.Fatal("subscription attempted without consent")
			}
			if tc.via == viaSubscribe {
				b, _ := json.Marshal(h.wb.sub[0])
				text := string(b)
				for _, want := range []string{`"page":"https://fleet.example/apply"`, `"phrase5":{"value":"已通过"}`, `"character_string19":{"value":"rq-sub"}`, `"touser":"openid-sub"`} {
					if !strings.Contains(text, want) {
						t.Fatalf("payload %s missing %s", text, want)
					}
				}
				if len(h.wb.tpl) != 0 {
					t.Fatal("sent a duplicate fallback")
				}
			}
			if tc.grant && tc.prefer == store.NotifyWeChat {
				if id, err := h.srv.Store.ClaimRequestSubscribe("rq-sub", "sub-review"); err != nil || id != "" {
					t.Fatalf("grant reused %q %v", id, err)
				}
				if ok, err := h.srv.Store.GrantRequestSubscribe("rq-sub", store.IdentityWeChat, "union-sub", "openid-sub", "sub-review"); err != nil || ok {
					t.Fatalf("decided grant rearmed %v %v", ok, err)
				}
			}
		})
	}
}

func TestApplySubscribeOwnershipAndPage(t *testing.T) {
	h := newNotifyHarness(t)
	h.srv.WxGW.SubReview = "sub-review"
	h.srv.FleetPublicURL = h.http.URL
	h.applicant(t, "rq-sub", store.IdentityWeChat, "union-sub", store.NotifyWeChat, "", "openid-sub", false, time.Now())
	ac := newApplyClient(t, h.ghHarness, store.IdentityWeChat, "union-sub", "申请人", "")
	page, _ := http.NewRequest("GET", h.http.URL+"/apply?lang=zh", nil)
	page.Header.Set("User-Agent", "MicroMessenger")
	resp, err := ac.c.Do(page)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(b), `template="sub-review"`) || !strings.Contains(resp.Header.Get("Content-Security-Policy"), "https://res.wx.qq.com") {
		t.Fatalf("page %d %s", resp.StatusCode, b)
	}
	if resp, body := ac.do("GET", "/apply?lang=zh", nil); resp.StatusCode != 200 || strings.Contains(body, "wx-open-subscribe") {
		t.Fatal("non-WeChat page exposed subscription entry")
	}
	form := url.Values{"id": {"rq-sub"}, "template": {"sub-review"}}
	other := newApplyClient(t, h.ghHarness, store.IdentityWeChat, "other", "other", "")
	if resp, _ := other.do("POST", applySubscribePath, form); resp.StatusCode != 404 {
		t.Fatalf("other: %d", resp.StatusCode)
	}
	bad, _ := http.NewRequest("POST", h.http.URL+applySubscribePath, strings.NewReader(form.Encode()))
	bad.Header.Set("Origin", "https://evil.example")
	bad.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err = ac.c.Do(bad)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("csrf: %d", resp.StatusCode)
	}
	for i := 0; i < 2; i++ {
		if resp, b := ac.do("POST", applySubscribePath, form); resp.StatusCode != 204 {
			t.Fatalf("own %d %s", resp.StatusCode, b)
		}
	}
	if id, err := h.srv.Store.ClaimRequestSubscribe("rq-sub", "other-template"); err != nil || id != "" {
		t.Fatalf("wrong template %q %v", id, err)
	}
	if id, err := h.srv.Store.ClaimRequestSubscribe("rq-sub", "sub-review"); err != nil || id != "openid-sub" {
		t.Fatalf("claim %q %v", id, err)
	}
	ac.do("POST", applySubscribePath, form)
	if id, _ := h.srv.Store.ClaimRequestSubscribe("rq-sub", "sub-review"); id != "" {
		t.Fatal("browser replay rearmed consumed grant")
	}
	h.decide(t, "rq-sub", store.RequestRejected, "reason")
	if resp, _ := ac.do("POST", applySubscribePath, form); resp.StatusCode != 409 {
		t.Fatalf("decided: %d", resp.StatusCode)
	}
}

func TestSubscribeSDKSignatureAndNewRequestFields(t *testing.T) {
	h := newNotifyHarness(t)
	page := "https://fleet.example/apply?lang=zh&edit=1"
	c, err := h.srv.WxGW.sdkConfig(context.Background(), page)
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("%x", sha1.Sum([]byte(fmt.Sprintf("jsapi_ticket=test-js-ticket&noncestr=%s&timestamp=%d&url=%s", c.Nonce, c.Timestamp, page))))
	if c.Signature != want {
		t.Fatal("signature differs")
	}
	h.srv.WxGW.NewReqFields = "thing1=platform,thing2=person,time4=time"
	data := h.srv.newReqTemplateFields(map[string]string{"thing1": Brand, "thing2": "申请人", "time6": "2026-11-01 10:20:30", "character_string10": "1"})
	if len(data) != 3 || data["time4"] != "2026-11-01 10:20:30" || data["thing2"] != "申请人" {
		t.Fatalf("fields %+v", data)
	}
}
