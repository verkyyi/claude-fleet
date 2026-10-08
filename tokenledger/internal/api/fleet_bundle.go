package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
)

// The whole client in ONE download (claude-fleet#2260, EPIC #2259 C1).
//
// The installer used to fetch the manifest and then every file it lists, one
// request each — ~140 round trips, which a new colleague's first install waited
// on for close to two minutes. GET /install/bundle.tar.gz (the image's client)
// and GET /install/stable/<sha>/bundle.tar.gz (stable's, through this hub) are
// the same files as one gzip'd tar, its SHA-256 in X-Ccquota-Sha256 like every
// /install download:
//
//	manifest            the list (for stable: its manifest, at this name)
//	<path>              every file the manifest lists but the installer
//	vendor/tmux         the static tmux for ?os=&arch= (uname -s / uname -m),
//	                    when this build packed one for that platform
//
// Nothing here is a second copy: the bytes are the ones /install/<path> and
// /install/stable/<sha>/<path> serve, read through the same readers. A bundle
// that cannot be built (a stable file out of reach) is a 502, and the
// installer falls back to file by file — so the bundle only ever makes an
// install faster, never one that fails where it used to work.

const bundleName = "bundle.tar.gz"

// bundleCache keeps the last few bundles: a commit's (or this image's) files
// never change, so neither does its bundle.
var bundleCache = struct {
	sync.Mutex
	m     map[string][]byte
	order []string
}{m: map[string][]byte{}}

const bundleCacheMax = 12

func bundleCached(key string) ([]byte, bool) {
	bundleCache.Lock()
	defer bundleCache.Unlock()
	b, ok := bundleCache.m[key]
	return b, ok
}

func bundleStore(key string, b []byte) {
	bundleCache.Lock()
	defer bundleCache.Unlock()
	if _, ok := bundleCache.m[key]; ok {
		return
	}
	if len(bundleCache.order) >= bundleCacheMax {
		delete(bundleCache.m, bundleCache.order[0])
		bundleCache.order = bundleCache.order[1:]
	}
	bundleCache.m[key] = b
	bundleCache.order = append(bundleCache.order, key)
}

// bundlePlatform is the vendor platform for an installer's uname -s / uname -m
// (conf/vendor-tmux.lock's names), or "" for one we pack nothing for.
func bundlePlatform(r *http.Request) string {
	var os, arch string
	switch strings.ToLower(r.URL.Query().Get("os")) {
	case "darwin", "macos":
		os = "macos"
	case "linux":
		os = "linux"
	default:
		return ""
	}
	switch strings.ToLower(r.URL.Query().Get("arch")) {
	case "arm64", "aarch64":
		arch = "arm64"
	case "x86_64", "amd64":
		arch = "x86_64"
	default:
		return ""
	}
	return os + "-" + arch
}

// buildBundle tars manifest + every name it lists (read) + vendor/tmux.
// A file is executable when it is under bin/ or starts with #! — the modes
// the per-file installer gives it.
func buildBundle(manifest []byte, read func(string) ([]byte, error), tmux []byte) ([]byte, error) {
	_, names := fleetclient.ParseManifest(manifest)
	if len(names) == 0 {
		return nil, errors.New("the manifest lists no files")
	}
	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	tw := tar.NewWriter(zw)
	mtime := time.Unix(0, 0)
	add := func(name string, b []byte, mode int64) error {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(b)), ModTime: mtime, Typeflag: tar.TypeReg, Format: tar.FormatUSTAR}); err != nil {
			return err
		}
		_, err := tw.Write(b)
		return err
	}
	if err := add(fleetclient.ManifestName, manifest, 0o644); err != nil {
		return nil, err
	}
	for _, n := range names {
		b, err := read(n)
		if err != nil {
			return nil, errors.New(n + ": " + err.Error())
		}
		mode := int64(0o644)
		if strings.HasPrefix(n, "bin/") || bytes.HasPrefix(b, []byte("#!")) {
			mode = 0o755
		}
		if err := add(n, b, mode); err != nil {
			return nil, err
		}
	}
	if len(tmux) > 0 {
		if err := add("vendor/tmux", tmux, 0o755); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func writeBundle(w http.ResponseWriter, b []byte, immutable bool) {
	sum := sha256.Sum256(b)
	w.Header().Set("Content-Type", "application/gzip")
	if immutable {
		w.Header().Set("Cache-Control", "public, max-age=86400, immutable")
	} else {
		w.Header().Set("Cache-Control", "no-store")
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Ccquota-Sha256", hex.EncodeToString(sum[:]))
	_, _ = w.Write(b)
}

// handleImageBundle serves GET /install/bundle.tar.gz: this image's client.
func (s *Server) handleImageBundle(w http.ResponseWriter, r *http.Request) {
	plat := bundlePlatform(r)
	key := "image/" + fleetclient.Version + "/" + plat
	b, ok := bundleCached(key)
	if !ok {
		m, err := fleetclient.Files.ReadFile(fleetclient.ManifestName)
		if err == nil {
			b, err = buildBundle(m, fleetclient.Files.ReadFile, fleetclient.VendorTmux(plat))
		}
		if err != nil {
			httpError(w, http.StatusInternalServerError, "bundle: "+err.Error())
			return
		}
		bundleStore(key, b)
	}
	writeBundle(w, b, false)
}

// handleStableBundle serves GET /install/stable/<sha>/bundle.tar.gz: stable's
// client at <sha> (the files /install/stable/<sha>/<path> serves), with this
// image's static tmux.
func (s *Server) handleStableBundle(w http.ResponseWriter, r *http.Request, sha string) {
	plat := bundlePlatform(r)
	key := "stable/" + sha + "/" + plat
	b, ok := bundleCached(key)
	if !ok {
		ctx := r.Context()
		m, err := s.Stable.File(ctx, sha, StableManifestPath)
		if err == nil {
			b, err = buildBundle(m, func(p string) ([]byte, error) {
				if !stablePathOK(p) {
					return nil, errors.New("not a client path")
				}
				return s.Stable.File(ctx, sha, p)
			}, fleetclient.VendorTmux(plat))
		}
		if err != nil {
			httpError(w, http.StatusBadGateway, "stable "+sha[:7]+" bundle: "+err.Error())
			return
		}
		bundleStore(key, b)
	}
	writeBundle(w, b, true)
}
