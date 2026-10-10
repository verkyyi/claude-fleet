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
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
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

// DefaultStall: a response that sends no byte for this long is cut — the only
// deadline a fetch has (claude-fleet#2701: a whole-body deadline threw away a
// 700 MB release at 1 MB/s, every time).
const DefaultStall = 30 * time.Second

// ProgressEvery: how often a running download prints its line.
const ProgressEvery = 5 * time.Second

// Fetcher downloads a release from the hub and checks it against the pinned
// key. It never talks to anything but Hub.
//
// Artifacts download one by one into Cache as <sha256>.part — resumed with a
// Range request from whatever is already there, after a cut connection in the
// same run or a killed run before it — and become <sha256> only once their
// digest matches the manifest; a <sha256> already in Cache (a machine's earlier
// release, seeded by the updater) is not fetched again.
type Fetcher struct {
	Hub    string // https://hub…, no trailing slash needed
	Key    ed25519.PublicKey
	Client *http.Client // no overall Timeout: Stall is the deadline
	// Cache keeps the artifacts across runs; "" = <dest>.dl, removed once whole.
	Cache string
	// Platforms, when set, fetches only the artifacts the tree's release.json
	// pins for these "<os>-<arch>" (Pinned) — not every file the hub carries.
	// A tree with no release.json falls back to every artifact.
	Platforms []string
	Stall     time.Duration // 0 = DefaultStall
	Progress  io.Writer     // nil = quiet; one line per artifact + every ProgressEvery
}

func (f *Fetcher) client() *http.Client {
	if f.Client != nil {
		return f.Client
	}
	return http.DefaultClient
}

func (f *Fetcher) stall() time.Duration {
	if f.Stall > 0 {
		return f.Stall
	}
	return DefaultStall
}

func (f *Fetcher) say(format string, a ...any) {
	if f.Progress != nil {
		fmt.Fprintf(f.Progress, format+"\n", a...)
	}
}

// body is a response whose every Read re-arms the stall timer: no byte for
// Stall cancels the request, and the error says so.
type body struct {
	resp    *http.Response
	timer   *time.Timer
	stall   time.Duration
	stalled *atomic.Bool
	cancel  context.CancelFunc
}

func (b *body) Read(p []byte) (int, error) {
	n, err := b.resp.Body.Read(p)
	if n > 0 {
		b.timer.Reset(b.stall)
	}
	if err != nil && err != io.EOF && b.stalled.Load() {
		err = fmt.Errorf("no bytes for %s", b.stall)
	}
	return n, err
}

func (b *body) Close() error {
	b.timer.Stop()
	err := b.resp.Body.Close()
	b.cancel()
	return err
}

// open GETs u (from byte `from` on, when > 0) under the stall deadline, which
// covers the wait for the headers too.
func (f *Fetcher) open(ctx context.Context, u string, from int64) (*body, error) {
	ctx, cancel := context.WithCancel(ctx)
	stalled := new(atomic.Bool)
	d := f.stall()
	timer := time.AfterFunc(d, func() { stalled.Store(true); cancel() })
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		timer.Stop()
		cancel()
		return nil, err
	}
	if from > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(from, 10)+"-")
	}
	resp, err := f.client().Do(req)
	if err != nil {
		timer.Stop()
		cancel()
		if stalled.Load() {
			return nil, fmt.Errorf("%s: no answer for %s", u, d)
		}
		return nil, err
	}
	return &body{resp: resp, timer: timer, stall: d, stalled: stalled, cancel: cancel}, nil
}

func (f *Fetcher) get(ctx context.Context, rel string, max int64) ([]byte, error) {
	u := strings.TrimRight(f.Hub, "/") + Path + rel
	r, err := f.open(ctx, u, 0)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	if r.resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(r, 200))
		return nil, fmt.Errorf("%s: HTTP %d %s", u, r.resp.StatusCode, strings.TrimSpace(string(b)))
	}
	b, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", u, err)
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("%s: larger than %d bytes", u, max)
	}
	return b, nil
}

// Manifest fetches and verifies <sha>'s manifest ("stable" = whatever the hub
// names stable now; the signed manifest then says which sha that is). It
// returns the parsed manifest and the exact signed bytes + signature.
//
// The manifest and its signature are two reads, and the hub resolves each
// through <sha>/current on its own: a build or reseal of the same sha landing
// between them hands back a manifest of one build and the signature of another,
// which fails the check with the right key (claude-fleet#2843: macmini, 341ae18,
// right after stable moved). So a failed check reads the pair once more; a key
// that really differs fails both times.
func (f *Fetcher) Manifest(ctx context.Context, sha string) (*Manifest, []byte, string, error) {
	m, mb, sig, err := f.manifestOnce(ctx, sha)
	if errors.Is(err, errBadSignature) {
		f.say("  %s: the signature did not match — reading the manifest and its signature again", sha)
		m, mb, sig, err = f.manifestOnce(ctx, sha)
	}
	return m, mb, sig, err
}

func (f *Fetcher) manifestOnce(ctx context.Context, sha string) (*Manifest, []byte, string, error) {
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
// artifact (or only the pinned ones, Platforms) at dest/.release/artifacts/<name>.
// Nothing that fails a check is left behind: it is built at dest.partial and
// renamed only when whole; what was downloaded stays in Cache for the next run.
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
		want, err := f.selectArtifacts(m, tmp)
		if err != nil {
			return nil, err
		}
		cache, own := f.Cache, false
		if cache == "" {
			cache, own = dest+".dl", true
		}
		if err := os.MkdirAll(cache, 0o755); err != nil {
			return nil, err
		}
		var total, need int64
		for _, a := range want {
			total += a.Size
			if !cached(cache, a) {
				need += a.Size - partSize(cache, a)
			}
		}
		f.say("release %s: %d artifacts, %s, %s to download", m.SHA[:12], len(want), sizeMB(total), sizeMB(need))
		for _, a := range want {
			if err := f.artifact(ctx, m.SHA, a, cache, meta+"/"+ArtifactDir+"/"+a.Name); err != nil {
				return nil, fmt.Errorf("artifact %s: %w", a.Name, err)
			}
		}
		if own {
			defer os.RemoveAll(cache)
		}
	}
	if err := os.Rename(tmp, dest); err != nil {
		return nil, err
	}
	ok = true
	return m, nil
}

// selectArtifacts: every artifact, or (Platforms) the ones the unpacked tree's
// release.json pins — those the manifest carries; a missing one is the
// caller's to name (the updater says which hub setting lacks it).
func (f *Fetcher) selectArtifacts(m *Manifest, tree string) ([]Blob, error) {
	if len(f.Platforms) == 0 {
		return m.Artifacts, nil
	}
	rj, err := os.ReadFile(filepath.Join(tree, ReleaseJSON))
	if errors.Is(err, os.ErrNotExist) {
		return m.Artifacts, nil
	}
	if err != nil {
		return nil, err
	}
	names, err := Pinned(rj, f.Platforms)
	if err != nil {
		return nil, err
	}
	pin := map[string]bool{}
	for _, n := range names {
		pin[n] = true
	}
	out := []Blob{}
	for _, a := range m.Artifacts {
		if pin[a.Name] {
			out = append(out, a)
		}
	}
	return out, nil
}

func sizeMB(n int64) string { return fmt.Sprintf("%.1f MB", float64(n)/(1<<20)) }

func cachePath(cache string, a Blob) string { return filepath.Join(cache, a.SHA256) }

func partSize(cache string, a Blob) int64 {
	if st, err := os.Stat(cachePath(cache, a) + ".part"); err == nil && st.Size() <= a.Size {
		return st.Size()
	}
	return 0
}

// cached: <cache>/<sha256> is there with the right size (its digest is checked
// when it is used).
func cached(cache string, a Blob) bool {
	st, err := os.Stat(cachePath(cache, a))
	return err == nil && st.Mode().IsRegular() && st.Size() == a.Size
}

func fileDigest(p string) (string, int64, error) {
	in, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer in.Close()
	h := sha256.New()
	n, err := io.Copy(h, in)
	return hex.EncodeToString(h.Sum(nil)), n, err
}

// place puts the cached file at dst: a hard link (same volume), else a copy.
func place(src, dst string) error {
	if err := os.Link(src, dst); err == nil {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

// artifact brings one artifact into the cache — from what is already there,
// resumed while each attempt makes progress — checks it against the manifest
// and places it at dst.
func (f *Fetcher) artifact(ctx context.Context, sha string, want Blob, cache, dst string) error {
	if !ValidArtifact(want.Name) {
		return fmt.Errorf("manifest: bad artifact name %q", want.Name)
	}
	final := cachePath(cache, want)
	if cached(cache, want) {
		if h, _, err := fileDigest(final); err == nil && h == want.SHA256 {
			f.say("  %s %s: already here", want.Name, sizeMB(want.Size))
			return place(final, dst)
		}
		_ = os.Remove(final)
	}
	u := strings.TrimRight(f.Hub, "/") + Path + sha + "/" + ArtifactDir + "/" + want.Name
	part := final + ".part"
	idle := 0
	for {
		have := partSize(cache, want)
		if have == 0 {
			_ = os.Remove(part) // larger than the artifact: start over
		}
		if have == want.Size {
			break
		}
		err := f.download(ctx, u, part, have, want)
		if err == nil {
			continue
		}
		if ctx.Err() != nil {
			return err
		}
		if partSize(cache, want) > have {
			idle = 0 // it moved: go on from there
		} else if idle++; idle >= 3 {
			return err
		}
		f.say("  %s: %v — resuming at %s", want.Name, err, sizeMB(partSize(cache, want)))
	}
	if h, n, err := fileDigest(part); err != nil {
		return err
	} else if n != want.Size || h != want.SHA256 {
		_ = os.Remove(part)
		return errors.New("digest does not match the manifest")
	}
	if err := os.Chmod(part, 0o755); err != nil {
		return err
	}
	if err := os.Rename(part, final); err != nil {
		return err
	}
	return place(final, dst)
}

// download appends to part from byte `have` on (a Range request; a hub that
// answers the whole file restarts it), printing progress as it goes.
func (f *Fetcher) download(ctx context.Context, u, part string, have int64, want Blob) error {
	r, err := f.open(ctx, u, have)
	if err != nil {
		return err
	}
	defer r.Close()
	flags := os.O_CREATE | os.O_WRONLY
	switch {
	case r.resp.StatusCode == http.StatusPartialContent && have > 0 &&
		strings.HasPrefix(r.resp.Header.Get("Content-Range"), "bytes "+strconv.FormatInt(have, 10)+"-"):
		flags |= os.O_APPEND
	case r.resp.StatusCode == http.StatusOK:
		flags |= os.O_TRUNC
		have = 0
	case r.resp.StatusCode == http.StatusRequestedRangeNotSatisfiable:
		_ = os.Remove(part)
		return fmt.Errorf("%s: HTTP 416 at %d", u, have)
	default:
		return fmt.Errorf("%s: HTTP %d", u, r.resp.StatusCode)
	}
	out, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return err
	}
	start, got := time.Now(), have
	if have > 0 {
		f.say("  %s: resuming at %s of %s", want.Name, sizeMB(have), sizeMB(want.Size))
	} else {
		f.say("  %s: %s", want.Name, sizeMB(want.Size))
	}
	last := start
	buf := make([]byte, 256<<10)
	var werr error
	for got < want.Size {
		n, rerr := r.Read(buf[:min(int64(len(buf)), want.Size-got)])
		if n > 0 {
			if _, werr = out.Write(buf[:n]); werr != nil {
				break
			}
			got += int64(n)
		}
		if f.Progress != nil && time.Since(last) >= ProgressEvery {
			last = time.Now()
			rate := float64(got-have) / time.Since(start).Seconds()
			eta := "?"
			if rate > 0 {
				eta = (time.Duration(float64(want.Size-got)/rate) * time.Second).Round(time.Second).String()
			}
			f.say("  %s: %s / %s · %.2f MB/s · eta %s", want.Name, sizeMB(got), sizeMB(want.Size), rate/(1<<20), eta)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			werr = rerr
			break
		}
	}
	if cerr := out.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return werr
	}
	if got < want.Size {
		return fmt.Errorf("short body: %s of %s", sizeMB(got), sizeMB(want.Size))
	}
	f.say("  %s: done %s in %s", want.Name, sizeMB(want.Size-have), time.Since(start).Round(time.Second))
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
