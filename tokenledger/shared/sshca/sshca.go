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
//   - key id: "person:<principal>" (gh:<GitHub ID>), which sshd writes to
//     its log on every login, so an auth line names the person, not a key.
//     The hub relay (C6, claude-fleet#1413) reads the principal back with
//     PrincipalOfKeyID; the login is in the principals and the serial in its
//     own field;
//   - extensions: the ordinary interactive set (pty, port/agent forwarding,
//     user rc). No critical options: no force-command, no source-address —
//     the routes a person comes in on (LAN, tailnet, relay) are many.
package sshca

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
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
	// secret is the CA's private key (PKCS#8 DER) as loaded — only what a
	// derived CA is computed from; nil for New's.
	secret []byte
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
	ca := &CA{signer: s}
	if raw, err := ssh.ParseRawPrivateKey(pem); err == nil {
		if der, err := x509.MarshalPKCS8PrivateKey(rawKey(raw)); err == nil {
			ca.secret = der
		}
	}
	return ca, nil
}

// rawKey turns ParseRawPrivateKey's pointer forms into what PKCS#8 marshals.
func rawKey(k any) any {
	if p, ok := k.(*ed25519.PrivateKey); ok {
		return *p
	}
	return k
}

// Derive is a second CA computed from this one's private key and label — its
// own key, its own public half, never usable as this CA. The hub keeps no
// second Secret for it: the door-session CA (A5SQ) is Derive("door-session").
// The same CA key and label give the same CA on every replica and restart.
func (c *CA) Derive(label string) (*CA, error) {
	secret := c.secret
	if secret == nil {
		// New's (tests): a signature over the label — deterministic for
		// ed25519, the only kind the tests use.
		sig, err := c.signer.Sign(rand.Reader, []byte("fleet sshca derive/v1 "+label))
		if err != nil {
			return nil, err
		}
		if c.signer.PublicKey().Type() != ssh.KeyAlgoED25519 {
			return nil, errors.New("derive needs the CA's private key")
		}
		secret = sig.Blob
	}
	m := hmac.New(sha256.New, secret)
	m.Write([]byte("fleet sshca derive/v1 " + label))
	s, err := ssh.NewSignerFromKey(ed25519.NewKeyFromSeed(m.Sum(nil)))
	if err != nil {
		return nil, err
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
	// PrincipalID is the person (gh:<GitHub ID>); it goes into the key id for audit.
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

// KeyIDPrefix starts a person's certificate key id.
const KeyIDPrefix = "person:"

// PrincipalOfKeyID is the person a certificate's key id names: everything
// after the prefix, which may itself hold a ':' (gh:<id>).
func PrincipalOfKeyID(keyID string) string {
	if p, ok := strings.CutPrefix(keyID, KeyIDPrefix); ok {
		return p
	}
	return keyID
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
	return c.sign(req.Key, KeyIDPrefix+req.PrincipalID, req.Logins, TTL, map[string]string{
		"permit-pty":              "",
		"permit-port-forwarding":  "",
		"permit-agent-forwarding": "",
		"permit-user-rc":          "",
		"permit-X11-forwarding":   "",
	}, now)
}

// PeerTTL is the longest a machine-to-machine certificate lives (claude-fleet
// #1626, EPIC #1615 decision 10): five minutes — enough to open one
// connection, which outlives it (sshd checks a certificate at login only).
const PeerTTL = 5 * time.Minute

// PeerRequest is a certificate for ONE machine to reach ONE other, for one
// purpose (claude-fleet#1626). The hub decides every field: Source is the
// requesting node as the hub knows it (host/user), Target the machine, Login
// the one OS login it admits there.
type PeerRequest struct {
	Key     ssh.PublicKey
	Source  string
	Target  string
	Purpose string
	Login   string
	// TTL is clamped to (0, PeerTTL]; zero means PeerTTL.
	TTL time.Duration
}

// SignPeer issues a machine-to-machine certificate. Its key id —
// "peer:<source>><target>:<purpose>" — is what the target's sshd logs on the
// login, so every cross-machine login names where it came from and why. No
// agent forwarding, no user rc, no X11: a peer runs a command or attaches a
// pane (pty, and a port forward for fleet-open), nothing more.
func (c *CA) SignPeer(req PeerRequest, now time.Time) (*Issued, error) {
	if req.Key == nil {
		return nil, errors.New("no key to sign")
	}
	if req.Login == "" || req.Source == "" || req.Target == "" || req.Purpose == "" {
		return nil, errors.New("a peer certificate needs a source, a target, a purpose and a login")
	}
	ttl := req.TTL
	if ttl <= 0 || ttl > PeerTTL {
		ttl = PeerTTL
	}
	return c.sign(req.Key, "peer:"+req.Source+">"+req.Target+":"+req.Purpose, []string{req.Login}, ttl,
		map[string]string{"permit-pty": "", "permit-port-forwarding": ""}, now)
}

// DoorSessionRequest is one door-session certificate (A5SQ): the door's
// one-off key, the person, the one login it admits on their home, and a
// short tag of the session it was signed for (for the key id).
type DoorSessionRequest struct {
	Key       ssh.PublicKey
	Principal string
	Login     string
	Session   string
	TTL       time.Duration
}

// SignDoorSession issues a door-session certificate: key id
// "door:<principal>:<session>", ONE principal (the home login), source-address
// loopback only (it reaches a home's entry port through the home's own agent,
// never from outside), the interactive set without agent forwarding.
func (c *CA) SignDoorSession(req DoorSessionRequest, now time.Time) (*Issued, error) {
	if req.Key == nil {
		return nil, errors.New("no key to sign")
	}
	if req.Principal == "" || req.Login == "" || req.Session == "" || req.TTL <= 0 {
		return nil, errors.New("a door-session certificate needs a person, a login, a session and a lifetime")
	}
	return c.signCrit(req.Key, "door:"+req.Principal+":"+req.Session, []string{req.Login}, req.TTL,
		map[string]string{"source-address": "127.0.0.1/32,::1/128"},
		map[string]string{"permit-pty": "", "permit-port-forwarding": ""}, now)
}

func (c *CA) sign(key ssh.PublicKey, keyID string, logins []string, ttl time.Duration, ext map[string]string, now time.Time) (*Issued, error) {
	return c.signCrit(key, keyID, logins, ttl, nil, ext, now)
}

func (c *CA) signCrit(key ssh.PublicKey, keyID string, logins []string, ttl time.Duration, crit, ext map[string]string, now time.Time) (*Issued, error) {
	return c.signTyped(ssh.UserCert, key, keyID, logins, ttl, crit, ext, now)
}

// HostTTL is how long a host certificate lives (claude-fleet T743): a machine
// asks for a new one well before (its entry's reach report, every few
// minutes, keeps one with a week left) — short enough that a revoked machine
// falls out on its own.
const HostTTL = 30 * 24 * time.Hour

// SignHost issues a HOST certificate for a machine's sshd key (claude-fleet
// T743): key id "host:<machine>", the names a client checks it under
// (principals — fleet-<alias> as fleet connect's HostKeyAlias spells it). A
// client that trusts this CA (@cert-authority) never asks about, nor refuses,
// a machine whose key changed but is signed.
func (c *CA) SignHost(key ssh.PublicKey, machine string, principals []string, ttl time.Duration, now time.Time) (*Issued, error) {
	if key == nil {
		return nil, errors.New("no key to sign")
	}
	if machine == "" || len(principals) == 0 || ttl <= 0 {
		return nil, errors.New("a host certificate needs a machine, its names and a lifetime")
	}
	return c.signTyped(ssh.HostCert, key, "host:"+machine, principals, ttl, nil, nil, now)
}

func (c *CA) signTyped(certType uint32, key ssh.PublicKey, keyID string, logins []string, ttl time.Duration, crit, ext map[string]string, now time.Time) (*Issued, error) {
	var sb [8]byte
	if _, err := rand.Read(sb[:]); err != nil {
		return nil, err
	}
	// Top bit clear: some tools print the serial as a signed int64.
	serial := binary.BigEndian.Uint64(sb[:]) &^ (1 << 63)
	after := now.Add(-skew).Truncate(time.Second)
	before := now.Add(ttl).Truncate(time.Second)
	cert := &ssh.Certificate{
		Key:             key,
		Serial:          serial,
		CertType:        certType,
		KeyId:           keyID,
		ValidPrincipals: append([]string(nil), logins...),
		ValidAfter:      uint64(after.Unix()),
		ValidBefore:     uint64(before.Unix()),
		Permissions:     ssh.Permissions{CriticalOptions: crit, Extensions: ext},
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
		KeyFingerprint: ssh.FingerprintSHA256(key),
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
