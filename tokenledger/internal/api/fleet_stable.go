package api

import (
	"bytes"
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
//   - GET /install/stable/<sha>/<path> is that file, fetched once from GitHub's
//     raw host and kept (a commit's bytes never change), SHA-256 in
//     X-Ccquota-Sha256 like every /install file. Only a sha this hub has seen
//     stable at, and only the client's paths — never an open proxy.
//   - GET /install serves stable's own installer when it is one that knows
//     this path (the stableAwareMark line), so a newer install logic needs no
//     redeploy either; an older stable's installer → the image's, as before.
//
// Stable unknown (GitHub out of reach since the hub started, the source off)
// → /version and /install are exactly the image's, byte for byte: the image's
// pack is the fallback, never removed. A nil StableSource is that, always.

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
	Repo    string        // owner/name; default verkyyi/claude-fleet
	APIBase string        // default https://api.github.com
	RawBase string        // default https://raw.githubusercontent.com
	TTL     time.Duration // how long a lookup is trusted; default 5m
	Client  *http.Client

	mu         sync.Mutex
	sha        string
	at         time.Time
	refreshing bool
	seen       []string          // the last few shas stable named (what /install/stable/ serves)
	files      map[string][]byte // "<sha>/<path>" → bytes
	size       int
}

const (
	stableSeenMax   = 4
	stableFileMax   = 4 << 20
	stableCacheMax  = 96 << 20
	stableFetchTime = 15 * time.Second
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

// File is <path> at <sha>, from the cache or GitHub's raw host.
func (s *StableSource) File(ctx context.Context, sha, path string) ([]byte, error) {
	key := sha + "/" + path
	s.mu.Lock()
	if b, ok := s.files[key]; ok {
		s.mu.Unlock()
		return b, nil
	}
	s.mu.Unlock()
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
	if s.files == nil || s.size+len(b) > stableCacheMax {
		s.files, s.size = map[string][]byte{}, 0
	}
	s.files[key] = b
	s.size += len(b)
	s.mu.Unlock()
	return b, nil
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
