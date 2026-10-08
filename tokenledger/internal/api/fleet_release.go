package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
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
const releaseBuildTime = 3 * time.Minute

// ReleaseStore builds, keeps and serves node releases.
type ReleaseStore struct {
	Dir          string             // one <sha>/ per release
	Key          ed25519.PrivateKey // signs every manifest
	Repo         string             // owner/name, written into the manifest
	Source       *StableSource      // where a commit's files come from
	DistDir      string             // ccquota-<os>-<arch> binaries (FleetDistDir)
	ArtifactsDir string             // pinned installers (Claude Code, Codex …)
	Keep         int                // default ReleaseKeep

	mu       sync.Mutex
	building map[string]*releaseBuild
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

func (rs *ReleaseStore) dir(sha string) string { return filepath.Join(rs.Dir, sha) }

// Has: <sha> is built and on disk.
func (rs *ReleaseStore) Has(sha string) bool {
	_, err := os.Stat(filepath.Join(rs.dir(sha), release.SigName))
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
	if !release.ValidSHA(sha) {
		return fmt.Errorf("bad sha %q", sha)
	}
	if rs.Has(sha) {
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
	if err := os.MkdirAll(rs.Dir, 0o755); err != nil {
		return err
	}
	var rnd [6]byte
	_, _ = rand.Read(rnd[:])
	tmp := filepath.Join(rs.Dir, ".tmp-"+sha+"-"+hex.EncodeToString(rnd[:]))
	if _, err := release.Build(tmp, rs.Repo, sha, files, rs.artifacts(), rs.Key, time.Now()); err != nil {
		_ = os.RemoveAll(tmp)
		return err
	}
	if err := os.Rename(tmp, rs.dir(sha)); err != nil {
		_ = os.RemoveAll(tmp)
		if rs.Has(sha) { // another replica of the volume won the race
			return nil
		}
		return err
	}
	rs.prune()
	return nil
}

// prune keeps the newest Keep releases (by their manifest's time) and never
// the one stable names now; stray build directories go too.
func (rs *ReleaseStore) prune() {
	ents, err := os.ReadDir(rs.Dir)
	if err != nil {
		return
	}
	cur := ""
	if rs.Source != nil {
		cur = rs.Source.Commit()
	}
	type rel struct {
		sha string
		at  time.Time
	}
	var rels []rel
	for _, e := range ents {
		n := e.Name()
		if strings.HasPrefix(n, ".tmp-") {
			if st, err := os.Stat(filepath.Join(rs.Dir, n)); err == nil && time.Since(st.ModTime()) > 2*releaseBuildTime {
				_ = os.RemoveAll(filepath.Join(rs.Dir, n))
			}
			continue
		}
		if !e.IsDir() || !release.ValidSHA(n) {
			continue
		}
		at := time.Time{}
		if b, err := os.ReadFile(filepath.Join(rs.Dir, n, release.ManifestName)); err == nil {
			var m release.Manifest
			if json.Unmarshal(b, &m) == nil {
				at = m.Created
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
	}
	base := rs.dir(sha)
	var file, ctype string
	immutable := true
	switch {
	case sub == "":
		file, ctype = release.ManifestName, "application/json"
		immutable = rest != "stable"
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
