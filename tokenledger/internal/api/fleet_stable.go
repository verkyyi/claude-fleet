package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// ONE update path: every computer follows the same stable (claude-fleet#1805,
// EPIC #1813 C3).
//
// Before this, a client followed the hub's IMAGE (the files packed into it at
// build time) while every machine followed git's refs/tags/stable — so moving
// stable upgraded the machines, and the MacBook's client waited for someone to
// redeploy the hub. Now the hub only REPORTS stable:
//
//   - GET /version's client_version is stable's commit (40 hex), with
//     `stable` (the same) and `client_url` — <hub>/install/stable/<sha>, the
//     repo's files at that commit through this hub (reachable where GitHub is
//     not). A client compares its .client-version with it, as before.
//   - GET /install/stable/<sha>/<path> is that file, fetched once from GitHub
//     and kept (a commit's bytes never change), SHA-256 in
//     X-Ccquota-Sha256 like every /install file. Only a sha this hub has seen
//     stable at, and only the client's paths — never an open proxy.
//   - GET /install serves stable's own installer when it is one that knows
//     this path (the stableAwareMark line), so a newer install logic needs no
//     redeploy either; an older stable's installer → the image's, as before.
//
// Stable unknown (GitHub out of reach since the hub started, the source off)
// → /version and /install are exactly the image's, byte for byte: the image's
// pack is the fallback, never removed. A nil StableSource is that, always.
//
// HOW the files are fetched (claude-fleet#1901): the whole commit at once, as
// codeload's tarball — ONE request that fills every client path — and only if
// that fails, file by file from the raw host. From the hub's cluster in China
// raw.githubusercontent.com is reset while api.github.com and
// codeload.github.com answer; file-by-file, every one of a client's ~300 files
// waited out the 15 s timeout and came back 502, so the install line a new
// colleague pastes died on its first download.

// stableAwareMark is the line an installer carries when it installs from
// client_url (bin/fleet-install.sh). Only such an installer is served from
// stable; an older one would install the image's files under stable's name.
const stableAwareMark = "fleet-install: stable-aware"

// StableManifestPath is where the client's manifest sits in the repo.
const StableManifestPath = "tokenledger/internal/api/fleetclient/manifest"

var shaRe = regexp.MustCompile(`^[0-9a-f]{40}$`)

// StableSource finds what refs/tags/stable names on GitHub and fetches the
// client's files at it. Zero values are GitHub's public endpoints.
type StableSource struct {
	Repo    string // owner/name; default verkyyi/claude-fleet
	APIBase string // default https://api.github.com
	RawBase string // default https://raw.githubusercontent.com
	// CodeloadBase serves /<repo>/tar.gz/<sha>; default codeload.github.com,
	// or RawBase when only that is set (a mirror / a test serves both).
	CodeloadBase string
	TTL          time.Duration // how long a lookup is trusted; default 5m
	Client       *http.Client

	mu         sync.Mutex
	sha        string
	at         time.Time
	refreshing bool
	seen       []string          // the last few shas stable named (what /install/stable/ serves)
	files      map[string][]byte // "<sha>/<path>" → bytes
	size       int
	whole      map[string]bool      // sha → its tarball is in files (a path not there is not in the commit)
	tarFail    map[string]time.Time // sha → when its tarball last failed (retried after a TTL)
	tarLock    sync.Mutex           // one tarball download at a time
}

const (
	stableSeenMax   = 4
	stableFileMax   = 4 << 20
	stableCacheMax  = 96 << 20
	stableFetchTime = 15 * time.Second
	stableTarTime   = 90 * time.Second
	stableTarMax    = 64 << 20
)

func (s *StableSource) repo() string {
	if s.Repo != "" {
		return s.Repo
	}
	return "verkyyi/claude-fleet"
}

func (s *StableSource) apiBase() string {
	if s.APIBase != "" {
		return strings.TrimRight(s.APIBase, "/")
	}
	return "https://api.github.com"
}

func (s *StableSource) rawBase() string {
	if s.RawBase != "" {
		return strings.TrimRight(s.RawBase, "/")
	}
	return "https://raw.githubusercontent.com"
}

func (s *StableSource) codeloadBase() string {
	switch {
	case s.CodeloadBase != "":
		return strings.TrimRight(s.CodeloadBase, "/")
	case s.RawBase != "":
		return s.rawBase()
	}
	return "https://codeload.github.com"
}

func (s *StableSource) client() *http.Client {
	if s.Client != nil {
		return s.Client
	}
	return &http.Client{Timeout: stableFetchTime}
}

func (s *StableSource) ttl() time.Duration {
	if s.TTL > 0 {
		return s.TTL
	}
	return 5 * time.Minute
}

// Commit is the last stable this source saw ("" before the first lookup
// answered). It never blocks on GitHub: a stale answer starts one lookup in the
// background and is returned meanwhile.
func (s *StableSource) Commit() string {
	s.mu.Lock()
	sha, stale := s.sha, time.Since(s.at) > s.ttl()
	if stale && !s.refreshing {
		s.refreshing = true
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), stableFetchTime)
			defer cancel()
			if err := s.Refresh(ctx); err != nil {
				log.Printf("fleet: stable lookup: %v", err)
			}
		}()
	}
	s.mu.Unlock()
	return sha
}

// Refresh asks GitHub which commit stable names now. A failure keeps the last
// answer (a hub that lost GitHub keeps handing out the stable it knew).
func (s *StableSource) Refresh(ctx context.Context) error {
	defer func() {
		s.mu.Lock()
		s.refreshing = false
		s.mu.Unlock()
	}()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.apiBase()+"/repos/"+s.repo()+"/commits/stable", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github.sha")
	resp, err := s.client().Do(req)
	if err != nil {
		s.touch()
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
	sha := strings.TrimSpace(string(b))
	if resp.StatusCode != http.StatusOK || !shaRe.MatchString(sha) {
		s.touch()
		return fmt.Errorf("%s: HTTP %d %q", req.URL, resp.StatusCode, firstLine(sha))
	}
	s.mu.Lock()
	s.sha, s.at = sha, time.Now()
	if !containsStr(s.seen, sha) {
		s.seen = append(s.seen, sha)
		if len(s.seen) > stableSeenMax {
			s.seen = s.seen[len(s.seen)-stableSeenMax:]
		}
	}
	s.mu.Unlock()
	return nil
}

// touch marks a failed lookup as an answer for one TTL, so a GitHub that is
// down is asked once per TTL, not on every /version.
func (s *StableSource) touch() {
	s.mu.Lock()
	s.at = time.Now()
	s.mu.Unlock()
}

// Seen says stable has named sha (one of the last few).
func (s *StableSource) Seen(sha string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return containsStr(s.seen, sha)
}

// File is <path> at <sha>, from the cache, the commit's tarball or GitHub's
// raw host — in that order.
func (s *StableSource) File(ctx context.Context, sha, path string) ([]byte, error) {
	key := sha + "/" + path
	if b, ok, whole := s.cached(key, sha); ok {
		return b, nil
	} else if whole {
		return nil, errStableNotFound
	}
	if s.loadTarball(ctx, sha) {
		if b, ok, _ := s.cached(key, sha); ok {
			return b, nil
		}
		return nil, errStableNotFound
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.rawBase()+"/"+s.repo()+"/"+sha+"/"+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, errStableNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", req.URL, resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, stableFileMax+1))
	if err != nil {
		return nil, err
	}
	if len(b) > stableFileMax {
		return nil, fmt.Errorf("%s: larger than %d bytes", path, stableFileMax)
	}
	s.mu.Lock()
	s.storeLocked(key, b)
	s.mu.Unlock()
	return b, nil
}

// cached: the bytes at key, and whether sha's whole tarball is loaded (then a
// miss means the path is not in the commit).
func (s *StableSource) cached(key, sha string) ([]byte, bool, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.files[key]
	return b, ok, s.whole[sha]
}

// storeLocked keeps b at key; a cache past its cap starts over (s.mu held).
func (s *StableSource) storeLocked(key string, b []byte) {
	if s.files == nil || s.size+len(b) > stableCacheMax {
		s.files, s.size, s.whole = map[string][]byte{}, 0, map[string]bool{}
	}
	s.files[key] = b
	s.size += len(b)
}

// loadTarball fills the cache with every client path of sha from codeload's
// tarball, once; true when sha is loaded whole. A failure is remembered for one
// TTL (the caller falls back to the raw host meanwhile).
func (s *StableSource) loadTarball(ctx context.Context, sha string) bool {
	s.tarLock.Lock()
	defer s.tarLock.Unlock()
	s.mu.Lock()
	whole, failed := s.whole[sha], s.tarFail[sha]
	s.mu.Unlock()
	if whole {
		return true
	}
	if !failed.IsZero() && time.Since(failed) < s.ttl() {
		return false
	}
	files, err := s.fetchTarball(ctx, sha)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		if s.tarFail == nil {
			s.tarFail = map[string]time.Time{}
		}
		s.tarFail[sha] = time.Now()
		log.Printf("fleet: stable %s tarball: %v (falling back to the raw host)", sha[:7], err)
		return false
	}
	for p, b := range files {
		s.storeLocked(sha+"/"+p, b)
	}
	if s.whole == nil {
		s.whole = map[string]bool{}
	}
	s.whole[sha] = true
	delete(s.tarFail, sha)
	return true
}

// fetchTarball is every client path (stablePathOK) of sha's tarball.
func (s *StableSource) fetchTarball(ctx context.Context, sha string) (map[string][]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, stableTarTime)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.codeloadBase()+"/"+s.repo()+"/tar.gz/"+sha, nil)
	if err != nil {
		return nil, err
	}
	c := *s.client()
	c.Timeout = stableTarTime
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", req.URL, resp.StatusCode)
	}
	zr, err := gzip.NewReader(io.LimitReader(resp.Body, stableTarMax))
	if err != nil {
		return nil, err
	}
	tr := tar.NewReader(zr)
	files := map[string][]byte{}
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if hd.Typeflag != tar.TypeReg {
			continue
		}
		// <repo>-<sha>/<path>: the top directory is the archive's, not the repo's
		_, p, ok := strings.Cut(hd.Name, "/")
		if !ok || !stablePathOK(p) || hd.Size > stableFileMax {
			continue
		}
		b, err := io.ReadAll(io.LimitReader(tr, stableFileMax+1))
		if err != nil {
			return nil, err
		}
		files[p] = b
	}
	if _, ok := files[StableManifestPath]; !ok {
		return nil, fmt.Errorf("%s: no %s in the tarball", req.URL, StableManifestPath)
	}
	return files, nil
}

var errStableNotFound = errors.New("not in stable")

// stablePathOK — the client's paths only: the manifest, and what an installer
// may write (bin/ conf/ hooks/ commands/ skills/ mod/), nothing that climbs.
func stablePathOK(p string) bool {
	if p == StableManifestPath {
		return true
	}
	if p == "" || strings.Contains(p, "..") || strings.Contains(p, "//") || strings.HasSuffix(p, "/") || strings.ContainsAny(p, "\\?#%") {
		return false
	}
	for _, d := range []string{"bin/", "conf/", "hooks/", "commands/", "skills/", "mod/"} {
		if strings.HasPrefix(p, d) {
			return true
		}
	}
	return false
}

// stableCommit — the stable this hub hands out, or "" (the image's client).
func (s *Server) stableCommit() string {
	if s.Stable == nil || !s.installReady() {
		return ""
	}
	return s.Stable.Commit()
}

// handleStableFile serves GET /install/stable/<sha>/<path>.
func (s *Server) handleStableFile(w http.ResponseWriter, r *http.Request, rest string) {
	sha, path, ok := strings.Cut(rest, "/")
	if ok && path == bundleName && s.Stable != nil && shaRe.MatchString(sha) && s.Stable.Seen(sha) {
		s.handleStableBundle(w, r, sha)
		return
	}
	if s.Stable == nil || !ok || !shaRe.MatchString(sha) || !stablePathOK(path) || !s.Stable.Seen(sha) {
		http.NotFound(w, r)
		return
	}
	b, err := s.Stable.File(r.Context(), sha, path)
	if errors.Is(err, errStableNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		httpError(w, http.StatusBadGateway, "stable "+sha[:7]+": "+err.Error())
		return
	}
	sum := sha256.Sum256(b)
	w.Header().Set("Content-Type", installContentType(path))
	// a commit's bytes never change
	w.Header().Set("Cache-Control", "public, max-age=86400, immutable")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Ccquota-Sha256", hex.EncodeToString(sum[:]))
	_, _ = w.Write(b)
}

// stableInstaller is stable's own installer, when it is one that installs from
// client_url; nil otherwise (the caller serves the image's).
func (s *Server) stableInstaller(ctx context.Context) []byte {
	sha := s.stableCommit()
	if sha == "" {
		return nil
	}
	m, err := s.Stable.File(ctx, sha, StableManifestPath)
	if err != nil {
		return nil
	}
	inst, _ := fleetclient.ParseManifest(m)
	if inst == "" || !stablePathOK(inst) {
		return nil
	}
	b, err := s.Stable.File(ctx, sha, inst)
	if err != nil || !bytes.HasPrefix(b, []byte("#!")) || !bytes.Contains(b, []byte(stableAwareMark)) {
		return nil
	}
	return b
}

func containsStr(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(s, "\n")
	if len(s) > 80 {
		s = s[:80]
	}
	return s
}
