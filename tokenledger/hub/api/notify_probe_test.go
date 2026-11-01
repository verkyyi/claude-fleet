package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestWxNotifyDeploymentProbe(t *testing.T) {
	for _, tc := range []struct {
		name                       string
		role                       string
		followed, dry, badRegistry bool
		code                       int
		wantErr                    string
		wantSent                   int
	}{
		{name: "preflight", role: store.RoleAdmin, followed: true, dry: true},
		{name: "one real test", role: store.RoleAdmin, followed: true, wantSent: 1},
		{name: "member refused", role: store.RoleUser, followed: true, wantErr: "named administrator not found"},
		{name: "unfollowed refused", role: store.RoleAdmin, wantErr: "no followed service-account identity"},
		{name: "wrong fields refused", role: store.RoleAdmin, followed: true, badRegistry: true, wantErr: "expected title and fields"},
		{name: "wechat refusal", role: store.RoleAdmin, followed: true, code: 43004, wantErr: "errcode 43004"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newNotifyHarness(t)
			h.srv.WxGW.SubReview = "sub-review"
			h.srv.WxGW.NewReqFields = "thing1=platform,thing2=person,time4=time"
			pid, _ := newPersonPrincipal()
			if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "admin", Role: tc.role, AddedBy: "test", AddedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			if err := h.srv.Store.SetHubReach(store.HubReach{Owner: pid, Channel: store.ReachWeChatMP, Addr: "private-openid", Followed: tc.followed, UpdatedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			h.wb.set(func(f *fakeWxNotify) { f.registryBad, f.tplErr, f.echo = tc.badRegistry, tc.code, true })
			result, err := h.srv.ProbeWxNewRequest(context.Background(), "ADMIN", tc.dry)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error = %v, want %s", err, tc.wantErr)
			}
			if tpl, kf := h.wb.sent(); tpl != tc.wantSent || kf != 0 || result.Sent != (tc.wantSent == 1) {
				t.Fatalf("unexpected delivery: tpl=%d kf=%d result=%+v", tpl, kf, result)
			}
			if tc.code != 0 && result.ErrCode != tc.code {
				t.Fatalf("lost WeChat error: %+v", result)
			}
			b, _ := json.Marshal(result)
			for _, private := range []string{"private-openid", "gate-secret", "wxtok-"} {
				if strings.Contains(string(b), private) || (err != nil && strings.Contains(err.Error(), private)) {
					t.Fatal("probe leaked private data")
				}
			}
			if tc.wantSent == 1 {
				h.wb.mu.Lock()
				defer h.wb.mu.Unlock()
				body := h.wb.tpl[0]
				if body["touser"] != "private-openid" || !strings.Contains(string(b), "测试") {
					t.Fatalf("test recipient or label wrong: %+v", result)
				}
			}
		})
	}
}

func TestWxReviewDeploymentProbe(t *testing.T) {
	for _, tc := range []struct {
		name          string
		role          string
		followed, dry bool
		code          int
		wantErr       bool
		wantSent      int
	}{
		{"send", store.RoleAdmin, true, false, 0, false, 1},
		{"dry", store.RoleAdmin, true, true, 0, false, 0},
		{"member", store.RoleUser, true, false, 0, true, 0},
		{"unfollowed", store.RoleAdmin, false, false, 0, true, 0},
		{"refused", store.RoleAdmin, true, false, 43004, true, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newNotifyHarness(t)
			// No subscription configuration or JS-SDK required for fallback.
			h.srv.WxGW.SubReview = ""
			pid, _ := newPersonPrincipal()
			if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "admin", Role: tc.role, AddedBy: "test", AddedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			if err := h.srv.Store.SetHubReach(store.HubReach{Owner: pid, Channel: store.ReachWeChatMP, Addr: "private-openid", Followed: tc.followed, UpdatedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			h.wb.set(func(f *fakeWxNotify) { f.tplErr, f.echo = tc.code, true })
			result, err := h.srv.ProbeWxReview(context.Background(), "ADMIN", tc.dry)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v", err)
			}
			if tpl, kf := h.wb.sent(); tpl != tc.wantSent || kf != 0 || len(h.wb.sub) != 0 || result.Sent != (tc.wantSent == 1) {
				t.Fatalf("unexpected delivery: %+v", result)
			}
			if tc.wantSent == 1 {
				if result.Template != h.srv.WxGW.TplReview || result.Fields["thing3"] != "【测试】审批结果通知" || result.Fields["character_string14"] != "review-probe" {
					t.Fatalf("wrong review payload: %+v", result)
				}
			}
			b, _ := json.Marshal(result)
			for _, private := range []string{"private-openid", "gate-secret", "wxtok-"} {
				if strings.Contains(string(b), private) || (err != nil && strings.Contains(err.Error(), private)) {
					t.Fatal("probe leaked private data")
				}
			}
		})
	}
}
