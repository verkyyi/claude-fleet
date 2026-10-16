package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// TestMacLanePrune reproduces #4494: Linux advances past retention while
// stable-macos still names a fully published, signed release on the same PVC.
func TestMacLanePrune(t *testing.T) {
	p := newPublishRig(t)
	p.rs.Keep = 3
	tok := p.oidc.token(nil)
	var shas []string
	prev := ""
	for i := 0; i < 9; i++ {
		sha := p.repo.commit(fmt.Sprintf("release-%d", i), nil)
		if code, body := p.publish(tok, sha, prev, nil, nil); code != 200 {
			t.Fatalf("publish: %d %s", code, body)
		}
		shas = append(shas, sha)
		if i == 0 {
			if code, body := p.publishMac(tok, sha); code != 200 {
				t.Fatalf("publish Mac: %d %s", code, body)
			}
		}
		prev = sha
	}
	// A second replica/restart has no in-memory lane cache or promotion state.
	other := &ReleaseStore{Dir: p.rs.Dir, Root: p.pub, Repo: p.rs.Repo, Keep: p.rs.Keep}
	for i := 0; i < 2; i++ {
		other.prune()
		p.rs.prune()
	}
	if got := other.MacStableSHA(); got != shas[0] {
		t.Fatalf("prune lost the published Mac lane: got %q, want %s", got, shas[0])
	}
	p.h.srv.Releases = other
	if got := p.stableFor(t, "darwin"); got != shas[0] {
		t.Fatalf("darwin = %s, want %s", got, shas[0])
	}
	if resp, _ := getBody(t, p.h.http.URL+release.Path+"stable?platform=darwin"); resp.Header.Get(ReleaseRefHeader) != RefStableMacOS {
		t.Fatal("darwin lost the Mac lane header")
	}
	if got := p.stableFor(t, "linux"); got != prev {
		t.Fatalf("linux = %s, want %s", got, prev)
	}
	if v := p.version(t); v["client_version_macos"] != shas[0] || v["client_url_macos"] != p.h.http.URL+"/install/stable/"+shas[0] || v["stable_macos_behind"] != float64(len(shas)-1) {
		t.Fatalf("/version lost the Mac lane or lag: %v", v)
	}
	// Only Keep full releases plus the Mac target survive. A chain proof must
	// not make a deleted tree/installer count as a downloadable release.
	for i, sha := range shas {
		want := i == 0 || i >= len(shas)-other.Keep
		if got := other.Has(sha); got != want {
			t.Errorf("Has release %d = %v, want %v", i, got, want)
		}
		if !want {
			if _, err := os.Stat(filepath.Join(other.Dir, sha)); !os.IsNotExist(err) {
				t.Errorf("old build directory %d retained or unreadable: %v", i, err)
			}
			if resp, _ := getBody(t, p.h.http.URL+release.Path+sha); resp.StatusCode != 404 {
				t.Errorf("proof-only release %d was served: %d", i, resp.StatusCode)
			}
		}
	}
	if ch := other.chain(prev); len(ch) != other.Keep {
		t.Fatalf("legacy full-build reader's boundary changed: %v", ch)
	}
	// An already broken legacy volume cannot be repaired by repeating the
	// historical Mac publish. A normal, verified newer lane publish can recover.
	must(t, os.Remove(other.chainProofPath(shas[2])))
	p.rs.macAt = time.Time{}
	p.h.srv.Releases = p.rs
	if got := p.stableFor(t, "darwin"); got != prev {
		t.Fatalf("legacy gap: darwin = %s, want fallback %s", got, prev)
	}
	if resp, _ := getBody(t, p.h.http.URL+release.Path+"stable?platform=darwin"); resp.Header.Get(ReleaseRefHeader) != "" {
		t.Fatal("unverifiable legacy lane advertised as Mac")
	}
	if v := p.version(t); v["client_version_macos"] != nil || v["client_url_macos"] != nil {
		t.Fatalf("legacy gap advertised a Mac lane: %v", v)
	}
	if code, body := p.publishMac(tok, shas[0]); code != 409 {
		t.Fatalf("legacy gap repeat publish: %d %s", code, body)
	}
	if code, body := p.publishMac(tok, prev); code != 200 {
		t.Fatalf("verified newer lane recovery: %d %s", code, body)
	}
	if got := other.MacStableSHA(); got != prev { // pointer change beats its TTL
		t.Fatalf("other replica did not see recovered lane: %s", got)
	}
}

// A small signed store fixture: five sequential releases, Mac at the first.
// Callers choose when to prune and deliberately damage only their temp volume.
func macProofRig(t *testing.T) (*releaseRig, []string) {
	t.Helper()
	r := newReleaseRig(t)
	r.rs.Source, r.rs.Keep = nil, 100
	var shas []string
	prev := ""
	for i := 1; i <= 5; i++ {
		sha := fmt.Sprintf("%040x", i)
		must(t, r.rs.publish(sha, map[string][]byte{"bin/fleet": []byte("fleet")}, nil,
			time.Now().Add(time.Duration(i)*time.Second), release.Seal{Prev: prev, Seq: int64(i)}))
		shas, prev = append(shas, sha), sha
	}
	setStable(t, r.rs, prev, 5)
	_, err := r.rs.moveMac(shas[0])
	must(t, err)
	return r, shas
}

func TestMacLaneProofRefusals(t *testing.T) {
	for _, damage := range []string{"missing", "partial", "signature", "repo", "sha", "seq", "prev", "untrusted", "mac-seq", "stable-seq", "foreign", "unsealed", "missing-target"} {
		t.Run(damage, func(t *testing.T) {
			r, shas := macProofRig(t)
			r.rs.Keep = 2
			r.rs.prune()
			path := r.rs.chainProofPath(shas[1])
			p, err := r.rs.readChainProof(shas[1])
			must(t, err)
			var m release.Manifest
			must(t, json.Unmarshal(p.Manifest, &m))
			key := r.key
			switch damage {
			case "missing":
				must(t, os.Remove(path))
			case "partial":
				must(t, os.WriteFile(path, []byte(`{"manifest":`), 0o644))
			case "mac-seq":
				must(t, os.WriteFile(filepath.Join(r.dir, releaseStableMacOS), []byte(jsonOf(t, stablePointer{shas[0], 2})), 0o644))
			case "stable-seq":
				setStable(t, r.rs, shas[4], 99)
			case "foreign":
				// A valid signed release with the right seq, but no signed edge
				// from this stable. Possession is not publication ancestry.
				foreign := fmt.Sprintf("%040x", 99)
				r.rs.Keep = 100
				must(t, r.rs.publish(foreign, map[string][]byte{"bin/fleet": []byte("foreign")}, nil, time.Now(), release.Seal{Seq: 1}))
				must(t, os.WriteFile(filepath.Join(r.dir, releaseStableMacOS), []byte(jsonOf(t, stablePointer{foreign, 1})), 0o644))
			case "missing-target":
				must(t, os.RemoveAll(filepath.Join(r.dir, shas[0])))
			default:
				switch damage {
				case "repo":
					m.Repo = "foreign/repo"
				case "sha":
					m.SHA = shas[0]
				case "seq":
					m.Seq = 1
				case "prev":
					m.Prev = "../../outside"
				case "unsealed":
					m.Seq = 0
				case "untrusted":
					_, key = newKey(t)
					m.Key = release.KeyID(key.Public().(ed25519.PublicKey))
				}
				p.Manifest = []byte(jsonOf(t, m))
				p.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(key, p.Manifest))
				if damage == "signature" {
					p.Signature = "invalid"
				}
				must(t, os.WriteFile(path, []byte(jsonOf(t, p)), 0o644))
			}
			other := &ReleaseStore{Dir: r.dir, Root: r.pub, Repo: r.rs.Repo}
			if got := other.MacStableSHA(); got != "" {
				t.Fatalf("accepted %s proof/pointer: %s", damage, got)
			}
			// Read validation and publishing use the same proof gate. A bad
			// Mac pointer alone may be repaired by an explicit valid publish.
			if damage != "mac-seq" && damage != "foreign" {
				if _, err := other.moveMac(shas[0]); err == nil {
					t.Fatalf("published through %s", damage)
				}
			}
			if damage == "foreign" {
				if _, err := other.moveMac(other.macPointer().SHA); err == nil {
					t.Fatal("published a signed foreign branch")
				}
			}
		})
	}
}

func TestMacLaneProofSharedPrune(t *testing.T) {
	r, shas := macProofRig(t)
	r.rs.Keep = 2
	other := &ReleaseStore{Dir: r.dir, Root: r.pub, Repo: r.rs.Repo, Keep: 2}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 12; i++ {
			reader := &ReleaseStore{Dir: r.dir, Root: r.pub, Repo: r.rs.Repo}
			if got := reader.MacStableSHA(); got != shas[0] {
				t.Errorf("read during prune lost lane: %s", got)
			}
		}
	}()
	for _, rs := range []*ReleaseStore{r.rs, other} {
		wg.Add(1)
		go func(rs *ReleaseStore) {
			defer wg.Done()
			for i := 0; i < 3; i++ {
				rs.prune()
			}
		}(rs)
	}
	wg.Wait()
	if got := other.MacStableSHA(); got != shas[0] {
		t.Fatalf("concurrent prune lost lane: %s", got)
	}
	if r.rs.Has(shas[1]) || r.rs.Has(shas[2]) {
		t.Fatal("concurrent prune retained old large artifacts")
	}
	// A failed proof write must retain the full build instead of severing it.
	r2, shas2 := macProofRig(t)
	must(t, os.WriteFile(filepath.Join(r2.dir, releaseChainDir), []byte("not a directory"), 0o644))
	r2.rs.Keep = 2
	r2.rs.prune()
	if !r2.rs.Has(shas2[1]) || r2.rs.MacStableSHA() != shas2[0] {
		t.Fatal("failed proof write broke the chain")
	}
}

func TestMacLaneProofRollback(t *testing.T) {
	r, shas := macProofRig(t)
	other := &ReleaseStore{Dir: r.dir, Root: r.pub, Repo: r.rs.Repo}
	if _, err := r.rs.moveMac(shas[3]); err != nil {
		t.Fatal(err)
	}
	if other.MacStableSHA() != shas[3] {
		t.Fatal("replica did not prime the newer lane")
	}
	// Roll the stable pointer back below Mac: a warm other replica must
	// immediately stop serving Mac, even within its five-second cache TTL.
	setStable(t, r.rs, shas[1], 2)
	if got := other.MacStableSHA(); got != "" {
		t.Fatalf("rollback served the now-ahead lane: %s", got)
	}
	if _, err := other.moveMac(shas[1]); err == nil {
		t.Fatal("broken/rolled-back ancestry allowed the Mac lane to move backward")
	}
	setStable(t, r.rs, shas[4], 5)
	if _, err := r.rs.moveMac(shas[4]); err != nil {
		t.Fatal(err)
	}
	if other.MacStableSHA() != shas[4] {
		t.Fatal("replica did not observe the forward move")
	}
	// A content rollback is a NEW signed sequence; never resurrect the old
	// Mac pointer for that same sha/old seq through a saved proof.
	must(t, r.rs.reseal(shas[0], release.Seal{Prev: shas[4], Seq: 6}))
	setStable(t, r.rs, shas[0], 6)
	must(t, os.WriteFile(filepath.Join(r.dir, releaseStableMacOS), []byte(jsonOf(t, stablePointer{shas[0], 1})), 0o644))
	if got := other.MacStableSHA(); got != "" {
		t.Fatalf("reseal revived an obsolete Mac seq: %s", got)
	}
}

func TestMacLaneProofTrust(t *testing.T) {
	r, shas := macProofRig(t)
	rootPub, rootKey := newKey(t)
	cert := keyCert(t, rootKey, r.pub, release.RoleSign)
	// The train's signatures carry the root endorsement. The reader/pruner
	// below has only the public root, as production's train-signed hub does.
	for _, sha := range shas {
		base := r.rs.dir(sha)
		m := r.rs.manifest(sha)
		m.KeyChain = []release.Doc{cert}
		mb := []byte(jsonOf(t, m))
		must(t, os.WriteFile(filepath.Join(base, release.ManifestName), mb, 0o644))
		must(t, os.WriteFile(filepath.Join(base, release.SigName), []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(r.key, mb))), 0o644))
	}
	other := &ReleaseStore{Dir: r.dir, Root: rootPub, Repo: r.rs.Repo, Keep: 2}
	other.prune()
	if got := other.MacStableSHA(); got != shas[0] || other.Has(shas[1]) {
		t.Fatalf("train-signed proof not usable without private key: lane %s", got)
	}
	revoked := filepath.Join(t.TempDir(), "revoked.json")
	must(t, os.WriteFile(revoked, []byte(jsonOf(t, revocation(t, rootKey, 1, release.KeyID(r.pub)))), 0o644))
	reader := &ReleaseStore{Dir: r.dir, Root: rootPub, Repo: r.rs.Repo, RevokedFile: revoked}
	if got := reader.MacStableSHA(); got != "" {
		t.Fatalf("revoked signer accepted from proof: %s", got)
	}
	if _, err := reader.moveMac(shas[0]); err == nil {
		t.Fatal("revoked signer accepted on lane publish")
	}
	// Revocation must not disable artifact retention. Another store still
	// archives only bytes; it does not confer trust on them by pruning.
	r2, shas2 := macProofRig(t)
	wrongRoot, _ := newKey(t)
	pruner := &ReleaseStore{Dir: r2.dir, Root: wrongRoot, Repo: r2.rs.Repo, Keep: 2}
	pruner.prune()
	if pruner.Has(shas2[1]) || pruner.MacStableSHA() != "" {
		t.Fatal("untrusted links either retained artifacts or gained trust by pruning")
	}
}
