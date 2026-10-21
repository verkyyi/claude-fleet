package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// TestEntryHostCertSigned (claude-fleet T743): a machine's entry reach report
// is answered with its entry key signed by the host CA — a HOST certificate,
// the names fleet connect checks it under, valid under the host CA — and every
// route machine carries that CA. No host CA (the user CA alone) ⇒ neither.
func TestEntryHostCertSigned(t *testing.T) {
	h := entryHarness(t)
	_, hostPriv, _ := ed25519.GenerateKey(rand.Reader)
	hostSigner, err := ssh.NewSignerFromKey(hostPriv)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.SSHHostCA = sshca.New(hostSigner)
	_, tok := rootNode(t, h, "root7", "mac-h", control.CapEntryKeys)
	k := reachKey(t)
	code, v, raw := reachPost(t, h, tok, control.EntryReachReport{Port: closedPort(t), HostKey: reachKeyLine(k), Listening: true}, "")
	if code != 200 || v.HostCert == "" {
		t.Fatalf("report: HTTP %d %s, want a host certificate", code, raw)
	}
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(v.HostCert))
	if err != nil {
		t.Fatal(err)
	}
	cert, ok := pk.(*ssh.Certificate)
	if !ok || cert.CertType != ssh.HostCert || string(cert.Key.Marshal()) != string(k.Marshal()) {
		t.Fatalf("not a host certificate of the reported key: %+v", pk)
	}
	ca := h.srv.hostCA()
	if ca == nil || h.srv.SSHCA == nil || ca.PublicKey() == h.srv.SSHCA.PublicKey() {
		t.Fatal("the host CA is missing or is the user CA itself")
	}
	caKey, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(ca.PublicKey()))
	checker := &ssh.CertChecker{IsHostAuthority: func(auth ssh.PublicKey, _ string) bool {
		return string(auth.Marshal()) == string(caKey.Marshal())
	}}
	if err := checker.CheckCert("fleet-mac-h", cert); err != nil {
		t.Fatalf("fleet-mac-h under the host CA: %v (principals %v)", err, cert.ValidPrincipals)
	}
	if err := checker.CheckCert("fleet-other", cert); err == nil {
		t.Fatal("the certificate is good for another machine's name")
	}
	if left := time.Until(time.Unix(int64(cert.ValidBefore), 0)); left < 29*24*time.Hour {
		t.Fatalf("certificate lives %v, want ~30 days", left)
	}
	rm := h.srv.routeMachine(FleetMachine{Hostname: "mac-h"}, func(string) bool { return false }, "", time.Now())
	if len(rm.HostCA) != 1 || rm.HostCA[0] != ca.PublicKey() {
		t.Fatalf("route machine HostCA = %v, want the host CA", rm.HostCA)
	}
	h.srv.SSHHostCA = nil
	h.srv.entryReachAt.Delete("mac-h")
	if _, v, _ = reachPost(t, h, tok, control.EntryReachReport{Port: closedPort(t), HostKey: reachKeyLine(k), Listening: true}, ""); v.HostCert != "" {
		t.Fatal("no SSH CA, yet a host certificate")
	}
	if rm := h.srv.routeMachine(FleetMachine{Hostname: "mac-h"}, func(string) bool { return false }, "", time.Now()); rm.HostCA != nil {
		t.Fatalf("no SSH CA, yet HostCA %v", rm.HostCA)
	}
}
