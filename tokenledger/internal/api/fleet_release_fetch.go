package api

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The Claude Code a release.json pins is the hub's to fetch, not a person's to
// upload (claude-fleet#2631): when a build lacks claude-<ver>-<os>-<arch>, the
// hub takes Anthropic's own npm package for that platform
// (@anthropic-ai/claude-code-<os>-<arch>@<ver> — the same bytes as
// downloads.claude.ai's, whose Google storage the cluster cannot reach), checks
// the tarball against the registry's dist.integrity (sha512), and drops its
// `package/claude` into CCQUOTA_FLEET_RELEASE_ARTIFACTS under the artifact name.
// The release that follows signs its sha256 like any other artifact.
//
// CCQUOTA_FLEET_RELEASE_NPM lists the registries, tried in order for the
// metadata (the first that answers names the integrity) and for the tarball
// (the first whose bytes match it): npm's own first, then npmmirror, which the
// cluster reaches at CDN speed. A name the hub cannot fetch stays missing and
// the build is refused, as before.

// DefaultNPMRegistries: npm itself, then its mirror the cluster reaches.
var DefaultNPMRegistries = []string{"https://registry.npmjs.org", "https://registry.npmmirror.com"}

const (
	npmMetaTime    = 20 * time.Second
	npmTarballTime = 2 * time.Minute
	npmTarballMax  = 1 << 30
	claudeNPMScope = "@anthropic-ai"
	claudeNPMEntry = "package/claude"
)

var claudeArtifactRe = regexp.MustCompile(`^claude-([0-9][0-9A-Za-z.+_-]*)-(darwin|linux)-(arm64|amd64)$`)

// claudeNPM: the npm package and version behind a claude artifact name, or ok=false.
func claudeNPM(name string) (pkg, version string, ok bool) {
	m := claudeArtifactRe.FindStringSubmatch(name)
	if m == nil {
		return "", "", false
	}
	arch := map[string]string{"arm64": "arm64", "amd64": "x64"}[m[3]]
	return "claude-code-" + m[2] + "-" + arch, m[1], true
}

func (rs *ReleaseStore) npmRegistries() []string {
	if len(rs.NPMRegistries) > 0 {
		return rs.NPMRegistries
	}
	return DefaultNPMRegistries
}

func (rs *ReleaseStore) npmClient(d time.Duration) *http.Client {
	if rs.Client != nil {
		return rs.Client
	}
	return &http.Client{Timeout: d}
}

type npmDist struct {
	Integrity string `json:"integrity"`
	Tarball   string `json:"tarball"`
}

// npmResolve: the dist of one claude artifact's package version, from the first
// registry that answers. An error = no registry has it (or none answered).
func (rs *ReleaseStore) npmResolve(ctx context.Context, name string) (npmDist, error) {
	pkg, ver, ok := claudeNPM(name)
	if !ok {
		return npmDist{}, fmt.Errorf("%s: not a claude artifact", name)
	}
	var errs []string
	for _, reg := range rs.npmRegistries() {
		u := strings.TrimSuffix(reg, "/") + "/" + claudeNPMScope + "%2f" + pkg + "/" + url.PathEscape(ver)
		d, err := func() (npmDist, error) {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
			if err != nil {
				return npmDist{}, err
			}
			req.Header.Set("Accept", "application/json")
			resp, err := rs.npmClient(npmMetaTime).Do(req)
			if err != nil {
				return npmDist{}, err
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return npmDist{}, fmt.Errorf("HTTP %d", resp.StatusCode)
			}
			var v struct {
				Dist npmDist `json:"dist"`
			}
			if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&v); err != nil {
				return npmDist{}, err
			}
			if !strings.HasPrefix(v.Dist.Integrity, "sha512-") {
				return npmDist{}, fmt.Errorf("no sha512 integrity")
			}
			return v.Dist, nil
		}()
		if err == nil {
			return d, nil
		}
		errs = append(errs, reg+": "+err.Error())
	}
	return npmDist{}, fmt.Errorf("%s@%s: %s", claudeNPMScope+"/"+pkg, ver, strings.Join(errs, "; "))
}

// fetchClaude puts one claude artifact into the artifacts dir, or says why not.
func (rs *ReleaseStore) fetchClaude(ctx context.Context, name string) error {
	if rs.ArtifactsDir == "" {
		return errors.New("no CCQUOTA_FLEET_RELEASE_ARTIFACTS to put it in")
	}
	dist, err := rs.npmResolve(ctx, name)
	if err != nil {
		return err
	}
	want, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(dist.Integrity, "sha512-"))
	if err != nil || len(want) != sha512.Size {
		return fmt.Errorf("%s: bad integrity %q", name, dist.Integrity)
	}
	pkg, ver, _ := claudeNPM(name)
	urls := []string{dist.Tarball}
	for _, reg := range rs.npmRegistries() {
		urls = append(urls, strings.TrimSuffix(reg, "/")+"/"+claudeNPMScope+"/"+pkg+"/-/"+pkg+"-"+url.PathEscape(ver)+".tgz")
	}
	seen := map[string]bool{}
	var errs []string
	for _, u := range urls {
		if u == "" || seen[u] {
			continue
		}
		seen[u] = true
		if err := rs.fetchClaudeFrom(ctx, u, want, name); err != nil {
			errs = append(errs, err.Error())
			continue
		}
		log.Printf("fleet: release artifact %s fetched from %s", name, u)
		return nil
	}
	return fmt.Errorf("%s: %s", name, strings.Join(errs, "; "))
}

// fetchClaudeFrom: one tarball URL → checked against want → its package/claude
// renamed into place (a reader sees the whole file or none).
func (rs *ReleaseStore) fetchClaudeFrom(ctx context.Context, u string, want []byte, name string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := rs.npmClient(npmTarballTime).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", u, resp.StatusCode)
	}
	tgz, err := os.CreateTemp(rs.ArtifactsDir, ".fetch-*")
	if err != nil {
		return err
	}
	defer os.Remove(tgz.Name())
	defer tgz.Close()
	h := sha512.New()
	n, err := io.Copy(io.MultiWriter(tgz, h), io.LimitReader(resp.Body, npmTarballMax+1))
	if err != nil {
		return fmt.Errorf("%s: %w", u, err)
	}
	if n > npmTarballMax {
		return fmt.Errorf("%s: over %d bytes", u, npmTarballMax)
	}
	if got := h.Sum(nil); string(got) != string(want) {
		return fmt.Errorf("%s: sha512 does not match the registry's integrity", u)
	}
	if _, err := tgz.Seek(0, io.SeekStart); err != nil {
		return err
	}
	gz, err := gzip.NewReader(tgz)
	if err != nil {
		return fmt.Errorf("%s: %w", u, err)
	}
	tr := tar.NewReader(gz)
	for {
		hd, err := tr.Next()
		if err == io.EOF {
			return fmt.Errorf("%s: no %s in the package", u, claudeNPMEntry)
		}
		if err != nil {
			return fmt.Errorf("%s: %w", u, err)
		}
		if hd.Name != claudeNPMEntry || hd.Typeflag != tar.TypeReg {
			continue
		}
		out, err := os.CreateTemp(rs.ArtifactsDir, ".claude-*")
		if err != nil {
			return err
		}
		_, cerr := io.Copy(out, io.LimitReader(tr, npmTarballMax))
		if err := out.Close(); cerr == nil {
			cerr = err
		}
		if cerr == nil {
			cerr = os.Chmod(out.Name(), 0o755)
		}
		if cerr == nil {
			cerr = os.Rename(out.Name(), filepath.Join(rs.ArtifactsDir, name))
		}
		if cerr != nil {
			_ = os.Remove(out.Name())
			return cerr
		}
		return nil
	}
}

// fillPinned fetches every missing name the hub knows how to fetch (Claude
// Code) and says which it could not.
func (rs *ReleaseStore) fillPinned(ctx context.Context, missing []string) []string {
	var still []string
	for _, n := range missing {
		if _, _, ok := claudeNPM(n); !ok {
			still = append(still, n)
			continue
		}
		if err := rs.fetchClaude(ctx, n); err != nil {
			log.Printf("fleet: release artifact %s: %v", n, err)
			still = append(still, n)
		}
	}
	return still
}

// fetchable: of names, the ones the hub does not hold but a build would fetch
// (the registry has the version) — metadata only, nothing downloaded.
func (rs *ReleaseStore) fetchable(ctx context.Context, have map[string]string, names []string) []string {
	out := []string{}
	if rs.ArtifactsDir == "" {
		return out
	}
	for _, n := range names {
		if _, ok := have[n]; ok {
			continue
		}
		if _, _, ok := claudeNPM(n); !ok {
			continue
		}
		if _, err := rs.npmResolve(ctx, n); err == nil {
			out = append(out, n)
		}
	}
	return out
}
