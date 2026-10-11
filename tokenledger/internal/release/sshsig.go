package release

import (
	"crypto/ed25519"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"strings"
)

// A client checks a release with the system's own `ssh-keygen -Y verify`, so
// it needs no ccquota and no crypto library (claude-fleet#3162): beside the
// base64 ed25519 signature (SigName, kept for every client installed before)
// the hub hands the same manifest bytes signed in OpenSSH's SSHSIG format
// (PROTOCOL.sshsig), with the same key. Ed25519 is deterministic and the key
// is the hub's, so the signature is made when it is served — a healed,
// re-signed manifest (claude-fleet#2631) never meets a stale one.
//
// The client's allowed_signers line is built from the key it pinned
// (`ed25519 <base64>` → `ssh-ed25519 <wire>`), so nothing new is trusted. A
// new signing key is accepted only when the old one vouches for it: the hub,
// holding both for the overlap (CCQUOTA_FLEET_RELEASE_PREV_KEY), serves
// Endorse's text at /v1/fleet/release/key-endorsement.
const (
	SSHSigName     = "manifest.sshsig"
	SSHSigHeader   = "X-Ccquota-Release-Sshsig" // the blob, base64 on one line, over the bytes in that response
	SSHSigNS       = "claude-fleet-release"     // a manifest
	SSHSigKeyNS    = "claude-fleet-release-key" // a new key, vouched for by the old
	EndorsementRel = "key-endorsement"
)

func sshString(b []byte) []byte {
	out := make([]byte, 4, 4+len(b))
	binary.BigEndian.PutUint32(out, uint32(len(b)))
	return append(out, b...)
}

// SSHWirePublicKey is the ssh-ed25519 public key blob.
func SSHWirePublicKey(pub ed25519.PublicKey) []byte {
	return append(sshString([]byte("ssh-ed25519")), sshString(pub)...)
}

// SSHPublicKey is the authorized_keys / allowed_signers form: `ssh-ed25519 <base64>`.
func SSHPublicKey(pub ed25519.PublicKey) string {
	return "ssh-ed25519 " + base64.StdEncoding.EncodeToString(SSHWirePublicKey(pub))
}

// SSHSign is the SSHSIG blob of msg under namespace (sha512, as ssh-keygen -Y sign).
func SSHSign(key ed25519.PrivateKey, namespace string, msg []byte) []byte {
	h := sha512.Sum512(msg)
	signed := []byte("SSHSIG")
	signed = append(signed, sshString([]byte(namespace))...)
	signed = append(signed, sshString(nil)...)
	signed = append(signed, sshString([]byte("sha512"))...)
	signed = append(signed, sshString(h[:])...)
	sig := append(sshString([]byte("ssh-ed25519")), sshString(ed25519.Sign(key, signed))...)
	blob := []byte("SSHSIG")
	blob = binary.BigEndian.AppendUint32(blob, 1)
	blob = append(blob, sshString(SSHWirePublicKey(key.Public().(ed25519.PublicKey)))...)
	blob = append(blob, sshString([]byte(namespace))...)
	blob = append(blob, sshString(nil)...)
	blob = append(blob, sshString([]byte("sha512"))...)
	return append(blob, sshString(sig)...)
}

// SSHSigArmor is the blob as `ssh-keygen -Y verify -s` reads it.
func SSHSigArmor(blob []byte) string {
	s := base64.StdEncoding.EncodeToString(blob)
	var b strings.Builder
	b.WriteString("-----BEGIN SSH SIGNATURE-----\n")
	for len(s) > 70 {
		b.WriteString(s[:70] + "\n")
		s = s[70:]
	}
	b.WriteString(s + "\n-----END SSH SIGNATURE-----\n")
	return b.String()
}

// Endorse is prev vouching for next: next's FormatPublicKey line, then the
// SSHSIG (SSHSigKeyNS) of exactly that line + "\n", armored.
func Endorse(prev ed25519.PrivateKey, next ed25519.PublicKey) string {
	line := FormatPublicKey(next) + "\n"
	return line + SSHSigArmor(SSHSign(prev, SSHSigKeyNS, []byte(line)))
}
