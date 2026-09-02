package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeSelfSigned plays the part of `tailscale cert`: it drops a cert+key
// pair for host into the two files.
func writeSelfSigned(t *testing.T, host, certFile, keyFile string, notAfter time.Time) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: host},
		DNSNames: []string{host}, NotBefore: time.Now().Add(-time.Hour), NotAfter: notAfter,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := x509.MarshalECPrivateKey(key)
	os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600)
}

func TestTailscaleCert_IssuesLoadsAndServes(t *testing.T) {
	dir := t.TempDir()
	calls := 0
	tc := &tailscaleCert{
		host: "macmini.example.ts.net", dir: dir,
		issue: func(host, certFile, keyFile string) error {
			calls++
			writeSelfSigned(t, host, certFile, keyFile, time.Now().Add(20*24*time.Hour))
			return nil
		},
	}
	if err := tc.refresh(); err != nil {
		t.Fatal(err)
	}
	c, err := tc.get(&tls.ClientHelloInfo{})
	if err != nil || c == nil || c.Leaf == nil {
		t.Fatalf("no certificate served: %v", err)
	}
	if c.Leaf.Subject.CommonName != "macmini.example.ts.net" {
		t.Errorf("served CN=%q", c.Leaf.Subject.CommonName)
	}
	if calls != 1 {
		t.Errorf("issue called %d times, want 1", calls)
	}
	// The key must not be world-readable.
	st, _ := os.Stat(filepath.Join(dir, "macmini.example.ts.net.key"))
	if st.Mode().Perm()&0o077 != 0 {
		t.Errorf("key file is %v; it must be owner-only", st.Mode().Perm())
	}
}

// A failed renewal keeps serving the certificate it has. Going dark on a
// transient tailscaled hiccup would be worse than serving a cert that is
// still valid for days.
func TestTailscaleCert_KeepsOldCertWhenRenewalFails(t *testing.T) {
	dir := t.TempDir()
	fail := false
	tc := &tailscaleCert{host: "h.ts.net", dir: dir,
		issue: func(host, cf, kf string) error {
			if fail {
				return errors.New("tailscaled is down")
			}
			writeSelfSigned(t, host, cf, kf, time.Now().Add(48*time.Hour))
			return nil
		}}
	if err := tc.refresh(); err != nil {
		t.Fatal(err)
	}
	fail = true
	if err := tc.refresh(); err == nil {
		t.Error("a failed renewal reported success")
	}
	if c, _ := tc.get(&tls.ClientHelloInfo{}); c == nil {
		t.Error("the previous certificate was dropped on a failed renewal")
	}
}

func TestTailscaleCert_FirstIssueFailureIsFatal(t *testing.T) {
	tc := &tailscaleCert{host: "h.ts.net", dir: t.TempDir(),
		issue: func(string, string, string) error { return errors.New("no https on this tailnet") }}
	if err := tc.refresh(); err == nil {
		t.Error("starting with no certificate at all must fail loudly, not serve nothing")
	}
}

func TestMagicDNSName(t *testing.T) {
	name, err := magicDNSName([]byte(`{"Self":{"DNSName":"macmini.tail435588.ts.net."},"CertDomains":["macmini.tail435588.ts.net"]}`))
	if err != nil || name != "macmini.tail435588.ts.net" {
		t.Errorf("got %q, %v", name, err)
	}
	// No CertDomains means HTTPS is not enabled on the tailnet; say so rather
	// than trying and failing later with a worse message.
	if _, err := magicDNSName([]byte(`{"Self":{"DNSName":"x.ts.net."}}`)); err == nil {
		t.Error("a tailnet without HTTPS enabled was accepted")
	}
}
