package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// claude-fleet#2772 (EPIC #2770 C2): the CI pushes each stable to the hub, the
// hub checks the bytes are that commit and that it is the release CI, and
// from then on never asks GitHub.

// gitRepo is a real git repository the publishes are cut from.
type gitRepo struct {
	t   *testing.T
	dir string
}

func newGitRepo(t *testing.T) *gitRepo {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	g := &gitRepo{t, t.TempDir()}
	g.git("init", "-q", "-b", "master")
	g.write(StableManifestPath, "bin/fleet\n")
	g.write(release.TreeListPath, "bin/\nconf/\n*\n!tokenledger/\n")
	g.write("README.md", "# r\n")
	g.write("tokenledger/go.mod", "module x\n")
	return g
}

func (g *gitRepo) git(args ...string) string {
	g.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = g.dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	out, err := cmd.Output()
	if err != nil {
		g.t.Fatalf("git %v: %v", args, err)
	}
	return string(out)
}

func (g *gitRepo) write(p, body string) {
	g.t.Helper()
	full := filepath.Join(g.dir, filepath.FromSlash(p))
	must(g.t, os.MkdirAll(filepath.Dir(full), 0o755))
	mode := os.FileMode(0o644)
	if strings.HasPrefix(p, "bin/") {
		mode = 0o755
	}
	must(g.t, os.WriteFile(full, []byte(body), mode))
}

// commit writes bin/fleet (and any extra files) and commits: its sha.
func (g *gitRepo) commit(say string, extra map[string]string) string {
	g.t.Helper()
	g.write("bin/fleet", "#!/bin/sh\necho "+say+"\n")
	for p, b := range extra {
		g.write(p, b)
	}
	g.git("add", "-A")
	g.git("commit", "-qm", say)
	return strings.TrimSpace(g.git("rev-parse", "HEAD"))
}

// archive is `git archive --format=tar <sha> | gzip`.
func (g *gitRepo) archive(sha string) []byte {
	g.t.Helper()
	cmd := exec.Command("git", "archive", "--format=tar", sha)
	cmd.Dir = g.dir
	tarb, err := cmd.Output()
	if err != nil {
		g.t.Fatal(err)
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write(tarb)
	_ = zw.Close()
	return buf.Bytes()
}

// commits is `git rev-list --first-parent <prev>..<sha> | git cat-file --batch`.
func (g *gitRepo) commits(prev, sha string) []byte {
	g.t.Helper()
	rng := sha
	if prev != "" {
		rng = prev + ".." + sha
	}
	list := g.git("rev-list", "--first-parent", rng)
	cmd := exec.Command("git", "cat-file", "--batch")
	cmd.Dir = g.dir
	cmd.Stdin = strings.NewReader(list)
	out, err := cmd.Output()
	if err != nil {
		g.t.Fatal(err)
	}
	return out
}

// oidcIssuer signs GitHub-Actions-shaped tokens and serves its keys.
type oidcIssuer struct {
	key  *rsa.PrivateKey
	kid  string
	srv  *httptest.Server
	hits int
	mu   sync.Mutex
}

func newOIDCIssuer(t *testing.T) *oidcIssuer {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	o := &oidcIssuer{key: k, kid: "k1"}
	o.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o.mu.Lock()
		o.hits++
		o.mu.Unlock()
		e := big.NewInt(int64(k.E)).Bytes()
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "kid": o.kid, "alg": "RS256", "use": "sig",
			"n": base64.RawURLEncoding.EncodeToString(k.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(e)}}})
	}))
	t.Cleanup(o.srv.Close)
	return o
}

const testIssuer = "https://token.actions.githubusercontent.com"

// token: a signed token with GitHub's claims for repo o/r, master,
// stable-auto.yml — edit overrides any claim.
func (o *oidcIssuer) token(edit map[string]any) string {
	now := time.Now().Unix()
	c := map[string]any{"iss": testIssuer, "aud": DefaultPublishAudience, "exp": now + 300, "nbf": now - 10, "iat": now - 10,
		"repository": "o/r", "ref": "refs/heads/master", "run_id": "4242",
		"workflow_ref": "o/r/.github/workflows/stable-auto.yml@refs/heads/master"}
	for k, v := range edit {
		c[k] = v
	}
	hb, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT", "kid": o.kid})
	pb, _ := json.Marshal(c)
	in := base64.RawURLEncoding.EncodeToString(hb) + "." + base64.RawURLEncoding.EncodeToString(pb)
	sum := sha256.Sum256([]byte(in))
	sig, _ := rsa.SignPKCS1v15(rand.Reader, o.key, crypto.SHA256, sum[:])
	return in + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// blackHole is GitHub out of reach: every request is counted and refused.
type blackHole struct {
	mu   sync.Mutex
	hits []string
}

func (b *blackHole) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	b.mu.Lock()
	b.hits = append(b.hits, r.URL.Path)
	b.mu.Unlock()
	http.Error(w, "black hole", http.StatusBadGateway)
}

func (b *blackHole) count() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.hits...)
}

type publishRig struct {
	*releaseRig
	tt   *testing.T
	h    *harness
	repo *gitRepo
	oidc *oidcIssuer
	hole *blackHole
}

func newPublishRig(t *testing.T) *publishRig {
	t.Helper()
	r := newReleaseRig(t)
	p := &publishRig{releaseRig: r, tt: t, repo: newGitRepo(t), oidc: newOIDCIssuer(t), hole: &blackHole{}}
	hole := httptest.NewServer(p.hole)
	t.Cleanup(hole.Close)
	// GitHub's three hosts all a black hole: nothing below may need them
	src := &StableSource{Repo: "o/r", APIBase: hole.URL, RawBase: hole.URL, CodeloadBase: hole.URL}
	r.rs.Source = src
	src.OnStable = r.rs.OnStable
	src.Local = r.rs
	r.rs.Publish = &PublishAuth{JWKSURL: p.oidc.srv.URL, CacheFile: filepath.Join(r.dir, ".publish-jwks.json")}
	p.h, _ = certHarness(t)
	p.h.srv.Stable = src
	p.h.srv.Releases = r.rs
	return p
}

// publish POSTs one stable: tree and commits cut from the repo unless given.
func (p *publishRig) publish(tok, sha, prev string, tree, commits []byte) (int, string) {
	p.t().Helper()
	if tree == nil {
		tree = p.repo.archive(sha)
	}
	if commits == nil {
		commits = p.repo.commits(prev, sha)
	}
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("sha", sha)
	_ = mw.WriteField("prev", prev)
	_ = mw.WriteField("run", "https://github.com/o/r/actions/runs/4242")
	fw, _ := mw.CreateFormFile("commits", "commits")
	_, _ = fw.Write(commits)
	fw, _ = mw.CreateFormFile("tree", "tree.tar.gz")
	_, _ = fw.Write(tree)
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, p.h.http.URL+release.Path+"publish", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		p.t().Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	_, _ = b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

func (p *publishRig) t() *testing.T { return p.tt }

// tarPlus is tarb with one more file appended.
func tarPlus(t *testing.T, tarb []byte, name, body string) []byte {
	t.Helper()
	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	tr := tar.NewReader(bytes.NewReader(tarb))
	for {
		hd, err := tr.Next()
		if err != nil {
			break
		}
		must(t, tw.WriteHeader(hd))
		_, _ = io.Copy(tw, tr)
	}
	must(t, tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg}))
	_, _ = tw.Write([]byte(body))
	must(t, tw.Close())
	return out.Bytes()
}

func (p *publishRig) stable(t *testing.T) *release.Manifest {
	t.Helper()
	resp, body := getBody(t, p.h.http.URL+release.Path+"stable")
	if resp.StatusCode != 200 {
		t.Fatalf("GET stable: %d %s", resp.StatusCode, body)
	}
	m, err := release.Verify(p.pub, []byte(body), resp.Header.Get("X-Ccquota-Release-Signature"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestPublishStoresAndServesWithGitHubGone(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", nil)
	b := p.repo.commit("B", nil)
	c := p.repo.commit("C", map[string]string{"conf/x.conf": "x=1\n"})
	tok := p.oidc.token(nil)

	if code, body := p.publish(tok, a, "", nil, nil); code != 200 || !strings.Contains(body, `"published"`) {
		t.Fatalf("first publish: %d %s", code, body)
	}
	// two commits at once (B then C): the chain is checked link by link
	if code, body := p.publish(tok, c, a, nil, nil); code != 200 {
		t.Fatalf("publish C over A: %d %s", code, body)
	}
	m := p.stable(t)
	if m.SHA != c || m.Prev != a || m.Seq != 2 {
		t.Fatalf("stable %s prev %s seq %d, want %s prev %s seq 2", m.SHA, m.Prev, m.Seq, c, a)
	}
	_ = b
	// the files are the commit's: bin/fleet says C, conf/x.conf is there, Go source is not
	dest := filepath.Join(t.TempDir(), "rt")
	got, err := (&release.Fetcher{Hub: p.h.http.URL, Key: p.pub}).Fetch(context.Background(), "stable", dest, true)
	if err != nil || got.SHA != c {
		t.Fatalf("fetch stable: %v %v", got, err)
	}
	if bs, _ := os.ReadFile(filepath.Join(dest, "bin/fleet")); string(bs) != "#!/bin/sh\necho C\n" {
		t.Fatalf("bin/fleet = %q", bs)
	}
	if _, err := os.Stat(filepath.Join(dest, "tokenledger/go.mod")); err == nil {
		t.Fatal("the Go source shipped")
	}
	// /version and /install/stable/<sha>/ follow the publish, not GitHub
	var v map[string]any
	_, body := getBody(t, p.h.http.URL+"/version")
	_ = json.Unmarshal([]byte(body), &v)
	if v["client_version"] != c || v["client_url"] != p.h.http.URL+"/install/stable/"+c {
		t.Fatalf("/version = %v, want %s", v, c)
	}
	resp, body := getBody(t, p.h.http.URL+"/install/stable/"+c+"/bin/fleet")
	if resp.StatusCode != 200 || body != "#!/bin/sh\necho C\n" {
		t.Fatalf("/install/stable/%s/bin/fleet: %d %q", c[:7], resp.StatusCode, body)
	}
	if resp, _ := getBody(t, p.h.http.URL+"/install/stable/"+b+"/bin/fleet"); resp.StatusCode != 404 {
		t.Fatalf("B was never stable here, yet served: %d", resp.StatusCode)
	}
	// a lookup GitHub would answer is never made, nor obeyed if in flight
	p.rs.OnStable(b)
	if p.stable(t).SHA != c {
		t.Fatal("a GitHub lookup moved a published stable")
	}
	if hits := p.hole.count(); len(hits) != 0 {
		t.Fatalf("the hub asked GitHub %d times: %v", len(hits), hits)
	}
	// one audit row per publish
	rows, err := p.h.srv.Store.FleetAuditLog(0)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range rows {
		if r.Action == "release_publish" && r.Outcome == "PUBLISHED" && strings.Contains(r.Actor, "stable-auto.yml run 4242") {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("audit: %d publish rows, want 2: %+v", n, rows)
	}
}

func TestPublishTamperedTreeRefused(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", nil)
	tok := p.oidc.token(nil)
	// one byte of one file changed, then archived again: not that commit
	cmd := exec.Command("git", "archive", "--format=tar", a)
	cmd.Dir = p.repo.dir
	tarb, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	bad := bytes.Replace(tarb, []byte("echo A"), []byte("echo X"), 1)
	if bytes.Equal(bad, tarb) {
		t.Fatal("nothing replaced")
	}
	if code, body := p.publish(tok, a, "", bad, nil); code != 400 || !strings.Contains(body, "tree") {
		t.Fatalf("tampered tree: %d %s", code, body)
	}
	// an extra file riding along
	if code, body := p.publish(tok, a, "", tarPlus(t, tarb, "bin/evil", "#!/bin/sh\nrm -rf ~\n"), nil); code != 400 {
		t.Fatalf("extra file: %d %s", code, body)
	}
	// a commit object edited (its tree line) under the sha it claims
	cs := p.repo.commits("", a)
	if code, body := p.publish(tok, a, "", nil, bytes.Replace(cs, []byte("A\n"), []byte("Z\n"), 1)); code != 400 {
		t.Fatalf("edited commit: %d %s", code, body)
	}
	if p.rs.Has(a) || p.rs.stable().SHA != "" {
		t.Fatal("a refused publish left a release behind")
	}
}

func TestPublishIdentityRefused(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", nil)
	for name, tok := range map[string]string{
		"none":         "",
		"other repo":   p.oidc.token(map[string]any{"repository": "evil/r", "workflow_ref": "evil/r/.github/workflows/stable-auto.yml@refs/heads/master"}),
		"other branch": p.oidc.token(map[string]any{"ref": "refs/heads/pr", "workflow_ref": "o/r/.github/workflows/stable-auto.yml@refs/heads/pr"}),
		"other flow":   p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/selftests.yml@refs/heads/master"}),
		"audience":     p.oidc.token(map[string]any{"aud": "sts.amazonaws.com"}),
		"issuer":       p.oidc.token(map[string]any{"iss": "https://evil.example"}),
		"expired":      p.oidc.token(map[string]any{"exp": time.Now().Add(-time.Hour).Unix()}),
		"bad sig":      p.oidc.token(nil)[:20] + "x" + p.oidc.token(nil)[21:],
		"a guess":      "hunter2",
	} {
		if code, body := p.publish(tok, a, "", nil, nil); code != 401 {
			t.Errorf("%s: %d %s", name, code, body)
		}
	}
	// the manual workflow is the other publisher
	if code, body := p.publish(p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/stable-publish.yml@refs/heads/master"}), a, "", nil, nil); code != 200 {
		t.Fatalf("stable-publish.yml: %d %s", code, body)
	}
	// the fallback bearer, when the hub carries one
	b := p.repo.commit("B", nil)
	p.rs.Publish.Token = "publish-only-secret"
	if code, body := p.publish("publish-only-secret", b, a, nil, nil); code != 200 {
		t.Fatalf("publish token: %d %s", code, body)
	}
	// the keys came once and are kept: a hub that loses the issuer still takes tokens
	if _, err := os.Stat(filepath.Join(p.dir, ".publish-jwks.json")); err != nil {
		t.Fatal("issuer keys not kept:", err)
	}
}

func TestPublishOnlyForward(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", nil)
	b := p.repo.commit("B", nil)
	tok := p.oidc.token(nil)
	if code, body := p.publish(tok, b, "", nil, nil); code != 200 {
		t.Fatalf("publish B: %d %s", code, body)
	}
	// back to A: nothing between B and A
	if code, body := p.publish(tok, a, b, nil, nil); code != 409 {
		t.Fatalf("rollback: %d %s", code, body)
	}
	// a CI that read a stale stable
	c := p.repo.commit("C", nil)
	if code, body := p.publish(tok, c, a, nil, nil); code != 409 || !strings.Contains(body, b) {
		t.Fatalf("stale prev: %d %s", code, body)
	}
	// sideways: a branch off A, whose chain never meets B
	p.repo.git("checkout", "-q", "-b", "side", a)
	d := p.repo.commit("D", nil)
	if code, body := p.publish(tok, d, b, nil, p.repo.commits(a, d)); code != 409 {
		t.Fatalf("sideways: %d %s", code, body)
	}
	// the same sha again: 200, nothing new
	if code, body := p.publish(tok, b, "", nil, []byte{}); code != 200 || !strings.Contains(body, `"already"`) {
		t.Fatalf("again: %d %s", code, body)
	}
	if m := p.stable(t); m.SHA != b || m.Seq != 1 {
		t.Fatalf("stable %s seq %d after refusals", m.SHA, m.Seq)
	}
}

func TestPublishRefusesMissingPinned(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", map[string]string{"release.json": `{"schema":1,"components":{"codex":{"version":"9.9.9","artifact":"codex-{version}-{os}-{arch}"}}}`})
	if code, body := p.publish(p.oidc.token(nil), a, "", nil, nil); code != 422 || !strings.Contains(body, "9.9.9") {
		t.Fatalf("missing pin: %d %s", code, body)
	}
	if p.rs.stable().SHA != "" {
		t.Fatal("stable moved to a release no machine could install")
	}
}

// claude-fleet#2930: a commit whose Go source is not the hub image's is a 422
// (ccquota:) and stable stays; a commit that changes no Go goes through.
func TestPublishRefusesStaleCCQuota(t *testing.T) {
	p := newPublishRig(t)
	tok := p.oidc.token(nil)
	a := p.repo.commit("A", map[string]string{"tokenledger/internal/x/x.go": "package x\n"})
	if code, body := p.publish(tok, a, "", nil, nil); code != 422 || !strings.Contains(body, "ccquota:") || !strings.Contains(body, "redeploy") {
		t.Fatalf("a new tokenledger/ over an old image: %d %s", code, body)
	}
	if p.rs.stable().SHA != "" {
		t.Fatal("stable moved onto a release carrying another commit's ccquota")
	}
	p.rs.DistSrc = release.SourceDigest(map[string][]byte{"tokenledger/go.mod": []byte("module x\n"), "tokenledger/internal/x/x.go": []byte("package x\n")})
	if code, body := p.publish(tok, a, "", nil, nil); code != 200 {
		t.Fatalf("once the image is A's: %d %s", code, body)
	}
	b := p.repo.commit("B", map[string]string{"conf/x.conf": "x=1\n"})
	if code, body := p.publish(tok, b, a, nil, nil); code != 200 {
		t.Fatalf("a commit with the same Go: %d %s", code, body)
	}
	if m := p.stable(t); m.SHA != b || m.CCQuotaSrc != p.rs.DistSrc {
		t.Fatalf("stable %s ccquota_src %q", m.SHA, m.CCQuotaSrc)
	}
}

// Off adds nothing: no release store (no signing key) or no publisher → the
// route is a 404 and the hub is as before.
func TestPublishOffAddsNothing(t *testing.T) {
	s := &Server{}
	mux := http.NewServeMux()
	mux.HandleFunc(release.Path, s.handleRelease)
	h := httptest.NewServer(mux)
	defer h.Close()
	resp, err := http.Post(h.URL+release.Path+"publish", "text/plain", strings.NewReader("x"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("no store: %d", resp.StatusCode)
	}
	r := newReleaseRig(t)
	resp, err = http.Post(r.hub.URL+release.Path+"publish", "text/plain", strings.NewReader("x"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("no publisher: %d", resp.StatusCode)
	}
	// a store that never took a publish still follows GitHub, as before
	src := r.rs.Source
	src.Local = r.rs
	if err := src.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if src.Commit() != shaA {
		t.Fatalf("Commit = %q, want GitHub's %s", src.Commit(), shaA)
	}
	// and Offline (CCQUOTA_FLEET_STABLE_REPO=off) with nothing published is
	// the image's client: no stable at all
	off := &StableSource{Offline: true, Local: r.rs}
	if off.Commit() != "" || off.Seen(shaA) {
		t.Fatal("an offline source with nothing published names a stable")
	}
}
