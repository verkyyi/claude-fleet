package authz

import (
	"strings"
	"testing"
	"time"
)

const sessSecret = "dev-only-set-ccquota-session-golden"

// ★★★ 审计分层，双向：一张入场票绝不能当会话 cookie 使，一张会话 cookie 也绝不能
// 冒充入场票。两者用同一种编码、可能还共用一把泄露的密钥 —— 把它们分开的只有 aud，
// 所以两个方向都要真的拒。kf-context 的 verifySession/verifyScoped 就是这么成对写的。
func TestSession_TicketAndCookieCannotImpersonateEachOther(t *testing.T) {
	now := at(goldenIAT)
	// 用同一把密钥签的入场票，拿去当 cookie 验。
	tok := signForTest(t, payloadJSON(`{"iss":"kf-context","aud":"ccquota","sub":"u","ten":"t","iat":%d,"exp":%d}`, goldenIAT), sessSecret)
	if _, err := VerifySession(tok, sessSecret, now); err == nil {
		t.Error("入场票被当成会话 cookie 收下了")
	}
	// 反方向：会话 cookie 拿去当入场票验。
	cookie := SignSession("u", sessSecret, now, time.Hour)
	if _, err := Verify(cookie, sessSecret, "ccquota", now); err == nil {
		t.Error("会话 cookie 被当成入场票收下了")
	}
}

func TestSession_RoundTrip(t *testing.T) {
	now := at(goldenIAT)
	s, err := VerifySession(SignSession("lee", sessSecret, now, time.Hour), sessSecret, now)
	if err != nil {
		t.Fatalf("自己签的验不回来: %v", err)
	}
	if s.Sub != "lee" {
		t.Fatalf("sub = %q, want lee", s.Sub)
	}
}

// 会话有自己的寿命，且**不吃票那 30 秒的时钟余量** —— 余量是给「两台机器之间传一张
// 90 秒的票」用的，给一张 8 小时的 cookie 续 30 秒没有任何意义，只是把过期这件事
// 变得说不清。
func TestSession_ExpiresExactly(t *testing.T) {
	now := at(goldenIAT)
	c := SignSession("lee", sessSecret, now, time.Hour)
	if _, err := VerifySession(c, sessSecret, at(goldenIAT+3599)); err != nil {
		t.Errorf("还没到期就被拒: %v", err)
	}
	if _, err := VerifySession(c, sessSecret, at(goldenIAT+3601)); err == nil {
		t.Error("过期 cookie 仍被放行")
	}
}

func TestSession_RejectsTamperedOrForeignKey(t *testing.T) {
	now := at(goldenIAT)
	c := SignSession("lee", sessSecret, now, time.Hour)
	body, _, _ := strings.Cut(c, ".")
	for name, bad := range map[string]string{
		"换签名": body + ".ZmFrZQ",
		"没有点": body,
		"空串":  "",
		"只有点": ".",
	} {
		if _, err := VerifySession(bad, sessSecret, now); err != ErrTicket {
			t.Errorf("%s: 回了 %v，want ErrTicket", name, err)
		}
	}
	if _, err := VerifySession(c, "dev-only-set-some-other-key", now); err != ErrTicket {
		t.Error("用别的密钥也验得过")
	}
	if _, err := VerifySession(c, "", now); err != ErrTicket {
		t.Error("没配密钥却放行了")
	}
}
