package api

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// A self-hosted hub follows ANOTHER hub's releases, not GitHub
// (claude-fleet#4847, EPIC #4839 C8).
//
// Where a hub's stable comes from, first that answers:
//
//	release   pushed to its own release store by the train (fleet_publish.go)
//	upstream  CCQUOTA_FLEET_UPSTREAM_HUB: that hub's signed stable, taken with
//	          the same protocol a client uses (fleet-release-fetch.py,
//	          release.Fetcher) and kept whole in this store — its manifest,
//	          signature, tree and artifacts, byte for byte
//	github    only when CCQUOTA_FLEET_STABLE_REPO names a repo (set by hand)
//	image     none of them: the client packed into this build
//
// Trust: nothing the upstream says is taken on its word. The manifest must
// verify against this store's anchor — CCQUOTA_FLEET_RELEASE_ROOT, the
// upstream's /v1/fleet/release/key copied once by the operator — through the
// commit's key chain and every revocation, the tree and each artifact against
// the digests it signs. So a mirroring store holds no signing key of its own
// (TrainSigned): it serves the upstream's signature, never its own. A release
// only ever moves forward (a higher seq than this store's stable).
//
// When: lazily, like the GitHub lookup it replaces — a /version (or any
// stable read) past StableSource's TTL starts ONE look in the background; no
// new loop, no new service. A look that finds the upstream on this store's
// stable already does nothing more.

// /version's stable_source: where the stable this hub hands out comes from.
const (
	stableSrcRelease  = "release"
	stableSrcUpstream = "upstream"
	stableSrcGitHub   = "github"
	stableSrcImage    = "image"
)

// upstreamMirrorTime bounds one mirror (a release's artifacts are hundreds of MB).
const upstreamMirrorTime = releaseBuildTime

// errUpstreamBehind: the upstream's stable is not past this store's.
var errUpstreamBehind = errors.New("upstream is not ahead")

// MirrorStable takes hub's stable into this store and makes it stable here;
// it returns the sha this store's stable is on afterwards.
func (rs *ReleaseStore) MirrorStable(ctx context.Context, hub string) (string, error) {
	if !rs.TrainSigned() {
		return "", errors.New("a hub that signs its own releases does not mirror another's — unset CCQUOTA_FLEET_RELEASE_KEY")
	}
	anchor := rs.anchor()
	if anchor == nil {
		return "", errors.New("no CCQUOTA_FLEET_RELEASE_ROOT to check the upstream's releases against")
	}
	f := &release.Fetcher{Hub: hub, Key: anchor, Client: rs.Client}
	m, _, _, err := f.Manifest(ctx, "stable")
	if err != nil {
		return rs.stable().SHA, fmt.Errorf("upstream %s: %w", hub, err)
	}
	rs.promoteMu.Lock()
	defer rs.promoteMu.Unlock()
	cur := rs.stable()
	if cur.SHA == m.SHA && rs.Has(m.SHA) {
		return cur.SHA, rs.markPublished(m.SHA)
	}
	if cur.SHA != "" && m.Seq <= cur.Seq {
		return cur.SHA, fmt.Errorf("upstream %s: stable %s is #%d, this hub's %s is #%d: %w",
			hub, short(m.SHA), m.Seq, short(cur.SHA), cur.Seq, errUpstreamBehind)
	}
	shaDir := filepath.Join(rs.Dir, m.SHA)
	if err := os.MkdirAll(shaDir, 0o755); err != nil {
		return cur.SHA, err
	}
	id := newBuildID(time.Now())
	if have := rs.manifest(m.SHA); !rs.Has(m.SHA) || have == nil || have.Seq != m.Seq {
		if _, err := f.Mirror(ctx, m.SHA, filepath.Join(shaDir, id)); err != nil {
			return cur.SHA, fmt.Errorf("upstream %s: release %s: %w", hub, short(m.SHA), err)
		}
		if err := replaceFile(filepath.Join(shaDir, releaseCurrent), ".current-"+id, []byte(id+"\n")); err != nil {
			return cur.SHA, err
		}
	}
	if err := rs.markPublished(m.SHA); err != nil {
		return cur.SHA, err
	}
	if err := rs.movePointer(m.SHA, m.Seq); err != nil {
		return cur.SHA, err
	}
	log.Printf("fleet: release %s (#%d) taken from upstream %s", short(m.SHA), m.Seq, hub)
	return m.SHA, nil
}

// refreshUpstream is Refresh for a source that follows an upstream hub.
func (s *StableSource) refreshUpstream(ctx context.Context) error {
	mr, ok := s.Local.(stableMirror)
	if !ok {
		return errors.New("CCQUOTA_FLEET_UPSTREAM_HUB needs a release store")
	}
	_, err := mr.MirrorStable(ctx, s.Upstream)
	s.mu.Lock()
	s.at, s.problem = time.Now(), ""
	if err != nil && !errors.Is(err, errUpstreamBehind) {
		s.problem = "cannot take stable from the upstream hub: " + err.Error()
	}
	s.mu.Unlock()
	if errors.Is(err, errUpstreamBehind) {
		return nil
	}
	return err
}

// stableMirror is the release store, for a source that follows an upstream.
type stableMirror interface {
	MirrorStable(ctx context.Context, hub string) (string, error)
}
