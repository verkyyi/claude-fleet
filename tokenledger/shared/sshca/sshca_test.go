package sshca

import (
	"crypto/ed25519"
	"encoding/pem"
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
// its only principal, twelve hours, a key id naming the person — and an
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
	if c.KeyId != "person:WangXiaoMing" || iss.KeyID != c.KeyId {
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
	if err := checker.CheckCert("erin", pc); err == nil {
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

// A peer certificate (claude-fleet#1626): one login, five minutes at most,
// a key id naming source, target and purpose, no agent forwarding.
func TestSignPeer(t *testing.T) {
	ca := newCA(t)
	k, _ := userKey(t)
	now := time.Date(2026, 10, 5, 8, 0, 0, 0, time.UTC)
	iss, err := ca.SignPeer(PeerRequest{Key: k, Source: "carol@mac-b", Target: "carol@mac-a", Purpose: "view", Login: "carol", TTL: time.Hour}, now)
	if err != nil {
		t.Fatal(err)
	}
	c := iss.Cert
	if got := time.Unix(int64(c.ValidBefore), 0).Sub(now); got != PeerTTL {
		t.Fatalf("lives %v; want PeerTTL (asked an hour)", got)
	}
	if c.KeyId != "peer:carol@mac-b>carol@mac-a:view" || len(c.ValidPrincipals) != 1 || c.ValidPrincipals[0] != "carol" {
		t.Fatalf("key id %q principals %v", c.KeyId, c.ValidPrincipals)
	}
	if _, ok := c.Permissions.Extensions["permit-agent-forwarding"]; ok {
		t.Fatal("agent forwarding on a peer certificate")
	}
	if _, ok := c.Permissions.Extensions["permit-pty"]; !ok {
		t.Fatal("no pty: a remote view could not attach")
	}
	short, _ := ca.SignPeer(PeerRequest{Key: k, Source: "a", Target: "b", Purpose: "move", Login: "carol", TTL: 30 * time.Second}, now)
	if got := short.ValidBefore.Sub(now); got != 30*time.Second {
		t.Fatalf("asked 30s, lives %v", got)
	}
	for _, bad := range []PeerRequest{
		{Key: k, Source: "a", Target: "b", Purpose: "view"},
		{Key: k, Target: "b", Purpose: "view", Login: "x"},
		{Key: k, Source: "a", Purpose: "view", Login: "x"},
		{Key: k, Source: "a", Target: "b", Login: "x"},
		{Source: "a", Target: "b", Purpose: "view", Login: "x"},
	} {
		if _, err := ca.SignPeer(bad, now); err == nil {
			t.Errorf("signed %+v", bad)
		}
	}
}

// The door-session CA (A5SQ): computed from the CA's own private key, the
// same on every load, its own key — a certificate of one is never the other's.
func TestDeriveIsStableAndApart(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	blk, err := ssh.MarshalPrivateKey(priv, "")
	if err != nil {
		t.Fatal(err)
	}
	a, err := Parse(pem.EncodeToMemory(blk))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Parse(pem.EncodeToMemory(blk))
	da, err := a.Derive("door-session")
	if err != nil {
		t.Fatal(err)
	}
	db, _ := b.Derive("door-session")
	if da.PublicKey() != db.PublicKey() {
		t.Fatal("the same CA key derived two door-session CAs")
	}
	if da.PublicKey() == a.PublicKey() {
		t.Fatal("the door-session CA is the CA itself")
	}
	if other, _ := a.Derive("other"); other.PublicKey() == da.PublicKey() {
		t.Fatal("two labels, one CA")
	}
	n, _ := newCA(t).Derive("door-session")
	if n.PublicKey() == da.PublicKey() {
		t.Fatal("two CA keys, one door-session CA")
	}
}

// A door-session certificate: one principal, two minutes, loopback only, a
// key id naming the person and the session, no agent forwarding.
func TestSignDoorSession(t *testing.T) {
	ca, _ := newCA(t).Derive("door-session")
	key, _ := userKey(t)
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	iss, err := ca.SignDoorSession(DoorSessionRequest{Key: key, Principal: "gh:1", Login: "alice", Session: "ab12cd34", TTL: 2 * time.Minute}, now)
	if err != nil {
		t.Fatal(err)
	}
	c := iss.Cert
	if c.KeyId != "door:gh:1:ab12cd34" || len(c.ValidPrincipals) != 1 || c.ValidPrincipals[0] != "alice" {
		t.Fatalf("key id %q principals %v", c.KeyId, c.ValidPrincipals)
	}
	if got := time.Unix(int64(c.ValidBefore), 0).Sub(now); got != 2*time.Minute {
		t.Fatalf("lifetime %s", got)
	}
	if c.CriticalOptions["source-address"] != "127.0.0.1/32,::1/128" {
		t.Fatalf("critical options %v", c.CriticalOptions)
	}
	if _, ok := c.Extensions["permit-agent-forwarding"]; ok {
		t.Fatal("agent forwarding on a door-session certificate")
	}
	for _, bad := range []DoorSessionRequest{{Key: key, Login: "a", Session: "s", TTL: time.Minute},
		{Key: key, Principal: "p", Session: "s", TTL: time.Minute}, {Key: key, Principal: "p", Login: "a", TTL: time.Minute},
		{Key: key, Principal: "p", Login: "a", Session: "s"}, {Principal: "p", Login: "a", Session: "s", TTL: time.Minute}} {
		if _, err := ca.SignDoorSession(bad, now); err == nil {
			t.Fatalf("signed %+v", bad)
		}
	}
}
