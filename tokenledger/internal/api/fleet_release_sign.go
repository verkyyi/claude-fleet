package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// The release signing key lives only in the release train (claude-fleet#3559,
// EPIC #3500 C17). A hub with no private key (CCQUOTA_FLEET_RELEASE_KEY unset,
// CCQUOTA_FLEET_RELEASE_ROOT set) keeps and serves releases it cannot sign:
//
//	POST …/publish  (sha, prev, commits, tree, signer)
//	    the commit checked as always, then built UNSIGNED for `signer` — the
//	    train's public key, which the commit's conf/release-keys/chain.json must
//	    vouch for from the root and no revocation may name — at
//	    <Dir>/<sha>/b…/, named by <Dir>/<sha>/unsigned (never served). 202
//	    {"status":"unsigned", "manifest": base64 of the exact bytes, seq, prev}.
//	POST …/publish  (sha, sig, sshsig)
//	    the train, having checked those bytes against its own checkout
//	    (bin/fleet-release-sign.py check), hands back their two signatures:
//	    checked here against the same chain (release.VerifyTrusted, the SSHSIG
//	    too), written beside the manifest, the build made current and stable —
//	    still one past the pointer, else 409 and the train starts over.
//
// So a hub that is broken into can serve old releases and refuse new ones,
// but cannot make one any machine takes. /key serves the ROOT (what a new
// machine pins); /revoked the newest revocation list the root signed — this
// hub's CCQUOTA_FLEET_RELEASE_REVOKED or the stable release's own.
//
// A hub that still holds its key signs as before; with a root configured too
// it serves the root at /key and every release carries the commit's chain, so
// machines pinned to its key move to the root at their next update (the
// migration's step A). Neither ⇒ no store, byte for byte as before.

// Where a commit keeps its public key documents (bin/fleet-release-sign.py).
const (
	ReleaseKeysChain   = "conf/release-keys/chain.json"
	ReleaseKeysRevoked = "conf/release-keys/revoked.json"
)

// releaseUnsigned names the build of <sha> waiting for the train's signature.
const releaseUnsigned = "unsigned"

// releaseStageTTL: how long a build waits for its signature (claude-fleet#3867).
// The train stages its release while its tests run and signs it once they are
// green; a build older than this was staged by a train that went red or away,
// and its signature is refused — the train publishes whole again. A var for
// the test.
var releaseStageTTL = 30 * time.Minute

// ReleaseSignerHeader says on /key who signs: hub | train.
const ReleaseSignerHeader = "X-Ccquota-Release-Signer"

// TrainSigned: this hub holds no signing key — the release train signs.
func (rs *ReleaseStore) TrainSigned() bool { return rs.Key == nil }

// anchor is the key a machine pins: the root, else this hub's signing key.
func (rs *ReleaseStore) anchor() ed25519.PublicKey {
	if rs.Root != nil {
		return rs.Root
	}
	if rs.Key != nil {
		return rs.Key.Public().(ed25519.PublicKey)
	}
	return nil
}

// releaseKeys reads a commit's chain and revocation list (absent = none).
func releaseKeys(all map[string][]byte) ([]release.Doc, *release.Doc, error) {
	var chain []release.Doc
	if b, ok := all[ReleaseKeysChain]; ok {
		if err := json.Unmarshal(b, &chain); err != nil {
			return nil, nil, fmt.Errorf("%s: %w", ReleaseKeysChain, err)
		}
	}
	var rev *release.Doc
	if b, ok := all[ReleaseKeysRevoked]; ok {
		rev = &release.Doc{}
		if err := json.Unmarshal(b, rev); err != nil {
			return nil, nil, fmt.Errorf("%s: %w", ReleaseKeysRevoked, err)
		}
	}
	return chain, rev, nil
}

// revocations: every list this hub knows — its own file and the stable
// release's — for a check here and for /revoked.
func (rs *ReleaseStore) revocations() []release.Doc {
	var out []release.Doc
	if rs.RevokedFile != "" {
		var d release.Doc
		if b, err := os.ReadFile(rs.RevokedFile); err == nil && json.Unmarshal(b, &d) == nil && d.Payload != "" {
			out = append(out, d)
		}
	}
	if m := rs.manifest(rs.stable().SHA); m != nil && m.Revoked != nil {
		out = append(out, *m.Revoked)
	}
	return out
}

// revokedDoc is /revoked: the newest-version list among revocations() that
// a root the anchor vouches for signed (nil = none).
func (rs *ReleaseStore) revokedDoc() *release.Doc {
	a := rs.anchor()
	if a == nil {
		return nil
	}
	var chain []release.Doc
	if m := rs.manifest(rs.stable().SHA); m != nil {
		chain = m.KeyChain
	}
	var best *release.Doc
	var bestV int64 = -1
	for _, d := range rs.revocations() {
		d := d
		t := release.NewTrust(a, chain, []release.Doc{d}, nil)
		if t.RevVersion == 0 && len(t.Revoked) == 0 {
			continue // not signed by a trusted root
		}
		if t.RevVersion > bestV {
			best, bestV = &d, t.RevVersion
		}
	}
	return best
}

// stage builds sha unsigned for signer: the publish's first half in a
// train-signed store. promoteMu is held by the caller.
func (rs *ReleaseStore) stage(sha string, all map[string][]byte, signer ed25519.PublicKey) (map[string]any, error) {
	chain, rev, err := releaseKeys(all)
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "%v", err)
	}
	revs := rs.revocations()
	if rev != nil {
		revs = append(revs, *rev)
	}
	t := release.NewTrust(rs.anchor(), chain, revs, nil)
	id := release.KeyID(signer)
	switch {
	case t.Revoked[id]:
		return nil, publishErr(http.StatusForbidden, "the train's key %s is revoked", id)
	case !t.Has(id):
		return nil, publishErr(http.StatusForbidden, "the train's key %s is not one the root %s vouches for through %s", id, release.KeyID(rs.anchor()), ReleaseKeysChain)
	}
	files, err := releaseTree(all)
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "release-tree.list: %v", err)
	}
	cur := rs.stable()
	seal := release.Seal{Prev: cur.SHA, Seq: cur.Seq + 1, Src: release.SourceDigest(all), KeyChain: chain, Revoked: rev, Signer: signer}
	shaDir := filepath.Join(rs.Dir, sha)
	if err := os.MkdirAll(shaDir, 0o755); err != nil {
		return nil, err
	}
	now := time.Now()
	bid := newBuildID(now)
	m, err := release.BuildSealed(filepath.Join(shaDir, bid), rs.Repo, sha, files, rs.artifacts(), nil, now, seal)
	if err != nil {
		_ = os.RemoveAll(filepath.Join(shaDir, bid))
		return nil, err
	}
	if err := replaceFile(filepath.Join(shaDir, releaseUnsigned), ".unsigned-"+bid, []byte(bid+"\n")); err != nil {
		return nil, err
	}
	mb, err := os.ReadFile(filepath.Join(shaDir, bid, release.ManifestName))
	if err != nil {
		return nil, err
	}
	log.Printf("fleet: release %s built unsigned as #%d for the train's key %s", sha[:7], m.Seq, id)
	return map[string]any{"status": "unsigned", "sha": sha, "prev": m.Prev, "seq": m.Seq, "key": id,
		"manifest": base64.StdEncoding.EncodeToString(mb)}, nil
}

// staged: the build of sha waiting for its signature ("" = none).
func (rs *ReleaseStore) staged(sha string) string {
	b, err := os.ReadFile(filepath.Join(rs.Dir, sha, releaseUnsigned))
	id := strings.TrimSpace(string(b))
	if err != nil || !buildIDRe.MatchString(id) {
		return ""
	}
	return filepath.Join(rs.Dir, sha, id)
}

// Sign takes the train's two signatures over the staged manifest of sha and
// makes it stable: the publish's second half.
func (rs *ReleaseStore) Sign(sha, sig, sshsig string) (map[string]any, error) {
	if !rs.TrainSigned() {
		return nil, publishErr(http.StatusConflict, "this hub signs its own releases — publish without a signature")
	}
	rs.promoteMu.Lock()
	defer rs.promoteMu.Unlock()
	base := rs.staged(sha)
	if base == "" {
		if p := rs.stable(); p.SHA == sha && rs.Has(sha) {
			return map[string]any{"status": "already", "sha": sha, "seq": p.Seq}, nil
		}
		return nil, publishErr(http.StatusConflict, "%s is not waiting for a signature — publish it first", short(sha))
	}
	if m := buildIDRe.FindStringSubmatch(filepath.Base(base)); m != nil {
		var at int64
		_, _ = fmt.Sscan(m[1], &at)
		if age := time.Since(time.Unix(at, 0)); age > releaseStageTTL {
			_ = os.Remove(filepath.Join(rs.Dir, sha, releaseUnsigned))
			return nil, publishErr(http.StatusConflict, "the staged build of %s expired (staged %s ago, a stage lasts %s) — publish again",
				short(sha), age.Round(time.Second), releaseStageTTL)
		}
	}
	mb, err := os.ReadFile(filepath.Join(base, release.ManifestName))
	if err != nil {
		return nil, err
	}
	pm, t, err := release.VerifyTrusted(rs.anchor(), mb, sig, rs.revocations(), nil)
	if err != nil {
		return nil, publishErr(http.StatusForbidden, "the signature: %v", err)
	}
	var blob []byte
	if sshsig != "" {
		if blob, err = base64.StdEncoding.DecodeString(strings.TrimSpace(sshsig)); err != nil ||
			!release.SSHSigVerify(t.Key(pm.Key), release.SSHSigNS, mb, blob) {
			return nil, publishErr(http.StatusForbidden, "the SSHSIG is not the signer's over these bytes")
		}
	}
	cur := rs.stable()
	if pm.Prev != cur.SHA || pm.Seq != cur.Seq+1 {
		return nil, publishErr(http.StatusConflict, "stable moved to %s (#%d) since %s was built — publish again", short(cur.SHA), cur.Seq, short(sha))
	}
	if err := os.WriteFile(filepath.Join(base, release.SigName), []byte(strings.TrimSpace(sig)+"\n"), 0o644); err != nil {
		return nil, err
	}
	if blob != nil {
		if err := os.WriteFile(filepath.Join(base, release.SSHSigName), []byte(release.SSHSigArmor(blob)), 0o644); err != nil {
			return nil, err
		}
	}
	bid := filepath.Base(base)
	if err := replaceFile(filepath.Join(rs.Dir, sha, releaseCurrent), ".current-"+bid, []byte(bid+"\n")); err != nil {
		return nil, err
	}
	_ = os.Remove(filepath.Join(rs.Dir, sha, releaseUnsigned))
	if err := rs.movePointer(sha, pm.Seq); err != nil {
		return nil, err
	}
	return map[string]any{"status": "published", "sha": sha, "prev": pm.Prev, "seq": pm.Seq, "key": pm.Key}, nil
}
