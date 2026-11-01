package main

import "testing"

// The WeChat endpoints follow CCQUOTA_WECHAT_AUTHORIZE_BASE / _API_BASE so the
// no-GitHub e2e can stand WeChat up on 127.0.0.1 (claude-fleet#3605); unset is
// the real ones (empty fields).
func TestWeChatEndpointsFromEnv(t *testing.T) {
	env := map[string]string{"CCQUOTA_WECHAT_WEB_APPID": "wxa", "CCQUOTA_WECHAT_WEB_SECRET": "s"}
	get := func(k string) string { return env[k] }
	wx, _, err := otherWaysFromEnv(get)
	if err != nil || wx == nil {
		t.Fatalf("wechat off: %v", err)
	}
	if wx.AuthorizeBase != "" || wx.APIBase != "" {
		t.Fatalf("unset endpoints should stay empty (the real ones): %q %q", wx.AuthorizeBase, wx.APIBase)
	}
	env["CCQUOTA_WECHAT_AUTHORIZE_BASE"] = " http://127.0.0.1:1/ "
	env["CCQUOTA_WECHAT_API_BASE"] = "http://127.0.0.1:2"
	if wx, _, _ = otherWaysFromEnv(get); wx.AuthorizeBase != "http://127.0.0.1:1/" || wx.APIBase != "http://127.0.0.1:2" {
		t.Fatalf("endpoints not taken from the env: %q %q", wx.AuthorizeBase, wx.APIBase)
	}
}

// The service account's road (claude-fleet#4054) is on only with both the
// workbench URL and its gate; half set is off, never a refusal to start.
func TestWxGatewayFromEnv(t *testing.T) {
	env := map[string]string{}
	get := func(k string) string { return env[k] }
	if g := wxGatewayFromEnv(get); g != nil {
		t.Fatalf("nothing set: %+v", g)
	}
	env["CCQUOTA_WX_INTERNAL_URL"] = "http://workbench/internal/wx"
	if g := wxGatewayFromEnv(get); g != nil {
		t.Fatal("URL without the token turned the road on")
	}
	env["CCQUOTA_WX_INTERNAL_TOKEN"] = " t0k "
	g := wxGatewayFromEnv(get)
	if g == nil || g.URL != "http://workbench/internal/wx" || g.Token != "t0k" || g.AppID != "" || g.RelayURL != "" {
		t.Fatalf("both set: %+v", g)
	}
	// The in-app relay (claude-fleet#4055) rides the same gateway.
	env["CCQUOTA_WX_RELAY_URL"] = " https://ac.ssl.24gmweb.com/node_w/wx/oauth/relay "
	if g := wxGatewayFromEnv(get); g == nil || g.RelayURL != "https://ac.ssl.24gmweb.com/node_w/wx/oauth/relay" || g.RelayTarget != "" {
		t.Fatalf("relay set: %+v", g)
	}
	env["CCQUOTA_WX_SUB_REVIEW"] = "subscription-id"
	env["CCQUOTA_WX_TPL_NEWREQ_FIELDS"] = "thing1=platform,thing2=person,time4=time"
	env["CCQUOTA_WX_INTERNAL_TOKEN"] = "gate"
	if g := wxGatewayFromEnv(get); g.SubReview != "subscription-id" || g.NewReqFields != env["CCQUOTA_WX_TPL_NEWREQ_FIELDS"] {
		t.Fatal("subscription and replacement template fields not loaded")
	}
	delete(env, "CCQUOTA_WX_INTERNAL_TOKEN")
	if g := wxGatewayFromEnv(get); g != nil {
		t.Fatal("the relay turned on without the gate token that checks its signature")
	}
}
