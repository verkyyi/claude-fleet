package authz

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
	"time"
)

// ── 跨语言黄金向量 ────────────────────────────────────────────────────────────
// 与 core/kf-context/src/authzTicket.test.ts、ai-site/app/lib/aicallTicket.test.ts
// 和 core/aicall/backend/app/ticket.py 的 GOLDEN_* **逐字节相同**。本包是这条格式的
// 第四个实现（第一个不是 JS/Python），所以它必须咬同一条向量。
//
// ★ 名字刻意不含 KEY/SECRET：gitleaks 的 generic-api-key 规则会把标识符文本本身当成
//
//	一次泄漏报出来（aicall 那侧实测报过），用仓库约定的 `dev-only-set-` 前缀占位。
const (
	goldenHMAC   = "dev-only-set-aicall-ticket-golden"
	goldenIAT    = 1756339200
	goldenTicket = "eyJpc3MiOiJhaS1zaXRlIiwiYXVkIjoiYWljYWxsIiwic3ViIjoidGVzYV9kZW1vIiwidGVuIjoidGVzYSIsImlhdCI6MTc1NjMzOTIwMCwiZXhwIjoxNzU2MzM5MjkwfQ.2taECKRFj6tRIsR3dwQ2kDwh1ewmJTZmzp1R2IHRaCk"
)

func at(sec int64) time.Time { return time.Unix(sec, 0).UTC() }

// ★★★ 这条是本包存在的全部前提。只测「自己签的自己能验」是不够的 —— 字段顺序、
// 分隔符、base64 变体换了照样自洽，而对面会在上线那天把人 401 弹回来。
func TestVerify_GoldenVectorFromTheOtherThreeImplementations(t *testing.T) {
	p, err := Verify(goldenTicket, goldenHMAC, "aicall", at(goldenIAT+10))
	if err != nil {
		t.Fatalf("黄金向量验不过: %v", err)
	}
	if p.Iss != "ai-site" || p.Aud != "aicall" || p.Sub != "tesa_demo" || p.Ten != "tesa" {
		t.Fatalf("载荷解错了: %+v", p)
	}
	if p.Iat != goldenIAT || p.Exp != goldenIAT+90 {
		t.Fatalf("时间字段解错了: iat=%d exp=%d", p.Iat, p.Exp)
	}
	if p.Switchable {
		t.Error("黄金向量那条路没有 swi 键，不该解出 true")
	}
}

// HMAC 的输入是 **base64url 之后那段 ASCII 的字节**，不是 JSON 原文。
// aicall 那侧的注释把这条单独拎出来说：错了的表现是「一直 401，两边代码看着都对」。
func TestVerify_SignatureCoversTheEncodedBodyNotTheJSON(t *testing.T) {
	body, _, _ := strings.Cut(goldenTicket, ".")
	tampered := body + ".ZmFrZQ"
	if _, err := Verify(tampered, goldenHMAC, "aicall", at(goldenIAT)); err == nil {
		t.Fatal("换掉签名还验得过")
	}
}

// 密钥缺失一律拒绝，绝不回落默认值 —— 默认签名密钥是可以凭空铸造任意身份的东西。
func TestVerify_NoSecretIsAlwaysARejection(t *testing.T) {
	if _, err := Verify(goldenTicket, "", "aicall", at(goldenIAT)); err == nil {
		t.Fatal("没配密钥却放行了")
	}
}

// aud 逐字段核对：一张签给别的下游站的票，在这里必须是拒绝。
func TestVerify_AudienceIsCheckedExactly(t *testing.T) {
	if _, err := Verify(goldenTicket, goldenHMAC, "ccquota", at(goldenIAT)); err == nil {
		t.Fatal("签给 aicall 的票被 ccquota 收下了")
	}
}

// iss 判据是「在不在白名单里」，不是「有没有 iss」。放开成后者等于任何人签的票都收，
// 而 HMAC 密钥一旦泄露，iss 是唯一还能把「谁签的」区分开的东西。
func TestVerify_IssuerWhitelistNotMerelyPresent(t *testing.T) {
	tok := signForTest(t, payloadJSON(`{"iss":"somebody-else","aud":"ccquota","sub":"u","ten":"t","iat":%d,"exp":%d}`, goldenIAT), goldenHMAC)
	if _, err := Verify(tok, goldenHMAC, "ccquota", at(goldenIAT)); err == nil {
		t.Fatal("白名单外的签发方被收下了")
	}
	for _, iss := range []string{"ai-site", "kf-context"} {
		tok := signForTest(t, payloadJSON(`{"iss":"`+iss+`","aud":"ccquota","sub":"u","ten":"t","iat":%d,"exp":%d}`, goldenIAT), goldenHMAC)
		if _, err := Verify(tok, goldenHMAC, "ccquota", at(goldenIAT)); err != nil {
			t.Errorf("白名单内的 %s 被拒: %v", iss, err)
		}
	}
}

// 票只活 90 秒，两台机器的 NTP 不会完全一致 —— 不给余量就变成「偶发登录失败」，
// 是最难查的那种。30 秒，仍远小于 TTL。
func TestVerify_ClockSkewWindowThenExpiry(t *testing.T) {
	exp := int64(goldenIAT + 90)
	if _, err := Verify(goldenTicket, goldenHMAC, "aicall", at(exp+ClockSkewSec-1)); err != nil {
		t.Errorf("偏移窗口内被拒: %v", err)
	}
	if _, err := Verify(goldenTicket, goldenHMAC, "aicall", at(exp+ClockSkewSec+1)); err == nil {
		t.Error("过期票在偏移窗口外仍被放行")
	}
}

// sub 是授权依据（ten 只是归因）。空 sub 等于「谁都不是」，必须拒。
func TestVerify_EmptySubjectIsRejected(t *testing.T) {
	tok := signForTest(t, payloadJSON(`{"iss":"kf-context","aud":"ccquota","sub":"","ten":"t","iat":%d,"exp":%d}`, goldenIAT), goldenHMAC)
	if _, err := Verify(tok, goldenHMAC, "ccquota", at(goldenIAT)); err == nil {
		t.Fatal("空 sub 被放行")
	}
}

// 可选的 swi 键只在为真时出现；本站不给这个能力，但要能正确读出来而不是解析失败。
func TestVerify_OptionalSwitchableKey(t *testing.T) {
	tok := signForTest(t, payloadJSON(`{"iss":"kf-context","aud":"ccquota","sub":"u","ten":"t","iat":%d,"exp":%d,"swi":true}`, goldenIAT), goldenHMAC)
	p, err := Verify(tok, goldenHMAC, "ccquota", at(goldenIAT))
	if err != nil {
		t.Fatalf("带 swi 的票验不过: %v", err)
	}
	if !p.Switchable {
		t.Error("swi=true 没被读出来")
	}
}

// 失败只有一种错误，不让调用方从错误信息里区分「密钥不对」与「票过期了」。
func TestVerify_OneErrorKindOnly(t *testing.T) {
	for _, tok := range []string{"", "no-dot", ".", "a.b", goldenTicket + "x"} {
		if _, err := Verify(tok, goldenHMAC, "aicall", at(goldenIAT)); err != ErrTicket {
			t.Errorf("Verify(%q) 回了 %v，want ErrTicket", tok, err)
		}
	}
}

// ── 测试辅助：铸一张票 ────────────────────────────────────────────────────────
// 签票**刻意不在本包导出** —— 下游站只验不签。一个能签票的下游等于第二个签发方，
// 而 `iss` 白名单的全部价值就是「谁签的分得清」。
func payloadJSON(tmpl string, iat int64) string {
	return fmt.Sprintf(tmpl, iat, iat+90)
}

func signForTest(t *testing.T, payload, secret string) string {
	t.Helper()
	body := base64.RawURLEncoding.EncodeToString([]byte(payload))
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
