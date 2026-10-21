package api

import (
	"log"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// Host certificates (claude-fleet T743): the hub signs each home machine's
// entry host key with its HOST CA (Server.SSHHostCA — a key of its own, its
// own Secret, never derived from the user CA). The machine gets its
// certificate in the answer to its entry reach report and shows it from its
// entry sshd (HostCertificate); every route list and home answer carries the
// CA's public key (FleetMachine.HostCA), and fleet connect trusts it as one
// @cert-authority line — so a machine whose key changed, or a home that moved
// to another machine, is still known without a question. No host CA ⇒ no
// certificate, no HostCA: byte for byte as before.

// hostCA is the host CA, nil when the hub has none.
func (s *Server) hostCA() *sshca.CA { return s.SSHHostCA }

// hostCAKeys is what a route list's machine carries as HostCA: the host CA's
// public key, nil when there is none.
func (s *Server) hostCAKeys() []string {
	if ca := s.hostCA(); ca != nil {
		return []string{ca.PublicKey()}
	}
	return nil
}

// hostPrincipals are the names a client checks <host>'s certificate under:
// fleet-<alias> as fleet connect's HostKeyAlias spells it (the admin's short
// name, else what the route lists gave) and fleet-<hostname>, each as given
// and lowercased, each once.
func (s *Server) hostPrincipals(host string) []string {
	names := []string{host}
	if i := strings.IndexByte(host, '.'); i > 0 {
		names = append(names, host[:i])
	}
	for _, m := range s.fleetMachines() {
		if strings.EqualFold(m.Hostname, host) {
			names = append(names, m.alias())
		}
	}
	var out []string
	seen := map[string]bool{}
	for _, n := range names {
		for _, v := range []string{n, strings.ToLower(n)} {
			if p := "fleet-" + v; v != "" && sshToken(v) && !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	return out
}

// signEntryHostCert is <host>'s entry key signed by the host CA, one
// known_hosts-style line ("<cert type> <base64> host:<host>"), "" when the hub
// has no SSH CA or the signing failed (logged).
func (s *Server) signEntryHostCert(host string, key ssh.PublicKey, now time.Time) string {
	ca := s.hostCA()
	if ca == nil || key == nil {
		return ""
	}
	iss, err := ca.SignHost(key, strings.ToLower(host), s.hostPrincipals(host), sshca.HostTTL, now)
	if err != nil {
		log.Printf("fleet: sign %s's entry host certificate: %v", host, err)
		return ""
	}
	return iss.Line
}
