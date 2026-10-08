package release

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

// Path is the hub route a release lives under: <hub>/v1/fleet/release/<sha>.
const Path = "/v1/fleet/release/"

// KeyPath serves the hub's signing public key (FormatPublicKey). A machine
// pins it once, at install (`fleet node install`, C1) — never per fetch.
const KeyPath = Path + "key"

const (
	manifestMax = 16 << 20
	treeMax     = 256 << 20
)

// Fetcher downloads a release from the hub and checks it against the pinned
// key. It never talks to anything but Hub.
type Fetcher struct {
	Hub    string // https://hub…, no trailing slash needed
	Key    ed25519.PublicKey
	Client *http.Client
}

func (f *Fetcher) client() *http.Client {
	if f.Client != nil {
		return f.Client
	}
	return http.DefaultClient
}

func (f *Fetcher) get(ctx context.Context, rel string, max int64) ([]byte, error) {
	u := strings.TrimRight(f.Hub, "/") + Path + rel
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := f.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return nil, fmt.Errorf("%s: HTTP %d %s", u, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("%s: larger than %d bytes", u, max)
	}
	return b, nil
}

// Manifest fetches and verifies <sha>'s manifest ("stable" = whatever the hub
// names stable now; the signed manifest then says which sha that is). It
// returns the parsed manifest and the exact signed bytes + signature.
func (f *Fetcher) Manifest(ctx context.Context, sha string) (*Manifest, []byte, string, error) {
	if sha != "stable" && !ValidSHA(sha) {
		return nil, nil, "", fmt.Errorf("bad sha %q", sha)
	}
	mb, err := f.get(ctx, sha, manifestMax)
	if err != nil {
		return nil, nil, "", err
	}
	at := sha
	if sha == "stable" {
		// the signature lives under the commit the manifest names; the
		// claim is only trusted once that signature checks out below
		var peek struct {
			SHA string `json:"sha"`
		}
		if json.Unmarshal(mb, &peek) != nil || !ValidSHA(peek.SHA) {
			return nil, nil, "", errors.New("stable: the hub's manifest names no commit")
		}
		at = peek.SHA
	}
	sig, err := f.get(ctx, at+"/"+SigName, 1024)
	if err != nil {
		return nil, nil, "", err
	}
	m, err := Verify(f.Key, mb, string(sig))
	if err != nil {
		return nil, nil, "", err
	}
	if sha != "stable" && m.SHA != sha {
		return nil, nil, "", fmt.Errorf("asked for %s, the signed manifest is %s", sha, m.SHA)
	}
	return m, mb, strings.TrimSpace(string(sig)), nil
}

// Fetch installs <sha> under dest (which must not exist): the runtime tree at
// dest/, the signed manifest at dest/.release/, and — when artifacts — every
// artifact at dest/.release/artifacts/<name>. Nothing that fails a check is
// left behind: it is built at dest.partial and renamed only when whole.
func (f *Fetcher) Fetch(ctx context.Context, sha, dest string, artifacts bool) (*Manifest, error) {
	if _, err := os.Lstat(dest); err == nil {
		return nil, fmt.Errorf("%s already exists", dest)
	}
	m, mb, sig, err := f.Manifest(ctx, sha)
	if err != nil {
		return nil, err
	}
	tree, err := f.get(ctx, m.SHA+"/"+TreeName, treeMax)
	if err != nil {
		return nil, err
	}
	tmp := dest + ".partial"
	_ = os.RemoveAll(tmp)
	if err := Unpack(m, tree, tmp); err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			_ = os.RemoveAll(tmp)
		}
	}()
	meta := tmp + "/.release"
	if err := os.MkdirAll(meta+"/"+ArtifactDir, 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(meta+"/"+ManifestName, mb, 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(meta+"/"+SigName, []byte(sig+"\n"), 0o644); err != nil {
		return nil, err
	}
	if artifacts {
		for _, a := range m.Artifacts {
			if err := f.artifact(ctx, m.SHA, a, meta+"/"+ArtifactDir+"/"+a.Name); err != nil {
				return nil, err
			}
		}
	}
	if err := os.Rename(tmp, dest); err != nil {
		return nil, err
	}
	ok = true
	return m, nil
}

// artifact streams one artifact to dst and checks it against the manifest.
func (f *Fetcher) artifact(ctx context.Context, sha string, want Blob, dst string) error {
	if !ValidArtifact(want.Name) {
		return fmt.Errorf("manifest: bad artifact name %q", want.Name)
	}
	u := strings.TrimRight(f.Hub, "/") + Path + sha + "/" + ArtifactDir + "/" + want.Name
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := f.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", u, resp.StatusCode)
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, h), io.LimitReader(resp.Body, want.Size+1))
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if n != want.Size || hex.EncodeToString(h.Sum(nil)) != want.SHA256 {
		return errors.New(want.Name + ": digest does not match the manifest")
	}
	return nil
}

// VerifyDir re-checks an installed release dir against its own signed
// manifest and the pinned key: every file present with its digest.
func VerifyDir(key ed25519.PublicKey, dir string) (*Manifest, error) {
	mb, err := os.ReadFile(dir + "/.release/" + ManifestName)
	if err != nil {
		return nil, err
	}
	sig, err := os.ReadFile(dir + "/.release/" + SigName)
	if err != nil {
		return nil, err
	}
	m, err := Verify(key, mb, string(sig))
	if err != nil {
		return nil, err
	}
	for _, fl := range m.Files {
		b, err := os.ReadFile(dir + "/" + fl.Path)
		if err != nil {
			return nil, err
		}
		if int64(len(b)) != fl.Size || digest(b) != fl.SHA256 {
			return nil, fmt.Errorf("%s: digest does not match the manifest", fl.Path)
		}
	}
	for _, a := range m.Artifacts {
		b, err := os.ReadFile(dir + "/.release/" + ArtifactDir + "/" + a.Name)
		if errors.Is(err, os.ErrNotExist) {
			continue // fetched without artifacts
		}
		if err != nil {
			return nil, err
		}
		if err := CheckBlob(a, b); err != nil {
			return nil, err
		}
	}
	return m, nil
}

// Summary is one line for a person: sha, file and artifact counts, key.
func Summary(m *Manifest) string {
	b, _ := json.Marshal(struct {
		SHA       string `json:"sha"`
		Files     int    `json:"files"`
		Artifacts int    `json:"artifacts"`
		Key       string `json:"key"`
	}{m.SHA, len(m.Files), len(m.Artifacts), m.Key})
	return string(b)
}
