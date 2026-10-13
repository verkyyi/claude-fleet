package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func envOf(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestNotifyOffSendsNothing(t *testing.T) {
	for _, env := range []map[string]string{{}, {"FLEET_NOTIFY_WEBHOOK": ""}} {
		r, err := notifyPlan(envOf(env), "svc_degraded svc:livepage")
		if r != nil || err != nil {
			t.Fatalf("%v: want nothing, got %+v %v", env, r, err)
		}
	}
	r, err := notifyPlan(envOf(map[string]string{"FLEET_NOTIFY_WEBHOOK": "https://api.day.app/K"}), "  ")
	if r != nil || err != nil {
		t.Fatalf("an empty message: want nothing, got %+v %v", r, err)
	}
}

func TestNotifyKfNotify(t *testing.T) {
	var got map[string]string
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/notify" || r.Method != http.MethodPost {
			http.Error(w, "no", 404)
			return
		}
		auth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &got)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	env := envOf(map[string]string{"FLEET_NOTIFY_KF_URL": srv.URL + "/", "FLEET_NOTIFY_KF_KEY": "kfkey",
		"FLEET_NOTIFY_KF_TO": "YiLiangHui", "FLEET_NOTIFY_KF_SOURCE": "fleet:svc",
		// a webhook beside it loses: kf-notify first
		"FLEET_NOTIFY_WEBHOOK": "https://api.day.app/K"})
	r, err := notifyPlan(env, "fleet alert: svc_degraded svc:livepage\n3 of 5 failed: infra_error 3")
	if err != nil || r == nil {
		t.Fatal(r, err)
	}
	if err := notifySend(context.Background(), srv.Client(), r); err != nil {
		t.Fatal(err)
	}
	if auth != "Bearer kfkey" {
		t.Fatalf("auth %q", auth)
	}
	want := map[string]string{"dest": "person", "to": "YiLiangHui", "source": "fleet:svc", "severity": "error",
		"title": "fleet alert: svc_degraded svc:livepage", "body": "3 of 5 failed: infra_error 3"}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("%s = %q, want %q (%v)", k, got[k], v, got)
		}
	}
	if !strings.HasPrefix(got["dedupKey"], "fleet:") {
		t.Fatalf("dedupKey %q", got["dedupKey"])
	}
}

func TestNotifyKfRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		w.Write([]byte(`{"error":"key fleet 无权发到 person"}`))
	}))
	defer srv.Close()
	r, _ := notifyPlan(envOf(map[string]string{"FLEET_NOTIFY_KF_URL": srv.URL, "FLEET_NOTIFY_KF_KEY": "SECRETKEY"}), "x")
	err := notifySend(context.Background(), srv.Client(), r)
	if err == nil || !strings.Contains(err.Error(), "403") || strings.Contains(err.Error(), "SECRETKEY") {
		t.Fatalf("want a 403 naming no key, got %v", err)
	}
	if _, err := notifyPlan(envOf(map[string]string{"FLEET_NOTIFY_KF_URL": srv.URL}), "x"); err == nil {
		t.Fatal("a kf-notify address with no key must be refused")
	}
}

func TestNotifyWebhookKinds(t *testing.T) {
	for _, c := range []struct{ hook, want string }{
		{"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k", `{"markdown":{"content":"a \"b\"\nc"},"msgtype":"markdown"}`},
		{"https://open.feishu.cn/open-apis/bot/v2/hook/x", `{"content":{"text":"a \"b\"\nc"},"msg_type":"text"}`},
		{"https://api.day.app/KEY", `{"body":"a \"b\"\nc","group":"fleet","title":"a \"b\""}`},
		{"https://hooks.example.com/x", `{"text":"a \"b\"\nc"}`},
	} {
		r, err := notifyPlan(envOf(map[string]string{"FLEET_NOTIFY_WEBHOOK": c.hook}), "a \"b\"\nc")
		if err != nil || r == nil || string(r.body) != c.want || r.auth != "" || r.url != c.hook {
			t.Fatalf("%s: got %+v %v, want body %s", c.hook, r, err, c.want)
		}
	}
	if _, err := notifyPlan(envOf(map[string]string{"FLEET_NOTIFY_WEBHOOK": "http://hooks.example.com/x"}), "x"); err == nil {
		t.Fatal("an http:// webhook must be refused")
	}
}
