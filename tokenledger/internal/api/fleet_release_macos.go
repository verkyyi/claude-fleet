package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// The Mac lane (claude-fleet#3868, EPIC #3863 C5, 共同约定 3).
//
// stable means "Linux has verified it"; a Mac — a machine, or a client on one —
// follows stable-macos instead, which only ever names a release that was stable
// already (never ahead of stable) once the macOS half is green on it. The store
// keeps it as a second pointer beside <Dir>/stable:
//
//	<Dir>/stable-macos   {"sha": …, "seq": …}   seq = that release's own seal
//
// It is moved by a publish that names `ref=stable-macos` (only the sha — the
// release is on disk, signed, sealed at its place on the stable chain), and it
// is served where a platform is asked:
//
//	GET /v1/fleet/release/stable?platform=darwin   the Mac lane's release
//	GET /version   client_version_macos · client_url_macos beside client_version
//
// No pointer (no Mac lane set) ⇒ both answer stable, byte for byte: an older
// hub ignores ?platform= and a client reads client_version when the _macos
// field is missing (the compat road).

// releaseStableMacOS is the Mac lane's pointer, <Dir>/stable-macos.
const releaseStableMacOS = "stable-macos"

// RefStableMacOS is the publish form's `ref` that moves the Mac lane.
const RefStableMacOS = "stable-macos"

// ReleaseRefHeader names the lane …/stable?platform= served when it is not
// stable itself (fleet-release-lib.sh's REL_REF).
const ReleaseRefHeader = "X-Ccquota-Release-Ref"

// macPointer reads <Dir>/stable-macos (zero when there is none).
func (rs *ReleaseStore) macPointer() stablePointer {
	var p stablePointer
	b, err := os.ReadFile(filepath.Join(rs.Dir, releaseStableMacOS))
	if err != nil || json.Unmarshal(b, &p) != nil || !release.ValidSHA(p.SHA) || p.Seq < 1 {
		return stablePointer{}
	}
	return p
}

// onStableChain: sha is stable, or a release stable once stood on and the
// chain still reaches (the pointer walked back along prev).
func (rs *ReleaseStore) onStableChain(sha string) bool {
	for _, s := range rs.chain(rs.stable().SHA) {
		if s == sha {
			return true
		}
	}
	return false
}

// macTTL: how long a read of the Mac lane is trusted (/version asks on every
// client check; the pointer changes only on a publish).
const macTTL = 5 * time.Second

// MacStableSHA is the Mac lane's release, or "" — none set, pruned, or no
// longer on stable's chain (a stable rolled back under it: the Mac lane is
// never ahead of stable, so it reads as unset and a Mac follows stable).
func (rs *ReleaseStore) MacStableSHA() string {
	if rs == nil {
		return ""
	}
	rs.pubMu.Lock()
	if time.Since(rs.macAt) < macTTL {
		sha := rs.macSHA
		rs.pubMu.Unlock()
		return sha
	}
	rs.pubMu.Unlock()
	sha := ""
	if p := rs.macPointer(); p.SHA != "" && rs.Has(p.SHA) && rs.onStableChain(p.SHA) {
		sha = p.SHA
	}
	rs.pubMu.Lock()
	rs.macAt, rs.macSHA = time.Now(), sha
	rs.pubMu.Unlock()
	return sha
}

// StableSHAFor is /v1/fleet/release/stable for one platform: darwin with a Mac
// lane ⇒ its release, everything else ⇒ stable.
func (rs *ReleaseStore) StableSHAFor(platform string) string {
	if platform == "darwin" {
		if sha := rs.MacStableSHA(); sha != "" {
			return sha
		}
	}
	return rs.StableSHA()
}

// moveMac makes sha the Mac lane: a release this store holds on stable's chain
// (never ahead of stable), never behind the lane's current one.
func (rs *ReleaseStore) moveMac(sha string) (map[string]any, error) {
	rs.promoteMu.Lock()
	defer rs.promoteMu.Unlock()
	cur := rs.stable()
	if cur.SHA == "" {
		return nil, publishErr(http.StatusConflict, "this hub has no stable yet — the Mac lane follows stable, publish stable first")
	}
	m := rs.manifest(sha)
	if !rs.Has(sha) || m == nil || m.Seq < 1 || !rs.onStableChain(sha) {
		return nil, publishErr(http.StatusConflict, "%s is not a release on this hub's stable chain (stable %s) — the Mac lane only ever names a release that was stable already", short(sha), short(cur.SHA))
	}
	out := func(status string) map[string]any {
		return map[string]any{"status": status, "ref": RefStableMacOS, "sha": sha, "prev": "", "seq": m.Seq}
	}
	old := rs.macPointer()
	if old.SHA == sha {
		return out("already"), nil
	}
	if old.SHA != "" && rs.onStableChain(old.SHA) && m.Seq < old.Seq {
		return nil, publishErr(http.StatusConflict, "%s (#%d) is behind the Mac lane's %s (#%d) — it only moves forward", short(sha), m.Seq, short(old.SHA), old.Seq)
	}
	b, _ := json.Marshal(stablePointer{SHA: sha, Seq: m.Seq})
	if err := replaceFile(filepath.Join(rs.Dir, releaseStableMacOS), fmt.Sprintf(".stable-macos-%d-%s", m.Seq, sha[:12]), append(b, '\n')); err != nil {
		return nil, err
	}
	rs.pubMu.Lock()
	rs.macAt = time.Time{} // re-read now
	rs.pubMu.Unlock()
	return out("published"), nil
}
