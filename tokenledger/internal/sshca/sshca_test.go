package sshca

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func newCA(t *testing.T) *CA {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return New(s)
}

func userKey(t *testing.T) (ssh.PublicKey, string) {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return pk, strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pk))) + " alice@laptop"
}

// The certificate says exactly what the issue fixes: the person's login as
// its only principal, twelve hours, a key id naming the WeCom userid — and an
// sshd trusting the CA admits it as that login and nobody else.
func TestSignPrincipalsValidityKeyID(t *testing.T) {
	ca := newCA(t)
	_, line := userKey(t)
	key, err := ParseUserKey(line)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	iss, err := ca.Sign(Request{Key: key, PrincipalID: "WangXiaoMing", Logins: []string{"wangxiaoming"}}, now)
	if err != nil {
		t.Fatal(err)
	}
	c := iss.Cert
	if c.CertType != ssh.UserCert {
		t.Fatalf("cert type %d, want user", c.CertType)
	}
	if len(c.ValidPrincipals) != 1 || c.ValidPrincipals[0] != "wangxiaoming" {
		t.Fatalf("principals %v", c.ValidPrincipals)
	}
	if got := time.Unix(int64(c.ValidBefore), 0).Sub(now); got != 12*time.Hour {
		t.Fatalf("valid for %v after issue, want 12h", got)
	}
	if after := time.Unix(int64(c.ValidAfter), 0); !after.Before(now) || now.Sub(after) > 2*time.Minute {
		t.Fatalf("valid_after %v: want a small back-date from %v", after, now)
	}
	if !strings.HasPrefix(c.KeyId, "fleet:WangXiaoMing:wangxiaoming:") || iss.KeyID != c.KeyId {
		t.Fatalf("key id %q", c.KeyId)
	}
	if len(c.CriticalOptions) != 0 {
		t.Fatalf("critical options %v: none expected", c.CriticalOptions)
	}

	// Round-trip the written line and check it the way sshd does.
	parsed, _, _, _, err := ssh.ParseAuthorizedKey([]byte(iss.Line))
	if err != nil {
		t.Fatalf("written certificate does not parse: %v", err)
	}
	pc := parsed.(*ssh.Certificate)
	checker := &ssh.CertChecker{
		IsUserAuthority: func(auth ssh.PublicKey) bool {
			return string(auth.Marshal()) == string(ca.signer.PublicKey().Marshal())
		},
		Clock: func() time.Time { return now.Add(time.Hour) },
	}
	if err := checker.CheckCert("wangxiaoming", pc); err != nil {
		t.Fatalf("sshd-style check refused a fresh certificate: %v", err)
	}
	if err := checker.CheckCert("verkyyi", pc); err == nil {
		t.Fatal("certificate admitted a login that is not its principal")
	}
	checker.Clock = func() time.Time { return now.Add(12*time.Hour + time.Second) }
	if err := checker.CheckCert("wangxiaoming", pc); err == nil {
		t.Fatal("an expired certificate was accepted")
	}
	// Who signed it is what TrustedUserCAKeys judges (CheckCert does not).
	if string(pc.SignatureKey.Marshal()) != string(ca.signer.PublicKey().Marshal()) {
		t.Fatal("certificate is not signed by the hub's CA")
	}
	if other := newCA(t); string(pc.SignatureKey.Marshal()) == string(other.signer.PublicKey().Marshal()) {
		t.Fatal("certificate matches another CA")
	}
}

func TestSerialsDiffer(t *testing.T) {
	ca := newCA(t)
	k, _ := userKey(t)
	a, _ := ca.Sign(Request{Key: k, PrincipalID: "p", Logins: []string{"p"}}, time.Now())
	b, _ := ca.Sign(Request{Key: k, PrincipalID: "p", Logins: []string{"p"}}, time.Now())
	if a.Serial == b.Serial {
		t.Fatal("two certificates share a serial")
	}
}

func TestSignRefusesEmpty(t *testing.T) {
	ca := newCA(t)
	k, _ := userKey(t)
	if _, err := ca.Sign(Request{Key: k, PrincipalID: "p"}, time.Now()); err == nil {
		t.Fatal("signed a certificate with no principal login")
	}
	if _, err := ca.Sign(Request{Key: k, Logins: []string{"p"}}, time.Now()); err == nil {
		t.Fatal("signed a certificate for no one")
	}
}

func TestParseUserKey(t *testing.T) {
	ca := newCA(t)
	k, line := userKey(t)
	iss, _ := ca.Sign(Request{Key: k, PrincipalID: "p", Logins: []string{"p"}}, time.Now())
	for name, in := range map[string]string{
		"empty":       "",
		"garbage":     "hello",
		"two lines":   line + "\n" + line,
		"options":     `command="/bin/sh" ` + line,
		"certificate": iss.Line,
		"oversize":    strings.Repeat("A", MaxPublicKeyLen+1),
	} {
		if _, err := ParseUserKey(in); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := ParseUserKey("  " + line + "\n"); err != nil {
		t.Fatalf("a plain key line with surrounding space: %v", err)
	}
}

func TestValidCAPublicKey(t *testing.T) {
	ca := newCA(t)
	if !ValidCAPublicKey(ca.PublicKey()) {
		t.Fatalf("own public key refused: %q", ca.PublicKey())
	}
	for _, bad := range []string{"", ca.PublicKey() + "\nssh-ed25519 AAAA", "cert-authority " + ca.PublicKey(), "nope"} {
		if ValidCAPublicKey(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestParsePEM(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	block, err := ssh.MarshalPrivateKey(priv, "fleet ca")
	if err != nil {
		t.Fatal(err)
	}
	ca, err := Parse(pemEncode(block.Type, block.Bytes))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(ca.Fingerprint(), "SHA256:") {
		t.Fatalf("fingerprint %q", ca.Fingerprint())
	}
	if _, err := Parse([]byte("not a key")); err == nil {
		t.Fatal("parsed garbage as a CA key")
	}
}
