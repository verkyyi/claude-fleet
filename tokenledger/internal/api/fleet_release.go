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
//
// Public like /install: it is the public repo's files and the binaries
// /install already hands out — nothing here is a credential, and what makes it
// safe to take is the signature, checked against the key the machine pinned at
// install (`ccquota release fetch`). A sha the hub has not seen stable at and
// does not already hold is a 404 — never an open builder. No signing key
// (CCQUOTA_FLEET_RELEASE_KEY unset) ⇒ no store ⇒ every route 404s: the hub
// exactly as before.

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
	ArtifactsDir  string             // pinned installers (Claude Code, Codex …)
	Platforms     []string           // <os>-<arch> a release must carry release.json's pins for (default release.DefaultPlatforms)
	NPMRegistries []string           // where a missing Claude Code is fetched from (default DefaultNPMRegistries)
	Client        *http.Client       // the fetches' client (tests); nil = one per call
	Keep          int                // default ReleaseKeep

	mu        sync.Mutex
	building  map[string]*releaseBuild
	whole     map[string]bool      // build dirs found carrying every pin (heal)
	healTried map[string]time.Time // sha → last heal look
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

// releasePathOK — what a node runtime holds: the repo's top-level files and
// its runtime trees; never the Go source, the deploy tree or the CI's files.
// The client manifest rides along (the tarball reader requires it).
func releasePathOK(p string) bool {
	if p == StableManifestPath {
		return true
	}
	if p == "" || strings.Contains(p, "..") || strings.Contains(p, "//") || strings.HasSuffix(p, "/") || strings.ContainsAny(p, "\\\x00") {
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

// Ensure builds <sha> unless it is on disk; concurrent callers share one build.
func (rs *ReleaseStore) Ensure(ctx context.Context, sha string) error {
	return rs.ensure(ctx, sha, false)
}

// ensure builds <sha>; rebuild builds it again even when one is on disk (heal).
func (rs *ReleaseStore) ensure(ctx context.Context, sha string, rebuild bool) error {
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
			b.err = rs.build(bctx, sha)
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

func (rs *ReleaseStore) build(ctx context.Context, sha string) error {
	if rs.Source == nil {
		return errors.New("no stable source")
	}
	files, err := rs.Source.Tree(ctx, sha, releasePathOK)
	if err != nil {
		return err
	}
	arts := rs.artifacts()
	missing, err := rs.missingPinned(files, arts)
	if err != nil {
		return err
	}
	if len(missing) > 0 && len(rs.fillPinned(ctx, missing)) < len(missing) {
		// the hub fetched some (claude-fleet#2631): read the dir again
		arts = rs.artifacts()
		if missing, err = rs.missingPinned(files, arts); err != nil {
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
	return rs.publish(sha, files, arts, time.Now())
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
func (rs *ReleaseStore) publish(sha string, files map[string][]byte, artifacts map[string]string, now time.Time) error {
	shaDir := filepath.Join(rs.Dir, sha)
	if err := os.MkdirAll(shaDir, 0o755); err != nil {
		return err
	}
	var rnd [6]byte
	_, _ = rand.Read(rnd[:])
	id := fmt.Sprintf("b%d-%s", now.Unix(), hex.EncodeToString(rnd[:]))
	if _, err := release.Build(filepath.Join(shaDir, id), rs.Repo, sha, files, artifacts, rs.Key, now); err != nil {
		_ = os.RemoveAll(filepath.Join(shaDir, id))
		return err
	}
	// a file rename is one server-side copy on an object store: a reader sees
	// the old current or the new one, never half of it
	tmp := filepath.Join(shaDir, ".current-"+id)
	if err := os.WriteFile(tmp, []byte(id+"\n"), 0o644); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, filepath.Join(shaDir, releaseCurrent)); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	rs.prune()
	return nil
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
		if served != "" {
			if b, err := os.ReadFile(filepath.Join(served, release.ManifestName)); err == nil {
				var m release.Manifest
				if json.Unmarshal(b, &m) == nil {
					at = m.Created
				}
			}
		}
		rels = append(rels, rel{n, at})
	}
	sort.Slice(rels, func(i, j int) bool { return rels[i].at.After(rels[j].at) })
	for i, r := range rels {
		if i >= rs.keep() && r.sha != cur {
			_ = os.RemoveAll(filepath.Join(rs.Dir, r.sha))
		}
	}
}

// OnStable is StableSource.OnStable: build each new stable in the background.
func (rs *ReleaseStore) OnStable(sha string) {
	ctx, cancel := context.WithTimeout(context.Background(), releaseBuildTime)
	defer cancel()
	_ = rs.Ensure(ctx, sha)
}

// handleRelease serves GET /v1/fleet/release/….
func (s *Server) handleRelease(w http.ResponseWriter, r *http.Request) {
	rs := s.Releases
	if rs == nil {
		http.NotFound(w, r)
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
		_ = json.NewEncoder(w).Encode(map[string]any{"artifacts": names, "platforms": rs.platforms(),
			"fetchable": rs.fetchable(r.Context(), have, want)})
		return
	}
	sha, sub, _ := strings.Cut(rest, "/")
	if sha == "stable" && sub == "" && rs.Source != nil {
		sha = rs.Source.Commit()
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
	if err := rs.ensure(ctx, sha, true); err != nil {
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
