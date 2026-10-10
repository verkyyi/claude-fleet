package api

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// Node releases: the hub keeps every stable's files, and machines fetch them
// from here only (claude-fleet#2335, EPIC #2329 C7).
//
// A machine used to follow stable by `git fetch`ing GitHub — once per login,
// every 30 minutes, and not at all from a network that cannot reach GitHub.
// Now the hub follows GitHub (StableSource) and, each time stable moves,
// builds a release for that commit (internal/release): the runtime tree as one
// tar, the ccquota binaries for every platform it has (FleetDistDir), the
// Claude Code / Codex installers the operator pinned (the artifacts dir), a
// sha256 for each and its ed25519 signature over the lot. Kept on the hub's
// volume — the cluster's OSS bucket mounted, in production — newest
// ReleaseKeep (10), never the current stable.
//
//	GET /v1/fleet/release/key                   the signing public key
//	GET /v1/fleet/release/artifacts             the artifact names a build now carries
//	GET /v1/fleet/release/<sha|stable>          the signed manifest (.files …)
//	GET /v1/fleet/release/<sha>/manifest.sig    its signature
//	GET /v1/fleet/release/<sha>/tree.tar.gz     the runtime tree
//	GET /v1/fleet/release/<sha>/artifacts/<n>   one binary / installer
//	POST /v1/fleet/release/publish              the CI hands over a stable (fleet_publish.go)
//
// Since claude-fleet#2772 stable comes by that POST, not by StableSource's
// lookup: the commit's own bytes, checked against its sha here, then built from
// them — and once one has landed the store never asks GitHub again.
//
// Public like /install: it is the public repo's files and the binaries
// /install already hands out — nothing here is a credential, and what makes it
// safe to take is the signature, checked against the key the machine pinned at
// install (`ccquota release fetch`). A sha the hub has not seen stable at and
// does not already hold is a 404 — never an open builder. No signing key
// (CCQUOTA_FLEET_RELEASE_KEY unset) ⇒ no store ⇒ every route 404s: the hub
// exactly as before.
//
// What a release holds is the commit's own conf/release-tree.list
// (claude-fleet#2771, EPIC #2770 C1): the whole install a login needs — the
// runtime trees, .claude-plugin/, extras/ — and never the Go source, the
// deploy tree or the CI's files. A commit from before the list gets the old
// fixed set (releasePathOK).
//
// Which release is stable is the store's own pointer, <Dir>/stable — moved by
// one rename once the release it names is built and sealed (promote) — and
// every stable release carries its place on that chain under the signature:
// prev (the stable it replaced) and seq (+1 per move).

// ReleaseKeep is how many releases the store keeps.
const ReleaseKeep = 10

// releaseBuildTime bounds one build (a GitHub tarball + the copies).
const releaseBuildTime = 8 * time.Minute // room for a Claude Code fetch (claude-fleet#2631)

// ReleaseStore builds, keeps and serves node releases.
type ReleaseStore struct {
	Dir           string             // one <sha>/ per release
	Key           ed25519.PrivateKey // signs every manifest
	Repo          string             // owner/name, written into the manifest
	Source        *StableSource      // where a commit's files come from
	DistDir       string             // ccquota-<os>-<arch> binaries (FleetDistDir)
	DistSrc       string             // the Go source digest DistDir's binaries were built from (main.SrcDigest; claude-fleet#2930)
	ArtifactsDir  string             // pinned installers (Claude Code, Codex …)
	Platforms     []string           // <os>-<arch> a release must carry release.json's pins for (default release.DefaultPlatforms)
	NPMRegistries []string           // where a missing Claude Code is fetched from (default DefaultNPMRegistries)
	Client        *http.Client       // the fetches' client (tests); nil = one per call
	Keep          int                // default ReleaseKeep
	Publish       *PublishAuth       // who may POST …/publish (claude-fleet#2772); nil = the route is off

	mu        sync.Mutex
	building  map[string]*releaseBuild
	pending   map[string]release.Seal // sha → the seal promote wants its build to carry
	promoteMu sync.Mutex
	whole     map[string]bool      // build dirs found carrying every pin (heal)
	healTried map[string]time.Time // sha → last heal look
	pubMu     sync.Mutex
	pubAt     time.Time // when PublishedStable last read the disk
	pubSHA    string
	pubOn     bool
}

type releaseBuild struct {
	done chan struct{}
	err  error
}

func (rs *ReleaseStore) keep() int {
	if rs.Keep > 0 {
		return rs.Keep
	}
	return ReleaseKeep
}

// On-volume layout — written for an object store as much as a disk
// (claude-fleet#2366: production keeps it on an OSS bucket through ossfs,
// where a directory rename is copy-every-object-then-delete, not atomic, and
// both replicas build the same stable at once):
//
//	<Dir>/<sha>/b<unix>-<hex>/   one build, written in place, signature last,
//	                             never renamed and never changed after
//	<Dir>/<sha>/current          the build that is served: one small object,
//	                             replaced by a single-file rename
//
// Two replicas racing each finish their own build and point current at it;
// whichever wins, current names a whole, self-consistent build. The loser is
// pruned later.
const releaseCurrent = "current"

var buildIDRe = regexp.MustCompile(`^b([0-9]{1,19})-[0-9a-f]{12}$`)

// dir is the build current names for <sha> ("" when there is none).
func (rs *ReleaseStore) dir(sha string) string {
	b, err := os.ReadFile(filepath.Join(rs.Dir, sha, releaseCurrent))
	id := strings.TrimSpace(string(b))
	if err != nil || !buildIDRe.MatchString(id) {
		return ""
	}
	return filepath.Join(rs.Dir, sha, id)
}

// Has: <sha> is built and on disk.
func (rs *ReleaseStore) Has(sha string) bool {
	d := rs.dir(sha)
	if d == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(d, release.SigName))
	return err == nil
}

// releasePathSafe — a path that stays inside the tree; what the tarball
// reader takes before the commit's release-tree.list picks.
func releasePathSafe(p string) bool {
	return p != "" && !strings.Contains(p, "..") && !strings.Contains(p, "//") && !strings.HasSuffix(p, "/") && !strings.ContainsAny(p, "\\\x00")
}

// releaseTree keeps what the commit's own conf/release-tree.list names
// (claude-fleet#2771); a commit without one gets releasePathOK's old set. The
// client manifest rides along either way (the tarball reader requires it).
func releaseTree(files map[string][]byte) (map[string][]byte, error) {
	keep := releasePathOK
	if b, ok := files[release.TreeListPath]; ok {
		l, err := release.ParseTreeList(b)
		if err != nil {
			return nil, err
		}
		keep = func(p string) bool { return p == StableManifestPath || l.Keep(p) }
	}
	out := make(map[string][]byte, len(files))
	for p, b := range files {
		if releasePathSafe(p) && keep(p) {
			out[p] = b
		}
	}
	return out, nil
}

// releasePathOK — what a node runtime held before release-tree.list: the
// repo's top-level files and its runtime trees; never the Go source, the
// deploy tree or the CI's files.
func releasePathOK(p string) bool {
	if p == StableManifestPath {
		return true
	}
	if !releasePathSafe(p) {
		return false
	}
	if !strings.Contains(p, "/") {
		return !strings.HasPrefix(p, ".")
	}
	for _, d := range []string{"bin/", "conf/", "hooks/", "commands/", "skills/", "mod/", "shell/", "launchd/", "systemd/", "docs/"} {
		if strings.HasPrefix(p, d) {
			return true
		}
	}
	return false
}

var distArtifactRe = regexp.MustCompile(`^ccquota-(darwin|linux)-(amd64|arm64)$`)

// artifacts: name → source file, from the dist dir (ccquota binaries) and the
// pinned-installers dir (every regular file with a flat, sane name).
func (rs *ReleaseStore) artifacts() map[string]string {
	out := map[string]string{}
	add := func(dir string, ok func(string) bool) {
		if dir == "" {
			return
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			n := e.Name()
			if !ok(n) || !release.ValidArtifact(n) {
				continue
			}
			if st, err := os.Stat(filepath.Join(dir, n)); err == nil && st.Mode().IsRegular() {
				out[n] = filepath.Join(dir, n)
			}
		}
	}
	add(rs.DistDir, distArtifactRe.MatchString)
	add(rs.ArtifactsDir, func(n string) bool { return !strings.HasPrefix(n, ".") })
	return out
}

// distSrcCheck: may a release whose commit's Go source digests to src carry
// arts' ccquota binaries? Only when they were built from that very source
// (claude-fleet#2930): a release used to take whatever ccquota the hub image
// had, so a new runtime went out with an old ccquota — and a release is built
// once, never again. Refused like a missing pin, the next request after the
// image catches up builds it whole. No ccquota in arts, or a commit with no Go
// source (src ""), is nothing to check.
func (rs *ReleaseStore) distSrcCheck(src string, arts map[string]string) error {
	if src == "" {
		return nil
	}
	carries := false
	for n := range arts {
		if distArtifactRe.MatchString(n) {
			carries = true
		}
	}
	switch {
	case !carries || rs.DistSrc == src:
		return nil
	case rs.DistSrc == "":
		return fmt.Errorf("the hub's ccquota binaries name no Go source (an image built without the Dockerfile's src stamp) — cannot vouch they are this commit's (Go source %s); redeploy the hub image", src[:12])
	}
	return fmt.Errorf("the hub's ccquota binaries were built from Go source %s, this commit's tokenledger/ is %s — redeploy the hub image from this commit (or a later one with the same tokenledger/) first", rs.DistSrc[:min(12, len(rs.DistSrc))], src[:12])
}

// Ensure builds <sha> unless it is on disk; concurrent callers share one build.
func (rs *ReleaseStore) Ensure(ctx context.Context, sha string) error {
	return rs.ensure(ctx, sha, false, nil)
}

// ensure builds <sha>; rebuild builds it again even when one is on disk (heal).
// all, when given, is the commit's files (a publish) — else the build reads
// them from its own disk or the source.
func (rs *ReleaseStore) ensure(ctx context.Context, sha string, rebuild bool, all map[string][]byte) error {
	if !release.ValidSHA(sha) {
		return fmt.Errorf("bad sha %q", sha)
	}
	if !rebuild && rs.Has(sha) {
		return nil
	}
	rs.mu.Lock()
	b, ok := rs.building[sha]
	if !ok {
		if rs.building == nil {
			rs.building = map[string]*releaseBuild{}
		}
		b = &releaseBuild{done: make(chan struct{})}
		rs.building[sha] = b
		go func() {
			bctx, cancel := context.WithTimeout(context.Background(), releaseBuildTime)
			defer cancel()
			b.err = rs.build(bctx, sha, all)
			if b.err != nil {
				log.Printf("fleet: release %s: %v", sha[:7], b.err)
			} else {
				log.Printf("fleet: release %s built and signed", sha[:7])
			}
			rs.mu.Lock()
			delete(rs.building, sha)
			rs.mu.Unlock()
			close(b.done)
		}()
	}
	rs.mu.Unlock()
	select {
	case <-b.done:
		return b.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (rs *ReleaseStore) build(ctx context.Context, sha string, all map[string][]byte) error {
	var err error
	seal := rs.sealFor(sha)
	rebuilt := ""
	switch base := rs.dir(sha); {
	case all != nil:
	case base != "":
		// a rebuild (heal) takes the commit's files from the build it replaces:
		// the same bytes, no network (claude-fleet#2772) — and its ccquota too:
		// the tree carries no Go source to hold another one to (#2930)
		if all, err = treeFiles(filepath.Join(base, release.TreeName)); err != nil {
			return err
		}
		rebuilt = base
	case rs.Source == nil:
		return errors.New("no stable source")
	default:
		if all, err = rs.Source.Tree(ctx, sha, releasePathSafe); err != nil {
			return err
		}
	}
	if rebuilt == "" {
		seal.Src = release.SourceDigest(all)
	}
	files, err := releaseTree(all)
	if err != nil {
		return err
	}
	arts := rs.buildArtifacts(rebuilt)
	missing, err := rs.missingPinned(files, arts)
	if err != nil {
		return err
	}
	if len(missing) > 0 && len(rs.fillPinned(ctx, missing)) < len(missing) {
		// the hub fetched some (claude-fleet#2631): read the dir again
		arts = rs.buildArtifacts(rebuilt)
		if missing, err = rs.missingPinned(files, arts); err != nil {
			return err
		}
	}
	if rebuilt == "" {
		if err := rs.distSrcCheck(seal.Src, arts); err != nil {
			return err
		}
	}
	if len(missing) > 0 {
		// never bake a release a managed machine cannot install: it would be
		// kept, never rebuilt, and every machine would sit in backoff on it
		// (claude-fleet#2631). Unbuilt, the next request after the file lands
		// builds the whole one.
		return fmt.Errorf("release.json pins %s, which CCQUOTA_FLEET_RELEASE_ARTIFACTS does not hold — put it there", strings.Join(missing, ", "))
	}
	return rs.publish(sha, files, arts, time.Now(), seal)
}

// buildArtifacts: rs.artifacts(), but a rebuild of the build in base keeps
// that build's ccquota-* (claude-fleet#2930) — the binaries checked against
// its commit, never the image's of today.
func (rs *ReleaseStore) buildArtifacts(base string) map[string]string {
	arts := rs.artifacts()
	if base == "" {
		return arts
	}
	for n := range arts {
		if distArtifactRe.MatchString(n) {
			delete(arts, n)
		}
	}
	for n, p := range builtArtifacts(base) {
		if distArtifactRe.MatchString(n) {
			arts[n] = p
		}
	}
	return arts
}

// builtArtifacts: name → file of the artifacts a build carries.
func builtArtifacts(base string) map[string]string {
	arts := map[string]string{}
	ents, _ := os.ReadDir(filepath.Join(base, release.ArtifactDir))
	for _, e := range ents {
		if release.ValidArtifact(e.Name()) && e.Type().IsRegular() {
			arts[e.Name()] = filepath.Join(base, release.ArtifactDir, e.Name())
		}
	}
	return arts
}

// sealFor: the seal a new build of sha carries — the one promote is waiting
// on, else the one the served build already has (a heal keeps its place on
// the chain), else none.
func (rs *ReleaseStore) sealFor(sha string) release.Seal {
	rs.mu.Lock()
	seal, ok := rs.pending[sha]
	rs.mu.Unlock()
	if ok {
		return seal
	}
	if m := rs.manifest(sha); m != nil {
		return release.Seal{Prev: m.Prev, Seq: m.Seq, Src: m.CCQuotaSrc}
	}
	return release.Seal{}
}

// manifest: the served build's manifest of sha (nil when none).
func (rs *ReleaseStore) manifest(sha string) *release.Manifest {
	base := rs.dir(sha)
	if base == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(base, release.ManifestName))
	if err != nil {
		return nil
	}
	var m release.Manifest
	if json.Unmarshal(b, &m) != nil {
		return nil
	}
	return &m
}

func (rs *ReleaseStore) platforms() []string {
	if len(rs.Platforms) > 0 {
		return rs.Platforms
	}
	return release.DefaultPlatforms
}

// missingPinned: the artifacts the tree's release.json pins that arts lacks.
// A tree with no release.json pins nothing.
func (rs *ReleaseStore) missingPinned(files map[string][]byte, arts map[string]string) ([]string, error) {
	rj, ok := files[release.ReleaseJSON]
	if !ok {
		return nil, nil
	}
	want, err := release.Pinned(rj, rs.platforms())
	if err != nil {
		return nil, err
	}
	var missing []string
	for _, n := range want {
		if _, ok := arts[n]; !ok {
			missing = append(missing, n)
		}
	}
	return missing, nil
}

// publish writes one build of <sha> into its own directory (release.Build
// writes the signature last) and then points current at it.
func (rs *ReleaseStore) publish(sha string, files map[string][]byte, artifacts map[string]string, now time.Time, seal release.Seal) error {
	shaDir := filepath.Join(rs.Dir, sha)
	if err := os.MkdirAll(shaDir, 0o755); err != nil {
		return err
	}
	var rnd [6]byte
	_, _ = rand.Read(rnd[:])
	id := fmt.Sprintf("b%d-%s", now.Unix(), hex.EncodeToString(rnd[:]))
	if _, err := release.BuildSealed(filepath.Join(shaDir, id), rs.Repo, sha, files, artifacts, rs.Key, now, seal); err != nil {
		_ = os.RemoveAll(filepath.Join(shaDir, id))
		return err
	}
	// a file rename is one server-side copy on an object store: a reader sees
	// the old current or the new one, never half of it
	if err := replaceFile(filepath.Join(shaDir, releaseCurrent), ".current-"+id, []byte(id+"\n")); err != nil {
		return err
	}
	rs.prune()
	return nil
}

// replaceFile writes b to path by one rename from <dir>/<tmpName>.
func replaceFile(path, tmpName string, b []byte) error {
	tmp := filepath.Join(filepath.Dir(path), tmpName)
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// releaseStable is the store's stable pointer, <Dir>/stable (claude-fleet#2771).
const releaseStable = "stable"

// stablePointer is what <Dir>/stable holds.
type stablePointer struct {
	SHA string `json:"sha"`
	Seq int64  `json:"seq"`
}

// stable reads the pointer (zero when there is none yet).
func (rs *ReleaseStore) stable() stablePointer {
	var p stablePointer
	b, err := os.ReadFile(filepath.Join(rs.Dir, releaseStable))
	if err != nil || json.Unmarshal(b, &p) != nil || !release.ValidSHA(p.SHA) || p.Seq < 1 {
		return stablePointer{}
	}
	return p
}

// StableSHA is the release /v1/fleet/release/stable serves: the pointer, else
// — a store that has promoted nothing yet — what the source last saw.
func (rs *ReleaseStore) StableSHA() string {
	if p := rs.stable(); p.SHA != "" {
		return p.SHA
	}
	if rs.Source != nil {
		return rs.Source.Commit()
	}
	return ""
}

// promote makes sha the stable release: built, sealed one past the pointer
// (prev = the pointer's sha, seq = its seq + 1), then the pointer moved by one
// rename. Every step looks before it acts, so a promote that died half way —
// or another replica's promote of the same sha — is finished, never repeated:
// the pointer already on sha is a no-op, a build already carrying the wanted
// seal is not redone.
func (rs *ReleaseStore) promote(ctx context.Context, sha string) error {
	return rs.promoteWith(ctx, sha, nil)
}

// promoteWith is promote building from all — a publish's files — when the
// release is not on disk yet.
func (rs *ReleaseStore) promoteWith(ctx context.Context, sha string, all map[string][]byte) error {
	if !release.ValidSHA(sha) {
		return fmt.Errorf("bad sha %q", sha)
	}
	rs.promoteMu.Lock()
	defer rs.promoteMu.Unlock()
	cur := rs.stable()
	if cur.SHA == sha {
		return rs.ensure(ctx, sha, false, all)
	}
	want := release.Seal{Prev: cur.SHA, Seq: cur.Seq + 1}
	rs.mu.Lock()
	if rs.pending == nil {
		rs.pending = map[string]release.Seal{}
	}
	rs.pending[sha] = want
	rs.mu.Unlock()
	defer func() {
		rs.mu.Lock()
		delete(rs.pending, sha)
		rs.mu.Unlock()
	}()
	if err := rs.ensure(ctx, sha, false, all); err != nil {
		return err
	}
	if m := rs.manifest(sha); m == nil || m.Prev != want.Prev || m.Seq != want.Seq {
		// built before it was stable (or stable once before, under another
		// seq): sign it again with its new place, from its own files
		if err := rs.reseal(sha, want); err != nil {
			return err
		}
	}
	b, _ := json.Marshal(stablePointer{SHA: sha, Seq: want.Seq})
	if err := replaceFile(filepath.Join(rs.Dir, releaseStable), fmt.Sprintf(".stable-%d-%s", want.Seq, sha[:12]), append(b, '\n')); err != nil {
		return err
	}
	rs.pubMu.Lock()
	rs.pubAt = time.Time{} // PublishedStable reads the new pointer
	rs.pubMu.Unlock()
	log.Printf("fleet: release %s is stable #%d", sha[:7], want.Seq)
	rs.prune()
	return nil
}

// reseal publishes a new build of sha from its served build — the same tree
// and artifacts — carrying seal. No network: the bytes are already here.
func (rs *ReleaseStore) reseal(sha string, seal release.Seal) error {
	base := rs.dir(sha)
	if base == "" {
		return fmt.Errorf("release %s: nothing to reseal", sha[:7])
	}
	files, err := treeFiles(filepath.Join(base, release.TreeName))
	if err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(base, release.ArtifactDir)); err != nil && !os.IsNotExist(err) {
		return err
	}
	if m := rs.manifest(sha); m != nil {
		seal.Src = m.CCQuotaSrc // the same artifacts, the same check
	}
	return rs.publish(sha, files, builtArtifacts(base), time.Now(), seal)
}

// prune keeps the newest Keep releases (by their manifest's time) and never
// the one stable names now. Inside a kept release, builds current does not
// name (a lost race, a build that died) go once they are older than any build
// still running; so do stray entries from the layout before #2366.
func (rs *ReleaseStore) prune() {
	ents, err := os.ReadDir(rs.Dir)
	if err != nil {
		return
	}
	cur := ""
	if rs.Source != nil {
		cur = rs.Source.Commit()
	}
	ptr := rs.stable().SHA
	stale := func(unix int64) bool { return time.Since(time.Unix(unix, 0)) > 2*releaseBuildTime }
	type rel struct {
		sha string
		at  time.Time
	}
	var rels []rel
	for _, e := range ents {
		n := e.Name()
		if strings.HasPrefix(n, ".tmp-") { // the rename layout's staging dirs
			if st, err := os.Stat(filepath.Join(rs.Dir, n)); err == nil && stale(st.ModTime().Unix()) {
				_ = os.RemoveAll(filepath.Join(rs.Dir, n))
			}
			continue
		}
		if !e.IsDir() || !release.ValidSHA(n) {
			continue
		}
		served := rs.dir(n)
		if bs, err := os.ReadDir(filepath.Join(rs.Dir, n)); err == nil {
			for _, b := range bs {
				p := filepath.Join(rs.Dir, n, b.Name())
				if p == served || b.Name() == releaseCurrent {
					continue
				}
				if m := buildIDRe.FindStringSubmatch(b.Name()); m != nil {
					var unix int64
					_, _ = fmt.Sscan(m[1], &unix)
					if stale(unix) {
						_ = os.RemoveAll(p)
					}
				} else if strings.HasPrefix(b.Name(), ".current-") {
					if st, err := os.Stat(p); err == nil && stale(st.ModTime().Unix()) {
						_ = os.Remove(p)
					}
				}
			}
		}
		at := time.Time{}
		if m := rs.manifest(n); m != nil {
			at = m.Created
		}
		rels = append(rels, rel{n, at})
	}
	// the stable chain first (claude-fleet#2771), walked back from the
	// pointer, then the rest newest first: the kept links stay one unbroken
	// run — every kept link's prev is kept too, but the oldest's. Never the
	// stable, nor a release being built or promoted (its pointer moves after).
	keep := map[string]bool{cur: true, ptr: true}
	rs.mu.Lock()
	for sha := range rs.pending {
		keep[sha] = true
	}
	for sha := range rs.building {
		keep[sha] = true
	}
	rs.mu.Unlock()
	order := rs.chain(ptr)
	onChain := map[string]bool{}
	for _, sha := range order {
		onChain[sha] = true
	}
	sort.Slice(rels, func(i, j int) bool { return rels[i].at.After(rels[j].at) })
	for _, r := range rels {
		if !onChain[r.sha] {
			order = append(order, r.sha)
		}
	}
	for i, sha := range order {
		if i >= rs.keep() && !keep[sha] {
			_ = os.RemoveAll(filepath.Join(rs.Dir, sha))
		}
	}
}

// chain: from sha back along prev, every release on disk, each seq below the
// last (a release made stable again — a rollback — is resealed under a new
// seq, so the walk never loops).
func (rs *ReleaseStore) chain(sha string) []string {
	var out []string
	last := int64(-1)
	for sha != "" {
		m := rs.manifest(sha)
		if m == nil || m.Seq < 1 || (last >= 0 && m.Seq >= last) {
			break
		}
		out = append(out, sha)
		last, sha = m.Seq, m.Prev
	}
	return out
}

// OnStable is StableSource.OnStable: build each new stable in the background
// and make it the store's stable.
func (rs *ReleaseStore) OnStable(sha string) {
	if rs.published() {
		// stable comes by publish now (claude-fleet#2772): a lookup still in
		// flight from before the first one never moves the pointer
		log.Printf("fleet: release %s: GitHub says stable, ignored — this store takes publishes", sha[:7])
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), releaseBuildTime)
	defer cancel()
	if err := rs.promote(ctx, sha); err != nil {
		log.Printf("fleet: release %s: promote: %v", sha[:7], err)
	}
}

// handleRelease serves GET /v1/fleet/release/….
func (s *Server) handleRelease(w http.ResponseWriter, r *http.Request) {
	rs := s.Releases
	if rs == nil {
		http.NotFound(w, r)
		return
	}
	if strings.TrimPrefix(r.URL.Path, release.Path) == "publish" {
		s.handlePublish(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, release.Path)
	if rest == "key" {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte(release.FormatPublicKey(rs.Key.Public().(ed25519.PublicKey)) + "\n"))
		return
	}
	if rest == "artifacts" {
		// what a release built now would carry: fleet-stable.sh move checks
		// release.json's pins against it before stable moves (claude-fleet#2631)
		// ?want=a,b: which of those a build would fetch (Claude Code from npm)
		have := rs.artifacts()
		names := []string{}
		for n := range have {
			names = append(names, n)
		}
		sort.Strings(names)
		var want []string
		for _, n := range strings.Split(r.URL.Query().Get("want"), ",") {
			if n != "" && release.ValidArtifact(n) && len(want) < 16 {
				want = append(want, n)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		// ccquota_src: the Go source the ccquota-* were built from — fleet-stable.sh
		// move holds the target commit to it (claude-fleet#2930)
		_ = json.NewEncoder(w).Encode(map[string]any{"artifacts": names, "platforms": rs.platforms(),
			"fetchable": rs.fetchable(r.Context(), have, want), "ccquota_src": rs.DistSrc})
		return
	}
	sha, sub, _ := strings.Cut(rest, "/")
	if sha == "stable" && sub == "" {
		sha = rs.StableSHA()
	}
	if !release.ValidSHA(sha) {
		http.NotFound(w, r)
		return
	}
	if !rs.Has(sha) {
		// build only what stable has named — never an arbitrary commit
		if rs.Source == nil || !rs.Source.Seen(sha) {
			http.NotFound(w, r)
			return
		}
		if err := rs.Ensure(r.Context(), sha); err != nil {
			httpError(w, http.StatusBadGateway, "release "+sha[:7]+": "+err.Error())
			return
		}
	} else if sub == "" && rs.Source != nil && rs.Source.Seen(sha) {
		rs.heal(r.Context(), sha)
	}
	base := rs.dir(sha)
	if base == "" { // pruned since
		http.NotFound(w, r)
		return
	}
	var file, ctype string
	immutable := true
	switch {
	case sub == "":
		file, ctype = release.ManifestName, "application/json"
		immutable = false // a healed release re-signs it (claude-fleet#2631)
		if sig, err := os.ReadFile(filepath.Join(base, release.SigName)); err == nil {
			w.Header().Set("X-Ccquota-Release-Signature", strings.TrimSpace(string(sig)))
		}
	case sub == release.SigName:
		file, ctype = release.SigName, "text/plain; charset=utf-8"
	case sub == release.TreeName:
		file, ctype = release.TreeName, "application/gzip"
	case strings.HasPrefix(sub, release.ArtifactDir+"/") && release.ValidArtifact(strings.TrimPrefix(sub, release.ArtifactDir+"/")):
		file, ctype = sub, "application/octet-stream"
	default:
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(filepath.Join(base, filepath.FromSlash(file)))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if immutable {
		w.Header().Set("Cache-Control", "public, max-age=86400, immutable")
	} else {
		w.Header().Set("Cache-Control", "no-store")
	}
	http.ServeContent(w, r, "", st.ModTime(), f)
}

// releaseHealEvery: how often one release lacking a pinned artifact is retried.
const releaseHealEvery = 10 * time.Minute

// heal rebuilds a release on disk that lacks an artifact its release.json pins,
// once the hub can supply it (claude-fleet#2631): a release built before the
// file landed — or by a hub that could not fetch it — is otherwise kept as it
// is, and every managed machine sits in backoff on it until stable moves. A
// build found whole is never looked at again; a lacking one is retried at most
// every releaseHealEvery. A failed rebuild leaves the old one served.
func (rs *ReleaseStore) heal(ctx context.Context, sha string) {
	base := rs.dir(sha)
	if base == "" {
		return
	}
	rs.mu.Lock()
	if rs.whole == nil {
		rs.whole, rs.healTried = map[string]bool{}, map[string]time.Time{}
	}
	if rs.whole[base] || time.Since(rs.healTried[sha]) < releaseHealEvery {
		rs.mu.Unlock()
		return
	}
	rs.healTried[sha] = time.Now()
	rs.mu.Unlock()
	lack, err := rs.lacking(base)
	if err != nil || len(lack) == 0 {
		if err != nil {
			log.Printf("fleet: release %s: heal check: %v", sha[:7], err)
		}
		rs.mu.Lock()
		rs.whole[base] = err == nil
		rs.mu.Unlock()
		return
	}
	have := rs.artifacts()
	for _, n := range lack {
		if _, ok := have[n]; ok {
			continue
		}
		if _, _, ok := claudeNPM(n); !ok || rs.ArtifactsDir == "" {
			return // nothing the hub can do about this one
		}
	}
	log.Printf("fleet: release %s lacks %s — rebuilding", sha[:7], strings.Join(lack, ", "))
	if err := rs.ensure(ctx, sha, true, nil); err != nil {
		log.Printf("fleet: release %s: heal: %v", sha[:7], err)
	}
}

// lacking: the artifacts the build in base pins (its tree's release.json) but
// does not carry (its manifest).
func (rs *ReleaseStore) lacking(base string) ([]string, error) {
	mb, err := os.ReadFile(filepath.Join(base, release.ManifestName))
	if err != nil {
		return nil, err
	}
	var m release.Manifest
	if err := json.Unmarshal(mb, &m); err != nil {
		return nil, err
	}
	rj, err := treeFile(filepath.Join(base, release.TreeName), release.ReleaseJSON)
	if err != nil || rj == nil {
		return nil, err
	}
	want, err := release.Pinned(rj, rs.platforms())
	if err != nil {
		return nil, err
	}
	carried := map[string]bool{}
	for _, a := range m.Artifacts {
		carried[a.Name] = true
	}
	var out []string
	for _, n := range want {
		if !carried[n] {
			out = append(out, n)
		}
	}
	return out, nil
}

// treeFiles: every file of a release's tree.tar.gz.
func treeFiles(tgz string) (map[string][]byte, error) {
	f, err := os.Open(tgz)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(zr)
	out := map[string][]byte{}
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		if hd.Typeflag != tar.TypeReg {
			continue
		}
		b, err := io.ReadAll(io.LimitReader(tr, hd.Size))
		if err != nil {
			return nil, err
		}
		out[hd.Name] = b
	}
}

// treeFile: one file out of a release's tree.tar.gz (nil when it has none).
func treeFile(tgz, name string) ([]byte, error) {
	f, err := os.Open(tgz)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(zr)
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if hd.Name == name && hd.Typeflag == tar.TypeReg {
			return io.ReadAll(io.LimitReader(tr, 1<<20))
		}
	}
}
