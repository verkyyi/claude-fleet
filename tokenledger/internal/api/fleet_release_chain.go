package api

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// Keep the original signed bytes before deleting a release's large artifacts
// (#4494). Proofs are not builds: Has, downloads and publish still require the
// full release. No proof can bridge a gap that an older pruner already made.
// Both fields live in ONE atomically replaced object on the shared volume;
// []byte preserves the manifest's exact bytes through JSON encoding.
const releaseChainDir = "chain"

type releaseChainProof struct {
	Manifest  []byte `json:"manifest"`
	Signature string `json:"signature"`
}

func (rs *ReleaseStore) chainProofPath(sha string) string {
	return filepath.Join(rs.Dir, releaseChainDir, sha+".json")
}

func (rs *ReleaseStore) readChainProof(sha string) (releaseChainProof, error) {
	var p releaseChainProof
	b, err := os.ReadFile(rs.chainProofPath(sha))
	if err == nil {
		err = json.Unmarshal(b, &p)
	}
	return p, err
}

// Read one build, never a manifest and signature from different current IDs.
// A prune racing this read has already saved the proof before removing it.
func (rs *ReleaseStore) readChainLink(sha string) (releaseChainProof, error) {
	if !release.ValidSHA(sha) {
		return releaseChainProof{}, fmt.Errorf("invalid chain sha")
	}
	if base := rs.dir(sha); base != "" {
		mb, err := os.ReadFile(filepath.Join(base, release.ManifestName))
		if err == nil {
			sig, err := os.ReadFile(filepath.Join(base, release.SigName))
			if err == nil {
				return releaseChainProof{mb, string(sig)}, nil
			}
			if !os.IsNotExist(err) {
				return releaseChainProof{}, err
			}
		} else if !os.IsNotExist(err) {
			return releaseChainProof{}, err
		}
	}
	return rs.readChainProof(sha)
}

func (rs *ReleaseStore) verifyChainLink(sha string, p releaseChainProof, revs []release.Doc) *release.Manifest {
	if rs.anchor() == nil {
		return nil
	}
	m, _, err := release.VerifyTrusted(rs.anchor(), p.Manifest, p.Signature, revs, nil)
	if err != nil || m.SHA != sha || m.Repo != rs.Repo || m.Seq < 1 || (m.Prev != "" && !release.ValidSHA(m.Prev)) {
		return nil
	}
	return m
}

// archiveChainLink runs BEFORE RemoveAll. A failure retains the full release;
// another replica's identical prune is harmless. Nothing is signed or rebuilt.
// Small proofs are retained independently of Keep, even after the lane moves:
// deleting them using one replica's stale pointer could break another reader.
func (rs *ReleaseStore) archiveChainLink(sha string) error {
	p, err := rs.readChainLink(sha)
	if err != nil {
		return err
	}
	var m release.Manifest
	if err := json.Unmarshal(p.Manifest, &m); err != nil {
		return err
	}
	if m.Seq == 0 { // an unpromoted build is not a stable-chain link
		return nil
	}
	// Archiving grants no trust: readers verify every link. Keep even a
	// revoked signer's original bytes so revocation does not force indefinite
	// retention of its large artifacts or require signing anything anew.
	dir := filepath.Join(rs.Dir, releaseChainDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return replaceFile(rs.chainProofPath(sha), ".proof-"+newBuildID(time.Now()), b)
}

// macChain is anchored to the actual stable pointer, not to a claimed seq or
// mere possession of a signed foreign release. Every edge must be the signed
// prev with the next lower seq. A resealed rollback cannot loop into old proof.
func (rs *ReleaseStore) macChain(cur stablePointer, target string) []*release.Manifest {
	var out []*release.Manifest
	revs := rs.revocations()
	for cur.SHA != "" && cur.Seq > 0 {
		p, err := rs.readChainLink(cur.SHA)
		if err != nil {
			break
		}
		m := rs.verifyChainLink(cur.SHA, p, revs)
		if m == nil || m.Seq != cur.Seq {
			break
		}
		out = append(out, m)
		if m.SHA == target {
			break
		}
		cur = stablePointer{SHA: m.Prev, Seq: m.Seq - 1}
	}
	return out
}
