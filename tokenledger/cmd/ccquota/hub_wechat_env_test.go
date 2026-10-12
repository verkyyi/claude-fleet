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
