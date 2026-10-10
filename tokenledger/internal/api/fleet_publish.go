package api

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// Stable is PUSHED to the hub (claude-fleet#2772, EPIC #2770 C2).
//
// The hub used to find out stable had moved by asking GitHub every five
// minutes (StableSource) — so a hub that could not reach GitHub never saw a
// new version, and every machine behind it stood still. Now the CI that moves
// stable hands the hub the commit itself:
//
//	POST /v1/fleet/release/publish   multipart/form-data
//	  sha      the commit stable moved to
//	  prev     the stable the CI read from this hub (/v1/fleet/release/stable); "" for the first
//	  commits  `git rev-list --first-parent <prev>..<sha> | git cat-file --batch`
//	  tree     `git archive --format=tar <sha>` (gzip or not) — the WHOLE commit
//
// The hub trusts none of the road: it hashes the archive file by file into a
// git tree (release.TreeFromArchive), checks that tree is the one sha's commit
// object names, that every commit object hashes to the sha it is listed under,
// and that their first parents run unbroken from sha back to its own stable.
// Then it builds the release from those bytes (release-tree.list, the pinned
// artifacts, the signature) and moves its stable pointer — no GitHub request.
//
//	200 stored (or already stable — a re-run is a no-op) · 400 the bytes are not
//	that commit · 401 not our CI · 409 not forward of this hub's stable ·
//	422 a pinned artifact the hub cannot supply (as claude-fleet#2631)
//
// WHO may publish: a GitHub Actions OIDC token (PublishAuth) — this repo, this
// branch, one of the two publishing workflows; no long-lived secret. The
// fallback is a publish-only bearer (CCQUOTA_FLEET_PUBLISH_TOKEN). Once one
// publish has landed the store is marked (<Dir>/published) and the hub stops
// asking GitHub for good: /version, /install/stable/<sha>/ and the release
// routes all read the store.

// releasePublished marks a store that has taken a publish.
const releasePublished = "published"

// publishMaxBody bounds one publish (the whole repo as a tar: ~27 MB today).
const publishMaxBody = 256 << 20

// publishMaxCommits bounds the first-parent chain one publish may carry.
const publishMaxCommits = 20000

// PublishAuth says who may publish.
type PublishAuth struct {
	Issuer    string       // default https://token.actions.githubusercontent.com
	JWKSURL   string       // default <Issuer>/.well-known/jwks
	Audience  string       // default ccquota-fleet-release
	Repo      string       // owner/name the token must name; default the store's
	Ref       string       // default refs/heads/master
	Workflows []string     // default stable-auto.yml, stable-publish.yml
	Token     string       // the fallback publish-only bearer ("" = none)
	CacheFile string       // where the issuer's keys are kept across restarts
	Client    *http.Client // nil = a 15 s one
	Now       func() time.Time

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

// DefaultPublishAudience is the audience the publishing workflows ask for.
const DefaultPublishAudience = "ccquota-fleet-release"

func (a *PublishAuth) issuer() string {
	if a.Issuer != "" {
		return strings.TrimRight(a.Issuer, "/")
	}
	return "https://token.actions.githubusercontent.com"
}

func (a *PublishAuth) audience() string {
	if a.Audience != "" {
		return a.Audience
	}
	return DefaultPublishAudience
}

func (a *PublishAuth) ref() string {
	if a.Ref != "" {
		return a.Ref
	}
	return "refs/heads/master"
}

func (a *PublishAuth) workflows() []string {
	if len(a.Workflows) > 0 {
		return a.Workflows
	}
	return []string{"stable-auto.yml", "stable-publish.yml"}
}

func (a *PublishAuth) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

// errPublishAuth is every 401.
var errPublishAuth = errors.New("not the release CI")

// Check reads the request's bearer: who it is, or errPublishAuth (wrapped).
func (a *PublishAuth) Check(ctx context.Context, r *http.Request, repo string) (string, error) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		tok, ok = strings.CutPrefix(r.Header.Get("Authorization"), "bearer ")
	}
	tok = strings.TrimSpace(tok)
	if !ok || tok == "" {
		return "", fmt.Errorf("%w: no bearer", errPublishAuth)
	}
	if strings.Count(tok, ".") != 2 {
		if a.Token != "" && subtle.ConstantTimeCompare(sha256Sum(tok), sha256Sum(a.Token)) == 1 {
			return "publish-token", nil
		}
		return "", fmt.Errorf("%w: not a token this hub takes", errPublishAuth)
	}
	c, err := a.verifyJWT(ctx, tok)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errPublishAuth, err)
	}
	if a.Repo != "" {
		repo = a.Repo
	}
	if c.Repository != repo {
		return "", fmt.Errorf("%w: repository %q, want %q", errPublishAuth, c.Repository, repo)
	}
	if c.Ref != a.ref() {
		return "", fmt.Errorf("%w: ref %q, want %q", errPublishAuth, c.Ref, a.ref())
	}
	wf := ""
	for _, w := range a.workflows() {
		if c.WorkflowRef == repo+"/.github/workflows/"+w+"@"+a.ref() {
			wf = w
		}
	}
	if wf == "" {
		return "", fmt.Errorf("%w: workflow %q is not a publishing one", errPublishAuth, c.WorkflowRef)
	}
	return fmt.Sprintf("github-actions %s run %s", wf, c.RunID), nil
}

func sha256Sum(s string) []byte {
	h := sha256.Sum256([]byte(s))
	return h[:]
}

// oidcClaims is what a GitHub Actions token says that the hub reads.
type oidcClaims struct {
	Iss         string          `json:"iss"`
	Aud         json.RawMessage `json:"aud"`
	Exp         int64           `json:"exp"`
	Nbf         int64           `json:"nbf"`
	Repository  string          `json:"repository"`
	Ref         string          `json:"ref"`
	WorkflowRef string          `json:"workflow_ref"`
	RunID       string          `json:"run_id"`
}

func (c *oidcClaims) hasAud(want string) bool {
	var one string
	if json.Unmarshal(c.Aud, &one) == nil {
		return one == want
	}
	var many []string
	if json.Unmarshal(c.Aud, &many) == nil {
		for _, a := range many {
			if a == want {
				return true
			}
		}
	}
	return false
}

// verifyJWT checks an RS256 token against the issuer's keys and its time and
// audience claims.
func (a *PublishAuth) verifyJWT(ctx context.Context, tok string) (*oidcClaims, error) {
	parts := strings.Split(tok, ".")
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("bad header")
	}
	var hd struct{ Alg, Kid string }
	if json.Unmarshal(hb, &hd) != nil || hd.Alg != "RS256" {
		return nil, fmt.Errorf("alg %q, want RS256", hd.Alg)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, errors.New("bad signature encoding")
	}
	pub, err := a.key(ctx, hd.Kid)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
		return nil, errors.New("signature does not verify")
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("bad payload")
	}
	var c oidcClaims
	if err := json.Unmarshal(pb, &c); err != nil {
		return nil, errors.New("bad claims")
	}
	now := a.now().Unix()
	const skew = 60
	switch {
	case c.Iss != a.issuer():
		return nil, fmt.Errorf("issuer %q", c.Iss)
	case !c.hasAud(a.audience()):
		return nil, fmt.Errorf("audience is not %q", a.audience())
	case c.Exp == 0 || now > c.Exp+skew:
		return nil, errors.New("expired")
	case c.Nbf != 0 && now+skew < c.Nbf:
		return nil, errors.New("not valid yet")
	}
	return &c, nil
}

// jwksRefetch: how often an unknown key id may send the hub to the issuer.
const jwksRefetch = time.Minute

// key is the issuer's key kid — from memory, the cache file, or the issuer
// (asked at most once a jwksRefetch, and only for a kid not already known: a
// hub that lost GitHub keeps taking tokens signed by the keys it has).
func (a *PublishAuth) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.keys == nil && a.CacheFile != "" {
		if b, err := os.ReadFile(a.CacheFile); err == nil {
			a.keys, _ = parseJWKS(b)
		}
	}
	if k := a.keys[kid]; k != nil {
		return k, nil
	}
	if time.Since(a.fetched) < jwksRefetch {
		return nil, fmt.Errorf("unknown key id %q", kid)
	}
	a.fetched = time.Now()
	u := a.JWKSURL
	if u == "" {
		u = a.issuer() + "/.well-known/jwks"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	c := a.Client
	if c == nil {
		c = &http.Client{Timeout: 15 * time.Second}
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("unknown key id %q, and the issuer's keys: %v", kid, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	keys, err := parseJWKS(b)
	if resp.StatusCode != http.StatusOK || err != nil {
		return nil, fmt.Errorf("unknown key id %q, and the issuer's keys: HTTP %d %v", kid, resp.StatusCode, err)
	}
	a.keys = keys
	if a.CacheFile != "" {
		_ = replaceFile(a.CacheFile, "."+filepath.Base(a.CacheFile)+".tmp", b)
	}
	if k := keys[kid]; k != nil {
		return k, nil
	}
	return nil, fmt.Errorf("unknown key id %q", kid)
}

func parseJWKS(b []byte) (map[string]*rsa.PublicKey, error) {
	var set struct {
		Keys []struct{ Kty, Kid, N, E string }
	}
	if err := json.Unmarshal(b, &set); err != nil {
		return nil, err
	}
	out := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		nb, err1 := base64.RawURLEncoding.DecodeString(k.N)
		eb, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(eb) > 4 {
			continue
		}
		e := 0
		for _, x := range eb {
			e = e<<8 | int(x)
		}
		out[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: e}
	}
	if len(out) == 0 {
		return nil, errors.New("no RSA keys")
	}
	return out, nil
}

// publishError carries the status a refused publish answers.
type publishError struct {
	code int
	msg  string
}

func (e *publishError) Error() string { return e.msg }

func publishErr(code int, format string, a ...any) error {
	return &publishError{code, fmt.Sprintf(format, a...)}
}

// publishForm is one publish request, read whole.
type publishForm struct {
	sha, prev, run string
	commits, tree  []byte
	hasCommits     bool // an empty list is an answer: nothing between prev and sha
}

func readPublishForm(r *http.Request) (*publishForm, error) {
	mr, err := r.MultipartReader()
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "want multipart/form-data: %v", err)
	}
	f := &publishForm{}
	for {
		p, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, publishErr(http.StatusBadRequest, "body: %v", err)
		}
		b, err := io.ReadAll(p)
		if err != nil {
			return nil, publishErr(http.StatusRequestEntityTooLarge, "body: %v", err)
		}
		switch p.FormName() {
		case "sha":
			f.sha = strings.TrimSpace(string(b))
		case "prev":
			f.prev = strings.TrimSpace(string(b))
		case "run":
			f.run = firstLine(strings.TrimSpace(string(b)))
		case "commits":
			f.commits, f.hasCommits = b, true
		case "tree":
			f.tree = b
		}
	}
	switch {
	case !release.ValidSHA(f.sha):
		return nil, publishErr(http.StatusBadRequest, "sha: want 40 hex, got %q", firstLine(f.sha))
	case f.prev != "" && !release.ValidSHA(f.prev):
		return nil, publishErr(http.StatusBadRequest, "prev: want 40 hex or nothing, got %q", firstLine(f.prev))
	case !f.hasCommits:
		return nil, publishErr(http.StatusBadRequest, "commits: missing")
	case len(f.tree) == 0:
		return nil, publishErr(http.StatusBadRequest, "tree: missing")
	}
	return f, nil
}

// handlePublish serves POST /v1/fleet/release/publish.
func (s *Server) handlePublish(w http.ResponseWriter, r *http.Request) {
	rs := s.Releases
	if rs == nil || rs.Publish == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	who, err := rs.Publish.Check(r.Context(), r, rs.Repo)
	sha := ""
	done := func(code int, outcome, detail string, body map[string]any) {
		log.Printf("fleet: release publish %s by %s: %d %s %s", short(sha), orNone(who), code, outcome, detail)
		if s.Store != nil {
			if err := s.Store.FleetAudit(orNone(who), "release_publish", sha, outcome, firstLine(detail), time.Now()); err != nil {
				log.Printf("fleet: release publish audit: %v", err)
			}
		}
		if code != http.StatusOK {
			httpError(w, code, detail)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(body)
	}
	if err != nil {
		done(http.StatusUnauthorized, "REFUSED", err.Error(), nil)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, publishMaxBody)
	f, err := readPublishForm(r)
	if err != nil {
		var pe *publishError
		errors.As(err, &pe)
		done(pe.code, "REFUSED", pe.msg, nil)
		return
	}
	sha = f.sha
	if f.run != "" {
		who += " " + f.run
	}
	ctx, cancel := context.WithTimeout(r.Context(), releaseBuildTime)
	defer cancel()
	out, err := rs.Accept(ctx, f)
	if err != nil {
		var pe *publishError
		if !errors.As(err, &pe) {
			pe = &publishError{http.StatusBadGateway, err.Error()}
		}
		done(pe.code, "REFUSED", pe.msg, nil)
		return
	}
	done(http.StatusOK, strings.ToUpper(out["status"].(string)), fmt.Sprintf("stable #%v prev %v", out["seq"], short(fmt.Sprint(out["prev"]))), out)
}

func short(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	if sha == "" {
		return "-"
	}
	return sha
}

func orNone(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// Accept takes one publish: the bytes checked against the commit, the chain
// checked forward of the store's stable, the release built and made stable.
func (rs *ReleaseStore) Accept(ctx context.Context, f *publishForm) (map[string]any, error) {
	cur := rs.stable()
	ok := func(status string) map[string]any {
		p := rs.stable()
		m := rs.manifest(p.SHA)
		prev := ""
		if m != nil {
			prev = m.Prev
		}
		return map[string]any{"status": status, "sha": p.SHA, "prev": prev, "seq": p.Seq}
	}
	if cur.SHA == f.sha && rs.Has(f.sha) {
		if err := rs.markPublished(f.sha); err != nil {
			return nil, err
		}
		return ok("already"), nil
	}
	cs, err := release.ParseCommitBatch(bytes.NewReader(f.commits), publishMaxCommits)
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "%v", err)
	}
	if len(cs) == 0 {
		// `rev-list prev..sha` is empty: sha is prev or behind it
		return nil, publishErr(http.StatusConflict, "%s is not forward of %s (no commits between)", short(f.sha), short(f.prev))
	}
	if cs[0].SHA != f.sha {
		return nil, publishErr(http.StatusBadRequest, "commits: the first is %s, not %s", short(cs[0].SHA), short(f.sha))
	}
	for i := 0; i+1 < len(cs); i++ {
		if len(cs[i].Parents) == 0 || cs[i].Parents[0] != cs[i+1].SHA {
			return nil, publishErr(http.StatusBadRequest, "commits: %s's first parent is not %s", short(cs[i].SHA), short(cs[i+1].SHA))
		}
	}
	if cur.SHA != "" {
		if f.prev != cur.SHA {
			return nil, publishErr(http.StatusConflict, "this hub's stable is %s, not %s — read /v1/fleet/release/stable and publish from there", cur.SHA, orNone(f.prev))
		}
		last := cs[len(cs)-1]
		if len(last.Parents) == 0 || last.Parents[0] != cur.SHA {
			return nil, publishErr(http.StatusConflict, "%s is not forward of this hub's stable %s", short(f.sha), short(cur.SHA))
		}
	}
	gitFiles, tree, err := release.TreeFromArchive(bytes.NewReader(f.tree), release.ArchiveLimits{})
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "tree: %v", err)
	}
	if tree != cs[0].Tree {
		return nil, publishErr(http.StatusBadRequest, "tree: the archive hashes to %s, but %s names tree %s", short(tree), short(f.sha), short(cs[0].Tree))
	}
	all := make(map[string][]byte, len(gitFiles))
	for p, g := range gitFiles {
		if g.Mode != "120000" && releasePathSafe(p) { // a release carries regular files, as codeload's did
			all[p] = g.Data
		}
	}
	if _, ok := all[StableManifestPath]; !ok {
		return nil, publishErr(http.StatusBadRequest, "tree: no %s — not this repo", StableManifestPath)
	}
	files, err := releaseTree(all)
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "release-tree.list: %v", err)
	}
	arts := rs.artifacts()
	missing, err := rs.missingPinned(files, arts)
	if err != nil {
		return nil, publishErr(http.StatusBadRequest, "release.json: %v", err)
	}
	if len(missing) > 0 && len(rs.fillPinned(ctx, missing)) < len(missing) {
		if missing, err = rs.missingPinned(files, rs.artifacts()); err != nil {
			return nil, publishErr(http.StatusBadRequest, "release.json: %v", err)
		}
	}
	if len(missing) > 0 {
		return nil, publishErr(http.StatusUnprocessableEntity, "release.json pins %s, which CCQUOTA_FLEET_RELEASE_ARTIFACTS does not hold — put it there", strings.Join(missing, ", "))
	}
	// verified and ours: from here on GitHub is never asked — marked before the
	// build, so not even the build's own prune looks there
	if err := rs.markPublished(f.sha); err != nil {
		return nil, err
	}
	if err := rs.promoteWith(ctx, f.sha, all); err != nil {
		return nil, err
	}
	if p := rs.stable(); p.SHA != f.sha {
		// another publish moved it under us
		return nil, publishErr(http.StatusConflict, "stable moved to %s meanwhile", short(p.SHA))
	}
	return ok("published"), nil
}

// markPublished writes the store's publish mark once.
func (rs *ReleaseStore) markPublished(sha string) error {
	p := filepath.Join(rs.Dir, releasePublished)
	if _, err := os.Stat(p); err == nil {
		return nil
	}
	b, _ := json.Marshal(map[string]string{"first": sha, "at": time.Now().UTC().Format(time.RFC3339)})
	if err := replaceFile(p, ".published-"+sha[:12], append(b, '\n')); err != nil {
		return err
	}
	rs.pubMu.Lock()
	rs.pubAt = time.Time{} // re-read now
	rs.pubMu.Unlock()
	log.Printf("fleet: release store takes publishes from now on — no more stable lookups on GitHub")
	return nil
}

// publishedTTL: how long a read of the mark and the pointer is trusted (both
// change only on a publish; /version asks on every client check).
const publishedTTL = 5 * time.Second

// PublishedStable is StableLocal: the store's stable, and whether a publish
// has landed (then it is the only answer, even before its first pointer).
func (rs *ReleaseStore) PublishedStable() (string, bool) {
	rs.pubMu.Lock()
	defer rs.pubMu.Unlock()
	if time.Since(rs.pubAt) < publishedTTL {
		return rs.pubSHA, rs.pubOn
	}
	rs.pubAt, rs.pubSHA, rs.pubOn = time.Now(), "", rs.published()
	if rs.pubOn {
		rs.pubSHA = rs.stable().SHA
	}
	return rs.pubSHA, rs.pubOn
}

// published: the store has taken a publish.
func (rs *ReleaseStore) published() bool {
	_, err := os.Stat(filepath.Join(rs.Dir, releasePublished))
	return err == nil
}

// PublishedSeen is StableLocal: sha is a stable release this store holds.
func (rs *ReleaseStore) PublishedSeen(sha string) bool {
	if _, on := rs.PublishedStable(); !on || !release.ValidSHA(sha) || !rs.Has(sha) {
		return false
	}
	m := rs.manifest(sha)
	return m != nil && m.Seq >= 1
}

// PublishedTree is StableLocal: every file of sha's release.
func (rs *ReleaseStore) PublishedTree(sha string) (map[string][]byte, error) {
	base := rs.dir(sha)
	if base == "" {
		return nil, errStableNotFound
	}
	return treeFiles(filepath.Join(base, release.TreeName))
}
