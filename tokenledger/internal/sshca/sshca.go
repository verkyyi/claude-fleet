// Package sshca is the hub's SSH certificate authority (claude-fleet#1412).
//
// The hub holds ONE CA private key — read from a file the deployment mounts
// from its own k8s Secret, never from the database — and signs short-lived
// USER certificates with it. Every machine trusts that CA through sshd's
// TrustedUserCAKeys, so a person who has a certificate needs no key of theirs
// on any machine, and a person whose certificate has expired is refused
// without anyone deleting anything.
//
// What a certificate says is decided here and nowhere else:
//
//   - principals: the person's login (the one name C4 gave them on every
//     machine) — sshd lets the certificate in only as that login;
//   - validity: 12 hours from now (a minute of back-dating for clock skew);
//   - key id: "fleet:<wecom userid>:<login>:<serial>", which sshd writes to
//     its log on every login, so an auth line names the person, not a key;
//   - extensions: the ordinary interactive set (pty, port/agent forwarding,
//     user rc). No critical options: no force-command, no source-address —
//     the routes a person comes in on (LAN, tailnet, relay) are many.
package sshca

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// TTL is how long a certificate lives. Fixed by the operator's decision on
// EPIC #1407: twelve hours, and scan again when it runs out.
const TTL = 12 * time.Hour

// skew back-dates valid_after so a machine whose clock runs a little behind
// the hub's does not refuse a certificate minted a second ago.
const skew = time.Minute

// MaxPublicKeyLen bounds a submitted public key line. An RSA-8192 key is
// ~1.4KB in authorized_keys form.
const MaxPublicKeyLen = 4096

// CA signs user certificates.
type CA struct {
	signer ssh.Signer
}

// Load reads an OpenSSH private key (unencrypted — it lives in a Secret, and
// a passphrase would only move the secret into the Secret next to it).
func Load(path string) (*CA, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(b)
}

// Parse builds a CA from PEM-encoded private key bytes.
func Parse(pem []byte) (*CA, error) {
	s, err := ssh.ParsePrivateKey(pem)
	if err != nil {
		return nil, fmt.Errorf("ssh CA key: %w", err)
	}
	return &CA{signer: s}, nil
}

// New wraps an existing signer (tests).
func New(s ssh.Signer) *CA { return &CA{signer: s} }

// PublicKey is the CA's public key in authorized_keys form, one line, no
// newline: the exact content of a machine's /etc/ssh/fleet_user_ca.pub.
func (c *CA) PublicKey() string {
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(c.signer.PublicKey())))
}

// Fingerprint is the CA key's SHA256 fingerprint.
func (c *CA) Fingerprint() string {
	return ssh.FingerprintSHA256(c.signer.PublicKey())
}

// ParseUserKey parses the public key a person submits (one authorized_keys
// line, comment optional). A certificate is refused: we sign keys, not
// certificates of another CA.
func ParseUserKey(line string) (ssh.PublicKey, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, errors.New("no public key")
	}
	if len(line) > MaxPublicKeyLen || strings.ContainsAny(line, "\r\n") {
		return nil, errors.New("one public key line, please")
	}
	pk, _, opts, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil || len(opts) != 0 {
		return nil, errors.New("not an OpenSSH public key")
	}
	if _, ok := pk.(*ssh.Certificate); ok {
		return nil, errors.New("send the public key, not a certificate")
	}
	return pk, nil
}

// Request is what a certificate is signed for.
type Request struct {
	Key ssh.PublicKey
	// PrincipalID is the WeCom userid; it goes into the key id for audit.
	PrincipalID string
	// Logins are the OS logins the certificate admits (its principals).
	Logins []string
}

// Issued is a signed certificate and what it says.
type Issued struct {
	Cert        *ssh.Certificate
	Line        string // authorized_keys form: the content of <key>-cert.pub
	Serial      uint64
	KeyID       string
	Principals  []string
	ValidAfter  time.Time
	ValidBefore time.Time
	// KeyFingerprint is the SHA256 fingerprint of the person's key.
	KeyFingerprint string
}

// Sign issues a user certificate valid for TTL from now.
func (c *CA) Sign(req Request, now time.Time) (*Issued, error) {
	if req.Key == nil {
		return nil, errors.New("no key to sign")
	}
	if len(req.Logins) == 0 {
		return nil, errors.New("no login to admit")
	}
	if req.PrincipalID == "" {
		return nil, errors.New("no principal")
	}
	var sb [8]byte
	if _, err := rand.Read(sb[:]); err != nil {
		return nil, err
	}
	// Top bit clear: some tools print the serial as a signed int64.
	serial := binary.BigEndian.Uint64(sb[:]) &^ (1 << 63)
	after := now.Add(-skew).Truncate(time.Second)
	before := now.Add(TTL).Truncate(time.Second)
	keyID := fmt.Sprintf("fleet:%s:%s:%d", req.PrincipalID, req.Logins[0], serial)
	cert := &ssh.Certificate{
		Key:             req.Key,
		Serial:          serial,
		CertType:        ssh.UserCert,
		KeyId:           keyID,
		ValidPrincipals: append([]string(nil), req.Logins...),
		ValidAfter:      uint64(after.Unix()),
		ValidBefore:     uint64(before.Unix()),
		Permissions: ssh.Permissions{
			Extensions: map[string]string{
				"permit-pty":              "",
				"permit-port-forwarding":  "",
				"permit-agent-forwarding": "",
				"permit-user-rc":          "",
				"permit-X11-forwarding":   "",
			},
		},
	}
	if err := cert.SignCert(rand.Reader, c.signer); err != nil {
		return nil, err
	}
	return &Issued{
		Cert:           cert,
		Line:           strings.TrimSpace(string(ssh.MarshalAuthorizedKey(cert))) + " " + keyID,
		Serial:         serial,
		KeyID:          keyID,
		Principals:     cert.ValidPrincipals,
		ValidAfter:     after,
		ValidBefore:    before,
		KeyFingerprint: ssh.FingerprintSHA256(req.Key),
	}, nil
}

// ValidCAPublicKey reports whether line is exactly one plain public key — the
// only shape a node will write into its sshd's trusted-CA file.
func ValidCAPublicKey(line string) bool {
	if line == "" || len(line) > MaxPublicKeyLen || strings.ContainsAny(line, "\r\n") {
		return false
	}
	pk, _, opts, rest, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil || len(opts) != 0 || len(rest) != 0 {
		return false
	}
	_, isCert := pk.(*ssh.Certificate)
	return !isCert
}
