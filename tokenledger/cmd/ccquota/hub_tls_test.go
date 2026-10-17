package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writePair writes a self-signed certificate for name + its key, PEM.
func writePair(t *testing.T, dir, name string) (certFile, keyFile string, pool *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: name},
		DNSNames: []string{name}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	kder, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certFile, keyFile = filepath.Join(dir, "tls.crt"), filepath.Join(dir, "tls.key")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kder}), 0o600); err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool = x509.NewCertPool()
	pool.AddCert(cert)
	return certFile, keyFile, pool
}

// --tls-cert/--tls-key (claude-fleet#4630): neither = plain HTTP as before,
// half a pair or a bad pair refuses, a good pair serves HTTPS a client that
// trusts only that CA accepts.
func TestStaticTLS(t *testing.T) {
	dir := t.TempDir()
	cert, key, pool := writePair(t, dir, "hub.c9.test")
	if cfg, err := loadStaticTLS("", ""); cfg != nil || err != nil {
		t.Fatalf("neither flag: got %v, %v; want nil, nil", cfg, err)
	}
	for _, half := range [][2]string{{cert, ""}, {"", key}} {
		if _, err := loadStaticTLS(half[0], half[1]); err == nil || !strings.Contains(err.Error(), "go together") {
			t.Fatalf("half pair %v: err %v", half, err)
		}
	}
	if _, err := loadStaticTLS(cert, cert); err == nil {
		t.Fatal("a certificate as its own key was accepted")
	}
	if err := runHub([]string{"--db", filepath.Join(dir, "x.db"), "--no-auth", "--tls-cert", cert}); err == nil ||
		!strings.Contains(err.Error(), "go together") {
		t.Fatalf("runHub with half a pair: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "x.db")); err == nil {
		t.Fatal("the refusal created a database first")
	}

	cfg, err := loadStaticTLS(cert, key)
	if err != nil || cfg == nil || cfg.MinVersion != tls.VersionTLS12 {
		t.Fatalf("good pair: %v, %v", cfg, err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hs := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }),
		TLSConfig: cfg}
	go func() { _ = hs.ServeTLS(ln, "", "") }()
	defer hs.Close()
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: pool, ServerName: "hub.c9.test"}}}
	resp, err := client.Get("https://" + ln.Addr().String() + "/")
	if err != nil {
		t.Fatalf("HTTPS with the test CA: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
}
