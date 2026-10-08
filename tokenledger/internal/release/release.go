// Package release is a node release: one stable commit's runtime files, the
// binaries that go with it, a manifest of every sha256 and the hub's ed25519
// signature over that manifest (claude-fleet#2335, EPIC #2329 C7).
//
// The hub builds one per stable it sees and keeps it (internal/api's
// ReleaseStore); a machine fetches it from the hub only — never GitHub — and
// installs nothing that does not match the signature (Fetch). The bytes a
// machine trusts are the manifest's; the manifest is trusted because the key
// pinned on the machine signed it.
//
// On disk (the hub's store, one directory per sha):
//
//	<sha>/manifest.json   the signed bytes, exactly as served
//	<sha>/manifest.sig    base64 ed25519 signature over manifest.json
//	<sha>/tree.tar.gz     every runtime file, deterministic (mtime 0, sorted)
//	<sha>/artifacts/<n>   ccquota-<os>-<arch>, Claude Code / Codex installers
package release

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Schema is the manifest's format version.
const Schema = 1

// Names inside a release directory and under /v1/fleet/release/<sha>/.
const (
	ManifestName = "manifest.json"
	SigName      = "manifest.sig"
	TreeName     = "tree.tar.gz"
	ArtifactDir  = "artifacts"
)

// File is one runtime file in the tree.
type File struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   int64  `json:"mode"`
}

// Blob is the tree archive or an artifact: a name and its digest.
type Blob struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

// Manifest is what the hub signs.
type Manifest struct {
	Schema    int       `json:"schema"`
	Repo      string    `json:"repo"`
	SHA       string    `json:"sha"`
	Created   time.Time `json:"created"`
	Key       string    `json:"key"` // the signing key's fingerprint (KeyID)
	Tree      Blob      `json:"tree"`
	Files     []File    `json:"files"`
	Artifacts []Blob    `json:"artifacts"`
}

var (
	shaRe      = regexp.MustCompile(`^[0-9a-f]{40}$`)
	artifactRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`)
)

// ValidSHA: a full commit sha.
func ValidSHA(s string) bool { return shaRe.MatchString(s) }

// ValidArtifact: a flat artifact name, nothing that climbs or hides.
func ValidArtifact(s string) bool { return artifactRe.MatchString(s) && !strings.Contains(s, "..") }

// validPath: a relative path that stays inside the tree.
func validPath(p string) bool {
	return p != "" && !strings.HasPrefix(p, "/") && path.Clean(p) == p && p != "." &&
		!strings.HasPrefix(p, "../") && p != ".." && !strings.ContainsAny(p, "\\\x00")
}

// ── keys ─────────────────────────────────────────────────────────────────

// LoadPrivateKey reads an ed25519 key: PKCS#8 PEM (`openssl genpkey
// -algorithm ed25519`) or a base64 32-byte seed on one line.
func LoadPrivateKey(b []byte) (ed25519.PrivateKey, error) {
	if blk, _ := pem.Decode(b); blk != nil {
		k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
		if err != nil {
			return nil, err
		}
		ek, ok := k.(ed25519.PrivateKey)
		if !ok {
			return nil, errors.New("not an ed25519 key")
		}
		return ek, nil
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("want PKCS#8 PEM or a base64 32-byte seed")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// FormatPublicKey is the one-line public key: `ed25519 <base64>`.
func FormatPublicKey(pub ed25519.PublicKey) string {
	return "ed25519 " + base64.StdEncoding.EncodeToString(pub)
}

// ParsePublicKey reads FormatPublicKey's line (or the bare base64).
func ParsePublicKey(b []byte) (ed25519.PublicKey, error) {
	s := strings.TrimSpace(string(b))
	s = strings.TrimSpace(strings.TrimPrefix(s, "ed25519"))
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(raw) != ed25519.PublicKeySize {
		return nil, errors.New("not an ed25519 public key (`ed25519 <base64>`)")
	}
	return ed25519.PublicKey(raw), nil
}

// KeyID is a short fingerprint of a public key: sha256, 16 hex.
func KeyID(pub ed25519.PublicKey) string {
	s := sha256.Sum256(pub)
	return hex.EncodeToString(s[:8])
}

// Sign is the base64 signature over the manifest bytes.
func Sign(key ed25519.PrivateKey, manifest []byte) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, manifest))
}

// Verify checks sig over manifest with pub and parses it.
func Verify(pub ed25519.PublicKey, manifest []byte, sig string) (*Manifest, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(sig))
	if err != nil || !ed25519.Verify(pub, manifest, raw) {
		return nil, errors.New("signature does not match the pinned key")
	}
	var m Manifest
	if err := json.Unmarshal(manifest, &m); err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	if m.Schema != Schema || !ValidSHA(m.SHA) {
		return nil, fmt.Errorf("manifest: schema %d sha %q", m.Schema, m.SHA)
	}
	return &m, nil
}

// ── building ─────────────────────────────────────────────────────────────

func digest(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// fileMode: executable under bin/ or with a #! line, like the installer.
func fileMode(p string, b []byte) int64 {
	if strings.HasPrefix(p, "bin/") || bytes.HasPrefix(b, []byte("#!")) {
		return 0o755
	}
	return 0o644
}

// Build writes a signed release for sha into dir (which must not exist yet):
// files is the runtime tree, artifacts maps a name to the file to copy in.
func Build(dir, repo, sha string, files map[string][]byte, artifacts map[string]string, key ed25519.PrivateKey, now time.Time) (*Manifest, error) {
	if !ValidSHA(sha) {
		return nil, fmt.Errorf("bad sha %q", sha)
	}
	if len(files) == 0 {
		return nil, errors.New("no files")
	}
	if err := os.MkdirAll(dir+"/"+ArtifactDir, 0o755); err != nil {
		return nil, err
	}
	m := Manifest{Schema: Schema, Repo: repo, SHA: sha, Created: now.UTC().Truncate(time.Second),
		Key: KeyID(key.Public().(ed25519.PublicKey)), Files: []File{}, Artifacts: []Blob{}}

	names := make([]string, 0, len(files))
	for p := range files {
		if !validPath(p) {
			return nil, fmt.Errorf("bad path %q", p)
		}
		names = append(names, p)
	}
	sort.Strings(names)
	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	tw := tar.NewWriter(zw)
	for _, p := range names {
		b := files[p]
		mode := fileMode(p, b)
		if err := tw.WriteHeader(&tar.Header{Name: p, Mode: mode, Size: int64(len(b)), ModTime: time.Unix(0, 0), Typeflag: tar.TypeReg, Format: tar.FormatPAX}); err != nil {
			return nil, err
		}
		if _, err := tw.Write(b); err != nil {
			return nil, err
		}
		m.Files = append(m.Files, File{Path: p, SHA256: digest(b), Size: int64(len(b)), Mode: mode})
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	if err := os.WriteFile(dir+"/"+TreeName, buf.Bytes(), 0o644); err != nil {
		return nil, err
	}
	m.Tree = Blob{Name: TreeName, SHA256: digest(buf.Bytes()), Size: int64(buf.Len())}

	anames := make([]string, 0, len(artifacts))
	for n := range artifacts {
		if !ValidArtifact(n) {
			return nil, fmt.Errorf("bad artifact name %q", n)
		}
		anames = append(anames, n)
	}
	sort.Strings(anames)
	for _, n := range anames {
		sum, size, err := copyHashed(artifacts[n], dir+"/"+ArtifactDir+"/"+n)
		if err != nil {
			return nil, fmt.Errorf("artifact %s: %w", n, err)
		}
		m.Artifacts = append(m.Artifacts, Blob{Name: n, SHA256: sum, Size: size})
	}

	mb, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}
	mb = append(mb, '\n')
	if err := os.WriteFile(dir+"/"+ManifestName, mb, 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(dir+"/"+SigName, []byte(Sign(key, mb)+"\n"), 0o644); err != nil {
		return nil, err
	}
	return &m, nil
}

func copyHashed(src, dst string) (string, int64, error) {
	in, err := os.Open(src)
	if err != nil {
		return "", 0, err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return "", 0, err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, h), in)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return hex.EncodeToString(h.Sum(nil)), n, err
}

// ── unpacking ────────────────────────────────────────────────────────────

// Unpack checks tree (the tree.tar.gz bytes) against m and writes every file
// under dir, which must not exist yet. Any digest, size, extra or missing
// file is an error and leaves dir absent.
func Unpack(m *Manifest, tree []byte, dir string) (err error) {
	if digest(tree) != m.Tree.SHA256 || int64(len(tree)) != m.Tree.Size {
		return errors.New(TreeName + ": digest does not match the manifest")
	}
	want := make(map[string]File, len(m.Files))
	for _, f := range m.Files {
		if !validPath(f.Path) {
			return fmt.Errorf("manifest: bad path %q", f.Path)
		}
		want[f.Path] = f
	}
	if _, e := os.Lstat(dir); e == nil {
		return fmt.Errorf("%s already exists", dir)
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(dir)
		}
	}()
	zr, err := gzip.NewReader(bytes.NewReader(tree))
	if err != nil {
		return err
	}
	tr := tar.NewReader(zr)
	seen := map[string]bool{}
	for {
		hd, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return e
		}
		f, ok := want[hd.Name]
		if !ok || hd.Typeflag != tar.TypeReg || seen[hd.Name] {
			return fmt.Errorf("%s: not in the manifest", hd.Name)
		}
		b, e := io.ReadAll(io.LimitReader(tr, f.Size+1))
		if e != nil {
			return e
		}
		if int64(len(b)) != f.Size || digest(b) != f.SHA256 {
			return fmt.Errorf("%s: digest does not match the manifest", hd.Name)
		}
		p := dir + "/" + hd.Name
		if e := os.MkdirAll(path.Dir(p), 0o755); e != nil {
			return e
		}
		if e := os.WriteFile(p, b, os.FileMode(f.Mode&0o755)); e != nil {
			return e
		}
		seen[hd.Name] = true
	}
	if len(seen) != len(want) {
		return fmt.Errorf("tree: %d of %d files", len(seen), len(want))
	}
	return os.MkdirAll(dir, 0o755) // an empty tree is refused by Build; keep dir real
}

// CheckBlob: b is the artifact (or tree) the manifest names.
func CheckBlob(want Blob, b []byte) error {
	if int64(len(b)) != want.Size || digest(b) != want.SHA256 {
		return fmt.Errorf("%s: digest does not match the manifest", want.Name)
	}
	return nil
}
