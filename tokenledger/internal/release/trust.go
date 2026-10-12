package release

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

// The release signing key lives only in the release train; an offline ROOT
// key, kept by a person, vouches for it and revokes it (claude-fleet#3559,
// EPIC #3500 C17). A machine pins the root (or, until its first chained
// release, the hub's old signing key) and takes a manifest signed by any key
// the pin vouches for through the manifest's KeyChain — never one a
// revocation names. bin/fleet-release-verify.py is the same logic in Python;
// the two read one format:
//
//	Doc{Payload: base64(the exact JSON bytes), Sig: base64(Ed25519 over DocPrefix + those bytes)}
//
// payload kind "release-key" (KeyCert): By vouches for Key with Role sign|root
// — a root may vouch and revoke in turn, only when By is itself a root (the
// pinned key always is). payload kind "release-revoked" (Revocation): nothing
// those key ids signed counts, from the first time a machine sees the list; a
// machine keeps every id it saw (<pin>.revoked, RevokedPath).

// DocPrefix separates a key document's signature from any other use of a key.
const DocPrefix = "claude-fleet-release-doc\n"

// Doc is one signed key document (a key_chain entry, a revocation list).
type Doc struct {
	Payload string `json:"payload"`
	Sig     string `json:"sig"`
}

// KeyCert is a "release-key" payload.
type KeyCert struct {
	Schema  int    `json:"schema"`
	Kind    string `json:"kind"`
	Key     string `json:"key"`
	Role    string `json:"role"`
	By      string `json:"by"`
	Created string `json:"created,omitempty"`
	Note    string `json:"note,omitempty"`
}

// Revocation is a "release-revoked" payload.
type Revocation struct {
	Schema  int      `json:"schema"`
	Kind    string   `json:"kind"`
	Version int64    `json:"version"`
	Keys    []string `json:"keys"`
	By      string   `json:"by"`
	Created string   `json:"created,omitempty"`
}

const (
	KindKey     = "release-key"
	KindRevoked = "release-revoked"
	RoleRoot    = "root"
	RoleSign    = "sign"
)

var keyIDRe = regexp.MustCompile(`^[0-9a-f]{16}$`)

// SignDoc signs payload (any JSON value) as a Doc.
func SignDoc(key ed25519.PrivateKey, payload any) (Doc, error) {
	b, err := json.Marshal(payload)
	if err != nil {
		return Doc{}, err
	}
	return Doc{Payload: base64.StdEncoding.EncodeToString(b),
		Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(key, append([]byte(DocPrefix), b...)))}, nil
}

// bytes is the payload, UNVERIFIED.
func (d Doc) bytes() ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(d.Payload)
	return b, err == nil
}

// Verifies: pub signed d.
func (d Doc) Verifies(pub ed25519.PublicKey) bool {
	b, ok := d.bytes()
	sig, err := base64.StdEncoding.DecodeString(d.Sig)
	return ok && err == nil && len(pub) == ed25519.PublicKeySize && ed25519.Verify(pub, append([]byte(DocPrefix), b...), sig)
}

// trustedKey is one key the pin vouches for.
type trustedKey struct {
	pub  ed25519.PublicKey
	role string
	by   string
}

// Trust is what a pin vouches for through a chain, after its revocations.
type Trust struct {
	Anchor     ed25519.PublicKey
	keys       map[string]trustedKey
	Revoked    map[string]bool // every revoked id: what the machine already knew + every list a trusted root signed
	RevVersion int64           // the newest list's version
	// Repin is a root the anchor vouched for directly: the key a machine moves
	// its pin to once a release has verified (nil = none) — the one-time move
	// from the hub's old signing key to the offline root.
	Repin ed25519.PublicKey
}

// Has: id is a key the anchor vouches for (the anchor's own included).
func (t *Trust) Has(id string) bool { _, ok := t.keys[id]; return ok }

// Key: the trusted key of id (nil = none).
func (t *Trust) Key(id string) ed25519.PublicKey { return t.keys[id].pub }

// IDs lists every trusted key: id, role, who vouched.
func (t *Trust) IDs() []string {
	out := make([]string, 0, len(t.keys))
	for id, k := range t.keys {
		out = append(out, id+" "+k.role+" "+k.by)
	}
	sort.Strings(out)
	return out
}

func closeChain(anchor ed25519.PublicKey, chain []Doc, revoked map[string]bool) map[string]trustedKey {
	aid := KeyID(anchor)
	t := map[string]trustedKey{aid: {anchor, RoleRoot, ""}}
	for grew := true; grew; {
		grew = false
		for _, d := range chain {
			b, ok := d.bytes()
			var c KeyCert
			if !ok || json.Unmarshal(b, &c) != nil || c.Kind != KindKey {
				continue
			}
			signer, ok := t[c.By]
			if !ok || (revoked[c.By] && c.By != aid) {
				continue
			}
			pub, err := ParsePublicKey([]byte(c.Key))
			if err != nil {
				continue
			}
			id := KeyID(pub)
			if _, have := t[id]; have || revoked[id] || !d.Verifies(signer.pub) {
				continue
			}
			role := RoleSign
			if c.Role == RoleRoot && signer.role == RoleRoot {
				role = RoleRoot
			}
			t[id] = trustedKey{pub, role, c.By}
			grew = true
		}
	}
	return t
}

// NewTrust: every key anchor vouches for through chain, after every revocation
// in revocations a trusted root signed, and every id in known. The anchor is
// never revoked: a pinned root that leaked is the one case a person re-pins.
func NewTrust(anchor ed25519.PublicKey, chain []Doc, revocations []Doc, known map[string]bool) *Trust {
	aid := KeyID(anchor)
	rev := map[string]bool{}
	for id := range known {
		rev[id] = true
	}
	delete(rev, aid)
	var ver int64
	first := closeChain(anchor, chain, rev)
	for _, d := range revocations {
		b, ok := d.bytes()
		var r Revocation
		if !ok || json.Unmarshal(b, &r) != nil || r.Kind != KindRevoked {
			continue
		}
		by, ok := first[r.By]
		if !ok || by.role != RoleRoot || !d.Verifies(by.pub) {
			continue
		}
		for _, id := range r.Keys {
			if keyIDRe.MatchString(id) {
				rev[id] = true
			}
		}
		if r.Version > ver {
			ver = r.Version
		}
	}
	delete(rev, aid)
	t := &Trust{Anchor: anchor, keys: closeChain(anchor, chain, rev), Revoked: rev, RevVersion: ver}
	ids := make([]string, 0, len(t.keys))
	for id := range t.keys {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if k := t.keys[id]; k.role == RoleRoot && k.by == aid && id != aid {
			t.Repin = k.pub
			break
		}
	}
	return t
}

// errRevoked: the manifest's signer is on a revocation list.
var errRevoked = errors.New("signed by a key the root revoked")

// VerifyTrusted checks sig over manifest with the key the anchor vouches for
// (the anchor itself, or one through the manifest's key_chain no revocation
// names — the manifest's own, extra's, or known's) and parses it.
func VerifyTrusted(anchor ed25519.PublicKey, manifest []byte, sig string, extra []Doc, known map[string]bool) (*Manifest, *Trust, error) {
	var peek Manifest
	if err := json.Unmarshal(manifest, &peek); err != nil {
		return nil, nil, fmt.Errorf("manifest: %w", err)
	}
	revs := append([]Doc{}, extra...)
	if peek.Revoked != nil {
		revs = append(revs, *peek.Revoked)
	}
	t := NewTrust(anchor, peek.KeyChain, revs, known)
	want := peek.Key
	if want == "" {
		want = KeyID(anchor)
	}
	if t.Revoked[want] {
		return nil, t, fmt.Errorf("%w (%s)", errRevoked, want)
	}
	pub := t.Key(want)
	if pub == nil {
		// the signer is not one the pin vouches for: the old message, which the
		// node updater and the selftests read (claude-fleet#3559)
		return nil, t, fmt.Errorf("%w (signed by %s, which %s does not vouch for)", errBadSignature, want, KeyID(anchor))
	}
	m, err := Verify(pub, manifest, sig)
	return m, t, err
}

// IsRevoked: err is VerifyTrusted's refusal of a revoked signer.
func IsRevoked(err error) bool { return errors.Is(err, errRevoked) }

// RevokedPath is where a machine keeps every revoked id it saw, beside its pin.
func RevokedPath(pin string) string { return pin + ".revoked" }

// revokedFile is RevokedPath's content.
type revokedFile struct {
	Version int64    `json:"version"`
	Keys    []string `json:"keys"`
}

// LoadRevoked reads RevokedPath (empty when none).
func LoadRevoked(pin string) (map[string]bool, int64) {
	out := map[string]bool{}
	b, err := os.ReadFile(RevokedPath(pin))
	var f revokedFile
	if err != nil || json.Unmarshal(b, &f) != nil {
		return out, 0
	}
	for _, id := range f.Keys {
		if keyIDRe.MatchString(id) {
			out[id] = true
		}
	}
	return out, f.Version
}

// Keep writes what t learned beside the pin: every revoked id (the file only
// ever grows), and the pin moved to t.Repin (the old kept as <pin>.prev).
// Called only after a release verified under t. It says what it changed.
func (t *Trust) Keep(pin string) (string, error) {
	var said []string
	have, ver := LoadRevoked(pin)
	grew := t.RevVersion > ver
	for id := range t.Revoked {
		if !have[id] {
			have[id], grew = true, true
		}
	}
	if grew {
		ids := make([]string, 0, len(have))
		for id := range have {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		if t.RevVersion > ver {
			ver = t.RevVersion
		}
		b, _ := json.Marshal(revokedFile{Version: ver, Keys: ids})
		if err := writeAtomic(RevokedPath(pin), append(b, '\n')); err != nil {
			return "", err
		}
		said = append(said, "revoked "+strings.Join(ids, " "))
	}
	if t.Repin != nil {
		cur, err := os.ReadFile(pin)
		if err == nil {
			if old, err := ParsePublicKey(cur); err == nil && old.Equal(t.Repin) {
				return strings.Join(said, "; "), nil
			}
			if err := writeAtomic(pin+".prev", cur); err != nil {
				return "", err
			}
		}
		if err := writeAtomic(pin, []byte(FormatPublicKey(t.Repin)+"\n")); err != nil {
			return "", err
		}
		said = append(said, fmt.Sprintf("re-pinned to the root %s (vouched for by %s; the old kept as %s.prev)", KeyID(t.Repin), KeyID(t.Anchor), pin))
	}
	return strings.Join(said, "; "), nil
}

func writeAtomic(p string, b []byte) error {
	tmp := fmt.Sprintf("%s.tmp.%d", p, os.Getpid())
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
